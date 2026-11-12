import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Adds the bearer token to every authenticated call, and on a 401 refreshes once (through the session's
/// single-flight refresh) and retries.
struct AuthMiddleware: ClientMiddleware {
    /// Operations that work without signing in.
    static let publicOperations: Set<String> = [
        "getPing", "getVersionInfo", "getPublicSettings",
        "loginUser", "refreshToken", "oidcGenerateState", "oidcHandleMobileCallback",
    ]

    let session: GrimmorySession

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard !Self.publicOperations.contains(operationID) else {
            return try await next(request, body, baseURL)
        }

        let token = try await session.validAccessToken()
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        let (response, responseBody) = try await next(request, body, baseURL)

        // A request body that can only be read once can't be sent again.
        guard response.status == .unauthorized, body?.iterationBehavior != .single else {
            return (response, responseBody)
        }

        let fresh = try await session.refresh(replacing: token)
        request.headerFields[.authorization] = "Bearer \(fresh)"
        return try await next(request, body, baseURL)
    }
}

/// Grimmory sends `Instant`s with fractional seconds only when they're non-zero, so accept both forms.
struct GrimmoryDateTranscoder: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    func decode(_ string: String) throws -> Date {
        if let date = try? Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(string, strategy: .iso8601) {
            return date
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not an ISO 8601 date: \(string)"))
    }
}
