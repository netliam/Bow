import Foundation
import Testing
@testable import GrimmoryAPI

private let provider = GrimmoryServerInfo.OIDCProvider(
    name: "Authelia", issuer: URL(string: "https://auth.example.com")!, clientID: "grimmory",
    scopes: "openid profile email groups offline_access")

private let discovery: GrimmoryClient.URLLoader = { url in
    guard url.absoluteString == "https://auth.example.com/.well-known/openid-configuration" else {
        throw GrimmoryError.notFound
    }
    return Data(#"{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/api/oidc/authorization?ui=1"}"#.utf8)
}

private func json(_ body: String?) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data((body ?? "").utf8)) as? [String: Any] ?? [:]
}

private func query(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") })
}

@Suite struct OIDCTests {
    /// RFC 7636, appendix B.
    @Test func codeChallengeMatchesRFC7636() {
        #expect(GrimmoryClient.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func beginBuildsTheSameRequestAsTheWebApp() async throws {
        let server = FakeGrimmory { request in
            request.path == "/api/v1/auth/oidc/state" ? (200, #"{"state":"S1"}"#) : (404, "{}")
        }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server,
                                    loadURL: discovery)

        let request = try await client.beginOIDCSignIn(provider: provider)

        #expect(request.callbackScheme == "grimmory")
        #expect(request.authorizationURL.host() == "auth.example.com")
        #expect(request.authorizationURL.path() == "/api/oidc/authorization")
        let q = query(request.authorizationURL)
        #expect(q["ui"] == "1")  // The endpoint's own query survives.
        #expect(q["response_type"] == "code")
        #expect(q["client_id"] == "grimmory")
        #expect(q["redirect_uri"] == "grimmory://oauth2-callback")
        #expect(q["scope"] == "openid profile email groups offline_access")
        #expect(q["state"] == "S1")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["code_challenge"] == GrimmoryClient.codeChallenge(for: request.codeVerifier))
        #expect(q["nonce"] == request.nonce)
        #expect(request.codeVerifier.count >= 43)  // RFC 7636 minimum.
        #expect(await server.requests.allSatisfy { $0.authorization == nil })
    }

    @Test func completeExchangesTheCodeThroughGrimmory() async throws {
        let server = FakeGrimmory { request in
            switch request.path {
            case "/api/v1/auth/oidc/state": (200, #"{"state":"S1"}"#)
            case let path where path.hasPrefix("/api/v1/auth/oidc/mobile/callback?"):
                (200, Fixtures.tokenJSON(access: "A1", refresh: "R1"))
            case "/api/v1/users/me": (200, Fixtures.userJSON)
            default: (404, "{}")
            }
        }
        let store = InMemoryTokenStore()
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: store, transport: server, loadURL: discovery)
        let request = try await client.beginOIDCSignIn(provider: provider)

        let user = try await client.completeOIDCSignIn(
            request, callbackURL: URL(string: "grimmory://oauth2-callback?code=C1&state=S1")!)

        #expect(user.username == "alice")
        #expect(try await store.load()?.accessToken == "A1")
        let exchange = try #require(await server.requests.first { $0.path.contains("/oidc/mobile/callback") })
        #expect(exchange.method == .post)
        let q = query(URL(string: "https://x\(exchange.path)")!)
        #expect(q["code"] == "C1")
        #expect(q["code_verifier"] == request.codeVerifier)
        #expect(q["redirect_uri"] == "grimmory://oauth2-callback")
        #expect(q["nonce"] == request.nonce)
        #expect(q["state"] == "S1")
    }

    @Test func rejectsACallbackForAnotherSignIn() async throws {
        let server = FakeGrimmory { request in
            request.path == "/api/v1/auth/oidc/state" ? (200, #"{"state":"S1"}"#) : (500, "{}")
        }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server,
                                    loadURL: discovery)
        let request = try await client.beginOIDCSignIn(provider: provider)

        await #expect(throws: GrimmoryError.oidcFailed("the sign-in response doesn't match this sign-in")) {
            try await client.completeOIDCSignIn(request, callbackURL: URL(string: "grimmory://oauth2-callback?code=C1&state=OTHER")!)
        }
        #expect(await server.count(path: "/api/v1/auth/oidc/mobile") == 0)
    }

    @Test func reportsTheProvidersError() async throws {
        let server = FakeGrimmory { _ in (200, #"{"state":"S1"}"#) }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server,
                                    loadURL: discovery)
        let request = try await client.beginOIDCSignIn(provider: provider)

        await #expect(throws: GrimmoryError.oidcFailed("User denied access")) {
            try await client.completeOIDCSignIn(request, callbackURL: URL(
                string: "grimmory://oauth2-callback?error=access_denied&error_description=User%20denied%20access&state=S1")!)
        }
    }

    @Test func unreachableProviderFailsClearly() async throws {
        let server = FakeGrimmory { _ in (200, #"{"state":"S1"}"#) }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server,
                                    loadURL: { _ in throw URLError(.cannotFindHost) })

        await #expect(throws: GrimmoryError.oidcFailed("couldn't reach the identity provider at auth.example.com")) {
            try await client.beginOIDCSignIn(provider: provider)
        }
    }
}

