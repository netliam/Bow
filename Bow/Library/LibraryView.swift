import BowLibrary
import BowModel
import BowSync
import GrimmoryAPI
import SwiftData
import SwiftUI

/// A slice of the library: everything, a reading state, downloads, an account, or a shelf. Series and authors list
/// their groups instead of books.
enum LibraryFilter: Hashable {
    case all, reading, finished, downloaded, series, authors, onDevice
    case account(UUID)
    case shelf(UUID)

    var title: String {
        switch self {
        case .all: "All Books"
        case .reading: "Reading"
        case .finished: "Finished"
        case .downloaded: "Downloaded"
        case .series: "Series"
        case .authors: "Authors"
        case .onDevice: "On This Device"
        case .account, .shelf: "Library"
        }
    }

    var symbol: String {
        switch self {
        case .all: "books.vertical"
        case .reading: "book"
        case .finished: "checkmark.circle"
        case .downloaded: "arrow.down.circle"
        case .series: "square.stack"
        case .authors: "person.2"
        case .onDevice: "ipad.and.iphone"
        case .account: "server.rack"
        case .shelf: "books.vertical"
        }
    }

    func contains(_ book: Book) -> Bool {
        switch self {
        case .all, .series, .authors: true
        case .reading: book.isInProgress
        case .finished: book.readStatus == GrimmoryReadStatusRaw.read
        case .downloaded: book.readableFile?.downloadState == .downloaded
        case .onDevice: book.account?.kind == .local
        case .account(let id): book.account?.id == id
        case .shelf(let id): book.shelves.contains { $0.id == id }
        }
    }
}

/// Read status values, as stored on `Book.readStatus`.
enum GrimmoryReadStatusRaw {
    static let reading = "READING"
    static let reReading = "RE_READING"
    static let read = "READ"
}

extension Book {
    /// Started and not finished: has a position here or on the server, or is marked as reading.
    var isInProgress: Bool {
        if readStatus == GrimmoryReadStatusRaw.read { return false }
        if readStatus == GrimmoryReadStatusRaw.reading || readStatus == GrimmoryReadStatusRaw.reReading { return true }
        guard let fraction = progress?.fraction else { return false }
        return fraction > 0 && fraction < 0.995
    }

    /// The last time this device moved through the book, for "Continue" and "Recently Read".
    var lastReadDate: Date? { progress?.fraction ?? 0 > 0 ? progress?.updatedAt : nil }
}

/// How book grids are ordered. Remembered across launches.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recentlyRead, recentlyAdded, title, author

    var id: Self { self }

    var title: String {
        switch self {
        case .recentlyRead: "Recently Read"
        case .recentlyAdded: "Recently Added"
        case .title: "Title"
        case .author: "Author"
        }
    }

    func sorted(_ books: [Book]) -> [Book] {
        switch self {
        case .title:
            books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            books.sorted {
                let a = $0.authors.first.map(AuthorNames.sortKey) ?? "~"
                let b = $1.authors.first.map(AuthorNames.sortKey) ?? "~"
                return a == b ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    : a.localizedStandardCompare(b) == .orderedAscending
            }
        case .recentlyAdded:
            books.sorted { ($0.addedOn ?? .distantPast) > ($1.addedOn ?? .distantPast) }
        case .recentlyRead:
            books.sorted { ($0.lastReadDate ?? .distantPast) > ($1.lastReadDate ?? .distantPast) }
        }
    }
}

/// The Library tab: collection chips along the top, and the chosen collection below.
struct LibraryTab: View {
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var filter: LibraryFilter = .all

