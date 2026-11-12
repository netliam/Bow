import Foundation
import Synchronization

/// What happened to a transfer, keyed by the id it was started with (a `BookFile.id`).
public enum TransferEvent: Sendable {
    case progress(UUID, Double)
    /// The response arrived. `file` is a temporary copy the receiver must move or delete.
    case finished(UUID, file: URL, statusCode: Int, mimeType: String?)
    case failed(UUID, any Error)
}

/// Runs file downloads. The real one is a background `URLSession`; tests use a fake.
public protocol FileTransfer: AnyObject, Sendable {
    func setHandler(_ handler: @escaping @Sendable (TransferEvent) -> Void)
    func start(_ request: URLRequest, id: UUID)
    func cancel(id: UUID)
    /// Transfers still running, including ones that survived a relaunch.
    func activeIDs() async -> Set<UUID>
}

/// Downloads in a background `URLSession`, so they continue while Bow is suspended and are handed back after a
/// relaunch. The session sends the app's shared cookies, so servers behind a sign-in proxy work too.
public final class BackgroundURLSessionTransfer: NSObject, FileTransfer, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let identifier = "app.bow.downloads"

    private var session: URLSession!
    private let handler = Mutex<(@Sendable (TransferEvent) -> Void)?>(nil)
    /// Finished files waiting for their task's completion callback, by task id.
    private let finishedFiles = Mutex<[Int: URL]>([:])
    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    private let eventsCompletion = Mutex<(@Sendable () -> Void)?>(nil)

    public init(identifier: String = BackgroundURLSessionTransfer.identifier) {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpCookieStorage = .shared
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func setHandler(_ handler: @escaping @Sendable (TransferEvent) -> Void) {
        self.handler.withLock { $0 = handler }
    }

    /// Called by the system once all events for a relaunch have been delivered.
    public func setBackgroundEventsCompletion(_ completion: @escaping @Sendable () -> Void) {
        eventsCompletion.withLock { $0 = completion }
    }

    public func start(_ request: URLRequest, id: UUID) {
        let task = session.downloadTask(with: request)
        task.taskDescription = id.uuidString
        task.resume()
    }

    public func cancel(id: UUID) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == id.uuidString }.forEach { $0.cancel() }
        }
    }

    public func activeIDs() async -> Set<UUID> {
        Set(await session.allTasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }

    private func emit(_ event: TransferEvent) {
        handler.withLock { $0 }?(event)
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else {
            return
        }
        emit(.progress(id, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so move it now.
        let owned = FileManager.default.temporaryDirectory.appending(path: "download-\(UUID().uuidString)")
        if (try? FileManager.default.moveItem(at: location, to: owned)) != nil {
            finishedFiles.withLock { $0[downloadTask.taskIdentifier] = owned }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let file = finishedFiles.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            let cancelled = (error as? URLError)?.code == .cancelled
            emit(.failed(id, cancelled ? CancellationError() : error))
        } else if let file, let response = task.response as? HTTPURLResponse {
            emit(.finished(id, file: file, statusCode: response.statusCode, mimeType: response.mimeType))
        } else {
            emit(.failed(id, URLError(.badServerResponse)))
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = eventsCompletion.withLock { value -> (@Sendable () -> Void)? in
            defer { value = nil }
            return value
        }
        DispatchQueue.main.async { completion?() }
    }
}
