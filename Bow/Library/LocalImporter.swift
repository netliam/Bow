import BowLibrary
import BowModel
import DCEpubReaderKit
import Foundation
import Observation
import SwiftData

/// Adds EPUB files to the library from Files, "Open in Bow", or drag and drop. Books are copied into Bow's
/// storage and filed under the "On This Device" account, so they work without a server.
@MainActor
@Observable
final class LocalImporter {
    /// The last import problem, worth telling the user about.
    var problem: String?
    private(set) var isImporting = false

    private let context: ModelContext
    private let storage: BookStorage

    init(context: ModelContext, storage: BookStorage = .standard) {
        self.context = context
        self.storage = storage
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            isImporting = true
            defer { isImporting = false }
            for url in urls { await importFile(url) }
        }
    }

    private struct Metadata: Sendable {
        var title: String?
        var authors: [String]
        var publisher: String?
    }

    private func importFile(_ url: URL) async {
        let name = url.deletingPathExtension().lastPathComponent
        let bookID = UUID()
        do {
            let copy = try copyIn(url)
            let path = try storage.store(downloaded: copy, bookID: bookID, format: .epub)
            let metadata = try await Task.detached(priority: .userInitiated) { [storage] in
                let epub = try DCEpubParser.parse(from: try storage.unzippedEPUB(relativePath: path))
                Self.saveCover(of: epub, to: storage.directory(for: bookID))
                return Metadata(title: epub.metadata.title, authors: epub.metadata.creators,
                                publisher: epub.metadata.publisher)
            }.value

            let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let book = Book(id: bookID, account: try localAccount(),
                            title: title?.isEmpty == false ? title! : name, authors: metadata.authors)
            let file = BookFile(book: book, format: .epub, fileName: url.lastPathComponent)
            file.localRelativePath = path
            file.downloadState = .downloaded
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: storage.url(forRelativePath: path).path(percentEncoded: false))
            file.sizeBytes = (attributes?[.size] as? NSNumber)?.int64Value
            context.insert(book)
            context.insert(file)
            try context.save()
            problem = nil
        } catch {
            storage.removeFiles(for: bookID)
            problem = "Couldn't add “\(name)”: it isn't an EPUB Bow can read."
        }
    }

    /// Copies the file somewhere Bow owns. Files from other apps are security-scoped; "Open in" copies land in
    /// `Documents/Inbox`, which is cleaned up afterwards.
    private func copyIn(_ url: URL) throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString).epub")
        try FileManager.default.copyItem(at: url, to: copy)
        if url.path(percentEncoded: false).contains("/Documents/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
        return copy
    }

    private func localAccount() throws -> Account {
        let local = Account.Kind.local.rawValue
        if let account = try context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.kindRaw == local })).first {
            return account
        }
        let account = Account(kind: .local, displayName: "On This Device")
        context.insert(account)
        return account
    }

    /// Copies the EPUB's cover image (the `cover-image` item, or the one EPUB 2's `<meta name="cover">` names) to
    /// `<book folder>/cover`, where `CoverView` looks for local books' covers.
    nonisolated private static func saveCover(of epub: DCEpubBook, to folder: URL) {
        let item = epub.manifest.first { ($0.properties ?? "").split(separator: " ").contains("cover-image") }
            ?? epub.manifest.first { $0.id == epub.metadata.coverHint && $0.mediaType.hasPrefix("image/") }
        guard let item else { return }
        try? FileManager.default.copyItem(at: epub.resourceURL(forHref: item.href), to: folder.appending(path: "cover"))
    }
}