@Suite struct OtherSignInTests {
    @Test func remoteAuthSignsIn() async throws {
        let server = FakeGrimmory { request in
            switch request.path {
            case "/api/v1/auth/remote": (200, Fixtures.tokenJSON(access: "A1", refresh: "R1"))
            case "/api/v1/users/me": (200, Fixtures.userJSON)
            default: (404, "{}")
            }
        }
        let store = InMemoryTokenStore()
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: store, transport: server)

        let user = try await client.signInWithRemoteAuth()

        #expect(user.username == "alice")
        #expect(try await store.load()?.refreshToken == "R1")
        #expect(await server.requests.first?.authorization == nil)
    }

    @Test func remoteAuthOffIsForbidden() async throws {
        let server = FakeGrimmory { _ in (403, #"{"message":"Remote authentication is disabled"}"#) }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server)

        await #expect(throws: GrimmoryError.forbidden) { try await client.signInWithRemoteAuth() }
    }

    @Test func proxySignInPageIsRecognised() async throws {
        let page = "<!doctype html><title>Sign in – Authelia</title>"
        let server = FakeGrimmory { _ in (200, page) }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()),
                                    transport: server)

        await #expect(throws: GrimmoryError.webPageInsteadOfAPI) { try await client.serverInfo() }
        await #expect(throws: GrimmoryError.webPageInsteadOfAPI) { try await client.allBookIDs() }
    }

    @Test func serverInfoReportsSetupAndRemoteAuth() async throws {
        let server = FakeGrimmory { request in
            switch request.path {
            case "/api/v1/public-settings": (200, #"{"remoteAuthEnabled":true,"oidcEnabled":false}"#)
            case "/api/v1/setup/status": (200, #"{"status":200,"message":"Initial setup is pending.","data":false}"#)
            default: (404, "{}")
            }
        }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server)

        let info = try await client.serverInfo()

        #expect(info.needsSetup)
        #expect(info.remoteAuthEnabled)
        #expect(info.passwordLoginAllowed)
        #expect(info.oidc == nil)
    }

    @Test func oidcScopesDefaultLikeTheWebApp() async throws {
        let server = FakeGrimmory { request in
            request.path == "/api/v1/public-settings"
                ? (200, #"{"oidcEnabled":true,"oidcProviderDetails":{"issuerUri":"https://auth.example.com","clientId":"grimmory","scopes":""}}"#)
                : (404, "{}")
        }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server)

        #expect(try await client.serverInfo().oidc?.scopes == "openid profile email groups offline_access")
    }

    @Test func createFirstAdminThenSignsIn() async throws {
        let server = FakeGrimmory { request in
            switch request.path {
            case "/api/v1/setup": (200, #"{"status":200,"message":"Admin user created successfully."}"#)
            case "/api/v1/auth/login": (200, Fixtures.tokenJSON(access: "A1", refresh: "R1"))
            case "/api/v1/users/me": (200, Fixtures.userJSON)
            default: (404, "{}")
            }
        }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server)

        let user = try await client.createFirstAdmin(username: "alice", name: "Alice", email: "alice@example.com",
                                                     password: "s3cret-pass")

        #expect(user.username == "alice")
        let setup = try #require(await server.requests.first)
        #expect(setup.path == "/api/v1/setup")
        #expect(try json(setup.body)["username"] as? String == "alice")
    }

    @Test func defaultPasswordIsFlaggedAndCanBeChanged() async throws {
        let server = FakeGrimmory { request in
            switch request.path {
            case "/api/v1/auth/login": (200, #"{"accessToken":"A1","refreshToken":"R1","expires":7200,"isDefaultPassword":true}"#)
            case "/api/v1/users/me": (200, Fixtures.userJSON)
            case "/api/v1/users/change-password": (200, "{}")
            default: (404, "{}")
            }
        }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server)

        let user = try await client.signIn(username: "alice", password: "changeme")
        #expect(user.hasDefaultPassword)

        try await client.changePassword(current: "changeme", new: "better-pass")
        let change = try #require(await server.requests.last)
        #expect(change.method == .put)
        #expect(change.authorization == "Bearer A1")
        #expect(try json(change.body)["newPassword"] as? String == "better-pass")
    }

    @Test func signOutReturnsTheProvidersLogoutURL() async throws {
        let server = FakeGrimmory { request in
            request.path == "/api/v1/auth/logout"
                ? (200, #"{"logoutUrl":"https://auth.example.com/logout?id_token_hint=abc"}"#)
                : (404, "{}")
        }
        let store = InMemoryTokenStore(Fixtures.tokens())
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: store, transport: server)

        let logoutURL = try await client.signOut()

        #expect(logoutURL == URL(string: "https://auth.example.com/logout?id_token_hint=abc"))
        #expect(try await store.load() == nil)
        #expect(await server.requests.first?.body?.contains("R1") == true)
    }

    @Test func signOutForgetsTokensEvenOffline() async throws {
        struct Offline: Error {}
        let server = FakeGrimmory { _ in throw Offline() }
        let store = InMemoryTokenStore(Fixtures.tokens())
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: store, transport: server)

        #expect(try await client.signOut() == nil)
        #expect(try await store.load() == nil)
    }
}
