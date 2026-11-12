import GrimmoryAPI
import SwiftUI

/// Shown after signing in with a password an admin set. Grimmory's web app makes users change it; Bow does too,
/// but allows "Later" since the account works either way.
struct ChangePasswordView: View {
    let client: GrimmoryClient
    let currentPassword: String

    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New Password", text: $newPassword).textContentType(.newPassword)
                    SecureField("Confirm New Password", text: $confirmation).textContentType(.newPassword)
                } footer: {
                    Text("This account still has the password an administrator set. Choose your own.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)
            .navigationTitle("Change Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Change") { Task { await change() } }
                        .disabled(newPassword.isEmpty || newPassword != confirmation)
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private func change() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.changePassword(current: currentPassword, new: newPassword)
            dismiss()
        } catch {
            errorMessage = AddServerView.message(for: error)
        }
    }
}
