import BowLibrary
import BowModel
import BowSync
import GrimmoryAPI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Bow's places: Home (what to read next), Library (everything), Stats and Search, plus, in the iPad and Mac
/// sidebar, series, authors and your Grimmory shelves, as Grimmory's web sidebar has them. Tabs on iPhone.
struct RootView: View {
    enum Tab: Hashable { case home, library, stats, search, series, authors, shelf(UUID) }

    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @Environment(BookIntake.self) private var intake
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Shelf.name) private var shelves: [Shelf]

    @State private var tab: Tab = .home
    @State private var actions = AppActions()

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("Home", systemImage: "house", value: Tab.home) {
                NavigationStack {
                    HomeView()
                        .bookDestinations()
                }
            }
            SwiftUI.Tab("Library", systemImage: "books.vertical", value: Tab.library) {
                NavigationStack {
                    LibraryTab()
                        .bookDestinations()
                }
            }
            SwiftUI.Tab("Stats", systemImage: "chart.line.uptrend.xyaxis", value: Tab.stats) {
                NavigationStack {
                    StatsView()
                        .bookDestinations()
                }
            }
            SwiftUI.Tab(value: Tab.search, role: .search) {
                SearchTab()
            }
            // Sidebar only: hidden tabs would still fill a "More" tab on iPhone, where the Library chips reach these.
            if sizeClass == .regular {
                TabSection("Browse") {
                    collectionTab(.series, value: .series)
                    collectionTab(.authors, value: .authors)
                }
                .defaultVisibility(.hidden, for: .tabBar)
            }
            if sizeClass == .regular, !shelves.isEmpty {
                TabSection("Shelves") {
                    ForEach(sortedShelves) { shelf in
                        SwiftUI.Tab(shelf.name, systemImage: ShelfIcon.symbol(for: shelf), value: Tab.shelf(shelf.id)) {
                            NavigationStack {
                                LibraryContent(filter: .shelf(shelf.id), title: shelf.name) { EmptyView() }
                                    .bookDestinations()
                            }
                        }
                        .badge(shelf.books.count(where: { !$0.isRemovedOnServer }))
                    }
                }
                .defaultVisibility(.hidden, for: .tabBar)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .fileImporter(isPresented: $actions.isImporting, allowedContentTypes: Self.bookTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { intake.receive(urls) }
        }
        .sheet(isPresented: .init(get: { !intake.staged.isEmpty }, set: { if !$0 { intake.clear() } })) {
            AddBooksSheet()
        }
        .sheet(isPresented: $actions.isAddingServer) {
            AddServerView { _ in
                tab = .home
                Task { await librarySync.syncAll(modelContext.container) }
            }
        }
        .sheet(isPresented: $actions.isShowingAccounts) {
            AccountsView()
        }
        .task { await librarySync.syncAll(modelContext.container) }
        // Outermost, so the sheets above get it too: a sheet's content reads the environment where it's attached.
        .environment(actions)
    }
}

extension RootView {
    /// Regular shelves first, then magic ones, each by name, as Grimmory lists them.
    private var sortedShelves: [Shelf] {
        shelves.filter { $0.account?.kind == .grimmory }
            .sorted { ($0.kind == .regular ? 0 : 1, $0.name) < ($1.kind == .regular ? 0 : 1, $1.name) }
    }

    private func collectionTab(_ filter: LibraryFilter, value: Tab) -> some TabContent<Tab> {
        SwiftUI.Tab(filter.title, systemImage: filter.symbol, value: value) {
            NavigationStack {
                LibraryContent(filter: filter, title: filter.title) { EmptyView() }
                    .bookDestinations()
            }
        }
    }

    /// What the file picker offers: EPUBs, plus PDFs and comics when there's a server to upload them to.
    static var bookTypes: [UTType] {
        [.epub, .pdf] + ["cbz", "cbr", "cb7"].compactMap { UTType(filenameExtension: $0) }
    }
}

/// App-wide actions any screen can start: adding a server, importing files, managing accounts.
@Observable
final class AppActions {
    var isAddingServer = false
    var isImporting = false
    var isShowingAccounts = false
}

extension View {
    /// Where a tab's navigation stack can go: a book, a series or author, or a library collection.
    func bookDestinations() -> some View {
        navigationDestination(for: Book.self) { BookDetailView(book: $0) }
            .navigationDestination(for: BookCollection.self) { CollectionView(collection: $0) }
            .navigationDestination(for: LibraryFilter.self) { filter in
                LibraryContent(filter: filter, title: filter.title)
            }
    }

    /// The account button at the top of Home and Library.
    func accountToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .primaryAction) { AccountButton() }
        }
    }
}

/// The signed-in account's initials (or a person), opening accounts and settings.
struct AccountButton: View {
    @Environment(AppActions.self) private var actions
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    var body: some View {
        Button {
            actions.isShowingAccounts = true
        } label: {
            if let initials {
                Text(initials)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.gradient, in: .circle)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel("Accounts")
    }

    private var initials: String? {
        guard let account = accounts.first(where: { $0.kind == .grimmory }) else { return nil }
        let name = account.username ?? account.displayName
        return String(name.prefix(2)).uppercased()
    }
}
