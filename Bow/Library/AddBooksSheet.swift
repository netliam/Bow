import BowModel
import BowSync
import GrimmoryAPI
import SwiftData
import SwiftUI

/// Asks where new book files should go: this device, a Grimmory library folder, or Grimmory's bookdrop. Only the
/// destinations the account is allowed show (`canUpload`, `canAccessBookdrop`). Then shows each file's upload.
struct AddBooksSheet: View {
    @Environment(BookIntake.self) private var intake
    @Environment(LibrarySync.self) private var librarySync
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    @State private var options: [UUID: ServerOptions] = [:]
    @State private var isUploading = false
    @State private var sentTo: GrimmoryUploadDestination?

    /// What one account lets this user do.
    struct ServerOptions {
        var folders: [GrimmoryUploadFolder] = []
        var canUpload = false
        var canBookdrop = false
        var error: String?
        var isLoaded = false
    }

    private var servers: [Account] { accounts.filter { $0.kind == .grimmory } }
    private var isFinished: Bool { !intake.staged.isEmpty && intake.staged.allSatisfy { $0.state == .done } }

    var body: some View {
        NavigationStack {
            List {
                if !intake.staged.isEmpty {  // Empty only while closing.
                    Section(intake.staged.count == 1 ? "1 Book" : "\(intake.staged.count) Books") {
                        ForEach(intake.staged) { file in fileRow(file) }
                    }
                }
                if sentTo == nil {
                    destinations
                } else if isFinished {
                    Section { finishedMessage }
                }
            }
            .navigationTitle("Add Books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isFinished {
                        Button("Cancel") { close() }.disabled(isUploading)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isFinished || (sentTo != nil && !isUploading) { Button("Done") { close() } }
                }
            }
            .task { await loadOptions() }
            .interactiveDismissDisabled(isUploading)
        }
    }

    // MARK: Destinations

    @ViewBuilder private var destinations: some View {
        ForEach(servers) { account in
            let server = options[account.id] ?? ServerOptions()
            Section {
                if !server.isLoaded {
                    HStack {
                        ProgressView()
                        Text("Checking what you can upload…").foregroundStyle(.secondary)
                    }
                } else if let error = server.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    if server.canUpload {
                        ForEach(server.folders) { folder in
                            destinationButton(
                                title: "Add to \(folder.libraryName)",
                                detail: server.folders.filter { $0.libraryID == folder.libraryID }.count > 1
                                    ? folder.path : "Shows up in your library right away.",
                                symbol: "books.vertical", destination: folder.destination, account: account
                            )
                        }
                    }
                    if server.canBookdrop {
                        destinationButton(title: "Send to Bookdrop",
                                          detail: "Review the details in Grimmory before it joins a library.",
                                          symbol: "tray.and.arrow.down", destination: .bookdrop, account: account)
                    }
                    if !server.canUpload, !server.canBookdrop {
                        Label("Your account on this server can't upload books.", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(account.displayName)
            }
        }
        Section {
            Button {
                intake.keepOnDevice()
                if intake.staged.isEmpty { dismiss() }
            } label: {
                DestinationLabel(title: "Keep on This Device",
                                 detail: intake.staged.allSatisfy(\.isEPUB)
                                     ? "Only on this device. Not added to any server."
                                     : "EPUBs only. Other files stay here to upload.",
                                 symbol: "ipad.and.iphone")
            }
            .disabled(!intake.staged.contains(where: \.isEPUB))
        }
    }

    private func destinationButton(title: String, detail: String, symbol: String,
                                   destination: GrimmoryUploadDestination, account: Account) -> some View {
        Button {
            sentTo = destination
            isUploading = true
            Task {
                await intake.upload(to: destination, account: account) {
                    await librarySync.syncAll(modelContext.container)
                }
                isUploading = false
            }
        } label: {
            DestinationLabel(title: title, detail: detail, symbol: symbol)
        }
    }

    // MARK: Files

    private func fileRow(_ file: BookIntake.StagedFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isEPUB ? "book.closed" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(2)
                if case .failed(let reason) = file.state {
                    Text(reason).font(.footnote).foregroundStyle(.red)
                }
            }
            Spacer()
            switch file.state {
            case .waiting: EmptyView()
            case .uploading: ProgressView()
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var finishedMessage: some View {
        if sentTo == .bookdrop {
            Label("In the bookdrop. Open Grimmory to review the details and add them to a library.",
                  systemImage: "tray.and.arrow.down")
        } else {
            Label("Added to your library. They'll show up once the library refreshes.", systemImage: "checkmark")
        }
    }

    // MARK: Actions

    private func loadOptions() async {
        for account in servers {
            guard let client = GrimmoryAccounts.client(for: account) else {
                options[account.id] = ServerOptions(error: "Sign in again to upload here.", isLoaded: true)
                continue
            }
            do {
                let permissions = try await client.currentUser().permissions
                var server = ServerOptions(canUpload: permissions.canUpload || permissions.isAdmin,
                                           canBookdrop: permissions.canAccessBookdrop || permissions.isAdmin,
                                           isLoaded: true)
                if server.canUpload {
                    server.folders = (try? await client.uploadFolders()) ?? []
                    if server.folders.isEmpty { server.canUpload = false }
                }
                options[account.id] = server
            } catch {
                options[account.id] = ServerOptions(error: "Couldn't reach the server.", isLoaded: true)
            }
        }
    }

    private func close() {
        intake.clear()
        dismiss()
    }
}

private struct DestinationLabel: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.accentColor)
                // Plain grey: inside a button, `.secondary` would be a lighter shade of the tint.
                Text(detail).font(.footnote).foregroundStyle(Color(uiColor: .secondaryLabel))
            }
        }
        .padding(.vertical, 4)
    }
}