    var body: some View {
        // The chips scroll with the content: pinned above it, they would stop the large title from showing.
        LibraryContent(filter: filter, title: "Library") { chips }
            .id(filter)
            .accountToolbar()
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(chipFilters, id: \.self) { item in
                    Chip(title: title(for: item), symbol: symbol(for: item), isSelected: filter == item) {
                        withAnimation(.snappy) { filter = item }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 4)
    }

    private var chipFilters: [LibraryFilter] {
        // Wide layouts have the sidebar, which lists series, authors and shelves.
        let sidebar = sizeClass == .regular
        var items: [LibraryFilter] = [.all, .reading, .finished, .downloaded] + (sidebar ? [] : [.series, .authors])
        let grimmory = accounts.filter { $0.kind == .grimmory }
        if grimmory.count > 1 { items += grimmory.map { .account($0.id) } }
        if accounts.contains(where: { $0.kind == .local && !$0.books.isEmpty }) { items.append(.onDevice) }
        if sidebar { return items }
        let shelves = grimmory.flatMap(\.shelves)
            .sorted { ($0.kind == .regular ? 0 : 1, $0.name) < ($1.kind == .regular ? 0 : 1, $1.name) }
        items += shelves.map { .shelf($0.id) }
        return items
    }

    private func title(for filter: LibraryFilter) -> String {
        switch filter {
        case .account(let id): accounts.first { $0.id == id }?.displayName ?? "Server"
        case .shelf(let id): shelf(id)?.name ?? "Shelf"
        default: filter.title
        }
    }

    private func symbol(for filter: LibraryFilter) -> String {
        if case .shelf(let id) = filter, let shelf = shelf(id) { return ShelfIcon.symbol(for: shelf) }
        return filter.symbol
    }

    private func shelf(_ id: UUID) -> Shelf? {
        accounts.lazy.flatMap(\.shelves).first { $0.id == id }
    }
}

/// A rounded, selectable filter.
struct Chip: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One collection: a sorted grid of books, or the series or author list. Reads only from SwiftData, so it works
/// offline. EPUB files dropped on it are imported.
struct LibraryContent<Header: View>: View {
    let filter: LibraryFilter
    var title: String
    @ViewBuilder var header: Header

    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @Environment(LocalImporter.self) private var importer
    @Environment(BookIntake.self) private var intake
    @Environment(AppActions.self) private var actions
    @AppStorage("librarySort") private var sort: LibrarySort = .recentlyRead
    @Query(filter: #Predicate<Book> { !$0.isRemovedOnServer }) private var allBooks: [Book]

    var body: some View {
        Group {
            switch filter {
            case .series: SeriesListView(title: title) { header }
            case .authors: AuthorListView(title: title) { header }
            default:
                let books = sort.sorted(allBooks.filter(filter.contains))
                ScrollView {
                    header
                    if books.isEmpty {
                        emptyState.padding(.top, 40)
                    } else {
                        BookGrid(books: books)
                    }
                }
                .navigationTitle(title)
                .toolbar { sortMenu }
            }
        }
        .refreshable { await librarySync.syncAll(modelContext.container) }
        .dropDestination(for: URL.self) { urls, _ in
            let books = urls.filter { BookIntake.acceptedExtensions.contains($0.pathExtension.lowercased()) }
            intake.receive(books)
            return !books.isEmpty
        }
        .overlay(alignment: .bottom) {
            if let problem = librarySync.problem ?? importer.problem ?? intake.problem {
                Text(problem)
                    .font(.footnote)
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 10))
                    .padding()
                    .onTapGesture {
                        librarySync.problem = nil
                        importer.problem = nil
                        intake.problem = nil
                    }
            }
        }
    }

    @ToolbarContentBuilder private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            Picker("Sort By", selection: $sort) {
                ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if librarySync.isSyncing, allBooks.isEmpty {
            ProgressView("Loading your library…")
        } else if allBooks.isEmpty {
            ContentUnavailableView {
                Label("No Books Yet", systemImage: "books.vertical")
            } description: {
                Text("Connect a Grimmory server, or add EPUB books from Files.")
            } actions: {
                Button("Add Grimmory Server") { actions.isAddingServer = true }
                    .buttonStyle(.borderedProminent)
                Button("Add Books from Files") { actions.isImporting = true }
            }
        } else {
            ContentUnavailableView("Nothing Here Yet", systemImage: filter.symbol,
                                   description: Text("Books show up here as you read and download them."))
        }
    }
}

/// What a library tile shows under its cover. Chosen in Settings (the Accounts sheet).
enum LibraryTileStyle: String, CaseIterable {
    /// Title, author and a small progress ring.
    case detailed
    /// Only the progress or status, and a menu of actions.
    case compact

    static let storageKey = "libraryTileStyle"

    var title: String {
        switch self {
        case .detailed: "Title and Author"
        case .compact: "Cover Only"
        }
    }
}

