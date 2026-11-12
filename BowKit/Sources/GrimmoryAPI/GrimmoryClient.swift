import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import HTTPTypes

/// Bow's entry point to one Grimmory account. Wraps the generated client (internal) and maps its loosely typed
/// DTOs (everything optional, as Spring's spec declares them) into Bow's domain types.
public final class GrimmoryClient: Sendable {
    public typealias URLLoader = @Sendable (URL) async throws -> Data

    public let serverURL: URL
    let client: Client
    let session: GrimmorySession
    let transport: any ClientTransport
    /// Fetches non-Grimmory URLs (the identity provider's OIDC discovery document).
    let loadURL: URLLoader

    /// - Parameter serverURL: The server root, e.g. `https://books.example.com` (no `/api`).
    public init(
        serverURL: URL,
        tokenStore: any GrimmoryTokenStore,
        transport: any ClientTransport = URLSessionTransport(),
        loadURL: @escaping URLLoader = GrimmoryClient.loadOverHTTP,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.serverURL = serverURL
        self.loadURL = loadURL
        self.transport = transport
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
        if case .ok(let versionOK) = try await unwrapped({ try await client.getVersionInfo() }) {
            version = try versionOK.body.json.current
        }

        var needsSetup = false
        if case .ok(let setupOK) = try await unwrapped({ try await client.getSetupStatus() }) {
            needsSetup = try setupOK.body.json.data == false
        }

        var oidc: GrimmoryServerInfo.OIDCProvider?
        if settings.oidcEnabled == true,
           let details = settings.oidcProviderDetails,
           let issuer = details.issuerUri.flatMap(URL.init(string:)),
           let clientID = details.clientId {
            oidc = .init(name: details.providerName, issuer: issuer, clientID: clientID,
                         scopes: details.scopes.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultOIDCScopes)
        }
        return GrimmoryServerInfo(
            version: version,
            needsSetup: needsSetup,
            oidc: oidc,
            passwordLoginAllowed: !(settings.oidcEnabled == true && settings.oidcForceOnlyMode == true),
            remoteAuthEnabled: settings.remoteAuthEnabled ?? false
        )
    }

    /// The scopes Grimmory's web app asks for when the admin didn't set any.
    static let defaultOIDCScopes = "openid profile email groups offline_access"

    /// Creates the first (admin) account on a server that has none yet (`serverInfo().needsSetup`), then signs in.
    @discardableResult
    public func createFirstAdmin(username: String, name: String, email: String, password: String) async throws
        -> GrimmoryUser {
        let output = try await unwrapped {
            try await client.setupFirstUser(body: .json(.init(email: email, name: name, password: password,
                                                              username: username)))
        }
        guard case .ok = output else { throw GrimmoryError(status: statusCode(of: output)) }
        return try await signIn(username: username, password: password)
    }

    // MARK: Account

    public var isSignedIn: Bool {
        get async { (try? await session.tokens()) != nil }
    }

