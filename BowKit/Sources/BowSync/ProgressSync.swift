import BowModel
import Foundation
import GrimmoryAPI
import SwiftData

/// Where reading progress is sent. `GrimmoryClient` is the real one; tests use a fake.
public protocol ProgressDestination: Sendable {
    func updateEpubProgress(bookID: Int64, fileID: Int64, cfi: String?, href: String?, percentage: Double) async throws
}

extension GrimmoryClient: ProgressDestination {}

/// Records that a book's reading position changed, so `ProgressPusher` sends it. Keeps at most one pending
/// entry per book: only the latest position matters, and it's read from `ReadingProgress` at push time.
public enum ProgressOutbox {
    public static let entityName = "ReadingProgress"

    public static func enqueue(bookID: UUID, in context: ModelContext) {
        let entity = entityName
        let descriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate { $0.entityName == entity && $0.entityID == bookID }
        )
        if let pending = try? context.fetch(descriptor).first {
            // A newer position un-parks a change the server refused: it may accept this one.
            pending.isParked = false
            pending.nextAttemptAt = nil
        } else {
            context.insert(PendingChange(entityName: entityName, entityID: bookID, operation: .update))
        }
    }
}

public struct ProgressPushResult: Sendable, Equatable {
    public var sent = 0
    public var parked = 0
    public var failed = 0
}

/// Sends pending reading positions to Grimmory.
@ModelActor
public actor ProgressPusher {
    /// - Parameter destination: The server for a book's account, or `nil` for local books (dropped).
    public func pushPending(
        to destination: @Sendable (_ accountID: UUID) -> (any ProgressDestination)?,
        now: Date = Date()
    ) async -> ProgressPushResult {
        let entity = ProgressOutbox.entityName
        let descriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate { $0.entityName == entity && !$0.isParked },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        var result = ProgressPushResult()
        for change in (try? modelContext.fetch(descriptor)) ?? [] {
            if let next = change.nextAttemptAt, next > now { continue }
            let bookID = change.entityID
            guard let book = try? modelContext.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })).first,
                  let remoteID = book.remoteID, let accountID = book.account?.id,
                  let fileID = book.files.first(where: { $0.format == .epub })?.remoteFileID,
                  let progress = book.progress,
                  let server = destination(accountID)
            else {
                modelContext.delete(change)  // Nothing to send it to (a local book, or one gone from the library).
                continue
            }

            do {
                try await server.updateEpubProgress(bookID: remoteID, fileID: fileID, cfi: progress.cfi,
                                                    href: progress.href, percentage: progress.fraction * 100)
                modelContext.delete(change)
                result.sent += 1
            } catch let error as GrimmoryError where Self.isPermanent(error) {
                change.isParked = true
                change.lastError = "\(error)"
                result.parked += 1
            } catch {
                change.attempts += 1
                change.lastError = "\(error)"
                change.nextAttemptAt = now.addingTimeInterval(Self.backoff(attempts: change.attempts))
                result.failed += 1
            }
        }
        try? modelContext.save()
        return result
    }

    /// The server will refuse this again; retrying won't help until something changes.
    static func isPermanent(_ error: GrimmoryError) -> Bool {
        switch error {
        case .forbidden, .notFound: true
        case .http(let status): (400..<500).contains(status) && status != 408 && status != 429
        default: false
        }
    }

    /// 30 s, 1 min, 2 min, … capped at 1 hour.
    static func backoff(attempts: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(attempts - 1, 0))), 3600)
    }
}
