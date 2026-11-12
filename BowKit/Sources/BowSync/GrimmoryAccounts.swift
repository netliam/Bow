import BowModel
import Foundation
import GrimmoryAPI
import Synchronization

/// Ties a SwiftData `Account` to its `GrimmoryClient`. Tokens are stored in the Keychain under the account's id,
/// so the id is chosen before sign-in and the `Account` is only saved once sign-in succeeds.
///
/// There is exactly one client per account: each client owns the single-flight refresh, and Grimmory revokes a
/// refresh token on use, so two clients refreshing the same account would sign it out.
public enum GrimmoryAccounts {
    private static let clients = Mutex<[UUID: GrimmoryClient]>([:])

    public static func tokenStore(for accountID: UUID) -> KeychainTokenStore {
        KeychainTokenStore(account: accountID.uuidString)
    }

    public static func client(serverURL: URL, accountID: UUID) -> GrimmoryClient {
        clients.withLock { clients in
            if let client = clients[accountID], client.serverURL == serverURL { return client }
            let client = GrimmoryClient(serverURL: serverURL, tokenStore: tokenStore(for: accountID))
            clients[accountID] = client
            return client
        }
    }

    /// Drops the cached client, e.g. after signing out and removing the account.
    public static func forget(accountID: UUID) {
        _ = clients.withLock { $0.removeValue(forKey: accountID) }
    }

    /// `nil` for the local account.
    public static func client(for account: Account) -> GrimmoryClient? {
        guard account.kind == .grimmory, let serverURL = account.serverURL else { return nil }
        return client(serverURL: serverURL, accountID: account.id)
    }

    /// Turns what someone typed ("books.example.com", "http://nas.local:6060/") into a server root URL.
    /// Assumes HTTPS when no scheme is given.
    public static func normalizedServerURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil
        else { return nil }
        return url
    }
}
