import BowLibrary
import BowModel
import BowSync
import GrimmoryAPI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar of libraries (collapses to a stack on iPhone) and the selected library's books.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @Environment(LocalImporter.self) private var importer
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    @State private var selection: LibrarySelection? = .all
    @State private var isAddingServer = false
    @State private var isImporting = false
    @State private var accountToRemove: Account?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("All Books", systemImage: "books.vertical")
                    .tag(LibrarySelection.all)

                if let local = accounts.first(where: { $0.kind == .local }) {
                    Label(local.displayName, systemImage: "ipad.and.iphone")
                        .tag(LibrarySelection.account(local.id))
                }

                ForEach(grimmoryAccounts) { account in
                    Section(account.displayName) {
                        Label("Library", systemImage: "server.rack")
                            .tag(LibrarySelection.account(account.id))
                            .contextMenu {
                                Button("Sign Out and Remove…", role: .destructive) { accountToRemove = account }
                            }
                        ForEach(shelves(of: account, .regular)) { shelf in
                            Label(shelf.name, systemImage: ShelfIcon.symbol(for: shelf))
                                .tag(LibrarySelection.shelf(shelf.id))
                        }
                        ForEach(shelves(of: account, .magic)) { shelf in
                            Label(shelf.name, systemImage: ShelfIcon.symbol(for: shelf))
                                .tag(LibrarySelection.shelf(shelf.id))
                        }
                    }
                }
            }
            .navigationTitle("Bow")
            .toolbar {
                Menu("Add", systemImage: "plus") {
                    Button("Add Grimmory Server", systemImage: "server.rack") { isAddingServer = true }
                    Button("Add Books from Files", systemImage: "doc.badge.plus") { isImporting = true }
                }
            }
        } detail: {
            NavigationStack {
                LibraryView(accountID: selection?.accountID, shelfID: selection?.shelfID,
                            isAddingServer: $isAddingServer, isImporting: $isImporting)
                    .id(selection)
                    .navigationTitle(title)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importer.importFiles(urls) }
        }
        .sheet(isPresented: $isAddingServer) {
            AddServerView { accountID in
                selection = .account(accountID)
                Task { await librarySync.syncAll(modelContext.container) }
            }
        }
        .confirmationDialog("Sign out of \(accountToRemove?.displayName ?? "")?",
                            isPresented: .init(get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Sign Out and Remove", role: .destructive) {
                if let account = accountToRemove { Task { await remove(account) } }
            }
        } message: {
            Text("Its books are removed from this device. Nothing changes on the server.")
        }
        .task { await librarySync.syncAll(modelContext.container) }
    }

    private var grimmoryAccounts: [Account] { accounts.filter { $0.kind == .grimmory } }

    private func shelves(of account: Account, _ kind: Shelf.Kind) -> [Shelf] {
        account.shelves
            .filter { $0.kind == kind }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var title: String {
        if let shelfID = selection?.shelfID {
            return accounts.lazy.flatMap(\.shelves).first { $0.id == shelfID }?.name ?? "Shelf"
        }
        guard let id = selection?.accountID else { return "All Books" }
        return accounts.first { $0.id == id }?.displayName ?? "Library"
    }

    private func remove(_ account: Account) async {
        if let client = GrimmoryAccounts.client(for: account) {
            _ = try? await client.signOut()
        }
        GrimmoryAccounts.forget(accountID: account.id)
        if selection?.accountID == account.id || account.shelves.contains(where: { $0.id == selection?.shelfID }) {
            selection = .all
        }
        for book in account.books { BookStorage.standard.removeFiles(for: book.id) }  // Downloads go too.
        modelContext.delete(account)
        try? modelContext.save()
    }
}

enum LibrarySelection: Hashable {
    case all
    case account(UUID)
    case shelf(UUID)

    var accountID: UUID? {
        if case .account(let id) = self { id } else { nil }
    }

    var shelfID: UUID? {
        if case .shelf(let id) = self { id } else { nil }
    }
}
