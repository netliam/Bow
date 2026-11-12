import BowModel
import BowSync
import GrimmoryAPI
import SwiftData
import SwiftUI

/// Runs catalog sync for every Grimmory account and reports progress to the UI.
@Observable
final class LibrarySync {
    private(set) var isSyncing = false
    /// A sync problem worth telling the user about, e.g. an account that was signed out.
    var problem: String?

    private var isPushing = false

    /// Sends changes waiting in the outbox (reading positions, read status, ratings). Runs before every catalog
    /// pull, so what comes back already includes this device's changes.
    func pushChanges(_ container: ModelContainer) async {
        guard !isPushing else { return }
        isPushing = true
        defer { isPushing = false }

        var clients: [UUID: GrimmoryClient] = [:]
        for account in (try? container.mainContext.fetch(FetchDescriptor<Account>())) ?? [] {
            clients[account.id] = GrimmoryAccounts.client(for: account)
        }
        let destinations = clients
        _ = await OutboxPusher(modelContainer: container).pushPending(to: { destinations[$0] })
    }

    func syncAll(_ container: ModelContainer) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        await pushChanges(container)
        let accounts = (try? container.mainContext.fetch(FetchDescriptor<Account>())) ?? []
        for account in accounts {
            guard let client = GrimmoryAccounts.client(for: account) else { continue }
            do {
                _ = try await CatalogSyncer(modelContainer: container).sync(accountID: account.id, from: client)
                problem = nil
            } catch GrimmoryError.signedOut {
                problem = "You've been signed out of \(account.displayName). Remove the server and add it again to sign back in."
            } catch GrimmoryError.webPageInsteadOfAPI {
                problem = "\(account.displayName) answered with a web page. If it's behind a sign-in proxy, its session may have expired."
            } catch {
                problem = "Couldn't update \(account.displayName): \(error.localizedDescription)"
            }
        }
    }
}
