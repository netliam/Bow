import AuthenticationServices
import BowModel
import BowSync
import GrimmoryAPI
import SwiftData
import SwiftUI

/// Connects a Grimmory server: asks for its address, reads which sign-in methods it allows, and offers exactly
/// those: first-run setup, password, OIDC and proxy (remote) auth.
struct AddServerView: View {
    /// Called with the new account's id once it's saved.
    let onAdded: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var address = ""
    @State private var server: ConnectedServer?
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var email = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var isShowingProxySignIn = false
    @State private var pendingPasswordChange: PendingAccount?

    /// The server being signed in to. The account id is picked now because tokens are stored under it.
    struct ConnectedServer {
        let url: URL
        let accountID = UUID()
        let info: GrimmoryServerInfo
        var client: GrimmoryClient { GrimmoryAccounts.client(serverURL: url, accountID: accountID) }
    }

    struct PendingAccount: Identifiable {
        let id: UUID
        let client: GrimmoryClient
        let currentPassword: String
    }

    var body: some View {
        NavigationStack {
            Form {
                if let server {
                    signInSections(server)
                } else {
                    addressSection
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)
            .navigationTitle(server == nil ? "Add Server" : (server?.url.host() ?? "Sign In"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if let server { GrimmoryAccounts.forget(accountID: server.accountID) }
                        dismiss()
                    }
                }
                if isWorking {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
        }
        .sheet(isPresented: $isShowingProxySignIn) {
            if let server {
                ProxySignInView(serverURL: server.url, client: server.client) { user in
                    isShowingProxySignIn = false
                    finish(server, user: user, password: nil)
                }
            }
        }
        .sheet(item: $pendingPasswordChange, onDismiss: { completeAfterPasswordChange() }) { pending in
            ChangePasswordView(client: pending.client, currentPassword: pending.currentPassword)
        }
    }

    // MARK: Steps

    private var addressSection: some View {
        Section {
            TextField("books.example.com", text: $address)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await connect() } }
            Button("Continue") { Task { await connect() } }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Server Address")
        } footer: {
            Text("The address you use for Grimmory in a browser. HTTPS is assumed unless you type http://.")
        }
    }

    @ViewBuilder private func signInSections(_ server: ConnectedServer) -> some View {
        let info = server.info
        if info.needsSetup {
            Section {
                TextField("Name", text: $name).textContentType(.name)
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password).textContentType(.newPassword)
                Button("Create Admin Account") { Task { await createAdmin(server) } }
                    .disabled([name, username, email, password].contains { $0.isEmpty })
            } header: {
                Text("Set Up This Server")
            } footer: {
                Text("This Grimmory server has no accounts yet. The first one is the administrator.")
            }
        } else {
            if let oidc = info.oidc {
                Section {
                    Button("Sign in with \(oidc.name ?? "Single Sign-On")") { Task { await signInWithOIDC(server, oidc) } }
                }
            }
            if info.passwordLoginAllowed {
                Section(info.oidc == nil ? "Sign In" : "Or use a password") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit { Task { await signInWithPassword(server) } }
                    Button("Sign In") { Task { await signInWithPassword(server) } }
                        .disabled(username.isEmpty || password.isEmpty)
                }
            }
            if info.remoteAuthEnabled {
                Section {
                    Button("Sign in through \(server.url.host() ?? "the server")'s login page") {
                        isShowingProxySignIn = true
                    }
                } footer: {
                    Text("For servers behind a sign-in proxy such as Authelia or Authentik.")
                }
            }
        }
        if let version = info.version {
            Section { LabeledContent("Grimmory", value: version) }
        }
    }

    // MARK: Actions

    private func connect() async {
        guard let url = GrimmoryAccounts.normalizedServerURL(address) else {
            errorMessage = "That doesn't look like a server address."
            return
        }
        await run {
            let accountID = UUID()
            let info = try await GrimmoryAccounts.client(serverURL: url, accountID: accountID).serverInfo()
            GrimmoryAccounts.forget(accountID: accountID)
            server = ConnectedServer(url: url, info: info)
        }
    }

    private func signInWithPassword(_ server: ConnectedServer) async {
        await run {
            let user = try await server.client.signIn(username: username, password: password)
            finish(server, user: user, password: password)
        }
    }

    private func createAdmin(_ server: ConnectedServer) async {
        await run {
            let user = try await server.client.createFirstAdmin(username: username, name: name, email: email,
                                                                password: password)
            finish(server, user: user, password: password)
        }
    }

    private func signInWithOIDC(_ server: ConnectedServer, _ provider: GrimmoryServerInfo.OIDCProvider) async {
        await run {
            let request = try await server.client.beginOIDCSignIn(provider: provider)
            let callback: URL
            do {
                // `.shared` reuses the browser's provider session, so someone already signed in skips the form.
                callback = try await webAuthenticationSession.authenticate(
                    using: request.authorizationURL,
                    callbackURLScheme: request.callbackScheme,
                    preferredBrowserSession: .shared
                )
            } catch ASWebAuthenticationSessionError.canceledLogin {
                return
            }
            let user = try await server.client.completeOIDCSignIn(request, callbackURL: callback)
            finish(server, user: user, password: nil)
        }
    }

    /// Saves the account. A password the admin set is changed first, as the web app requires.
    private func finish(_ server: ConnectedServer, user: GrimmoryUser, password: String?) {
        let account = Account(id: server.accountID, kind: .grimmory, displayName: server.url.host() ?? "Grimmory",
                              serverURL: server.url, username: user.username)
        modelContext.insert(account)
        try? modelContext.save()

        if user.hasDefaultPassword, let password {
            pendingPasswordChange = PendingAccount(id: server.accountID, client: server.client, currentPassword: password)
        } else {
            onAdded(server.accountID)
            dismiss()
        }
    }

    private func completeAfterPasswordChange() {
        guard let server else { return }
        onAdded(server.accountID)
        dismiss()
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case GrimmoryError.unauthorized: "Wrong username or password."
        case GrimmoryError.forbidden: "The server refused. Your account may not be allowed to sign in this way."
        case GrimmoryError.notFound: "No Grimmory server found at that address."
        case GrimmoryError.webPageInsteadOfAPI:
            "The server answered with a web page instead of Grimmory. Check the address, or if it's behind a sign-in proxy, sign in through its login page."
        case GrimmoryError.oidcFailed(let reason): "Single sign-on failed: \(reason)."
        case GrimmoryError.unexpectedResponse: "That server doesn't look like Grimmory."
        case let error as URLError:
            switch error.code {
            case .appTransportSecurityRequiresSecureConnection:
                "Bow only allows plain http:// for servers on your local network. Use https:// for this server."
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                "Couldn't reach a server at that address. Check it, and that the server is running."
            case .timedOut: "The server took too long to answer."
            case .notConnectedToInternet, .networkConnectionLost: "You're offline."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                "The server's HTTPS certificate isn't trusted by this device."
            default: error.localizedDescription
            }
        case is DecodingError: "That server doesn't look like Grimmory."
        default: error.localizedDescription
        }
    }
}
