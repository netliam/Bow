import Foundation
import SwiftData
import Testing
import ZIPFoundation
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

    @Test func readingFractionWeighsChaptersBySize() {
        #expect(ReadingFraction.estimate(chapterSizes: [100, 300, 600], spineIndex: 0) == 0)
        #expect(ReadingFraction.estimate(chapterSizes: [100, 300, 600], spineIndex: 1) == 0.1)
        #expect(ReadingFraction.estimate(chapterSizes: [100, 300, 600], spineIndex: 2) == 0.4)
        #expect(ReadingFraction.estimate(chapterSizes: [100, 300, 600], spineIndex: 9) == 1)
        #expect(ReadingFraction.estimate(chapterSizes: [], spineIndex: 3) == 0)
    }
}

private struct FakeFileSource: BookFileSource {
    var result: @Sendable () throws -> URL

    func downloadFile(bookID: Int64, fileID: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        progress(0.5)
        return try result()
    }
}

@MainActor
@Suite struct DownloadCenterTests {
    let context: ModelContext
    let file: BookFile
    let storage = BookStorage(root: temporaryDirectory().appending(path: "Books"))

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

    @Test func downloadsIntoStorage() async throws {
        let epub = try makeEPUB()
        let center = DownloadCenter(context: context, storage: storage) { _ in FakeFileSource { epub } }

        await center.download(file)?.value

        #expect(file.downloadState == .downloaded)
        let path = try #require(file.localRelativePath)
        #expect(FileManager.default.fileExists(atPath: storage.url(forRelativePath: path).path(percentEncoded: false)))
        #expect((file.sizeBytes ?? 0) > 0)
        #expect(center.progress.isEmpty)
        #expect(center.failures.isEmpty)
    }

    @Test func forbiddenDownloadExplainsWhy() async throws {
        let center = DownloadCenter(context: context, storage: storage) { _ in
            FakeFileSource { throw GrimmoryErrorStub.forbidden }
        }

        await center.download(file)?.value

        #expect(file.downloadState == .failed)
        #expect(center.failures[file.id] == "Your Grimmory account isn't allowed to download books.")
    }

    @Test func removingADownloadKeepsTheBook() async throws {
        let epub = try makeEPUB()
        let center = DownloadCenter(context: context, storage: storage) { _ in FakeFileSource { epub } }
        await center.download(file)?.value

        center.removeDownload(file)

        #expect(file.downloadState == .remote)
        #expect(file.localRelativePath == nil)
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
    }

    @Test func interruptedDownloadsResetOnLaunch() throws {
        file.downloadState = .downloading
        try context.save()

        _ = DownloadCenter(context: context, storage: storage) { _ in nil }

        #expect(file.downloadState == .remote)
    }
}

import GrimmoryAPI
private enum GrimmoryErrorStub {
    static let forbidden = GrimmoryError.forbidden
}
