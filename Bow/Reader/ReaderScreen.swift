import BowLibrary
import BowModel
import BowSync
import BookKit
import GrimmoryAPI
import SwiftData
import SwiftUI

/// Opens a downloaded EPUB in BookKit where the reader last left it, or where another device left it
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
    @State private var pdf: PDFOpening?
    @State private var pdfChoice: PDFChoice?
    @State private var failure: String?
    /// Times this reading, for Grimmory's stats. Created when the book opens.
    @State private var sessions: ReadingSessionRecorder?
    @Environment(\.scenePhase) private var scenePhase

    /// BookKit's PDF reader, built once (it keeps its own state), and what it reads from and saves to.
    struct PDFOpening {
        let view: BKPDFReaderView
        let store: BowPDFStore
    }

    /// Both this device and the server have a page, and the server's is newer.
    struct PDFChoice {
        let url: URL
        let serverPage: Int
        let percentage: Double
    }

    /// Built once: `BKReaderView` observes the view model it's given, so rebuilding it would restart the book.
    struct LoadedReader {
        let view: BKReaderView
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
        let epub: BKEpubBook
        let server: ServerPosition
    }

    var body: some View {
        Group {
            if let reader {
                reader.view
            } else if let pdf {
                pdf.view
            } else if let choice {
                choiceView(serverPercentage: choice.server.percentage) {
                    start(choice.epub, at: choice.server)
                } stay: {
                    start(choice.epub, at: nil)
                }
            } else if let pdfChoice {
                choiceView(serverPercentage: pdfChoice.percentage) {
                    openPDF(pdfChoice.url, at: pdfChoice.serverPage)
                } stay: {
                    openPDF(pdfChoice.url, at: book.progress?.spineIndex ?? 0)
                }
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
        .onDisappear { endSession() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { endSession() }  // The next page turn starts a new session.
        }
    }

    private func choiceView(serverPercentage: Double, goToServer: @escaping () -> Void,
                            stay: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label("Continue Where You Left Off?", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text("You read further on another device (\(Int(serverPercentage.rounded()))%). "
                 + "On this device you're at \(Int(((book.progress?.fraction ?? 0) * 100).rounded()))%.")
        } actions: {
            Button("Go to \(Int(serverPercentage.rounded()))%", action: goToServer)
                .buttonStyle(.borderedProminent)
            Button("Stay Here", action: stay)
        }
    }

    /// Builds the PDF reader at `page` (from 0), with Bow's highlights and position behind it.
    private func openPDF(_ url: URL, at page: Int) {
        pdfChoice = nil
        let container = modelContext.container
        let store = BowPDFStore(book: book, url: url, startPage: page, context: modelContext,
                                sessions: pdfRecorder()) { [librarySync] in
            Task { await librarySync.pushChanges(container) }
        }
        var menu = BKHighlightMenuConfiguration()
        menu.palettes = GrimmoryHighlights.palettes
        guard let view = BKPDFReaderViewBuilder.build(url: url, bookId: book.id.uuidString, highlightStore: store,
                                                      positionStore: store, menuConfiguration: menu)
        else {
            failure = "The file couldn't be read as a PDF. It may be password protected."
            return
        }
        pdf = PDFOpening(view: view, store: store)
    }

    /// One recorder per opening, kept so closing the reader can end its session.
    private func pdfRecorder() -> ReadingSessionRecorder {
        let recorder = sessions ?? ReadingSessionRecorder(book: book, bookType: .pdf, context: modelContext)
        sessions = recorder
        return recorder
    }

    /// Ends the reading session and sends it, so it shows in Grimmory's stats straight away.
    private func endSession() {
        sessions?.end()
        let container = modelContext.container
        Task { await librarySync.pushChanges(container) }
    }

    private func close() {
        endSession()
        if let onClose { onClose() } else { dismiss() }
    }

    private func load() async {
        guard reader == nil, choice == nil, pdf == nil, pdfChoice == nil else { return }
        guard let file = book.readableFile, let path = file.localRelativePath else {
            failure = "This book isn't downloaded."
            return
        }
        if file.format == .pdf {
            await loadPDF(BookStorage.standard.url(forRelativePath: path))
            return
        }
        let epub: BKEpubBook
        do {
            epub = try await Task.detached(priority: .userInitiated) {
                try BKEpubParser.parse(from: try BookStorage.standard.unzippedEPUB(relativePath: path))
            }.value
        } catch {
            failure = "The file couldn't be read as an EPUB. Try removing the download and downloading it again."
            return
        }

        await syncAnnotations(in: epub)

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

    /// Opens a PDF at this device's page, or the server's when it's newer (asking first if this device has one).
    private func loadPDF(_ url: URL) async {
        await syncPDFAnnotations()
        let local = book.progress?.spineIndex
        guard let remoteID = book.remoteID, let account = book.account,
              let client = GrimmoryAccounts.client(for: account)
        else {
            openPDF(url, at: local ?? 0)
            return
        }
        let fetched = await withTimeout(3) { try await client.pdfProgress(bookID: remoteID) }
        guard let server = fetched ?? nil, server.page >= 1, server.page - 1 != local else {
            openPDF(url, at: local ?? 0)
            return
        }
        guard let local else {
            openPDF(url, at: server.page - 1)  // Never opened here.
            return
        }
        // As for EPUBs: this device's own pushes move `lastReadTime` too, so require a clear margin.
        let localTime = book.progress?.updatedAt ?? .distantPast
        if let serverTime = server.lastReadTime, serverTime > localTime.addingTimeInterval(60) {
            pdfChoice = PDFChoice(url: url, serverPage: server.page - 1, percentage: server.percentage)
        } else {
            openPDF(url, at: local)
        }
    }

    /// Sends this device's PDF highlight changes, then brings in the web viewer's. Gives up after a few seconds.
    private func syncPDFAnnotations() async {
        guard book.remoteID != nil, let account = book.account, let client = GrimmoryAccounts.client(for: account)
        else { return }
        let syncer = PDFAnnotationSyncer(context: modelContext)
        let bookID = book.id
        await withTimeout(4) {
            try? await syncer.push(bookID: bookID, to: client)
            try await syncer.pull(bookID: bookID, from: client)
        }
    }

    /// The position Grimmory has, if it's newer than this device's and somewhere else. Gives up after a few
    /// seconds so a slow or unreachable server never keeps a downloaded book from opening.
    private func newerServerPosition(in epub: BKEpubBook) async -> ServerPosition? {
        guard let remoteID = book.remoteID, let account = book.account,
              let client = GrimmoryAccounts.client(for: account)
        else { return nil }

        let fetched = await withTimeout(3) { try await client.epubProgress(bookID: remoteID) }
        guard let server = fetched ?? nil, let cfi = server.cfi, cfi != book.progress?.cfi else { return nil }

        // This device's own pushes also move the server's `lastReadTime`, a few seconds after the position
        // changed here, so require a clear margin.
        let local = book.progress?.updatedAt ?? .distantPast
        guard let serverTime = server.lastReadTime, serverTime > local.addingTimeInterval(60) else { return nil }

        guard let target = await BKCFIConverter(book: epub).coords(fromCFI: cfi) else { return nil }
        return ServerPosition(spineIndex: target.spineIndex, coords: target.coords, percentage: server.percentage)
    }

    /// Brings in annotations made elsewhere (Grimmory's web reader, other devices) and places them in this
    /// edition. Like the position check, it gives up after a few seconds rather than hold the book closed.
    private func syncAnnotations(in epub: BKEpubBook) async {
        if book.remoteID != nil, let account = book.account, let client = GrimmoryAccounts.client(for: account) {
            let syncer = AnnotationSyncer(context: modelContext)
            let bookID = book.id
            await withTimeout(4) { try await syncer.pull(bookID: bookID, from: client) }
        }

        let unplaced = book.annotations.filter { $0.deletedAt == nil && $0.kitCoords == nil && $0.cfi != nil }
        guard !unplaced.isEmpty else { return }
        let converter = BKCFIConverter(book: epub)
        for annotation in unplaced {
            guard let cfi = annotation.cfi, let place = await converter.coords(fromCFI: cfi) else { continue }
            annotation.kitCoords = place.coords
            annotation.spineIndex = place.spineIndex
        }
        try? modelContext.save()
    }

    /// `work`'s result, or nil if it fails or takes longer than `seconds` (it's cancelled then). A slow or
    /// unreachable server must never keep a downloaded book from opening.
    @discardableResult
    private func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @MainActor () async throws -> T) async -> T? {
        let task = Task { try await work() }
        let timer = Task {
            try await Task.sleep(for: .seconds(seconds))
            task.cancel()
        }
        defer { timer.cancel() }
        return try? await task.value
    }

    private func start(_ epub: BKEpubBook, at server: ServerPosition?) {
        choice = nil
        let container = modelContext.container
        let recorder = ReadingSessionRecorder(book: book, bookType: .epub, context: modelContext)
        sessions = recorder
        let delegate = BowReaderDelegate(context: modelContext, bookID: book.id, epub: epub, sessions: recorder) {
            Task { await librarySync.pushChanges(container) }
        }
        var configuration = BKReaderConfiguration()
        configuration.bookId = book.id.uuidString
        configuration.defaults = UserDefaults(suiteName: "app.bow.reader") ?? .standard
        configuration.onClose = { close() }
        // Grimmory's styles and colours, so annotations look the same here and in its web reader. The default
        // menu actions (note, look up, search, copy, share; delete on a highlight) already match it.
        configuration.highlightMenu.palettes = GrimmoryHighlights.palettes
        #if targetEnvironment(macCatalyst)
        // Books on the Mac only slides pages; no curl, and no page-turn setting.
        configuration.allowsPageCurl = false
        #endif

        let view = BKReaderViewBuilder.build(
            epub,
            spineIndex: server?.spineIndex ?? book.progress?.spineIndex ?? 0,
            initialCoords: server?.coords ?? book.progress?.kitCoords,
            delegate: delegate,
            configuration: configuration
        )
        reader = LoadedReader(view: view, delegate: delegate)
    }
}
