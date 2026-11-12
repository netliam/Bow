import CryptoKit
import Foundation

/// An OIDC sign-in in progress: open `authorizationURL` in `ASWebAuthenticationSession` (SwiftUI:
/// `webAuthenticationSession.authenticate(using:callbackURLScheme:preferredBrowserSession:)`) with
/// `callbackScheme`, then pass the URL it returns to `GrimmoryClient.completeOIDCSignIn`.
///
/// Holds the PKCE verifier and nonce, so keep it in memory only and don't reuse it.
public struct OIDCSignInRequest: Sendable {
    public let authorizationURL: URL
    public let callbackScheme: String
    let redirectURI: URL
    let state: String
    let nonce: String
    let codeVerifier: String
}

extension GrimmoryClient {
    /// The redirect Grimmory allows for native apps by default (admins can add others). The identity provider's
    /// client must list it too. `ASWebAuthenticationSession` catches it itself, so Bow never registers the scheme.
    public static let defaultOIDCRedirectURI = URL(string: "grimmory://oauth2-callback")!

    /// Builds the provider's authorization URL the way Grimmory's web app does: authorization code + PKCE (S256),
    /// a one-time `state` issued by the server, and a random `nonce` the server checks in the ID token.
    public func beginOIDCSignIn(
        provider: GrimmoryServerInfo.OIDCProvider,
        redirectURI: URL = GrimmoryClient.defaultOIDCRedirectURI
    ) async throws -> OIDCSignInRequest {
        guard let scheme = redirectURI.scheme else { throw GrimmoryError.oidcFailed("redirect URI has no scheme") }

        let stateOutput = try await unwrapped { try await client.oidcGenerateState() }
        guard case .ok(let ok) = stateOutput, let state = try ok.body.json.additionalProperties["state"] else {
            throw GrimmoryError.oidcFailed("the server didn't issue a sign-in state")
        }

        let endpoint = try await authorizationEndpoint(issuer: provider.issuer)
        let verifier = Self.randomURLSafeString()
        let nonce = Self.randomURLSafeString()

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        let existingItems = components?.queryItems ?? []
        components?.queryItems = existingItems + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: provider.scopes),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        guard let url = components?.url else { throw GrimmoryError.oidcFailed("couldn't build the authorization URL") }

        return OIDCSignInRequest(authorizationURL: url, callbackScheme: scheme, redirectURI: redirectURI,
                                 state: state, nonce: nonce, codeVerifier: verifier)
    }

    /// Finishes sign-in with the URL the identity provider redirected to. Grimmory exchanges the code with the
    /// provider (it holds the client secret) and returns its own tokens.
    @discardableResult
    public func completeOIDCSignIn(_ request: OIDCSignInRequest, callbackURL: URL) async throws -> GrimmoryUser {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            throw GrimmoryError.oidcFailed(value("error_description") ?? error)
        }
        guard value("state") == request.state else {
            throw GrimmoryError.oidcFailed("the sign-in response doesn't match this sign-in")
        }
        guard let code = value("code") else { throw GrimmoryError.oidcFailed("the provider returned no code") }

        let output = try await unwrapped {
            try await client.oidcHandleMobileCallback(query: .init(
                code: code,
                codeVerifier: request.codeVerifier,
                redirectUri: request.redirectURI.absoluteString,
                nonce: request.nonce,
                state: request.state
            ))
        }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        return try await finishSignIn(try ok.body.json)
    }

    private func authorizationEndpoint(issuer: URL) async throws -> URL {
        struct Discovery: Decodable { let authorization_endpoint: URL }
        let discoveryURL = issuer.appending(path: ".well-known/openid-configuration")
        do {
            return try JSONDecoder().decode(Discovery.self, from: try await loadURL(discoveryURL)).authorization_endpoint
        } catch {
            throw GrimmoryError.oidcFailed("couldn't reach the identity provider at \(issuer.host() ?? issuer.absoluteString)")
        }
    }

    static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    static func randomURLSafeString() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
