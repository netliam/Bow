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
                            IconTile(symbol: "server.rack", color: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName).font(.body.weight(.medium))
                                Text(subtitle(for: account))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { accountToRemove = account }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .controlSize(.small)
                        }
                    }
                    Button {
                        dismiss()
                        actions.isAddingServer = true
                    } label: {
                        Row(title: "Add Grimmory Server", symbol: "plus", color: .green)
                    }
                }
                Section("On This Device") {
                    Button {
                        dismiss()
                        actions.isImporting = true
                    } label: {
                        Row(title: "Add Books from Files", symbol: "doc.badge.plus", color: .orange)
                    }
                    Button {
                        Task { await librarySync.syncAll(modelContext.container) }
                    } label: {
                        Row(title: librarySync.isSyncing ? "Syncing…" : "Sync Now",
                            symbol: "arrow.triangle.2.circlepath", color: .indigo)
                    }
                    .disabled(librarySync.isSyncing)
                }
            }
            .tint(.primary)  // Rows read as list items, not links; Remove keeps its own red.
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

/// A white symbol on a small coloured tile, as in Settings, so every row's text starts at the same place.
private struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color.gradient, in: .rect(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

/// An action row: tile and plain title, so it reads as a list item rather than a link.
private struct Row: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, color: color)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}
