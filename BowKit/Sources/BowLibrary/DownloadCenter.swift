import BowModel
import Foundation
import GrimmoryAPI
import Observation
import SwiftData

/// Where a book file can be downloaded from. `GrimmoryClient` is the real one; tests use a fake.
public protocol BookFileSource: Sendable {
    func downloadFile(bookID: Int64, fileID: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

extension GrimmoryClient: BookFileSource {}

/// Downloads books for offline reading and reports progress to the UI. State that must survive a relaunch
/// (`downloadState`, `localRelativePath`) lives on `BookFile`; progress is only in memory.
@MainActor
@Observable
public final class DownloadCenter {
    /// 0–1 for files downloading now, keyed by `BookFile.id`.
    public private(set) var progress: [UUID: Double] = [:]
    /// Why the last download of a file failed, keyed by `BookFile.id`.
    public private(set) var failures: [UUID: String] = [:]

    private let context: ModelContext
    private let storage: BookStorage
    private let source: @MainActor (Account) -> (any BookFileSource)?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(context: ModelContext, storage: BookStorage = .standard,
                source: @escaping @MainActor (Account) -> (any BookFileSource)?) {
        self.context = context
        self.storage = storage
        self.source = source
        resetInterruptedDownloads()
    }

    /// Starts downloading `file` unless it's already downloading or downloaded.
    @discardableResult
    public func download(_ file: BookFile) -> Task<Void, Never>? {
        guard file.downloadState != .downloading, file.downloadState != .downloaded else { return tasks[file.id] }
        guard let book = file.book, let bookID = book.remoteID, let fileID = file.remoteFileID,
              let account = book.account, let source = source(account)
        else {
            failures[file.id] = "This book can't be downloaded."
            return nil
        }

        let fileKey = file.id
        let bookKey = book.id
        let format = file.format
        file.downloadState = .downloading
        failures[fileKey] = nil
        progress[fileKey] = 0
        try? context.save()

        // The center lives as long as the app, so holding it strongly here is fine.
        let task = Task { [storage, self] in
            do {
                let temporary = try await source.downloadFile(bookID: bookID, fileID: fileID) { fraction in
                    Task { @MainActor [self] in
                        if progress[fileKey] != nil { progress[fileKey] = fraction }
                    }
                }
                let path = try storage.store(downloaded: temporary, bookID: bookKey, format: format)
                let file = storage.url(forRelativePath: path).path(percentEncoded: false)
                let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.int64Value
                finish(fileKey) { file in
                    file.localRelativePath = path
                    file.sizeBytes = size ?? file.sizeBytes
                    file.downloadState = .downloaded
                }
            } catch is CancellationError {
                finish(fileKey) { $0.downloadState = .remote }
            } catch {
                failures[fileKey] = Self.message(for: error)
                finish(fileKey) { $0.downloadState = .failed }
            }
        }
        tasks[fileKey] = task
        return task
    }

    public func cancel(_ file: BookFile) {
        tasks[file.id]?.cancel()
    }

    /// Deletes the downloaded copy. The book stays in the library and can be downloaded again.
    public func removeDownload(_ file: BookFile) {
        tasks[file.id]?.cancel()
        if let book = file.book { storage.removeFiles(for: book.id) }
        file.localRelativePath = nil
        file.downloadState = .remote
        try? context.save()
    }

    private func finish(_ fileID: UUID, _ update: (BookFile) -> Void) {
        tasks[fileID] = nil
        progress[fileID] = nil
        let descriptor = FetchDescriptor<BookFile>(predicate: #Predicate { $0.id == fileID })
        guard let file = try? context.fetch(descriptor).first else { return }
        update(file)
        try? context.save()
    }

    /// A download that was running when the app quit never finished.
    private func resetInterruptedDownloads() {
        let downloading = BookFile.DownloadState.downloading.rawValue
        let descriptor = FetchDescriptor<BookFile>(predicate: #Predicate { $0.downloadStateRaw == downloading })
        for file in (try? context.fetch(descriptor)) ?? [] { file.downloadState = .remote }
        try? context.save()
    }

    static func message(for error: any Error) -> String {
        switch error {
        case GrimmoryError.forbidden: "Your Grimmory account isn't allowed to download books."
        case GrimmoryError.notFound: "The server no longer has this file."
        case GrimmoryError.signedOut: "You've been signed out of this server."
        case GrimmoryError.webPageInsteadOfAPI: "The server's sign-in proxy needs you to sign in again."
        case let error as URLError where error.code == .notConnectedToInternet: "You're offline."
        default: error.localizedDescription
        }
    }
}
