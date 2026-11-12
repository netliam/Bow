import Foundation
import Testing
@testable import GrimmoryAPI

@Suite struct SignInTests {
    @Test func signInStoresTokensAndMapsPermissions() async throws {
        let server = FakeGrimmory { request in
            switch request.path {
            case "/api/v1/auth/login": (200, Fixtures.tokenJSON(access: "A1", refresh: "R1", expires: 7200))
            case "/api/v1/users/me": (200, Fixtures.userJSON)
            default: (404, "{}")
            }
        }
        let store = InMemoryTokenStore()
        let start = Date()
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: store, transport: server)

        let user = try await client.signIn(username: "alice", password: "pw")

        #expect(user.id == 7)
        #expect(user.username == "alice")
        #expect(user.permissions.canDownload)
        #expect(user.permissions.canEditMetadata)
        #expect(!user.permissions.canUpload)
        #expect(!user.permissions.isAdmin)

        let saved = try #require(try await store.load())
        #expect(saved.accessToken == "A1")
        #expect(saved.refreshToken == "R1")
        // `expires` is a lifetime in seconds, not a timestamp.
        #expect(abs(saved.accessTokenExpiry.timeIntervalSince(start) - 7200) < 5)

        let me = try #require(await server.requests.last)
        #expect(me.authorization == "Bearer A1")
    }

    @Test func publicCallsSendNoToken() async throws {
        let server = FakeGrimmory { request in
            switch request.path {
            case "/api/v1/public-settings":
                (200, #"{"oidcEnabled":true,"oidcForceOnlyMode":true,"oidcProviderDetails":{"providerName":"Authelia","issuerUri":"https://auth.example.com","clientId":"grimmory","scopes":"openid profile"}}"#)
            case "/api/v1/version": (200, #"{"current":"v2.4.0","latest":"v2.4.1"}"#)
            default: (404, "{}")
            }
        }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server)

        let info = try await client.serverInfo()

        #expect(info.version == "v2.4.0")
        #expect(info.oidc?.clientID == "grimmory")
        #expect(info.oidc?.issuer == URL(string: "https://auth.example.com"))
        #expect(!info.passwordLoginAllowed)
        #expect(await server.requests.allSatisfy { $0.authorization == nil })
    }

    @Test func wrongPasswordIsUnauthorized() async throws {
        let server = FakeGrimmory { _ in (401, #"{"message":"Invalid credentials"}"#) }
        let store = InMemoryTokenStore()
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: store, transport: server)

        await #expect(throws: GrimmoryError.unauthorized) {
            try await client.signIn(username: "alice", password: "nope")
        }
        #expect(try await store.load() == nil)
    }
}

@Suite struct RefreshTests {
    /// Grimmory revokes a refresh token when it's used, so two requests that both see a 401 must share one refresh.
    @Test func concurrent401sShareOneRefresh() async throws {
        let server = FakeGrimmory { request in
            switch (request.path, request.authorization) {
            case ("/api/v1/auth/refresh", _):
                try await Task.sleep(for: .milliseconds(50))  // Keep the refresh in flight while others arrive.
                return (200, Fixtures.tokenJSON(access: "A2", refresh: "R2"))
            case (_, "Bearer A2"): return (200, "[1,2,3]")
            default: return (401, "{}")
            }
        }
        let store = InMemoryTokenStore(Fixtures.tokens(access: "A1", refresh: "R1"))
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: store, transport: server)

        async let a = client.allBookIDs()
        async let b = client.allBookIDs()
        async let c = client.allBookIDs()
        let results = try await [a, b, c]

