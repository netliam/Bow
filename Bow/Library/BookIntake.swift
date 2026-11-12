import BowLibrary
import BowModel
import BowSync
import Foundation
import GrimmoryAPI
import Observation
import SwiftData

/// Where every book file entering Bow goes first: Files, "Open in Bow", the share sheet and drag and drop.
///
/// With no server, EPUBs are imported onto this device straight away. With one, the files are copied in and Bow
/// asks where they should go: this device, a Grimmory library, or Grimmory's bookdrop (`AddBooksSheet`).
@MainActor
@Observable
final class BookIntake {
    /// A file copied into Bow, waiting for a destination or uploading.
    struct StagedFile: Identifiable, Equatable {
        enum State: Equatable {
            case waiting, uploading, done
            case failed(String)
        }

        let id = UUID()
        let name: String
        let url: URL
        var state: State = .waiting

        var isEPUB: Bool { url.pathExtension.lowercased() == "epub" }
    }

    /// Files waiting to be sent somewhere. The add-books sheet shows while this isn't empty.
    var staged: [StagedFile] = []
    var problem: String?

    /// Formats Grimmory reads, and so can be uploaded. Only EPUBs can be kept on this device.
    static let acceptedExtensions: Set<String> = ["epub", "pdf", "cbz", "cbr", "cb7"]

    private let context: ModelContext
    private let importer: LocalImporter

    init(context: ModelContext, importer: LocalImporter) {
        self.context = context
        self.importer = importer
    }

    var hasServer: Bool {
        let grimmory = Account.Kind.grimmory.rawValue
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.kindRaw == grimmory })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    func receive(_ urls: [URL]) {
        let books = urls.filter { Self.acceptedExtensions.contains($0.pathExtension.lowercased()) }
        guard !books.isEmpty else {
            if !urls.isEmpty { problem = "Bow can add EPUB, PDF and comic files." }
            return
        }
        guard hasServer else {
            let epubs = books.filter { $0.pathExtension.lowercased() == "epub" }
            importer.importFiles(epubs)
            if epubs.count < books.count {
                problem = "Only EPUB books can be kept on this device. Connect a Grimmory server to add PDFs and comics."
            }
            return
        }
        for url in books {
            do {
                staged.append(StagedFile(name: url.lastPathComponent, url: try stage(url)))
            } catch {
                problem = "Couldn't read \(url.lastPathComponent)."
            }
        }
    }

    /// Imports the waiting EPUBs onto this device. Other formats stay in the list, to upload instead. (The importer
    /// copies the files itself; the temporary copies are left for the system to clean up.)
    func keepOnDevice() {
        importer.importFiles(staged.filter { $0.isEPUB && $0.state != .done }.map(\.url))
        staged.removeAll(where: \.isEPUB)
    }

    /// Uploads every waiting file, one at a time, then refreshes the library.
    func upload(to destination: GrimmoryUploadDestination, account: Account, sync: @escaping () async -> Void) async {
        guard let client = GrimmoryAccounts.client(for: account) else {
            problem = "Sign in to \(account.displayName) again to upload."
            return
        }
        for index in staged.indices where staged[index].state != .done {
            staged[index].state = .uploading
            do {
                try await client.upload(file: staged[index].url, fileName: staged[index].name, to: destination)
                staged[index].state = .done
            } catch {
                staged[index].state = .failed(Self.describe(error))
            }
        }
        // Grimmory adds a library upload in the background, a moment after answering: refresh once it has.
        if case .library = destination, staged.contains(where: { $0.state == .done }) {
            try? await Task.sleep(for: .seconds(3))
            await sync()
        }
    }

    /// Forgets the waiting files and deletes Bow's copies.
    func clear() {
        for file in staged { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        staged = []
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case GrimmoryError.unexpectedResponse(let message): message
        case GrimmoryError.forbidden: "Your account isn't allowed to upload there."
        case GrimmoryError.http(413): "The file is larger than the server accepts."
        default: error.localizedDescription
        }
    }

    /// Copies a file somewhere Bow owns, keeping its name: files from other apps are only readable for a moment.
    private func stage(_ url: URL) throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: "staged-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        if url.path(percentEncoded: false).contains("/Documents/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
        return copy
    }
}
