import Foundation
import Testing
@testable import GrimmoryAPI

@Suite struct ReadingTests {
    @Test func downloadRequestsAreSigned() async throws {
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()),
                                    transport: FakeGrimmory())

        let primary = try await client.downloadRequest(bookID: 5)
        let additional = try await client.downloadRequest(bookID: 5, additionalFileID: 50)

        #expect(primary.url?.absoluteString == "https://books.example.com/api/v1/books/5/download")
        #expect(additional.url?.absoluteString == "https://books.example.com/api/v1/books/5/files/50/download")
        #expect(primary.value(forHTTPHeaderField: "Authorization") == "Bearer A1")
    }

    @Test func downloadRequestRefreshesAnExpiringToken() async throws {
        let server = FakeGrimmory { request in
            request.path == "/api/v1/auth/refresh" ? (200, Fixtures.tokenJSON(access: "A2", refresh: "R2")) : (404, "{}")
        }
        let client = GrimmoryClient(serverURL: Fixtures.server,
                                    tokenStore: InMemoryTokenStore(Fixtures.tokens(expiresIn: 5)), transport: server)

        let request = try await client.downloadRequest(bookID: 5)

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer A2")
    }

    @Test func checksFinishedDownloads() throws {
        try GrimmoryClient.checkDownload(statusCode: 200, mimeType: "application/epub+zip")
        #expect(throws: GrimmoryError.forbidden) { try GrimmoryClient.checkDownload(statusCode: 403, mimeType: nil) }
        #expect(throws: GrimmoryError.webPageInsteadOfAPI) {
            try GrimmoryClient.checkDownload(statusCode: 200, mimeType: "text/html")
        }
    }

    @Test func sendsStatusAndRating() async throws {
        let server = FakeGrimmory { _ in (200, "") }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()),
                                    transport: server)

        try await client.updateReadStatus(bookID: 5, status: .reReading)
        try await client.updateRating(bookID: 5, rating: 9)

        let requests = await server.requests
        #expect(requests.map(\.path) == ["/api/v1/app/books/5/status", "/api/v1/app/books/5/rating"])
        let status = try JSONSerialization.jsonObject(with: Data((requests[0].body ?? "").utf8)) as? [String: Any]
        #expect(status?["status"] as? String == "RE_READING")
        let rating = try JSONSerialization.jsonObject(with: Data((requests[1].body ?? "").utf8)) as? [String: Any]
        #expect(rating?["rating"] as? Int == 5)  // Clamped to Grimmory's 1–5.
    }

    @Test func sendsProgressAsAFileProgress() async throws {
        let server = FakeGrimmory { _ in (200, "") }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()),
                                    transport: server)

        try await client.updateEpubProgress(bookID: 5, fileID: 50, cfi: "epubcfi(/6/8!/4/2/1:0)",
                                            href: "OEBPS/ch3.xhtml", percentage: 42.5)

        let request = try #require(await server.requests.first)
        #expect(request.method == .put)
        #expect(request.path == "/api/v1/app/books/5/progress")
        let body = try JSONSerialization.jsonObject(with: Data((request.body ?? "").utf8)) as? [String: Any]
        let progress = try #require(body?["fileProgress"] as? [String: Any])
        #expect(progress["bookFileId"] as? Int == 50)
        #expect(progress["positionData"] as? String == "epubcfi(/6/8!/4/2/1:0)")
        #expect(progress["positionHref"] as? String == "OEBPS/ch3.xhtml")
        #expect(progress["progressPercent"] as? Double == 42.5)
        #expect(body?["epubProgress"] == nil)  // The deprecated field isn't sent.
    }

    @Test func readsServerProgress() async throws {
        let server = FakeGrimmory { _ in
            (200, #"{"readProgress":42.5,"lastReadTime":"2026-11-10T20:00:00Z","epubProgress":{"cfi":"epubcfi(/6/8!/4)","href":"ch3.xhtml","percentage":42.5}}"#)
        }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()),
                                    transport: server)

        let progress = try #require(try await client.epubProgress(bookID: 5))

        #expect(progress.cfi == "epubcfi(/6/8!/4)")
        #expect(progress.percentage == 42.5)
        #expect(progress.lastReadTime == (try Date("2026-11-10T20:00:00Z", strategy: .iso8601)))
    }
}
