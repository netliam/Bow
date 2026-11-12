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

    func syncAll(_ container: ModelContainer) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

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
