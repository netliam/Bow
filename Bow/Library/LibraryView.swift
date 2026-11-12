import BowModel
import SwiftData
import SwiftUI

/// Every book, or one account's, as a grid of covers. Reads only from SwiftData, so it works offline.
struct LibraryView: View {
    let accountID: UUID?
    @Binding var isAddingServer: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @Query private var books: [Book]

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
                            BookTile(book: book)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(book: book)
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
        .accessibilityElement(children: .combine)
    }
}
