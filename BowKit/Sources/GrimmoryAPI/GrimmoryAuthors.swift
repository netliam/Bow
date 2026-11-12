import Foundation

/// What Grimmory knows about an author, beyond the name on their books.
public struct GrimmoryAuthor: Sendable, Equatable {
    public var id: Int64
    public var name: String
    /// Plain text or simple HTML, from the metadata providers or typed in the web app.
    public var description: String?
    public var hasPhoto: Bool
}

extension GrimmoryClient {
    // MARK: Authors

    /// The author with exactly this name (ignoring case), with their description. Books carry only author names,
    /// so this is how Bow finds the author record.
    public func author(named name: String) async throws -> GrimmoryAuthor? {
        let output = try await unwrapped {
            try await client.appGetAuthors(query: .init(page: 0, size: 20, search: name))
        }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        guard let match = try ok.body.json.content?.first(where: { $0.name?.caseInsensitiveCompare(name) == .orderedSame }),
              let id = match.id
        else { return nil }

        let detailOutput = try await unwrapped { try await client.appGetAuthorDetail(path: .init(authorId: id)) }
        guard case .ok(let detailOK) = detailOutput else { throw GrimmoryError(status: statusCode(of: detailOutput)) }
        let detail = try detailOK.body.json
        return GrimmoryAuthor(id: id, name: detail.name ?? name, description: detail.description,
                              hasPhoto: detail.hasPhoto ?? match.hasPhoto ?? false)
    }

    /// The author's photo, sized for lists and headers (JPEG).
    public func authorPhoto(id: Int64) async throws -> Data {
        try await authorizedData(path: "/api/v1/media/author/\(id)/thumbnail", operationID: "getAuthorThumbnail")
    }
}
