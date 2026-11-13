import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Where an uploaded book goes: straight into a library folder, or into the bookdrop to be reviewed in Grimmory.
public enum GrimmoryUploadDestination: Sendable, Hashable {
    case library(libraryID: Int64, pathID: Int64)
    case bookdrop
}

/// A library folder a book can be uploaded to. Most libraries have one.
public struct GrimmoryUploadFolder: Sendable, Hashable, Identifiable {
    public var libraryID: Int64
    public var libraryName: String
    public var pathID: Int64
    /// The folder on the server, e.g. `/books`.
    public var path: String

    public var id: Int64 { pathID }
    public var destination: GrimmoryUploadDestination { .library(libraryID: libraryID, pathID: pathID) }
}

extension GrimmoryClient {
    // MARK: Upload

    /// The library folders the user can upload to.
    public func uploadFolders() async throws -> [GrimmoryUploadFolder] {
        struct Library: Decodable {
            struct Path: Decodable {
                var id: Int64?
                var path: String?
            }
            var id: Int64?
            var name: String?
            var paths: [Path]?
        }
        let data = try await authorizedData(path: "/api/v1/libraries", operationID: "getLibraries")
        return try JSONDecoder().decode([Library].self, from: data).flatMap { library -> [GrimmoryUploadFolder] in
            guard let libraryID = library.id else { return [] }
            return (library.paths ?? []).compactMap { path in
                path.id.map {
                    GrimmoryUploadFolder(libraryID: libraryID, libraryName: library.name ?? "Library", pathID: $0,
                                         path: path.path ?? "")
                }
            }
        }
    }

    /// Uploads a book file. A library upload shows up after Grimmory's next catalog sync; a bookdrop upload waits
    /// for someone to review it in Grimmory.
    public func upload(file: URL, fileName: String? = nil, to destination: GrimmoryUploadDestination) async throws {
        let name = fileName ?? file.lastPathComponent
        let boundary = "Bow-\(UUID().uuidString)"
        let safeName = name.replacingOccurrences(of: "\"", with: "'")
        let head = Array(("--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
            + "Content-Type: \(Self.mimeType(for: name))\r\n\r\n").utf8)
        let tail = Array("\r\n--\(boundary)--\r\n".utf8)
        let fileSize = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? Int ?? 0
        // Streamed from disk a chunk at a time: comics and PDFs can be hundreds of megabytes.
        let body = HTTPBody(MultipartFileStream(head: head, file: file, tail: tail),
                            length: .known(Int64(head.count + fileSize + tail.count)), iterationBehavior: .multiple)

        let path: String
        let operationID: String
        switch destination {
        case .library(let libraryID, let pathID):
            path = "/api/v1/files/upload?libraryId=\(libraryID)&pathId=\(pathID)"
            operationID = "uploadFile"
        case .bookdrop:
            path = "/api/v1/files/upload/bookdrop"
            operationID = "uploadFile_1"
        }

        var request = HTTPRequest(method: .post, scheme: nil, authority: nil, path: path)
        request.headerFields[.contentType] = "multipart/form-data; boundary=\(boundary)"
        request.headerFields[.accept] = "*/*"
        let middleware = AuthMiddleware(session: session)
        let (response, responseBody) = try await middleware.intercept(
            request, body: body, baseURL: serverURL, operationID: operationID
        ) { [transport] request, body, baseURL in
            try await transport.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
        guard (200..<300).contains(response.status.code) else {
            // Grimmory explains refusals (wrong format, too large, already in the library) in `message`.
            if let responseBody, let data = try? await Data(collecting: responseBody, upTo: 64 * 1024),
               let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String,
               !message.isEmpty {
                throw GrimmoryError.unexpectedResponse(message)
            }
            throw GrimmoryError(status: response.status.code)
        }
    }

    static func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "epub": "application/epub+zip"
        case "pdf": "application/pdf"
        case "cbz": "application/vnd.comicbook+zip"
        case "cbr": "application/vnd.comicbook-rar"
        default: "application/octet-stream"
        }
    }
}

/// The multipart body as chunks: the part header, the file read from disk, then the closing boundary. Each
/// iteration reopens the file, so the body can be sent again after a token refresh.
struct MultipartFileStream: AsyncSequence, Sendable {
    typealias Element = ArraySlice<UInt8>
    let head: [UInt8]
    let file: URL
    let tail: [UInt8]

    func makeAsyncIterator() -> Iterator { Iterator(stream: self) }

    struct Iterator: AsyncIteratorProtocol {
        let stream: MultipartFileStream
        var stage = 0
        var handle: FileHandle?

        mutating func next() async throws -> ArraySlice<UInt8>? {
            switch stage {
            case 0:
                stage = 1
                handle = try FileHandle(forReadingFrom: stream.file)
                return stream.head[...]
            case 1:
                if let data = try handle?.read(upToCount: 256 * 1024), !data.isEmpty { return ArraySlice(data) }
                try handle?.close()
                stage = 2
                return stream.tail[...]
            default:
                return nil
            }
        }
    }
}
