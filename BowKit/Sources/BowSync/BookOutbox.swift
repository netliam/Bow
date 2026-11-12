import BowModel
import Foundation
import GrimmoryAPI
import SwiftData

/// Where per-book changes are sent. `GrimmoryClient` is the real one; tests use a fake.
public protocol BookStateDestination: Sendable {
    func updateEpubProgress(bookID: Int64, fileID: Int64, cfi: String?, href: String?, percentage: Double) async throws
    func updateReadStatus(bookID: Int64, status: GrimmoryReadStatus) async throws
    func updateRating(bookID: Int64, rating: Int?) async throws
}

extension GrimmoryClient: BookStateDestination {}

/// Records that something about a book changed on this device, so `OutboxPusher` sends it (ADR-0002). Keeps at
/// most one pending entry per book and kind: only the latest value matters, and it's read from the book at push
/// time.
public enum BookOutbox {
    public enum Kind: String, CaseIterable, Sendable {
        case progress = "ReadingProgress"
        case readStatus = "Book.readStatus"
        case rating = "Book.rating"
    }

    public static func enqueue(_ kind: Kind, bookID: UUID, in context: ModelContext) {
        let entity = kind.rawValue
        let descriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate { $0.entityName == entity && $0.entityID == bookID }
        )
        if let pending = try? context.fetch(descriptor).first {
            // A newer value un-parks a change the server refused: it may accept this one.
            pending.isParked = false
            pending.nextAttemptAt = nil
        } else {
            context.insert(PendingChange(entityName: entity, entityID: bookID, operation: .update))
        }
    }

    /// Books with an unsent change of `kind`. Catalog sync leaves those fields alone so it can't undo a local edit.
    public static func pendingBookIDs(_ kind: Kind, in context: ModelContext) -> Set<UUID> {
        let entity = kind.rawValue
        let descriptor = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.entityName == entity })
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.entityID))
    }
}

public struct OutboxPushResult: Sendable, Equatable {
    public var sent = 0
    public var parked = 0
    public var failed = 0
}

/// Sends pending book changes to Grimmory.
@ModelActor
public actor OutboxPusher {
    /// - Parameter destination: The server for a book's account, or `nil` for local books (dropped).
    public func pushPending(
        to destination: @Sendable (_ accountID: UUID) -> (any BookStateDestination)?,
        now: Date = Date()
    ) async -> OutboxPushResult {
        let kinds = BookOutbox.Kind.allCases.map(\.rawValue)
        let descriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate { kinds.contains($0.entityName) && !$0.isParked },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        var result = OutboxPushResult()
        for change in (try? modelContext.fetch(descriptor)) ?? [] {
            if let next = change.nextAttemptAt, next > now { continue }
            let bookID = change.entityID
            guard let kind = BookOutbox.Kind(rawValue: change.entityName),
                  let book = try? modelContext.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })).first,
                  let remoteID = book.remoteID, let accountID = book.account?.id,
                  let server = destination(accountID)
            else {
                modelContext.delete(change)  // Nothing to send it to (a local book, or one gone from the library).
                continue
            }

            do {
                switch kind {
                case .progress:
                    guard let fileID = book.files.first(where: { $0.format == .epub })?.remoteFileID,
                          let progress = book.progress
                    else { break }
                    try await server.updateEpubProgress(bookID: remoteID, fileID: fileID, cfi: progress.cfi,
                                                        href: progress.href, percentage: progress.fraction * 100)
                case .readStatus:
                    let status = book.readStatus.flatMap(GrimmoryReadStatus.init(rawValue:)) ?? .unset
                    try await server.updateReadStatus(bookID: remoteID, status: status)
                case .rating:
                    try await server.updateRating(bookID: remoteID, rating: book.rating)
                }
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
