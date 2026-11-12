import Foundation
import Security

/// The tokens Grimmory issues at sign-in. The access token lasts 2 hours; the refresh token lasts 30 days and is
/// replaced on every refresh (the old one is revoked).
public struct GrimmoryTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var accessTokenExpiry: Date

    public init(accessToken: String, refreshToken: String, accessTokenExpiry: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiry = accessTokenExpiry
    }
}

/// Where a signed-in account's tokens are kept.
public protocol GrimmoryTokenStore: Sendable {
    func load() async throws -> GrimmoryTokens?
    func save(_ tokens: GrimmoryTokens) async throws
    func clear() async throws
}

/// Keeps tokens in the Keychain, one item per account. Readable after first unlock, so background sync works
/// while the device is locked; never synced to iCloud Keychain.
public struct KeychainTokenStore: GrimmoryTokenStore {
    public let account: String
    public let service: String

    /// `account` should identify the server and user, e.g. `"https://books.example.com|alice"`.
    public init(account: String, service: String = "app.bow.grimmory") {
        self.account = account
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load() async throws -> GrimmoryTokens? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(GrimmoryTokens.self, from: data)
    }

    public func save(_ tokens: GrimmoryTokens) async throws {
        let data = try JSONEncoder().encode(tokens)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() async throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// Keeps tokens in memory only. For tests and previews.
public actor InMemoryTokenStore: GrimmoryTokenStore {
    private var tokens: GrimmoryTokens?

    public init(_ tokens: GrimmoryTokens? = nil) {
        self.tokens = tokens
    }

    public func load() async throws -> GrimmoryTokens? { tokens }
    public func save(_ tokens: GrimmoryTokens) async throws { self.tokens = tokens }
    public func clear() async throws { tokens = nil }
}
