import BowLibrary
import BowModel
import SwiftData
import SwiftUI

/// Every book, or one account's, as a grid of covers. Reads only from SwiftData, so it works offline.
/// Tapping a book opens it, downloading it first if needed.
struct LibraryView: View {
    let accountID: UUID?
    @Binding var isAddingServer: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @Environment(DownloadCenter.self) private var downloads
    @Query private var books: [Book]
    @State private var openBook: Book?
    /// Opened as soon as its download finishes, if the reader tapped it to read.
    @State private var openWhenDownloaded: UUID?
    @State private var unsupportedBook: Book?

    init(accountID: UUID?, isAddingServer: Binding<Bool>) {
        self.accountID = accountID
        self._isAddingServer = isAddingServer
        let filter: Predicate<Book>
        if let accountID {
            filter = #Predicate { !$0.isRemovedOnServer && $0.account?.id == accountID }
        } else {
            filter = #Predicate { !$0.isRemovedOnServer }
        }
        _books = Query(filter: filter, sort: \Book.title)
    }

    var body: some View {
        Group {
            if books.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 20)], spacing: 24) {
                        ForEach(books) { book in
                            Button { open(book) } label: { BookTile(book: book) }
                                .buttonStyle(.plain)
                                .contextMenu { downloadMenu(for: book) }
                        }
                    }
                    .padding()
                }
            }
        }
        .refreshable { await librarySync.syncAll(modelContext.container) }
        .overlay(alignment: .bottom) {
            if let problem = librarySync.problem {
                Text(problem)
                    .font(.footnote)
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 10))
                    .padding()
            }
        }
        .fullScreenCover(item: $openBook) { book in
            ReaderScreen(book: book)
        }
        .alert("Bow can't read this book yet", isPresented: .init(
            get: { unsupportedBook != nil }, set: { if !$0 { unsupportedBook = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text("Bow opens EPUB books for now. PDF and comic support are coming.")
        }
        .onChange(of: downloadedIDs) {
            guard let id = openWhenDownloaded, let book = books.first(where: { $0.id == id }),
                  epubFile(of: book)?.downloadState == .downloaded
            else { return }
            openWhenDownloaded = nil
            openBook = book
        }
    }

    /// Changes whenever a download finishes, to open a book the reader was waiting for.
    private var downloadedIDs: [UUID] {
        books.compactMap { epubFile(of: $0)?.downloadState == .downloaded ? $0.id : nil }
    }

    private func epubFile(of book: Book) -> BookFile? {
        book.files.first { $0.format == .epub }
    }

    private func open(_ book: Book) {
        guard let file = epubFile(of: book) else {
            unsupportedBook = book
            return
        }
        switch file.downloadState {
        case .downloaded:
            openBook = book
        case .downloading:
            openWhenDownloaded = book.id
        case .remote, .failed:
            openWhenDownloaded = book.id
            downloads.download(file)
        }
    }

    @ViewBuilder private func downloadMenu(for book: Book) -> some View {
        if let file = epubFile(of: book) {
            switch file.downloadState {
            case .downloaded:
                Button("Remove Download", systemImage: "trash") { downloads.removeDownload(file) }
            case .downloading:
                Button("Cancel Download", systemImage: "xmark") { downloads.cancel(file) }
            case .remote:
                Button("Download", systemImage: "arrow.down.circle") { downloads.download(file) }
            case .failed:
                if let reason = downloads.failures[file.id] { Text(reason) }
                Button("Try Again", systemImage: "arrow.clockwise") { downloads.download(file) }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if librarySync.isSyncing {
            ProgressView("Loading your library…")
        } else {
            ContentUnavailableView {
                Label("No Books Yet", systemImage: "books.vertical")
            } description: {
                Text("Connect a Grimmory server to see your library here.")
            } actions: {
                Button("Add Grimmory Server") { isAddingServer = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct BookTile: View {
    let book: Book
    @Environment(DownloadCenter.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(book: book)
                .overlay(alignment: .bottomTrailing) { downloadBadge.padding(6) }
            if let fraction = book.progress?.fraction, fraction > 0 {
                ProgressView(value: min(fraction, 1))
                    .tint(.secondary)
            }
            Text(book.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let author = book.authors.first {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(accessibilityHint)
    }

    private var file: BookFile? { book.files.first { $0.format == .epub } }

    @ViewBuilder private var downloadBadge: some View {
        if let file {
            switch file.downloadState {
            case .downloading:
                ProgressView(value: downloads.progress[file.id] ?? 0)
                    .progressViewStyle(.circular)
                    .padding(4)
                    .background(.regularMaterial, in: .circle)
            case .remote:
                badge("icloud.and.arrow.down")
            case .failed:
                badge("exclamationmark.triangle.fill").foregroundStyle(.yellow)
            case .downloaded:
                EmptyView()
            }
        }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .padding(6)
            .background(.regularMaterial, in: .circle)
    }

    private var accessibilityHint: String {
        switch file?.downloadState {
        case .downloaded: "Opens the book."
        case .downloading: "Downloading."
        case .remote, .failed: "Downloads and opens the book."
        case nil: "Bow can't open this format yet."
        }
    }
}
