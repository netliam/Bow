import BowModel
import SwiftData
import SwiftUI

/// The reader in a window of its own (Mac). Closing the book closes the window.
struct ReaderWindow: View {
    static let id = "reader"

    let bookID: UUID?

    @Environment(\.dismissWindow) private var dismissWindow
    @Query private var books: [Book]

    init(bookID: UUID?) {
        self.bookID = bookID
        let id = bookID ?? UUID()
        _books = Query(filter: #Predicate { $0.id == id })
    }

    var body: some View {
        if let book = books.first {
            ReaderScreen(book: book, onClose: { dismissWindow() })
                .navigationTitle(book.title)
        } else {
            ContentUnavailableView("Book Not Found", systemImage: "book.closed",
                                   description: Text("It may have been removed from your library."))
        }
    }
}
