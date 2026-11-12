import Foundation

public enum GrimmoryError: Error, Equatable, Sendable {
    /// No tokens, or the refresh token was rejected. The user has to sign in again.
    case signedOut
    /// The server rejected the credentials or token (401).
    case unauthorized
    /// The user lacks the permission for this (403), e.g. downloading without `canDownload`.
    case forbidden
    case notFound
    /// Any other unexpected status code.
    case http(status: Int)
    /// The server answered, but not with what Grimmory sends (wrong URL, an old version).
    case unexpectedResponse(String)
    /// The server answered an API call with a web page. Usually a reverse proxy (Authelia, Authentik, …) asking
    /// the user to sign in to it first; otherwise the server URL points at something other than Grimmory.
    case webPageInsteadOfAPI
    /// OIDC sign-in failed; the message is safe to show.
    case oidcFailed(String)

    init(status: Int) {
        switch status {
        case 401: self = .unauthorized
        case 403: self = .forbidden
        case 404: self = .notFound
        default: self = .http(status: status)
        }
    }
}
