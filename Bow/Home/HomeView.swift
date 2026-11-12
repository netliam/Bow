import BowModel
import SwiftData
import SwiftUI

/// What to read next: books in progress, the next book in series you've started, what's new, what's downloaded,
/// and your shelves. Built from the books on this device, so it works offline.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @Environment(AppActions.self) private var actions
    @Query(filter: #Predicate<Book> { !$0.isRemovedOnServer }) private var books: [Book]
    @Query(sort: \Shelf.name) private var shelves: [Shelf]

    var body: some View {
        ScrollView {
            if books.isEmpty {
                welcome
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !continueReading.isEmpty {
                        ContinueSection(books: continueReading)
                    }
                    ReadingSummaryCard()
                    shelfRow("Next in Series", subtitle: "Pick up where a series left off.", books: nextInSeries)
                    shelfRow("Recently Added", subtitle: "New in your library.", books: recentlyAdded,
                             seeAll: .all, large: true)
                    shelfRow("Ready Offline", subtitle: "Downloaded to this device.", books: downloaded,
                             seeAll: .downloaded)
                    ForEach(shelves.filter { $0.kind == .regular }) { shelf in
                        shelfRow(shelf.name, subtitle: nil, books: Array(shelf.books.filter { !$0.isRemovedOnServer }.prefix(20)),
                                 seeAll: .shelf(shelf.id))
                    }
                    ForEach(shelves.filter { $0.kind == .magic }) { shelf in
                        shelfRow(shelf.name, subtitle: "Magic shelf", books: Array(shelf.books.filter { !$0.isRemovedOnServer }.prefix(20)),
                                 seeAll: .shelf(shelf.id))
                    }
                    shelfRow("Finished", subtitle: "Books you've read.", books: finished, seeAll: .finished)
                }
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Home")
        .accountToolbar()
        .refreshable { await librarySync.syncAll(modelContext.container) }
    }

    // MARK: Sections

    /// Started and not finished, most recently read first.
    private var continueReading: [Book] {
        books.filter(\.isInProgress)
            .sorted { ($0.lastReadDate ?? .distantPast) > ($1.lastReadDate ?? .distantPast) }
            .prefix(12).map { $0 }
    }

    /// For each series with a finished or started book, the first later book you haven't started.
    private var nextInSeries: [Book] {
        let inProgress = Set(continueReading.map(\.id))
        return Dictionary(grouping: books.filter { $0.seriesName != nil }) { $0.seriesName! }
            .compactMap { _, series -> Book? in
                let ordered = BookCollection.series("").sorted(series)
                guard let lastStarted = ordered.lastIndex(where: { $0.readStatus == GrimmoryReadStatusRaw.read || $0.isInProgress })
                else { return nil }
                return ordered[(lastStarted + 1)...].first { book in
                    !inProgress.contains(book.id) && book.readStatus != GrimmoryReadStatusRaw.read
                        && (book.progress?.fraction ?? 0) == 0
                }
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var recentlyAdded: [Book] {
        LibrarySort.recentlyAdded.sorted(books).prefix(15).map { $0 }
    }

    private var downloaded: [Book] {
        books.filter { LibraryFilter.downloaded.contains($0) && $0.readStatus != GrimmoryReadStatusRaw.read }
            .prefix(20).map { $0 }
    }

    private var finished: [Book] {
        LibrarySort.recentlyRead.sorted(books.filter { LibraryFilter.finished.contains($0) }).prefix(20).map { $0 }
    }

    @ViewBuilder
    private func shelfRow(_ title: String, subtitle: String?, books: [Book], seeAll: LibraryFilter? = nil,
                          large: Bool = false) -> some View {
        if !books.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title, subtitle: subtitle, seeAll: seeAll)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(books) { book in
                            NavigationLink(value: book) {
                                CoverTile(book: book, width: large ? 150 : 112)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.vertical, 18)
        }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Welcome to Bow")
                .font(.largeTitle.bold())
                .fontDesign(.serif)
            Text("Connect your Grimmory server to read your library anywhere, even offline. Or add EPUB books from Files.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Button {
                    actions.isAddingServer = true
                } label: {
                    Text("Connect a Server").frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    actions.isImporting = true
                } label: {
                    Text("Add Books from Files").frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

/// A serif section title, with an optional line under it and a link to the whole collection.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var seeAll: LibraryFilter?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let seeAll {
                NavigationLink(value: seeAll) {
                    HStack(spacing: 4) {
                        titleText
                        Image(systemName: "chevron.right")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows all of them.")
            } else {
                titleText
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private var titleText: some View {
        Text(title)
            .font(.title2.bold())
            .fontDesign(.serif)
    }
}

/// A cover with its title and author underneath, for horizontal rows.
struct CoverTile: View {
    let book: Book
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A fixed height: a row's height comes from its first tile, so a cover sized by its width alone would
            // shrink under books with longer captions.
            CoverView(book: book)
                .frame(width: width, height: width * 1.5)
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
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
    }
}

// MARK: Continue

/// The top of Home: books in progress as wide cards, tinted to match their covers.
private struct ContinueSection: View {
    let books: [Book]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Continue", seeAll: .reading)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(books) { book in
                        NavigationLink(value: book) { ContinueCard(book: book) }
                            .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
        .padding(.top, 8)
        .padding(.bottom, 18)
    }
}

private struct ContinueCard: View {
    let book: Book
    @State private var tint: Color?

    var body: some View {
        HStack(spacing: 14) {
            CoverView(book: book)
                .frame(width: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)
                if let author = book.authors.first {
                    Text(author)
                        .font(.subheadline)
                        .lineLimit(1)
                        .opacity(0.85)
                }
                Text(detail)
                    .font(.footnote)
                    .opacity(0.7)
                ProgressView(value: min(book.progress?.fraction ?? 0, 1))
                    .tint(.white)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 300, height: 112)
        .background(tint ?? Color(white: 0.25), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
        .task(id: book.coverUpdatedOn) {
            if let image = await CoverView.image(for: book), let color = image.readableTint() {
                withAnimation(.easeOut(duration: 0.25)) { tint = Color(uiColor: color) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let kind = book.readableFile?.format == .pdf ? "PDF" : "Book"
        let percent = Int(((book.progress?.fraction ?? 0) * 100).rounded())
        return "\(kind) · \(percent)%"
    }
}
