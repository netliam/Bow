import BowLibrary
import BowModel
import BowSync
import GrimmoryAPI
import SwiftData
import SwiftUI

/// Servers Bow is signed in to, and ways to add books.
struct AccountsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppActions.self) private var actions
    @Environment(LibrarySync.self) private var librarySync
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @State private var accountToRemove: Account?

    var body: some View {
        NavigationStack {
            List {
                Section("Servers") {
                    ForEach(accounts.filter { $0.kind == .grimmory }) { account in
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName).font(.body.weight(.medium))
                                Text(subtitle(for: account))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { accountToRemove = account }
                                .buttonStyle(.borderless)
                                .font(.footnote)
                        }
                    }
                    Button("Add Grimmory Server", systemImage: "plus") {
                        dismiss()
                        actions.isAddingServer = true
                    }
                }
                Section("On This Device") {
                    Button("Add Books from Files", systemImage: "doc.badge.plus") {
                        dismiss()
                        actions.isImporting = true
                    }
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await librarySync.syncAll(modelContext.container) }
                    }
                    .disabled(librarySync.isSyncing)
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
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
        }
    }

    private func subtitle(for account: Account) -> String {
        let books = account.books.filter { !$0.isRemovedOnServer }.count
        let user = account.username.map { "\($0) · " } ?? ""
        return "\(user)\(books) book\(books == 1 ? "" : "s")"
    }

    private func remove(_ account: Account) async {
        if let client = GrimmoryAccounts.client(for: account) {
            _ = try? await client.signOut()
        }
        GrimmoryAccounts.forget(accountID: account.id)
        for book in account.books { BookStorage.standard.removeFiles(for: book.id) }  // Downloads go too.
        modelContext.delete(account)
        try? modelContext.save()
    }
}
