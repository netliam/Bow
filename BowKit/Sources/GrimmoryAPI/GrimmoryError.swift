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

/// Readable messages for anywhere that shows `error.localizedDescription`. Screens with more context (sign-in,
/// downloads) still word their own.
extension GrimmoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .signedOut: "You've been signed out. Sign in again."
        case .unauthorized: "The server didn't accept your sign-in."
        case .forbidden: "Your account isn't allowed to do that."
        case .notFound: "The server doesn't have that."
        case .http(let status): "The server returned an error (\(status))."
        case .unexpectedResponse: "The server's answer wasn't what Grimmory sends."
        case .webPageInsteadOfAPI: "The server answered with a web page. Its sign-in proxy may need you to sign in again."
        case .oidcFailed(let reason): "Single sign-on failed: \(reason)."
        }
    }
}