        #expect(results == [[1, 2, 3], [1, 2, 3], [1, 2, 3]])
        #expect(await server.count(path: "/api/v1/auth/refresh") == 1)
        let refresh = try #require(await server.requests.first { $0.path == "/api/v1/auth/refresh" })
        #expect(refresh.body?.contains("R1") == true)
        #expect(try await store.load()?.refreshToken == "R2")
    }

    @Test func refreshesBeforeExpiry() async throws {
        let server = FakeGrimmory { request in
            switch request.path {
            case "/api/v1/auth/refresh": (200, Fixtures.tokenJSON(access: "A2", refresh: "R2"))
            default: request.authorization == "Bearer A2" ? (200, "[]") : (401, "{}")
            }
        }
        // Expires in 10 s, inside the 60 s margin: refresh first instead of sending a token about to die.
        let store = InMemoryTokenStore(Fixtures.tokens(access: "A1", expiresIn: 10))
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: store, transport: server)

        _ = try await client.allBookIDs()

        let paths = await server.requests.map(\.path)
        #expect(paths == ["/api/v1/auth/refresh", "/api/v1/app/books/ids"])
    }

    @Test func rejectedRefreshSignsOut() async throws {
        let server = FakeGrimmory { _ in (401, "{}") }
        let store = InMemoryTokenStore(Fixtures.tokens())
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: store, transport: server)

        await #expect(throws: GrimmoryError.signedOut) { try await client.allBookIDs() }
        #expect(try await store.load() == nil)
        #expect(await !client.isSignedIn)
    }

    @Test func networkFailureDuringRefreshKeepsTokens() async throws {
        struct Offline: Error {}
        let server = FakeGrimmory { request in
            if request.path == "/api/v1/auth/refresh" { throw Offline() }
            return (401, "{}")
        }
        let tokens = Fixtures.tokens()
        let store = InMemoryTokenStore(tokens)
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: store, transport: server)

        await #expect(throws: (any Error).self) { try await client.allBookIDs() }
        #expect(try await store.load() == tokens)
    }

    @Test func signedOutWithoutTokens() async throws {
        let server = FakeGrimmory()
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server)

        await #expect(throws: GrimmoryError.signedOut) { try await client.allBookIDs() }
        #expect(await server.requests.isEmpty)
    }
}

@Suite struct CatalogTests {
    @Test func booksPageSendsFlatQueryAndMapsDates() async throws {
        let server = FakeGrimmory { request in
            guard request.path.hasPrefix("/api/v1/app/books?") else { return (404, "{}") }
            return (200, """
            {"content":[
              {"id":12,"title":"Dune","authors":["Frank Herbert"],"seriesName":"Dune","seriesNumber":1,
               "readProgress":42.5,"readStatus":"READING","primaryFileId":99,"primaryFileType":"EPUB",
               "addedOn":"2026-11-01T10:15:30.123456Z","coverUpdatedOn":"2026-11-02T08:00:00Z"},
              {"title":"no id, skipped"}
            ],"page":0,"size":50,"totalElements":101,"totalPages":3,"hasNext":true,"hasPrevious":false}
            """)
        }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()),
                                    transport: server)

        let page = try await client.books(page: 0, pageSize: 200)

        let path = try #require(await server.requests.first?.path)
        #expect(path.contains("page=0"))
        #expect(path.contains("size=50"))  // Clamped to Grimmory's cap.
        #expect(!path.contains("request"))  // Spring's @ModelAttribute is sent as separate parameters.

        #expect(page.totalItems == 101)
        #expect(page.hasNext)
        #expect(page.items.count == 1)
        let dune = try #require(page.items.first)
        #expect(dune.id == 12)
        #expect(dune.authors == ["Frank Herbert"])
        #expect(dune.readProgress == 42.5)
        #expect(dune.primaryFileType == "EPUB")
        // Grimmory sends fractional seconds only when they're non-zero; both forms must decode.
        let added = try Date("2026-11-01T10:15:30Z", strategy: .iso8601).addingTimeInterval(0.123456)
        #expect(abs(try #require(dune.addedOn).timeIntervalSince(added)) < 0.001)
        #expect(dune.coverUpdatedOn == (try Date("2026-11-02T08:00:00Z", strategy: .iso8601)))
    }

    @Test func networkErrorsArriveUnwrapped() async throws {
        let server = FakeGrimmory { _ in throw URLError(.cannotConnectToHost) }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(), transport: server)

        await #expect(throws: URLError(.cannotConnectToHost)) { try await client.serverInfo() }
    }

    @Test func forbiddenIsReported() async throws {
        let server = FakeGrimmory { _ in (403, "{}") }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()),
                                    transport: server)

        await #expect(throws: GrimmoryError.forbidden) { try await client.allBookIDs() }
    }
}
