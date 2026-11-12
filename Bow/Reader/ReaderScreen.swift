import BowLibrary
import BowModel
import BowSync
import DCEpubReaderKit
import GrimmoryAPI
import SwiftData
import SwiftUI

/// Opens a downloaded EPUB in DCEpubReaderKit where the reader last left it, or where another device left it
/// if that's more recent (after asking, when this device has its own position).
struct ReaderScreen: View {
    let book: Book
    /// Closes the reader. `nil` dismisses it (full-screen cover); the Mac reader window closes itself.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @State private var reader: LoadedReader?
    @State private var choice: Choice?
    @State private var failure: String?

    /// Built once: `DCReaderView` observes the view model it's given, so rebuilding it would restart the book.
    struct LoadedReader {
        let view: DCReaderView
        let delegate: BowReaderDelegate
    }

    /// Where to start, read from the server.
    struct ServerPosition {
        let spineIndex: Int
        let coords: String
        let percentage: Double
    }

    /// Both this device and the server have a position, and the server's is newer.
    struct Choice {
        let epub: DCEpubBook
        let server: ServerPosition
    }

    var body: some View {
        Group {
            if let reader {
                reader.view
            } else if let choice {
                choiceView(choice)
            } else if let failure {
                ContentUnavailableView {
                    Label("Can't Open This Book", systemImage: "book.closed")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Close") { close() }
                }
            } else {
                ProgressView("Opening \(book.title)…")
            }
        }
        .task { await load() }
    }

    private func choiceView(_ choice: Choice) -> some View {
        ContentUnavailableView {
            Label("Continue Where You Left Off?", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text("You read further on another device (\(Int(choice.server.percentage.rounded()))%). "
                 + "On this device you're at \(Int(((book.progress?.fraction ?? 0) * 100).rounded()))%.")
        } actions: {
            Button("Go to \(Int(choice.server.percentage.rounded()))%") {
                start(choice.epub, at: choice.server)
            }
            .buttonStyle(.borderedProminent)
            Button("Stay Here") { start(choice.epub, at: nil) }
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func load() async {
        guard reader == nil, choice == nil else { return }
        guard let path = book.files.first(where: { $0.format == .epub })?.localRelativePath else {
            failure = "This book isn't downloaded."
            return
        }
        let epub: DCEpubBook
        do {
            epub = try await Task.detached(priority: .userInitiated) {
                try DCEpubParser.parse(from: try BookStorage.standard.unzippedEPUB(relativePath: path))
            }.value
        } catch {
            failure = "The file couldn't be read as an EPUB. Try removing the download and downloading it again."
            return
        }

        guard let server = await newerServerPosition(in: epub) else {
            start(epub, at: nil)
            return
        }
        if book.progress?.kitCoords == nil {
            start(epub, at: server)  // Never opened here: nothing to choose between.
        } else {
            choice = Choice(epub: epub, server: server)
        }
    }

    /// The position Grimmory has, if it's newer than this device's and somewhere else. Gives up after a few
    /// seconds so a slow or unreachable server never keeps a downloaded book from opening.
    private func newerServerPosition(in epub: DCEpubBook) async -> ServerPosition? {
        guard let remoteID = book.remoteID, let account = book.account,
              let client = GrimmoryAccounts.client(for: account)
        else { return nil }

        let fetched = await withTaskGroup(of: GrimmoryEpubProgress??.self) { group in
            group.addTask { try? await client.epubProgress(bookID: remoteID) }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return .some(nil)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
        guard let server = fetched, let cfi = server.cfi, cfi != book.progress?.cfi else { return nil }

        // This device's own pushes also move the server's `lastReadTime`, a few seconds after the position
        // changed here, so require a clear margin.
        let local = book.progress?.updatedAt ?? .distantPast
        guard let serverTime = server.lastReadTime, serverTime > local.addingTimeInterval(60) else { return nil }

        guard let target = await DCCFIConverter(book: epub).coords(fromCFI: cfi) else { return nil }
        return ServerPosition(spineIndex: target.spineIndex, coords: target.coords, percentage: server.percentage)
    }

    private func start(_ epub: DCEpubBook, at server: ServerPosition?) {
        choice = nil
        let container = modelContext.container
        let delegate = BowReaderDelegate(context: modelContext, bookID: book.id, epub: epub) {
            Task { await librarySync.pushChanges(container) }
        }
        var configuration = DCReaderConfiguration()
        configuration.bookId = book.id.uuidString
        configuration.defaults = UserDefaults(suiteName: "app.bow.reader") ?? .standard
        configuration.onClose = { close() }

        let view = DCReaderViewBuilder.build(
            epub,
            spineIndex: server?.spineIndex ?? book.progress?.spineIndex ?? 0,
            initialCoords: server?.coords ?? book.progress?.kitCoords,
            delegate: delegate,
            configuration: configuration
        )
        reader = LoadedReader(view: view, delegate: delegate)
    }
}
