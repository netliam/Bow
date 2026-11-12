import Foundation

/// A highlight (or a highlight with a note) in an EPUB, as Grimmory's web reader stores it.
public struct GrimmoryAnnotation: Sendable, Equatable {
    public var id: Int64
    /// A range CFI.
    public var cfi: String
    public var text: String
    /// `#RRGGBB`.
    public var color: String?
    /// `highlight`, `underline`, `strikethrough` or `squiggly`.
    public var style: String?
    public var note: String?
    public var chapterTitle: String?

    public init(id: Int64, cfi: String, text: String, color: String? = nil, style: String? = nil,
                note: String? = nil, chapterTitle: String? = nil) {
        self.id = id
        self.cfi = cfi
        self.text = text
        self.color = color
        self.style = style
        self.note = note
        self.chapterTitle = chapterTitle
    }
}

/// A bookmarked position in an EPUB.
public struct GrimmoryBookmark: Sendable, Equatable {
    public var id: Int64
    public var cfi: String?
    public var title: String?

    public init(id: Int64, cfi: String?, title: String?) {
        self.id = id
        self.cfi = cfi
        self.title = title
    }
}

// Annotation and bookmark timestamps are `LocalDateTime` with no time zone, so Bow doesn't read them (see
// docs/grimmory-api.md): the server's copy wins unless this device has a change waiting to go out.
extension GrimmoryClient {
    // MARK: Annotations

    public func annotations(bookID: Int64) async throws -> [GrimmoryAnnotation] {
        let output = try await unwrapped { try await client.getAnnotationsForBook(path: .init(bookId: bookID)) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        return try ok.body.json.compactMap(Self.annotation)
    }

    /// Creates an annotation and returns its server ID.
    public func createAnnotation(bookID: Int64, cfi: String, text: String, color: String?, style: String?,
                                 note: String?, chapterTitle: String?) async throws -> Int64 {
        let body = Components.Schemas.CreateAnnotationRequest(
            bookId: bookID, cfi: cfi, chapterTitle: chapterTitle, color: color, note: note, style: style, text: text
        )
        let output = try await unwrapped { try await client.createAnnotation(body: .json(body)) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        guard let id = try ok.body.json.id else { throw GrimmoryError.unexpectedResponse("annotation without an id") }
        return id
    }

    /// Grimmory lets only the colour, style and note change; the text and CFI are fixed at creation.
    public func updateAnnotation(id: Int64, color: String?, style: String?, note: String?) async throws {
        let body = Components.Schemas.UpdateAnnotationRequest(color: color, note: note, style: style)
        let output = try await unwrapped {
            try await client.updateAnnotation(path: .init(annotationId: id), body: .json(body))
        }
        guard case .ok = output else { throw GrimmoryError(status: statusCode(of: output)) }
    }

    public func deleteAnnotation(id: Int64) async throws {
        let output = try await unwrapped { try await client.deleteAnnotation(path: .init(annotationId: id)) }
        guard case .noContent = output else { throw GrimmoryError(status: statusCode(of: output)) }
    }

    // MARK: Bookmarks

    public func bookmarks(bookID: Int64) async throws -> [GrimmoryBookmark] {
        let output = try await unwrapped { try await client.getBookmarksForBook(path: .init(bookId: bookID)) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        return try ok.body.json.compactMap { dto in
            dto.id.map { GrimmoryBookmark(id: $0, cfi: dto.cfi, title: dto.title) }
        }
    }

    /// Creates a bookmark and returns its server ID.
    public func createBookmark(bookID: Int64, cfi: String, title: String?) async throws -> Int64 {
        let body = Components.Schemas.CreateBookMarkRequest(bookId: bookID, cfi: cfi, title: title)
        let output = try await unwrapped { try await client.createBookmark(body: .json(body)) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        guard let id = try ok.body.json.id else { throw GrimmoryError.unexpectedResponse("bookmark without an id") }
        return id
    }

    public func updateBookmark(id: Int64, cfi: String?, title: String?) async throws {
        let body = Components.Schemas.UpdateBookMarkRequest(cfi: cfi, title: title)
        let output = try await unwrapped { try await client.updateBookmark(path: .init(bookmarkId: id), body: .json(body)) }
        guard case .ok = output else { throw GrimmoryError(status: statusCode(of: output)) }
    }

    public func deleteBookmark(id: Int64) async throws {
        let output = try await unwrapped { try await client.deleteBookmark(path: .init(bookmarkId: id)) }
        guard case .noContent = output else { throw GrimmoryError(status: statusCode(of: output)) }
    }

    private static func annotation(_ dto: Components.Schemas.Annotation) -> GrimmoryAnnotation? {
        guard let id = dto.id, let cfi = dto.cfi else { return nil }
        return GrimmoryAnnotation(id: id, cfi: cfi, text: dto.text ?? "", color: dto.color, style: dto.style,
                                  note: dto.note, chapterTitle: dto.chapterTitle)
    }
}
