import Foundation
import Testing
@testable import GrimmoryAPI

@Suite struct UploadTests {
    private func client(_ server: FakeGrimmory) -> GrimmoryClient {
        GrimmoryClient(serverURL: Fixtures.server, tokenStore: InMemoryTokenStore(Fixtures.tokens()), transport: server)
    }

    private func bookFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).epub")
        try Data("EPUB BYTES".utf8).write(to: url)
        return url
    }

    @Test func uploadsToALibraryFolder() async throws {
        let server = FakeGrimmory { _ in (204, "") }
        let file = try bookFile()

        try await client(server).upload(file: file, fileName: "Dune.epub", to: .library(libraryID: 1, pathID: 3))

        let request = try #require(await server.requests.first)
        #expect(request.method == .post)
        #expect(request.path == "/api/v1/files/upload?libraryId=1&pathId=3")
        #expect(request.authorization == "Bearer A1")
        let body = try #require(request.body)
        #expect(body.contains(#"Content-Disposition: form-data; name="file"; filename="Dune.epub""#))
        #expect(body.contains("Content-Type: application/epub+zip"))
        #expect(body.contains("EPUB BYTES"))
    }

    /// The body streams from disk, so a retry after a token refresh must read the file again from the start.
    @Test func aRefreshedRetrySendsTheWholeFileAgain() async throws {
        let server = FakeGrimmory { request in
            switch request.path {
            case "/api/v1/auth/refresh": (200, Fixtures.tokenJSON(access: "A2", refresh: "R2"))
            default: request.authorization == "Bearer A2" ? (204, "") : (401, "{}")
            }
        }
        let file = try bookFile()

        try await client(server).upload(file: file, to: .bookdrop)

        let uploads = await server.requests.filter { $0.path == "/api/v1/files/upload/bookdrop" }
        #expect(uploads.count == 2)
        #expect(uploads.allSatisfy { $0.body?.contains("EPUB BYTES") == true && $0.body?.hasSuffix("--\r\n") == true })
    }

    @Test func uploadsToTheBookdrop() async throws {
        let server = FakeGrimmory { _ in (200, #"{"id":9}"#) }

        try await client(server).upload(file: try bookFile(), to: .bookdrop)

        #expect(await server.requests.first?.path == "/api/v1/files/upload/bookdrop")
    }

    @Test func refusalsCarryTheServersMessage() async throws {
        let server = FakeGrimmory { _ in (400, #"{"status":400,"message":"File already exists in the library"}"#) }

        await #expect(throws: GrimmoryError.unexpectedResponse("File already exists in the library")) {
            try await client(server).upload(file: try bookFile(), to: .bookdrop)
        }
    }

    @Test func readsLibraryFolders() async throws {
        let server = FakeGrimmory { _ in
            (200, #"[{"id":1,"name":"Fiction","paths":[{"id":1,"path":"/books"},{"id":2,"path":"/more"}]},{"id":2,"name":"Comics","paths":[]}]"#)
        }

        let folders = try await client(server).uploadFolders()

        #expect(folders.map(\.path) == ["/books", "/more"])
        #expect(folders.first?.libraryName == "Fiction")
        #expect(folders.first?.destination == .library(libraryID: 1, pathID: 1))
    }
}
