import BowLibrary
import BowModel
import SwiftData
import SwiftUI

/// Every book, or one account's, as a grid of covers. Reads only from SwiftData, so it works offline.
/// Tapping a book opens its detail page; EPUB files dropped on the grid are imported.
struct LibraryView: View {
    let accountID: UUID?
    let shelfID: UUID?
    @Binding var isAddingServer: Bool
    @Binding var isImporting: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @Environment(LocalImporter.self) private var importer
    @Query private var books: [Book]

    init(accountID: UUID?, shelfID: UUID? = nil, isAddingServer: Binding<Bool>, isImporting: Binding<Bool>) {
        self.accountID = accountID
        self.shelfID = shelfID
        self._isAddingServer = isAddingServer
        self._isImporting = isImporting
        let filter: Predicate<Book>
        if let shelfID {
            filter = #Predicate { book in !book.isRemovedOnServer && book.shelves.contains { $0.id == shelfID } }
        } else if let accountID {
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
                ScrollView { BookGrid(books: books) }
            }
        }
        .refreshable { await librarySync.syncAll(modelContext.container) }
        .dropDestination(for: URL.self) { urls, _ in
            let books = urls.filter { $0.pathExtension.lowercased() == "epub" }
            importer.importFiles(books)
            return !books.isEmpty
        }
        .overlay(alignment: .bottom) {
            if let problem = librarySync.problem ?? importer.problem {
                Text(problem)
                    .font(.footnote)
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 10))
                    .padding()
                    .onTapGesture {
                        librarySync.problem = nil
                        importer.problem = nil
                    }
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
                Text("Connect a Grimmory server, or add EPUB books from Files.")
            } actions: {
                Button("Add Grimmory Server") { isAddingServer = true }
                    .buttonStyle(.borderedProminent)
                Button("Add Books from Files") { isImporting = true }
            }
        }
    }
}

/// Books as a grid of covers, each opening its detail page, with download actions in the context menu.
struct BookGrid: View {
    let books: [Book]
    /// Shows "Book 2" under each title, for a series.
    var showsSeriesNumber = false
    @Environment(DownloadCenter.self) private var downloads

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 20)], spacing: 24) {
            ForEach(books) { book in
                NavigationLink(value: book) { BookTile(book: book, showsSeriesNumber: showsSeriesNumber) }
                    .buttonStyle(.plain)
                    .contextMenu { downloadMenu(for: book) }
            }
        }
        .padding()
    }

    @ViewBuilder private func downloadMenu(for book: Book) -> some View {
        if let file = book.readableFile, book.account?.kind != .local {
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

}

private struct BookTile: View {
    let book: Book
    var showsSeriesNumber = false
    @Environment(DownloadCenter.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(book: book)
                .overlay(alignment: .bottomTrailing) { downloadBadge.padding(6) }
            if let fraction = book.progress?.fraction, fraction > 0 {
                ProgressView(value: min(fraction, 1))
                    .tint(.secondary)
            }
            if showsSeriesNumber, let number = book.seriesNumber {
                Text("Book \(number.formatted())")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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

    private var file: BookFile? { book.readableFile }

    @ViewBuilder private var downloadBadge: some View {
        if let file, book.account?.kind != .local {
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
        case .downloaded: "Shows the book. It's available offline."
        case .downloading: "Downloading."
        case .remote, .failed: "Shows the book."
        case nil: "Bow can't open this format yet."
        }
    }
}