    @discardableResult
    public func signIn(username: String, password: String) async throws -> GrimmoryUser {
        let output = try await unwrapped { try await client.loginUser(body: .json(.init(password: password, username: username))) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        return try await finishSignIn(try ok.body.json)
    }

    /// Signs in as the user a reverse proxy (Authelia, Authentik, …) vouches for with its headers, when the
    /// server has remote auth on (`serverInfo().remoteAuthEnabled`). The request must reach Grimmory through the
    /// proxy with the proxy's session, so the app signs in to the proxy first (in a web view) and shares its
    /// cookies with the transport. Throws `.forbidden` if remote auth is off.
    @discardableResult
    public func signInWithRemoteAuth() async throws -> GrimmoryUser {
        let output = try await unwrapped { try await client.loginRemote() }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        return try await finishSignIn(try ok.body.json)
    }

    /// Stores the tokens from any sign-in method and loads the user.
    func finishSignIn(_ dto: Components.Schemas.AccessTokenDto) async throws -> GrimmoryUser {
        try await session.setTokens(try Self.tokens(from: dto, now: Date()))
        var user = try await currentUser()
        user.hasDefaultPassword = user.hasDefaultPassword || (dto.isDefaultPassword ?? false)
        return user
    }

    /// For accounts still on the password an admin set (`GrimmoryUser.hasDefaultPassword`).
    public func changePassword(current: String, new: String) async throws {
        let output = try await unwrapped {
            try await client.changePassword(body: .json(.init(currentPassword: current, newPassword: new)))
        }
        guard case .ok = output else { throw GrimmoryError(status: statusCode(of: output)) }
    }

    /// Revokes the session on the server when it can, and always forgets the tokens locally.
    ///
    /// - Returns: For OIDC accounts, the identity provider's end-session URL, if Grimmory built one. Opening it
    ///   ends the provider session too; otherwise the next OIDC sign-in may go straight through.
    @discardableResult
    public func signOut() async throws -> URL? {
        var providerLogoutURL: URL?
        if let tokens = try? await session.tokens(),
           case .ok(let ok)? = try? await client.logout(body: .json(.init(refreshToken: tokens.refreshToken))) {
            providerLogoutURL = (try? ok.body.json.logoutUrl).flatMap { $0 }.flatMap(URL.init(string:))
        }
        try await session.clear()
        return providerLogoutURL
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

    // MARK: Media

    /// The book's cover thumbnail (JPEG). Grimmory changes `coverUpdatedOn` whenever it changes, so cache by that.
    public func thumbnail(bookID: Int64) async throws -> Data {
        try await authorizedData(path: "/api/v1/media/book/\(bookID)/thumbnail", operationID: "getBookThumbnail")
    }

    /// A GET for binary endpoints the generated client doesn't cover. Goes through the same `AuthMiddleware`, so it
    /// gets the bearer token, the single-flight refresh on 401, and proxy-page detection.
    func authorizedData(path: String, operationID: String) async throws -> Data {
        var request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: path)
        request.headerFields[.accept] = "*/*"
        let middleware = AuthMiddleware(session: session)
        let (response, body) = try await middleware.intercept(
            request, body: nil, baseURL: serverURL, operationID: operationID
        ) { [transport] request, body, baseURL in
            try await transport.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
        guard response.status == .ok else { throw GrimmoryError(status: response.status.code) }
        guard let body else { return Data() }
        return try await Data(collecting: body, upTo: 50 * 1024 * 1024)
    }

    // MARK: Mapping

    /// The default `loadURL`: a plain GET that fails on non-2xx.
    public static let loadOverHTTP: URLLoader = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GrimmoryError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

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
/// so callers see the real error: `GrimmoryError.signedOut` from the middleware, `URLError` from the network,
/// `DecodingError` from a malformed response.
func unwrapped<T>(_ call: () async throws -> T) async throws -> T {
    do {
        return try await call()
    } catch let error as ClientError {
        throw error.underlyingError
    }
}

/// The status code of a generated `Output` that isn't `.ok`. Most of Grimmory's spec documents only 200, so
/// errors arrive as `.undocumented(statusCode:_:)`; the few documented ones get named cases like `.forbidden`.
func statusCode(of output: some Sendable) -> Int {
    guard let child = Mirror(reflecting: output).children.first, let label = child.label else { return 0 }
    if label == "undocumented" {
        return Mirror(reflecting: child.value).children.first?.value as? Int ?? 0
    }
    return documentedStatusCodes[label] ?? 0
}

/// swift-openapi-generator's case names for documented status codes.
private let documentedStatusCodes: [String: Int] = [
    "ok": 200, "created": 201, "accepted": 202, "noContent": 204,
    "badRequest": 400, "unauthorized": 401, "forbidden": 403, "notFound": 404, "conflict": 409,
    "unprocessableContent": 422, "tooManyRequests": 429,
    "internalServerError": 500, "badGateway": 502, "serviceUnavailable": 503,
]
