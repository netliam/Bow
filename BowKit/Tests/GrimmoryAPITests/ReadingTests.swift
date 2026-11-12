import Foundation
import Synchronization
import Testing
@testable import GrimmoryAPI

/// Records download requests and answers them with scripted responses.
private final class FakeDownloader: Sendable {
    let requests = Mutex<[URLRequest]>([])
    let respond: @Sendable (URLRequest) -> (status: Int, mime: String, body: String)

    init(respond: @escaping @Sendable (URLRequest) -> (status: Int, mime: String, body: String)) {
        self.respond = respond
    }

    var downloader: GrimmoryClient.FileDownloader {
        { [self] request, progress in
            requests.withLock { $0.append(request) }
            let (status, mime, body) = respond(request)
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data(body.utf8).write(to: file)
            progress(1)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": mime])!
            return (file, response)
        }
    }
}

@Suite struct ReadingTests {
    @Test func downloadsWithTheBearerToken() async throws {
        let fake = FakeDownloader { _ in (200, "application/epub+zip", "EPUB BYTES") }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()),
                                    transport: FakeGrimmory(), downloader: fake.downloader)

        let file = try await client.downloadFile(bookID: 5, fileID: 50)

        #expect(try String(contentsOf: file, encoding: .utf8) == "EPUB BYTES")
        let request = try #require(fake.requests.withLock { $0.first })
        #expect(request.url?.absoluteString == "https://books.example.com/api/v1/books/5/files/50/download")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer A1")
    }

    @Test func downloadRefreshesOnceOn401() async throws {
        let fake = FakeDownloader { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer A2"
                ? (200, "application/epub+zip", "EPUB") : (401, "application/json", "{}")
        }
        let server = FakeGrimmory { request in
            request.path == "/api/v1/auth/refresh" ? (200, Fixtures.tokenJSON(access: "A2", refresh: "R2")) : (404, "{}")
        }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()),
                                    transport: server, downloader: fake.downloader)

        _ = try await client.downloadFile(bookID: 5, fileID: 50)

        #expect(fake.requests.withLock { $0.count } == 2)
        #expect(await server.count(path: "/api/v1/auth/refresh") == 1)
    }

    @Test func downloadWithoutPermissionIsForbidden() async throws {
        let fake = FakeDownloader { _ in (403, "application/json", "{}") }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()),
                                    transport: FakeGrimmory(), downloader: fake.downloader)

        await #expect(throws: GrimmoryError.forbidden) { try await client.downloadFile(bookID: 5, fileID: 50) }
    }

    @Test func proxyPageInsteadOfTheFile() async throws {
        let fake = FakeDownloader { _ in (200, "text/html", "<html>Sign in</html>") }
        let client = GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()),
                                    transport: FakeGrimmory(), downloader: fake.downloader)

        await #expect(throws: GrimmoryError.webPageInsteadOfAPI) { try await client.downloadFile(bookID: 5, fileID: 50) }
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
