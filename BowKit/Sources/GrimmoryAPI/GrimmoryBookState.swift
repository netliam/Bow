import Foundation

/// Grimmory's read statuses, as its web app offers them.
public enum GrimmoryReadStatus: String, CaseIterable, Sendable {
    case unread = "UNREAD"
    case reading = "READING"
    case reReading = "RE_READING"
    case read = "READ"
    case partiallyRead = "PARTIALLY_READ"
    case paused = "PAUSED"
    case wontRead = "WONT_READ"
    case abandoned = "ABANDONED"
    /// No status. Sent to clear one.
    case unset = "UNSET"

    public var title: String {
        switch self {
        case .unread: "Unread"
        case .reading: "Reading"
        case .reReading: "Re-reading"
        case .read: "Read"
        case .partiallyRead: "Partially Read"
        case .paused: "Paused"
        case .wontRead: "Won't Read"
        case .abandoned: "Abandoned"
        case .unset: "No Status"
        }
    }
}

/// The parts of Grimmory's book detail Bow shows but doesn't keep offline.
public struct GrimmoryBookDetail: Sendable, Equatable {
    public var subtitle: String?
    public var description: String?
    public var publisher: String?
    public var publishedDate: String?
    public var pageCount: Int?
    public var language: String?
    public var categories: [String]
    public var libraryName: String?
}

extension GrimmoryClient {
    public func updateReadStatus(bookID: Int64, status: GrimmoryReadStatus) async throws {
        guard let payload = Components.Schemas.UpdateStatusRequest.StatusPayload(rawValue: status.rawValue) else {
            throw GrimmoryError.unexpectedResponse("unknown status \(status.rawValue)")
        }
        let output = try await unwrapped {
            try await client.appUpdateStatus(path: .init(bookId: bookID), body: .json(.init(status: payload)))
        }
        guard case .ok = output else { throw GrimmoryError(status: statusCode(of: output)) }
    }

    /// 1–5 stars, or `nil` to clear.
    public func updateRating(bookID: Int64, rating: Int?) async throws {
        let output = try await unwrapped {
            try await client.appUpdateRating(path: .init(bookId: bookID),
                                             body: .json(.init(rating: rating.map { Int32(min(max($0, 1), 5)) })))
        }
        guard case .ok = output else { throw GrimmoryError(status: statusCode(of: output)) }
    }

    public func bookDetail(bookID: Int64) async throws -> GrimmoryBookDetail {
        let output = try await unwrapped { try await client.appGetBookDetail(path: .init(bookId: bookID)) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        let dto = try ok.body.json
        return GrimmoryBookDetail(
            subtitle: dto.subtitle, description: dto.description, publisher: dto.publisher,
            publishedDate: dto.publishedDate, pageCount: dto.pageCount.map(Int.init), language: dto.language,
            categories: dto.categories ?? [], libraryName: dto.libraryName
        )
    }

    // MARK: Downloads

    /// A signed request for a book's primary file, or one of its additional files (other formats), for a
    /// background `URLSession` to run. Grimmory rejects the primary file on the additional-file route (400), so
    /// the two can't share it. The token is valid for at least a minute, which covers the request starting;
    /// Grimmory checks it only then.
    public func downloadRequest(bookID: Int64, additionalFileID: Int64? = nil) async throws -> URLRequest {
        let path = additionalFileID.map { "api/v1/books/\(bookID)/files/\($0)/download" } ?? "api/v1/books/\(bookID)/download"
        var request = URLRequest(url: serverURL.appending(path: path))
        request.setValue("Bearer \(try await session.validAccessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Checks a finished download's response: Grimmory's errors, or an auth proxy's sign-in page.
    public static func checkDownload(statusCode: Int, mimeType: String?) throws {
        guard statusCode == 200 else { throw GrimmoryError(status: statusCode) }
        if mimeType == "text/html" { throw GrimmoryError.webPageInsteadOfAPI }
    }
}
