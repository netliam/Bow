import BowLibrary
import BowModel
import BowSync
import GrimmoryAPI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Bow's three places: Home (what to read next), Library (everything, by collection) and Search. Tabs on iPhone;
/// a sidebar on iPad and Mac.
struct RootView: View {
    enum Tab: Hashable { case home, library, search }

    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @Environment(LocalImporter.self) private var importer

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
            SwiftUI.Tab(value: Tab.search, role: .search) {
                SearchTab()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .fileImporter(isPresented: $actions.isImporting, allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importer.importFiles(urls) }
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
