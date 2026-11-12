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
    @State private var working: Action?
    @State private var errorMessage: String?
    @State private var isShowingProxySignIn = false
    @State private var pendingPasswordChange: PendingAccount?
    @FocusState private var focus: Field?

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

    /// What's running, so only that button shows a spinner.
    enum Action { case connect, singleSignOn, password, setup }
    enum Field: Hashable { case address, name, username, email, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if let server {
                        VStack(spacing: 28) {
                            serverCard(server)
                            if server.info.needsSetup {
                                setupForm(server)
                            } else {
                                signInOptions(server)
                            }
                        }
                        .transition(.push(from: .trailing))
                    } else {
                        VStack(spacing: 28) {
                            addressStep
                            errorBanner
                        }
                        .transition(.push(from: .leading))
                    }
                }
                .padding(24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .animation(.smooth, value: server?.url)
                .animation(.smooth, value: errorMessage)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(.systemGroupedBackground))
            .disabled(working != nil)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if let server { GrimmoryAccounts.forget(accountID: server.accountID) }
                        dismiss()
                    }
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

    /// Shown next to whatever failed: under Continue on the address step, under the heading when signing in.
    @ViewBuilder private var errorBanner: some View {
        if let errorMessage {
            ErrorBanner(message: errorMessage)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private var addressStep: some View {
        VStack(spacing: 28) {
            Header(symbol: "books.vertical.fill", title: "Connect to Grimmory",
                   message: "Sign in to your Grimmory server to read your library on this device, and keep your place in sync.")

            VStack(alignment: .leading, spacing: 8) {
                InputField(symbol: "server.rack") {
                    TextField("books.example.com", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.continue)
                        .focused($focus, equals: .address)
                        .onSubmit { Task { await connect() } }
                }
                Text("The address you use for Grimmory in a browser. HTTPS is assumed unless you type http://.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            PrimaryButton("Continue", isWorking: working == .connect) { Task { await connect() } }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { focus = .address }
    }

    private func serverCard(_ server: ConnectedServer) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.url.host() ?? server.url.absoluteString)
                    .font(.headline)
                    .lineLimit(1)
                Text(server.info.version.map { "Grimmory \($0)" } ?? "Grimmory")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Change") {
                GrimmoryAccounts.forget(accountID: server.accountID)
                self.server = nil
                errorMessage = nil
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder private func signInOptions(_ server: ConnectedServer) -> some View {
        let info = server.info
        VStack(spacing: 20) {
            Text("Sign In")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
            errorBanner

            if let oidc = info.oidc {
                PrimaryButton("Continue with \(oidc.name ?? "Single Sign-On")", symbol: "person.badge.key.fill",
                              isWorking: working == .singleSignOn) {
                    Task { await signInWithOIDC(server, oidc) }
                }
            }

            if info.passwordLoginAllowed {
                if info.oidc != nil { OrDivider() }
                VStack(spacing: 12) {
                    InputGroup {
                        InputField(symbol: "person") {
                            TextField("Username", text: $username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.next)
                                .focused($focus, equals: .username)
                                .onSubmit { focus = .password }
                        }
                        InputField(symbol: "lock") {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .submitLabel(.go)
                                .focused($focus, equals: .password)
                                .onSubmit { Task { await signInWithPassword(server) } }
                        }
                    }
                    let canSignIn = !username.isEmpty && !password.isEmpty
                    if info.oidc == nil {
                        PrimaryButton("Sign In", isWorking: working == .password) {
                            Task { await signInWithPassword(server) }
                        }
                        .disabled(!canSignIn)
                    } else {
                        SecondaryButton("Sign In with Password", isWorking: working == .password) {
                            Task { await signInWithPassword(server) }
                        }
                        .disabled(!canSignIn)
                    }
                }
            }

            if info.remoteAuthEnabled {
                VStack(spacing: 8) {
                    SecondaryButton("Use \(server.url.host() ?? "the Server")'s Sign-In Page", symbol: "globe") {
                        isShowingProxySignIn = true
                    }
                    Text("For servers behind a sign-in proxy such as Authelia or Authentik.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .onAppear { if info.oidc == nil, info.passwordLoginAllowed { focus = .username } }
    }

    private func setupForm(_ server: ConnectedServer) -> some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up This Server")
                    .font(.title2.bold())
                Text("This Grimmory server has no accounts yet. The first one you create is the administrator.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            errorBanner

            InputGroup {
                InputField(symbol: "person.text.rectangle") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .submitLabel(.next)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .username }
                }
                InputField(symbol: "person") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .email }
                }
                InputField(symbol: "envelope") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                }
                InputField(symbol: "lock") {
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                        .submitLabel(.done)
                        .focused($focus, equals: .password)
                }
            }

            PrimaryButton("Create Admin Account", isWorking: working == .setup) {
                Task { await createAdmin(server) }
            }
            .disabled([name, username, email, password].contains { $0.isEmpty })
        }
        .onAppear { focus = .name }
    }

    // MARK: Actions

    private func connect() async {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let url = GrimmoryAccounts.normalizedServerURL(address) else {
            errorMessage = "That doesn't look like a server address."
            return
        }
        await run(.connect) {
            let accountID = UUID()
            let info = try await GrimmoryAccounts.client(serverURL: url, accountID: accountID).serverInfo()
            GrimmoryAccounts.forget(accountID: accountID)
            server = ConnectedServer(url: url, info: info)
        }
    }

    private func signInWithPassword(_ server: ConnectedServer) async {
        guard !username.isEmpty, !password.isEmpty else { return }
        await run(.password) {
            let user = try await server.client.signIn(username: username, password: password)
            finish(server, user: user, password: password)
        }
    }

    private func createAdmin(_ server: ConnectedServer) async {
        await run(.setup) {
            let user = try await server.client.createFirstAdmin(username: username, name: name, email: email,
                                                                password: password)
            finish(server, user: user, password: password)
        }
    }

    private func signInWithOIDC(_ server: ConnectedServer, _ provider: GrimmoryServerInfo.OIDCProvider) async {
        await run(.singleSignOn) {
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

    private func run(_ action: Action, _ work: () async throws -> Void) async {
        working = action
        errorMessage = nil
        defer { working = nil }
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
