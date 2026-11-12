import BowModel
import Foundation
import GrimmoryAPI
import SwiftData

/// Where reading sessions are sent. `GrimmoryClient` is the real one; tests use a fake.
public protocol ReadingSessionDestination: Sendable {
    func record(_ session: GrimmoryReadingSession) async throws
}

extension GrimmoryClient: ReadingSessionDestination {}

/// Times one open book, the way Grimmory's web reader does, so its stats agree: a session starts when reading
/// starts, every page turn keeps it going, five idle minutes end it at the last page turn, and sessions shorter
/// than 30 seconds aren't kept. Finished sessions go into the outbox, so reading offline counts once back online.
@MainActor
public final class ReadingSessionRecorder {
    static let idleLimit: TimeInterval = 5 * 60
    static let minimumSeconds = 30
    nonisolated static let entityName = "ReadingSession"

    private struct Open {
        var start: Date
        var lastActivity: Date
        var startProgress: Double?
        var endProgress: Double?
        var startLocation: String?
        var endLocation: String?
    }

    private let context: ModelContext
    private let accountID: UUID?
    private let bookID: Int64?
    private let bookType: GrimmoryReadingSession.BookType
    private let now: () -> Date
    private var open: Open?

    /// `remoteBookID` nil (an imported book): nothing is recorded, as there's no server to count it.
    public init(book: Book, bookType: GrimmoryReadingSession.BookType, context: ModelContext,
                now: @escaping () -> Date = Date.init) {
        self.context = context
        self.accountID = book.account?.id
        self.bookID = book.remoteID
        self.bookType = bookType
        self.now = now
    }

    /// Call on every page turn (and when the book opens). `progress` is 0–100.
    public func activity(progress: Double?, location: String?) {
        let time = now()
        if let current = open, time.timeIntervalSince(current.lastActivity) > Self.idleLimit {
            finish(at: current.lastActivity)
        }
        var current = open ?? Open(start: time, lastActivity: time, startProgress: progress, startLocation: location)
        current.lastActivity = time
        current.endProgress = progress ?? current.endProgress
        current.endLocation = location ?? current.endLocation
        open = current
    }

    /// Call when the reader closes or the app goes to the background.
    public func end() {
        guard let current = open else { return }
        finish(at: min(now(), current.lastActivity.addingTimeInterval(Self.idleLimit)))
    }

    private func finish(at end: Date) {
        defer { open = nil }
        guard let current = open, let bookID, let accountID else { return }
        let session = GrimmoryReadingSession(
            bookID: bookID, bookType: bookType, start: current.start, end: end,
            startProgress: current.startProgress, endProgress: current.endProgress,
            startLocation: current.startLocation, endLocation: current.endLocation
        )
        guard session.durationSeconds >= Self.minimumSeconds,
              let payload = try? JSONEncoder().encode(Queued(accountID: accountID, session: session))
        else { return }
        context.insert(PendingChange(entityName: Self.entityName, entityID: UUID(), operation: .create, payload: payload))
        try? context.save()
    }

    nonisolated struct Queued: Codable, Sendable {
        var accountID: UUID
        var session: GrimmoryReadingSession
    }
}

/// Sends queued reading sessions to Grimmory.
@ModelActor
public actor ReadingSessionPusher {
    public func pushPending(
        to destination: @Sendable (_ accountID: UUID) -> (any ReadingSessionDestination)?,
        now: Date = Date()
    ) async -> OutboxPushResult {
        let name = ReadingSessionRecorder.entityName
        let descriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate { $0.entityName == name && !$0.isParked },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        var result = OutboxPushResult()
        for change in (try? modelContext.fetch(descriptor)) ?? [] {
            if let next = change.nextAttemptAt, next > now { continue }
            guard let payload = change.payload,
                  let queued = try? JSONDecoder().decode(ReadingSessionRecorder.Queued.self, from: payload),
                  let server = destination(queued.accountID)
            else {
                modelContext.delete(change)  // Unreadable, or the account was removed.
                continue
            }
            do {
                try await server.record(queued.session)
                modelContext.delete(change)
                result.sent += 1
            } catch let error as GrimmoryError where OutboxPusher.isPermanent(error) {
                change.isParked = true
                change.lastError = "\(error)"
                result.parked += 1
            } catch {
                change.attempts += 1
                change.lastError = "\(error)"
                change.nextAttemptAt = now.addingTimeInterval(OutboxPusher.backoff(attempts: change.attempts))
                result.failed += 1
            }
        }
        try? modelContext.save()
        return result
    }
}
