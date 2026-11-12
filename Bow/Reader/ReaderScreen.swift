import BowLibrary
import BowModel
import DCEpubReaderKit
import SwiftData
import SwiftUI

/// Opens a downloaded EPUB in DCEpubReaderKit where the reader last left it.
struct ReaderScreen: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @State private var reader: LoadedReader?
    @State private var failure: String?

    /// Built once: `DCReaderView` observes the view model it's given, so rebuilding it would restart the book.
    struct LoadedReader {
        let view: DCReaderView
        let delegate: BowReaderDelegate
    }

    var body: some View {
        Group {
            if let reader {
                reader.view
            } else if let failure {
                ContentUnavailableView {
                    Label("Can't Open This Book", systemImage: "book.closed")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Close") { dismiss() }
                }
            } else {
                ProgressView("Opening \(book.title)…")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard reader == nil else { return }
        guard let path = book.files.first(where: { $0.format == .epub })?.localRelativePath else {
            failure = "This book isn't downloaded."
            return
        }
        do {
            let epub = try await Task.detached(priority: .userInitiated) {
                try DCEpubParser.parse(from: try BookStorage.standard.unzippedEPUB(relativePath: path))
            }.value

            let container = modelContext.container
            let delegate = BowReaderDelegate(context: modelContext, bookID: book.id, epub: epub) {
                Task { await librarySync.pushProgress(container) }
            }
            var configuration = DCReaderConfiguration()
            configuration.bookId = book.id.uuidString
            configuration.defaults = UserDefaults(suiteName: "app.bow.reader") ?? .standard
            configuration.onClose = { dismiss() }

            let view = DCReaderViewBuilder.build(
                epub,
                spineIndex: book.progress?.spineIndex ?? 0,
                initialCoords: book.progress?.kitCoords,
                delegate: delegate,
                configuration: configuration
            )
            reader = LoadedReader(view: view, delegate: delegate)
        } catch {
            failure = "The file couldn't be read as an EPUB. Try removing the download and downloading it again."
        }
    }
}
