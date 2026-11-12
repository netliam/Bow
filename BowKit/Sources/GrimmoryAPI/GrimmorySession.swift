import Foundation

/// Owns an account's tokens and makes sure only one refresh ever runs at a time.
///
/// Grimmory revokes a refresh token the moment it's used. If two requests each saw a 401 and each refreshed, the
/// second would send an already-revoked token and sign the user out. So every caller that needs a refresh joins
/// the one in flight, and a caller whose token was already replaced just takes the new one.
actor GrimmorySession {
    typealias Refresher = @Sendable (_ refreshToken: String) async throws -> GrimmoryTokens

    /// Refresh this long before the access token expires, so requests don't race the deadline.
    static let expiryMargin: TimeInterval = 60

    private let store: any GrimmoryTokenStore
    private let refresher: Refresher
    private let now: @Sendable () -> Date
    private var cached: GrimmoryTokens?
    private var didLoad = false
    private var refreshTask: Task<GrimmoryTokens, any Error>?

    init(store: any GrimmoryTokenStore, now: @escaping @Sendable () -> Date = Date.init, refresher: @escaping Refresher) {
        self.store = store
        self.now = now
        self.refresher = refresher
    }

    func tokens() async throws -> GrimmoryTokens? {
        if !didLoad {
            cached = try await store.load()
            didLoad = true
        }
        return cached
    }

    func setTokens(_ tokens: GrimmoryTokens) async throws {
        try await store.save(tokens)
        cached = tokens
        didLoad = true
    }

    func clear() async throws {
        refreshTask?.cancel()
        refreshTask = nil
        cached = nil
        didLoad = true
        try await store.clear()
    }

    /// An access token that is good for at least `expiryMargin`, refreshing first if needed.
    func validAccessToken() async throws -> String {
        guard let current = try await tokens() else { throw GrimmoryError.signedOut }
        if current.accessTokenExpiry.timeIntervalSince(now()) > Self.expiryMargin {
            return current.accessToken
        }
        return try await refresh(replacing: current.accessToken)
    }

    /// Refreshes because `rejectedAccessToken` was refused (or is about to expire). Returns the new access token.
    func refresh(replacing rejectedAccessToken: String) async throws -> String {
        guard let current = try await tokens() else { throw GrimmoryError.signedOut }

        // No awaits from here until `refreshTask` is set, so concurrent callers can't both start a refresh.
        if let inFlight = refreshTask {
            return try await inFlight.value.accessToken
        }
        if current.accessToken != rejectedAccessToken {
            return current.accessToken  // Someone else already refreshed.
        }

        let task = Task { [refresher] in try await refresher(current.refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }

        do {
            let fresh = try await task.value
            try await setTokens(fresh)
            return fresh.accessToken
        } catch GrimmoryError.unauthorized {
            // The refresh token itself was rejected (expired or revoked): the session is over.
            try? await clear()
            throw GrimmoryError.signedOut
        }
        // Any other error (offline, server down) keeps the tokens so a later attempt can succeed.
    }
}
