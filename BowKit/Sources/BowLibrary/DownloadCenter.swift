import BowModel
import Foundation
import GrimmoryAPI
import Observation
import SwiftData

/// Signs download requests for a server. `GrimmoryClient` is the real one; tests use a fake.
public protocol BookFileSource: Sendable {
    func downloadRequest(bookID: Int64, fileID: Int64) async throws -> URLRequest
}

extension GrimmoryClient: BookFileSource {}

/// Downloads books for offline reading through a `FileTransfer` (a background `URLSession` in the app) and reports
/// progress to the UI. State that must survive a relaunch (`downloadState`, `localRelativePath`) lives on
/// `BookFile`; progress is only in memory.
@MainActor
@Observable
public final class DownloadCenter {
    /// 0–1 for files downloading now, keyed by `BookFile.id`.
    public private(set) var progress: [UUID: Double] = [:]
    /// Why the last download of a file failed, keyed by `BookFile.id`.
    public private(set) var failures: [UUID: String] = [:]

    private let context: ModelContext
    private let storage: BookStorage
    private let transfer: any FileTransfer
    private let source: @MainActor (Account) -> (any BookFileSource)?

    public init(context: ModelContext, storage: BookStorage = .standard, transfer: any FileTransfer,
                source: @escaping @MainActor (Account) -> (any BookFileSource)?) {
        self.context = context
        self.storage = storage
        self.transfer = transfer
        self.source = source
        transfer.setHandler { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // Taken now, so a download started before the check finishes isn't mistaken for an interrupted one.
        let downloadingAtLaunch = Self.downloadingFiles(in: context).map(\.id)
        Task { await reconcile(downloadingAtLaunch) }
    }

    /// Starts downloading `file` unless it's already downloading or downloaded. The returned task finishes once
    /// the transfer has started, not when it completes.
    @discardableResult
    public func download(_ file: BookFile) -> Task<Void, Never>? {
        guard file.downloadState != .downloading, file.downloadState != .downloaded else { return nil }
        guard let book = file.book, let bookID = book.remoteID, let fileID = file.remoteFileID,
              let account = book.account, let source = source(account)
        else {
            failures[file.id] = "This book can't be downloaded."
            return nil
        }

        let id = file.id
        file.downloadState = .downloading
        failures[id] = nil
        progress[id] = 0
        try? context.save()

        return Task {
            do {
                transfer.start(try await source.downloadRequest(bookID: bookID, fileID: fileID), id: id)
            } catch {
                handle(.failed(id, error))
            }
        }
    }

    public func cancel(_ file: BookFile) {
        transfer.cancel(id: file.id)
    }

    /// Deletes the downloaded copy. The book stays in the library and can be downloaded again.
    public func removeDownload(_ file: BookFile) {
        transfer.cancel(id: file.id)
        if let book = file.book { storage.removeFiles(for: book.id) }
        file.localRelativePath = nil
        file.downloadState = .remote
        progress[file.id] = nil
        try? context.save()
    }

    func handle(_ event: TransferEvent) {
        switch event {
        case let .progress(id, fraction):
            if progress[id] != nil { progress[id] = fraction }

        case let .finished(id, temporary, statusCode, mimeType):
            guard let file = file(id), let book = file.book else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            do {
                try GrimmoryClient.checkDownload(statusCode: statusCode, mimeType: mimeType)
                let path = try storage.store(downloaded: temporary, bookID: book.id, format: file.format)
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: storage.url(forRelativePath: path).path(percentEncoded: false))
                file.localRelativePath = path
                file.sizeBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? file.sizeBytes
                file.downloadState = .downloaded
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                failures[id] = Self.message(for: error)
                file.downloadState = .failed
            }
            progress[id] = nil
            try? context.save()

        case let .failed(id, error):
            guard let file = file(id) else { return }
            if error is CancellationError {
                file.downloadState = .remote
            } else {
                failures[id] = Self.message(for: error)
                file.downloadState = .failed
            }
            progress[id] = nil
            try? context.save()
        }
    }

    private func file(_ id: UUID) -> BookFile? {
        try? context.fetch(FetchDescriptor<BookFile>(predicate: #Predicate { $0.id == id })).first
    }

    private static func downloadingFiles(in context: ModelContext) -> [BookFile] {
        let downloading = BookFile.DownloadState.downloading.rawValue
        let descriptor = FetchDescriptor<BookFile>(predicate: #Predicate { $0.downloadStateRaw == downloading })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Of the files that were downloading when the app launched, those still running in the background session
    /// keep going; the rest were interrupted (the session was reset, or the app was deleted and restored).
    private func reconcile(_ downloadingAtLaunch: [UUID]) async {
        let active = await transfer.activeIDs()
        for id in downloadingAtLaunch {
            guard let file = file(id), file.downloadState == .downloading else { continue }
            if active.contains(id) {
                progress[id] = progress[id] ?? 0
            } else {
                file.downloadState = .remote
            }
        }
        try? context.save()
    }

    static func message(for error: any Error) -> String {
        switch error {
        case GrimmoryError.forbidden: "Your Grimmory account isn't allowed to download books."
        case GrimmoryError.notFound: "The server no longer has this file."
        case GrimmoryError.unauthorized, GrimmoryError.signedOut: "You've been signed out of this server."
        case GrimmoryError.webPageInsteadOfAPI: "The server's sign-in proxy needs you to sign in again."
        case let error as URLError where error.code == .notConnectedToInternet: "You're offline."
        default: error.localizedDescription
        }
    }
}
