import BowModel
import SwiftData
import SwiftUI

/// Searches the books on this device by title, author and series. With nothing typed, offers authors and series to
/// browse.
/// The Search tab. `.searchable` sits on the tab's navigation stack, where iOS puts a search tab's field.
struct SearchTab: View {
    @State private var query = ""

    var body: some View {
        NavigationStack {
            SearchView(query: query)
                .bookDestinations()
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titles, authors, series")
    }
}

struct SearchView: View {
    let query: String
    @Query(filter: #Predicate<Book> { !$0.isRemovedOnServer }) private var books: [Book]

    var body: some View {
        ScrollView {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                browse
            } else {
                results(for: trimmed)
            }
        }
        .navigationTitle("Search")
    }

    // MARK: Results

    @ViewBuilder
    private func results(for text: String) -> some View {
        let matches = books.filter { book in
            book.title.localizedStandardContains(text)
                || book.authors.contains { $0.localizedStandardContains(text) }
                || (book.seriesName?.localizedStandardContains(text) ?? false)
        }
        let authors = Set(books.flatMap(\.authors)).filter { $0.localizedStandardContains(text) }.sorted()
        let series = Set(books.compactMap(\.seriesName)).filter { $0.localizedStandardContains(text) }.sorted()

        if matches.isEmpty, authors.isEmpty, series.isEmpty {
            ContentUnavailableView.search(text: text)
                .padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if !authors.isEmpty || !series.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(authors, id: \.self) { author in
                            row(BookCollection.author(author), symbol: "person", detail: "Author")
                        }
                        ForEach(series, id: \.self) { name in
                            row(BookCollection.series(name), symbol: "square.stack", detail: "Series")
                        }
                    }
                    .padding(.horizontal)
                }
                if !matches.isEmpty {
                    SectionHeader(title: "Books")
                    BookGrid(books: LibrarySort.title.sorted(matches))
                }
            }
            .padding(.top, 8)
        }
    }

    private func row(_ collection: BookCollection, symbol: String, detail: String) -> some View {
        NavigationLink(value: collection) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(collection.title).font(.body.weight(.medium))
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Browse

    @ViewBuilder private var browse: some View {
        let authors = Set(books.flatMap(\.authors)).sorted {
            AuthorNames.sortKey($0).localizedStandardCompare(AuthorNames.sortKey($1)) == .orderedAscending
        }
        let series = Set(books.compactMap(\.seriesName)).sorted()
        VStack(alignment: .leading, spacing: 24) {
            if !authors.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Authors", seeAll: .authors)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 18) {
                            ForEach(authors, id: \.self) { author in
                                NavigationLink(value: BookCollection.author(author)) {
                                    VStack(spacing: 8) {
                                        AuthorAvatar(name: author, size: 72)
                                        Text(author)
                                            .font(.footnote.weight(.medium))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .frame(width: 84)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            if !series.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Series", seeAll: .series)
                        .padding(.bottom, 8)
                    ForEach(series, id: \.self) { name in
                        row(BookCollection.series(name), symbol: "square.stack",
                            detail: "\(books.filter { $0.seriesName == name }.count) books")
                            .padding(.horizontal)
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}
