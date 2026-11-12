import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// Bow's entry point to one Grimmory account. Wraps the generated client (internal) and maps its loosely typed
/// DTOs (everything optional, as Spring's spec declares them) into Bow's domain types.
public final class GrimmoryClient: Sendable {
    public let serverURL: URL
    private let client: Client
    private let session: GrimmorySession

    /// - Parameter serverURL: The server root, e.g. `https://books.example.com` (no `/api`).
    public init(
        serverURL: URL,
        tokenStore: any GrimmoryTokenStore,
        transport: any ClientTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.serverURL = serverURL
        let configuration = Configuration(dateTranscoder: GrimmoryDateTranscoder())

        // Refreshing goes through a client without the auth middleware, so it can't recurse into itself.
        let anonymous = Client(serverURL: serverURL, configuration: configuration, transport: transport)
        let session = GrimmorySession(store: tokenStore, now: now) { refreshToken in
            let output = try await unwrapped { try await anonymous.refreshToken(body: .json(.init(refreshToken: refreshToken))) }
            guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
            return try Self.tokens(from: try ok.body.json, now: now())
        }
        self.session = session
        self.client = Client(
            serverURL: serverURL,
            configuration: configuration,
            transport: transport,
            middlewares: [AuthMiddleware(session: session)]
        )
    }

    // MARK: Server

    /// Checks that `serverURL` is a Grimmory server and reads what the sign-in screen needs. Needs no account.
    public func serverInfo() async throws -> GrimmoryServerInfo {
        let settingsOutput = try await unwrapped { try await client.getPublicSettings() }
        guard case .ok(let ok) = settingsOutput else { throw GrimmoryError(status: statusCode(of: settingsOutput)) }
        let settings = try ok.body.json

        var version: String?
        if case .ok(let versionOK) = try await unwrapped { try await client.getVersionInfo() } {
            version = try versionOK.body.json.current
        }

        var oidc: GrimmoryServerInfo.OIDCProvider?
        if settings.oidcEnabled == true,
           let details = settings.oidcProviderDetails,
           let issuer = details.issuerUri.flatMap(URL.init(string:)),
           let clientID = details.clientId {
            oidc = .init(name: details.providerName, issuer: issuer, clientID: clientID,
                         scopes: details.scopes ?? "openid profile email offline_access")
        }
        return GrimmoryServerInfo(
            version: version,
            oidc: oidc,
            passwordLoginAllowed: !(settings.oidcEnabled == true && settings.oidcForceOnlyMode == true)
        )
    }

    // MARK: Account

    public var isSignedIn: Bool {
        get async { (try? await session.tokens()) != nil }
    }

    @discardableResult
    public func signIn(username: String, password: String) async throws -> GrimmoryUser {
        let output = try await unwrapped { try await client.loginUser(body: .json(.init(password: password, username: username))) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        let dto = try ok.body.json
        try await session.setTokens(try Self.tokens(from: dto, now: Date()))
        var user = try await currentUser()
        user.hasDefaultPassword = dto.isDefaultPassword ?? false
        return user
    }

    /// Revokes the session on the server when it can, and always forgets the tokens locally.
    public func signOut() async throws {
        if let tokens = try? await session.tokens() {
            _ = try? await client.logout(body: .json(.init(refreshToken: tokens.refreshToken)))
        }
        try await session.clear()
    }

    public func currentUser() async throws -> GrimmoryUser {
        let output = try await unwrapped { try await client.getMyself() }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        let dto = try ok.body.json
        guard let id = dto.id, let username = dto.username else {
            throw GrimmoryError.unexpectedResponse("user without id or username")
        }
        let p = dto.permissions
        var permissions = GrimmoryPermissions()
        permissions.isAdmin = p?.admin ?? false
        permissions.canDownload = p?.canDownload ?? false
        permissions.canUpload = p?.canUpload ?? false
        permissions.canEditMetadata = p?.canEditMetadata ?? false
        permissions.canEmailBook = p?.canEmailBook ?? false
        permissions.canDeleteBook = p?.canDeleteBook ?? false
        permissions.canAccessBookdrop = p?.canAccessBookdrop ?? false
        permissions.canAccessUserStats = p?.canAccessUserStats ?? false
        permissions.canManageLibrary = p?.canManageLibrary ?? false
        return GrimmoryUser(id: id, username: username, name: dto.name, email: dto.email,
                            permissions: permissions, hasDefaultPassword: dto.defaultPassword ?? false)
    }

    // MARK: Catalog

    /// One page of the user's books. Grimmory caps `pageSize` at 50.
    public func books(page: Int, pageSize: Int = 50) async throws -> GrimmoryPage<GrimmoryBookSummary> {
        let output = try await unwrapped { try await client.appGetBooks(query: .init(page: Int32(page), size: Int32(min(pageSize, 50)))) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        let dto = try ok.body.json
        return GrimmoryPage(
            items: (dto.content ?? []).compactMap(Self.summary),
            page: Int(dto.page ?? Int32(page)),
            totalItems: Int(dto.totalElements ?? 0),
            hasNext: dto.hasNext ?? false
        )
    }

    /// Every book ID the user can see, in one call. Books missing from this list were removed on the server.
    public func allBookIDs() async throws -> [Int64] {
        let output = try await unwrapped { try await client.appGetAllBookIds() }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        return try ok.body.json
    }

    // MARK: Mapping

    static func tokens(from dto: Components.Schemas.AccessTokenDto, now: Date) throws -> GrimmoryTokens {
        guard let access = dto.accessToken, let refresh = dto.refreshToken else {
            throw GrimmoryError.unexpectedResponse("token response without tokens")
        }
        // `expires` is the access token's lifetime in seconds, not a timestamp.
        let lifetime = TimeInterval(dto.expires ?? 7200)
        return GrimmoryTokens(accessToken: access, refreshToken: refresh, accessTokenExpiry: now.addingTimeInterval(lifetime))
    }

    static func summary(_ dto: Components.Schemas.AppBookSummary) -> GrimmoryBookSummary? {
        guard let id = dto.id else { return nil }
        return GrimmoryBookSummary(
            id: id,
            title: dto.title ?? "",
            authors: dto.authors ?? [],
            seriesName: dto.seriesName,
            seriesNumber: dto.seriesNumber.map(Double.init),
            libraryID: dto.libraryId,
            addedOn: dto.addedOn,
            lastReadTime: dto.lastReadTime,
            readProgress: dto.readProgress.map(Double.init),
            readStatus: dto.readStatus,
            personalRating: dto.personalRating.map(Int.init),
            primaryFileID: dto.primaryFileId,
            primaryFileType: dto.primaryFileType,
            coverUpdatedOn: dto.coverUpdatedOn
        )
    }
}

/// Runs a generated call, unwrapping the `ClientError` OpenAPIRuntime wraps around everything thrown inside it,
/// so callers see `GrimmoryError.signedOut` (and others) as themselves.
private func unwrapped<T>(_ call: () async throws -> T) async throws -> T {
    do {
        return try await call()
    } catch let error as ClientError {
        throw (error.underlyingError as? GrimmoryError) ?? error
    }
}

/// The status code of a generated `Output` that isn't `.ok`. Every generated output carries it in
/// `.undocumented(statusCode:_:)`, since Grimmory's spec documents only the 200 responses.
private func statusCode(of output: some Sendable) -> Int {
    guard let child = Mirror(reflecting: output).children.first, child.label == "undocumented",
          let code = Mirror(reflecting: child.value).children.first?.value as? Int
    else { return 0 }
    return code
}
