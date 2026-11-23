import BowModel
import Foundation
import GrimmoryAPI
import SwiftData

/// What every outbox (`BookOutbox`, `AnnotationOutbox`, `ShelfOutbox`, `PDFHighlights`, reading sessions) shares.
extension PendingChange {
    /// The pending entries of one kind for one item.
    static func matching(_ entityName: String, id: UUID, in context: ModelContext) -> [PendingChange] {
        let descriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate { $0.entityName == entityName && $0.entityID == id }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The items with a pending entry of one kind.
    static func ids(_ entityName: String, in context: ModelContext) -> Set<UUID> {
        let descriptor = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.entityName == entityName })
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.entityID))
    }

    /// After a send failed: a refusal the server will repeat is parked, anything else is retried later, waiting
    /// longer each time. Returns whether it was parked.
    @discardableResult
    func recordFailure(_ error: any Error, now: Date) -> Bool {
        lastError = "\(error)"
        if let error = error as? GrimmoryError, OutboxPusher.isPermanent(error) {
            isParked = true
            return true
        }
        attempts += 1
        nextAttemptAt = now.addingTimeInterval(OutboxPusher.backoff(attempts: attempts))
        return false
    }
}

extension OutboxPushResult {
    mutating func count(failure change: PendingChange, _ error: any Error, now: Date) {
        if change.recordFailure(error, now: now) { parked += 1 } else { failed += 1 }
    }
}
