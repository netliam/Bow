import BowModel
import BowSync
import GrimmoryAPI
import SwiftData
import SwiftUI

/// Sidebar of libraries (collapses to a stack on iPhone) and the selected library's books.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    @State private var selection: LibrarySelection? = .all
    @State private var isAddingServer = false
    @State private var accountToRemove: Account?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("All Books", systemImage: "books.vertical")
                    .tag(LibrarySelection.all)

                if !grimmoryAccounts.isEmpty {
                    Section("Servers") {
                        ForEach(grimmoryAccounts) { account in
                            Label(account.displayName, systemImage: "server.rack")
                                .tag(LibrarySelection.account(account.id))
                                .contextMenu {
                                    Button("Sign Out and Remove…", role: .destructive) { accountToRemove = account }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Bow")
            .toolbar {
                Button("Add Grimmory Server", systemImage: "plus") { isAddingServer = true }
            }
        } detail: {
            NavigationStack {
                LibraryView(accountID: selection?.accountID, isAddingServer: $isAddingServer)
                    .id(selection)
                    .navigationTitle(title)
            }
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

    private var title: String {
        guard let id = selection?.accountID else { return "All Books" }
        return accounts.first { $0.id == id }?.displayName ?? "Library"
    }

    private func remove(_ account: Account) async {
        if let client = GrimmoryAccounts.client(for: account) {
            _ = try? await client.signOut()
        }
        GrimmoryAccounts.forget(accountID: account.id)
        if selection?.accountID == account.id { selection = .all }
        modelContext.delete(account)
        try? modelContext.save()
    }
}

enum LibrarySelection: Hashable {
    case all
    case account(UUID)

    var accountID: UUID? {
        if case .account(let id) = self { id } else { nil }
    }
}
