import Foundation
import SwiftData
import Testing
@testable import BowModel
@testable import BowSync
@testable import GrimmoryAPI

private actor FakeDestination: ProgressDestination {
    struct Sent: Equatable { var bookID: Int64; var fileID: Int64; var cfi: String?; var percentage: Double }
    private(set) var sent: [Sent] = []
    var error: (any Error)?

    func fail(with error: (any Error)?) { self.error = error }

    func updateEpubProgress(bookID: Int64, fileID: Int64, cfi: String?, href: String?, percentage: Double) async throws {
        if let error { throw error }
        sent.append(Sent(bookID: bookID, fileID: fileID, cfi: cfi, percentage: percentage))
    }
}

@MainActor
@Suite struct ProgressSyncTests {
    let container: ModelContainer
    let book: Book

    init() throws {
        container = try BowStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let account = Account(kind: .grimmory, displayName: "Home", serverURL: URL(string: "https://books.example.com"))
        book = Book(account: account, remoteID: 5, title: "Moby-Dick")
        let progress = ReadingProgress(book: book, fraction: 0.25)
        progress.cfi = "epubcfi(/6/8!/4/2/1:0)"
        context.insert(account)
        context.insert(book)
        context.insert(BookFile(book: book, format: .epub, remoteFileID: 50))
        context.insert(progress)
        try context.save()
    }

    private func pending() throws -> [PendingChange] {
        try container.mainContext.fetch(FetchDescriptor<PendingChange>())
    }

    @Test func outboxKeepsOneEntryPerBook() throws {
        ProgressOutbox.enqueue(bookID: book.id, in: container.mainContext)
        ProgressOutbox.enqueue(bookID: book.id, in: container.mainContext)
        try container.mainContext.save()

        #expect(try pending().count == 1)
    }

    @Test func pushesTheLatestPosition() async throws {
        ProgressOutbox.enqueue(bookID: book.id, in: container.mainContext)
        book.progress?.fraction = 0.5  // Moved on after enqueueing; the push sends the latest.
        try container.mainContext.save()
        let server = FakeDestination()

        let result = await ProgressPusher(modelContainer: container).pushPending { _ in server }

        #expect(result == ProgressPushResult(sent: 1))
        #expect(await server.sent == [.init(bookID: 5, fileID: 50, cfi: "epubcfi(/6/8!/4/2/1:0)", percentage: 50)])
        #expect(try pending().isEmpty)
    }

    @Test func refusedChangesAreParkedAndANewPositionUnparksThem() async throws {
        ProgressOutbox.enqueue(bookID: book.id, in: container.mainContext)
        try container.mainContext.save()
        let server = FakeDestination()
        await server.fail(with: GrimmoryError.forbidden)

        let result = await ProgressPusher(modelContainer: container).pushPending { _ in server }

        #expect(result.parked == 1)
        #expect(try pending().first?.isParked == true)

        ProgressOutbox.enqueue(bookID: book.id, in: container.mainContext)
        #expect(try pending().first?.isParked == false)
    }

    @Test func networkFailuresBackOff() async throws {
        ProgressOutbox.enqueue(bookID: book.id, in: container.mainContext)
        try container.mainContext.save()
        let server = FakeDestination()
        await server.fail(with: URLError(.notConnectedToInternet))
        let pusher = ProgressPusher(modelContainer: container)
        let now = Date()

        #expect(await pusher.pushPending(to: { _ in server }, now: now).failed == 1)
        // Still waiting out the backoff: not retried yet.
        await server.fail(with: nil)
        #expect(await pusher.pushPending(to: { _ in server }, now: now.addingTimeInterval(10)) == ProgressPushResult())
        #expect(await pusher.pushPending(to: { _ in server }, now: now.addingTimeInterval(31)).sent == 1)
    }

    @Test func localBooksAreDropped() async throws {
        let local = Book(account: nil, title: "Imported")
        container.mainContext.insert(local)
        ProgressOutbox.enqueue(bookID: local.id, in: container.mainContext)
        try container.mainContext.save()

        let result = await ProgressPusher(modelContainer: container).pushPending { _ in nil }

        #expect(result == ProgressPushResult())
        #expect(try pending().isEmpty)
    }

    @Test func backoffDoublesUpToAnHour() {
        #expect(ProgressPusher.backoff(attempts: 1) == 30)
        #expect(ProgressPusher.backoff(attempts: 2) == 60)
        #expect(ProgressPusher.backoff(attempts: 20) == 3600)
    }
}