/// Books as a grid of covers, each opening its detail page, with the book's actions in the context menu (and, for
/// cover-only tiles, a "⋯" button).
struct BookGrid: View {
    let books: [Book]
    /// Shows "Book 2" under each title, for a series.
    var showsSeriesNumber = false
    @Environment(DownloadCenter.self) private var downloads
    @Environment(LocalImporter.self) private var importer
    @AppStorage(LibraryTileStyle.storageKey) private var style: LibraryTileStyle = .detailed
    @State private var bookToDelete: Book?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 20)], spacing: 24) {
            ForEach(books) { book in
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink(value: book) {
                        BookTile(book: book, showsSeriesNumber: showsSeriesNumber, style: style)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: book) }
                    if style == .compact {
                        // Outside the link, so the menu button doesn't open the book.
                        HStack {
                            Text(book.tileStatus)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Menu("Actions for \(book.title)", systemImage: "ellipsis") { menu(for: book) }
                                .labelStyle(.iconOnly)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 32, minHeight: 28, alignment: .trailing)
                                .contentShape(.rect)
                        }
                    }
                }
            }
        }
        .padding()
        .confirmationDialog("Delete \(bookToDelete?.title ?? "") from this device?",
                            isPresented: .init(get: { bookToDelete != nil }, set: { if !$0 { bookToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let book = bookToDelete { importer.delete(book) }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    @ViewBuilder private func menu(for book: Book) -> some View {
        StatusPicker(book: book)
        if book.account?.kind == .local {
            Button("Delete from Library", systemImage: "trash", role: .destructive) { bookToDelete = book }
        } else if let file = book.readableFile {
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

/// A book's read status as a menu, saved and sent when it changes. On the book page and in the book menu.
struct StatusPicker: View {
    let book: Book
    @Environment(LibrarySync.self) private var librarySync
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Picker("Status", systemImage: "bookmark", selection: Binding {
            book.status
        } set: { status in
            book.readStatus = status == .unset ? nil : status.rawValue
            librarySync.queue(.readStatus, for: book, in: modelContext)
        }) {
            ForEach(GrimmoryReadStatus.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
    }
}

extension Book {
    var status: GrimmoryReadStatus { readStatus.flatMap(GrimmoryReadStatus.init(rawValue:)) ?? .unset }

    /// Under a cover-only tile: how far along, or else the status.
    var tileStatus: String {
        if isInProgress, let fraction = progress?.fraction, fraction > 0 { return fraction.formatted(.percent.precision(.fractionLength(0))) }
        if status != .unset { return status.title }
        return (progress?.fraction ?? 0) > 0 ? "Read" : "New"
    }
}

private struct BookTile: View {
    let book: Book
    var showsSeriesNumber = false
    var style: LibraryTileStyle = .detailed
    @Environment(DownloadCenter.self) private var downloads

    var body: some View {
        let tile = VStack(alignment: .leading, spacing: 6) {
            CoverView(book: book)
                .overlay(alignment: .bottomTrailing) { downloadBadge.padding(6) }
            if style == .detailed {
                details
            }
        }
        .contentShape(.rect)
        if style == .detailed {
            tile.accessibilityElement(children: .combine).accessibilityHint(accessibilityHint)
        } else {
            // No title on screen, so name the book for VoiceOver (the status beside it reads on its own).
            tile.accessibilityElement(children: .ignore).accessibilityLabel(book.title).accessibilityHint(accessibilityHint)
        }
    }

    /// Always the same height (two title lines, one author line), so covers in a row line up; longer text is cut
    /// off with "…".
    @ViewBuilder private var details: some View {
        if showsSeriesNumber {
            Text(book.seriesNumber.map { "Book \($0.formatted())" } ?? " ")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(book.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2, reservesSpace: true)
            Spacer(minLength: 0)
            if let fraction = book.progress?.fraction, fraction > 0 {
                ProgressRing(fraction: fraction, lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        Text(book.authors.first ?? " ")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
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

extension LibraryContent where Header == EmptyView {
    /// A collection on its own (a Home "See All"), titled after itself.
    init(filter: LibraryFilter, title: String) {
        self.init(filter: filter, title: title, header: { EmptyView() })
    }
}
