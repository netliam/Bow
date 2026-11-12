import BowModel
import Foundation
import GrimmoryAPI
import SwiftData
import Testing
@testable import BowSync

private actor FakeSessionServer: ReadingSessionDestination {
    private(set) var sessions: [GrimmoryReadingSession] = []
    func record(_ session: GrimmoryReadingSession) async throws { sessions.append(session) }
}

@MainActor
@Suite struct ReadingSessionTests {
    let container: ModelContainer
    let book: Book
    let accountID: UUID
    var clock = Date(timeIntervalSince1970: 1_000_000)

    init() throws {
        container = try BowStore.makeContainer(inMemory: true)
        let account = Account(kind: .grimmory, displayName: "Home", serverURL: URL(string: "https://books.example.com"))
        accountID = account.id
        book = Book(account: account, remoteID: 2, title: "The Glass Coast")
        container.mainContext.insert(account)
        container.mainContext.insert(book)
        try container.mainContext.save()
    }

    /// A recorder whose clock the test moves.
    private final class Clock: @unchecked Sendable { var now: Date; init(_ d: Date) { now = d } }

    private func recorder(_ clock: Clock) -> ReadingSessionRecorder {
        ReadingSessionRecorder(book: book, bookType: .epub, context: container.mainContext) { clock.now }
    }

    private func push() async -> [GrimmoryReadingSession] {
        let server = FakeSessionServer()
        _ = await ReadingSessionPusher(modelContainer: container).pushPending { _ in server }
        return await server.sessions
    }

    @Test func aSessionRunsFromOpeningToTheLastPageTurnAndSends() async throws {
        let clock = Clock(self.clock)
        let r = recorder(clock)
        r.activity(progress: 10, location: "a")
        clock.now += 120
        r.activity(progress: 12, location: "b")
        clock.now += 60
        r.end()

        let sessions = await push()
        #expect(sessions.count == 1)
        #expect(sessions.first?.durationSeconds == 180)
        #expect(sessions.first?.startProgress == 10)
        #expect(sessions.first?.endProgress == 12)
        #expect(sessions.first?.endLocation == "b")
        #expect(sessions.first?.bookID == 2)
    }

    @Test func idleTimeSplitsSessionsAndIsNotCounted() async throws {
        let clock = Clock(self.clock)
        let r = recorder(clock)
        r.activity(progress: 10, location: "a")
        clock.now += 100
        r.activity(progress: 11, location: "b")   // Then the reader is left open for an hour.
        clock.now += 3600
        r.activity(progress: 11, location: "b")   // A new session starts here.
        clock.now += 40
        r.end()

        let sessions = await push().sorted { $0.start < $1.start }
        #expect(sessions.map(\.durationSeconds) == [100, 40])
    }

    @Test func closingLongAfterTheLastPageTurnCountsAtMostFiveMinutesMore() async throws {
        let clock = Clock(self.clock)
        let r = recorder(clock)
        r.activity(progress: 10, location: "a")
        clock.now += 7200
        r.end()

        #expect(await push().first?.durationSeconds == 300)
    }

    @Test func shortSessionsAndImportedBooksAreNotKept() async throws {
        let clock = Clock(self.clock)
        let r = recorder(clock)
        r.activity(progress: 10, location: "a")
        clock.now += 20
        r.end()

        let local = Book(account: nil, title: "Imported")
        container.mainContext.insert(local)
        let l = ReadingSessionRecorder(book: local, bookType: .epub, context: container.mainContext) { clock.now }
        l.activity(progress: 1, location: nil)
        clock.now += 600
        l.end()

        #expect(await push().isEmpty)
    }
}
