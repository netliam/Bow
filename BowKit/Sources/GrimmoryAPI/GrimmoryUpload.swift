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
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        let safeName = name.replacingOccurrences(of: "\"", with: "'")
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(Self.mimeType(for: name))\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file, options: .mappedIfSafe))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

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
            request, body: HTTPBody(body), baseURL: serverURL, operationID: operationID
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
