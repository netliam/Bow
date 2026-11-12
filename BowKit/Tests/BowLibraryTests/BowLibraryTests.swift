import Foundation
import SwiftData
import Testing
import ZIPFoundation
import GrimmoryAPI
@testable import BowLibrary
@testable import BowModel

private func temporaryDirectory() -> URL {
    // A space in the path, like the app's real "Application Support" folder.
    let url = FileManager.default.temporaryDirectory.appending(path: "Bow Library Tests \(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A minimal EPUB-shaped zip: mimetype, container.xml and one chapter.
private func makeEPUB() throws -> URL {
    let file = temporaryDirectory().appending(path: "book.epub")
    let archive = try Archive(url: file, accessMode: .create)
    for (path, text) in [
        ("mimetype", "application/epub+zip"),
        ("META-INF/container.xml", "<container/>"),
        ("OEBPS/chapter1.xhtml", "<html><body><p>Call me Ishmael.</p></body></html>"),
    ] {
        let data = Data(text.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
    return file
}

@Suite struct BookStorageTests {
    @Test func storesUnzipsAndRemoves() throws {
        let storage = BookStorage(root: temporaryDirectory().appending(path: "Books"))
        let bookID = UUID()

        let path = try storage.store(downloaded: try makeEPUB(), bookID: bookID, format: .epub)
        #expect(path == "\(bookID.uuidString)/book.epub")
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: path).path(percentEncoded: false)))

        let folder = try storage.unzippedEPUB(relativePath: path)
        let chapter = try String(contentsOf: folder.appending(path: "OEBPS/chapter1.xhtml"), encoding: .utf8)
        #expect(chapter.contains("Ishmael"))
        // Second call reuses the unzipped folder.
        #expect(try storage.unzippedEPUB(relativePath: path) == folder)

        let excluded = try storage.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)

        storage.removeFiles(for: bookID)
        #expect(!FileManager.default.fileExists(atPath: storage.directory(for: bookID).path(percentEncoded: false)))
    }
}

struct FakeFileSource: BookFileSource {
    var fail: (any Error)? = nil

    func downloadRequest(bookID: Int64, additionalFileID: Int64?) async throws -> URLRequest {
        if let fail { throw fail }
        return URLRequest(url: URL(string: "https://books.example.com/api/v1/books/\(bookID)/download")!)
    }
}

/// Records started transfers; tests deliver their events by hand.
final class FakeTransfer: FileTransfer, @unchecked Sendable {
    var started: [UUID: URLRequest] = [:]
    var cancelled: [UUID] = []
    var active: Set<UUID> = []

    func setHandler(_ handler: @escaping @Sendable (TransferEvent) -> Void) {}
    func start(_ request: URLRequest, id: UUID) { started[id] = request }
    func cancel(id: UUID) { cancelled.append(id) }
    func activeIDs() async -> Set<UUID> { active }
}

@MainActor
@Suite struct DownloadCenterTests {
    let context: ModelContext
    let file: BookFile
    let storage = BookStorage(root: temporaryDirectory().appending(path: "Books"))
    let transfer = FakeTransfer()

    init() throws {
        context = ModelContext(try BowStore.makeContainer(inMemory: true))
        let account = Account(kind: .grimmory, displayName: "Home", serverURL: URL(string: "https://books.example.com"))
        let book = Book(account: account, remoteID: 5, title: "Moby-Dick")
        file = BookFile(book: book, format: .epub, remoteFileID: 50)
        context.insert(account)
        context.insert(book)
        context.insert(file)
        try context.save()
    }

    private func center(_ source: FakeFileSource = FakeFileSource()) -> DownloadCenter {
        DownloadCenter(context: context, storage: storage, transfer: transfer) { _ in source }
    }

    @Test func startsATransferAndStoresTheFinishedFile() async throws {
        let center = center()
        await center.download(file)?.value
        #expect(file.downloadState == .downloading)
        #expect(transfer.started[file.id]?.url?.path() == "/api/v1/books/5/download")

        center.handle(.progress(file.id, 0.5))
        #expect(center.progress[file.id] == 0.5)

        center.handle(.finished(file.id, file: try makeEPUB(), statusCode: 200, mimeType: "application/epub+zip"))

        #expect(file.downloadState == .downloaded)
        let path = try #require(file.localRelativePath)
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: path).path(percentEncoded: false)))
        #expect((file.sizeBytes ?? 0) > 0)
        #expect(center.progress.isEmpty)
    }

    @Test func forbiddenDownloadExplainsWhy() async throws {
        let center = center()
        await center.download(file)?.value

        center.handle(.finished(file.id, file: try makeEPUB(), statusCode: 403, mimeType: "application/json"))

        #expect(file.downloadState == .failed)
        #expect(center.failures[file.id] == "Your Grimmory account isn't allowed to download books.")
    }

    @Test func proxyPageIsNotStoredAsABook() async throws {
        let center = center()
        await center.download(file)?.value

        center.handle(.finished(file.id, file: try makeEPUB(), statusCode: 200, mimeType: "text/html"))

        #expect(file.downloadState == .failed)
        #expect(file.localRelativePath == nil)
    }

    @Test func signingFailureNeverStartsATransfer() async throws {
        let center = center(FakeFileSource(fail: GrimmoryError.signedOut))
        await center.download(file)?.value

        #expect(transfer.started.isEmpty)
        #expect(file.downloadState == .failed)
        #expect(center.failures[file.id] == "You've been signed out of this server.")
    }

    @Test func cancellingReturnsToNotDownloaded() async throws {
        let center = center()
        await center.download(file)?.value

        center.cancel(file)
        center.handle(.failed(file.id, CancellationError()))

        #expect(transfer.cancelled == [file.id])
        #expect(file.downloadState == .remote)
        #expect(center.failures.isEmpty)
    }

    @Test func removingADownloadKeepsTheBook() async throws {
        let center = center()
        await center.download(file)?.value
        center.handle(.finished(file.id, file: try makeEPUB(), statusCode: 200, mimeType: "application/epub+zip"))

        center.removeDownload(file)

        #expect(file.downloadState == .remote)
        #expect(file.localRelativePath == nil)
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
    }

    @Test func relaunchKeepsLiveTransfersAndResetsLostOnes() async throws {
        let other = BookFile(book: file.book, format: .pdf, remoteFileID: 51)
        context.insert(other)
        file.downloadState = .downloading
        other.downloadState = .downloading
        try context.save()
        transfer.active = [file.id]  // Still running in the background session.

        let center = center()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        #expect(file.downloadState == .downloading)
        #expect(center.progress[file.id] == 0)
        #expect(other.downloadState == .remote)
    }
}
