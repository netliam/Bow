import Foundation
import Synchronization

/// Where a reader is in an EPUB, as Grimmory stores it.
public struct GrimmoryEpubProgress: Sendable, Equatable {
    public var cfi: String?
    public var href: String?
    /// 0–100.
    public var percentage: Double
    /// When the server last recorded reading. Grimmory's spec merges two `EpubProgress` classes and drops their
    /// `updatedAt`, so this is the book's `lastReadTime`.
    public var lastReadTime: Date?
}

extension GrimmoryClient {
    /// Streams a downloaded file to disk and reports the fraction done.
    public typealias FileDownloader = @Sendable (URLRequest, _ progress: @escaping @Sendable (Double) -> Void)
        async throws -> (URL, HTTPURLResponse)

    // MARK: Downloads

    /// Downloads one of a book's files to a temporary location the caller must move. Needs the `canDownload`
    /// permission (else `.forbidden`). Grimmory can't resume downloads, so a failed one starts over.
    public func downloadFile(bookID: Int64, fileID: Int64,
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let url = serverURL.appending(path: "api/v1/books/\(bookID)/files/\(fileID)/download")

        func attempt(token: String) async throws -> (URL, HTTPURLResponse) {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return try await downloader(request, progress)
        }

        let token = try await session.validAccessToken()
        var (file, response) = try await attempt(token: token)
        if response.statusCode == 401 {
            try? FileManager.default.removeItem(at: file)
            (file, response) = try await attempt(token: try await session.refresh(replacing: token))
        }
        guard response.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw GrimmoryError(status: response.statusCode)
        }
        if response.mimeType == "text/html" {
            try? FileManager.default.removeItem(at: file)
            throw GrimmoryError.webPageInsteadOfAPI
        }
        return file
    }

    /// The default downloader: `URLSession.shared` (so a proxy's shared cookies are sent), with progress read
    /// from the task as it runs. The file is moved somewhere stable before returning.
    public static let urlSessionDownloader: FileDownloader = { request, progress in
        let delegate = DownloadProgressDelegate(onProgress: progress)
        let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        let owned = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: owned)
        guard let http = response as? HTTPURLResponse else { throw GrimmoryError.unexpectedResponse("not HTTP") }
        return (owned, http)
    }

    // MARK: Reading progress

    public func epubProgress(bookID: Int64) async throws -> GrimmoryEpubProgress? {
        let output = try await unwrapped { try await client.getBookProgress(path: .init(bookId: bookID)) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        let dto = try ok.body.json
        guard let epub = dto.epubProgress else { return nil }
        return GrimmoryEpubProgress(cfi: epub.cfi, href: epub.href, percentage: Double(epub.percentage),
                                    lastReadTime: dto.lastReadTime)
    }

    /// Records where the reader is in one file of a book. `cfi` is what Grimmory's web reader resumes from.
    public func updateEpubProgress(bookID: Int64, fileID: Int64, cfi: String?, href: String?,
                                   percentage: Double) async throws {
        let progress = Components.Schemas.BookFileProgress(
            bookFileId: fileID, positionData: cfi, positionHref: href,
            progressPercent: Float(min(max(percentage, 0), 100))
        )
        let output = try await unwrapped {
            try await client.updateBookProgress(path: .init(bookId: bookID), body: .json(.init(fileProgress: progress)))
        }
        guard case .ok = output else { throw GrimmoryError(status: statusCode(of: output)) }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void
    private let observation = Mutex<NSKeyValueObservation?>(nil)

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let onProgress = onProgress
        observation.withLock {
            $0 = task.progress.observe(\.fractionCompleted) { progress, _ in onProgress(progress.fractionCompleted) }
        }
    }
}
