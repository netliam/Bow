import BowModel
import SwiftData
import SwiftUI

/// A group of books to browse: one series, or one author's books. Built from the books on this device, so it works
/// offline and includes imported books.
enum BookCollection: Hashable {
    case series(String)
    case author(String)

    var title: String {
        switch self {
        case .series(let name), .author(let name): name
        }
    }

    func contains(_ book: Book) -> Bool {
        switch self {
        case .series(let name): book.seriesName == name
        case .author(let name): book.authors.contains(name)
        }
    }

    /// Series in reading order (unnumbered books last); authors' books by title.
    func sorted(_ books: [Book]) -> [Book] {
        switch self {
        case .series:
            books.sorted { a, b in
                switch (a.seriesNumber, b.seriesNumber) {
                case let (x?, y?) where x != y: x < y
                case (_?, nil): true
                case (nil, _?): false
                default: a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            }
        case .author:
            books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}

/// One series' or author's books.
struct CollectionView: View {
    let collection: BookCollection
    @Query(filter: #Predicate<Book> { !$0.isRemovedOnServer }) private var allBooks: [Book]

    var body: some View {
        let books = collection.sorted(allBooks.filter(collection.contains))
        ScrollView {
            if case .series = collection, let subtitle = seriesSubtitle(books) {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top])
            }
            BookGrid(books: books, showsSeriesNumber: collection.isSeries)
        }
        .navigationTitle(collection.title)
        .overlay {
            if books.isEmpty {
                ContentUnavailableView("No Books", systemImage: "books.vertical")
            }
        }
    }

    private func seriesSubtitle(_ books: [Book]) -> String? {
        let authors = Set(books.flatMap(\.authors)).sorted()
        guard !authors.isEmpty else { return nil }
        return "By \(authors.formatted(.list(type: .and)))"
    }
}

private extension BookCollection {
    var isSeries: Bool {
        if case .series = self { true } else { false }
    }
}

/// Every series in the library.
struct SeriesListView: View {
    @Query(filter: #Predicate<Book> { !$0.isRemovedOnServer && $0.seriesName != nil }) private var books: [Book]

    var body: some View {
        let series = Dictionary(grouping: books) { $0.seriesName ?? "" }
            .map { (name: $0.key, books: BookCollection.series($0.key).sorted($0.value)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        List(series, id: \.name) { item in
            NavigationLink(value: BookCollection.series(item.name)) {
                HStack(spacing: 14) {
                    CoverView(book: item.books[0])
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.headline)
                        Text(seriesDetail(item.books))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .navigationTitle("Series")
        .overlay {
            if series.isEmpty {
                ContentUnavailableView("No Series", systemImage: "books.vertical",
                                       description: Text("Books that belong to a series are grouped here."))
            }
        }
    }

    private func seriesDetail(_ books: [Book]) -> String {
        let count = books.count == 1 ? "1 book" : "\(books.count) books"
        let authors = Set(books.flatMap(\.authors)).sorted()
        return authors.isEmpty ? count : "\(count) · \(authors.formatted(.list(type: .and)))"
    }
}

/// Every author in the library.
struct AuthorListView: View {
    @Query(filter: #Predicate<Book> { !$0.isRemovedOnServer }) private var books: [Book]

    var body: some View {
        var counts: [String: Int] = [:]
        for book in books {
            for author in Set(book.authors) { counts[author, default: 0] += 1 }
        }
        let authors = counts.keys.sorted { Self.sortKey($0).localizedStandardCompare(Self.sortKey($1)) == .orderedAscending }

        return List(authors, id: \.self) { author in
            NavigationLink(value: BookCollection.author(author)) {
                HStack(spacing: 14) {
                    Text(Self.initials(author))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.gradient, in: .circle)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(author).font(.headline)
                        let count = counts[author] ?? 0
                        Text(count == 1 ? "1 book" : "\(count) books")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Authors")
        .overlay {
            if authors.isEmpty {
                ContentUnavailableView("No Authors", systemImage: "person.2")
            }
        }
    }

    /// Sorted by surname, as bookshops do: "Susanna Clarke" files under C.
    static func sortKey(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard parts.count > 1, let last = parts.last else { return name }
        return "\(last) \(parts.dropLast().joined(separator: " "))"
    }

    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").compactMap(\.first)
        return String(letters.count > 1 ? [letters.first!, letters.last!] : letters).uppercased()
    }
}
