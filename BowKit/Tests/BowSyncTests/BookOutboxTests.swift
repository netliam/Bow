import Foundation
import SwiftData
import Testing
@testable import BowModel
@testable import BowSync
@testable import GrimmoryAPI

private actor FakeDestination: BookStateDestination {
    struct Sent: Equatable { var bookID: Int64; var fileID: Int64; var cfi: String?; var percentage: Double }
    private(set) var sent: [Sent] = []
    var error: (any Error)?
    /// Runs during the next rating send, as if the user changed something while it was on its way.
    private var duringSend: (@MainActor () -> Void)?

    func fail(with error: (any Error)?) { self.error = error }
    func onNextSend(_ action: @escaping @MainActor () -> Void) { duringSend = action }

    private(set) var pdfPages: [Int] = []

    func updatePDFProgress(bookID: Int64, fileID: Int64, page: Int, percentage: Double) async throws {
        if let error { throw error }
        pdfPages.append(page)
    }

    func updateEpubProgress(bookID: Int64, fileID: Int64, cfi: String?, href: String?, percentage: Double) async throws {
        if let error { throw error }
        sent.append(Sent(bookID: bookID, fileID: fileID, cfi: cfi, percentage: percentage))
    }

    private(set) var statuses: [GrimmoryReadStatus] = []
    private(set) var ratings: [Int?] = []

    func updateReadStatus(bookID: Int64, status: GrimmoryReadStatus) async throws {
        if let error { throw error }
        statuses.append(status)
    }

    func updateRating(bookID: Int64, rating: Int?) async throws {
        if let error { throw error }
        ratings.append(rating)
        if let action = duringSend {
            duringSend = nil
            await action()
        }
    }
}

@MainActor
@Suite struct BookOutboxTests {
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

    @Test func repeatedChangesGoOutOnce() async throws {
        BookOutbox.enqueue(.progress, bookID: book.id, in: container.mainContext)
        BookOutbox.enqueue(.progress, bookID: book.id, in: container.mainContext)
        try container.mainContext.save()
        let server = FakeDestination()

        #expect(await OutboxPusher(modelContainer: container).pushPending { _ in server } == OutboxPushResult(sent: 1))
        #expect(await server.sent.count == 1)
        #expect(try pending().isEmpty)
    }

    /// Rating 3, then 4 while 3 is still being sent: 4 must not be dropped with 3's entry.
    @Test func aChangeMadeWhileSendingStaysQueued() async throws {
        book.rating = 3
        BookOutbox.enqueue(.rating, bookID: book.id, in: container.mainContext)
        try container.mainContext.save()
        let server = FakeDestination()
        let context = container.mainContext
        let book = book
        await server.onNextSend {
            book.rating = 4
            BookOutbox.enqueue(.rating, bookID: book.id, in: context)
            try? context.save()
        }
        let pusher = OutboxPusher(modelContainer: container)

        _ = await pusher.pushPending { _ in server }
        #expect(try pending().count == 1)
        _ = await OutboxPusher(modelContainer: container).pushPending { _ in server }

        #expect(await server.ratings == [3, 4])
        #expect(try pending().isEmpty)
    }

    @Test func pushesTheLatestPosition() async throws {
        BookOutbox.enqueue(.progress, bookID: book.id, in: container.mainContext)
        book.progress?.fraction = 0.5  // Moved on after enqueueing; the push sends the latest.
        try container.mainContext.save()
        let server = FakeDestination()

        let result = await OutboxPusher(modelContainer: container).pushPending { _ in server }

        #expect(result == OutboxPushResult(sent: 1))
        #expect(await server.sent == [.init(bookID: 5, fileID: 50, cfi: "epubcfi(/6/8!/4/2/1:0)", percentage: 50)])
        #expect(try pending().isEmpty)
    }

    @Test func refusedChangesAreParkedAndANewPositionUnparksThem() async throws {
        BookOutbox.enqueue(.progress, bookID: book.id, in: container.mainContext)
        try container.mainContext.save()
        let server = FakeDestination()
        await server.fail(with: GrimmoryError.forbidden)

        let result = await OutboxPusher(modelContainer: container).pushPending { _ in server }

        #expect(result.parked == 1)
        #expect(try pending().first?.isParked == true)

        BookOutbox.enqueue(.progress, bookID: book.id, in: container.mainContext)
        #expect(try pending().first?.isParked == false)
    }

    @Test func networkFailuresBackOff() async throws {
        BookOutbox.enqueue(.progress, bookID: book.id, in: container.mainContext)
        try container.mainContext.save()
        let server = FakeDestination()
        await server.fail(with: URLError(.notConnectedToInternet))
        let pusher = OutboxPusher(modelContainer: container)
        let now = Date()

        #expect(await pusher.pushPending(to: { _ in server }, now: now).failed == 1)
        // Still waiting out the backoff: not retried yet.
        await server.fail(with: nil)
        #expect(await pusher.pushPending(to: { _ in server }, now: now.addingTimeInterval(10)) == OutboxPushResult())
        #expect(await pusher.pushPending(to: { _ in server }, now: now.addingTimeInterval(31)).sent == 1)
    }

    @Test func localBooksAreDropped() async throws {
        let local = Book(account: nil, title: "Imported")
        container.mainContext.insert(local)
        BookOutbox.enqueue(.progress, bookID: local.id, in: container.mainContext)
        try container.mainContext.save()

        let result = await OutboxPusher(modelContainer: container).pushPending { _ in nil }

        #expect(result == OutboxPushResult())
        #expect(try pending().isEmpty)
    }

    @Test func sendsStatusAndRatingAndKindsDoNotMerge() async throws {
        book.readStatus = "READ"
        book.rating = 4
        BookOutbox.enqueue(.readStatus, bookID: book.id, in: container.mainContext)
        BookOutbox.enqueue(.rating, bookID: book.id, in: container.mainContext)
        BookOutbox.enqueue(.progress, bookID: book.id, in: container.mainContext)
        try container.mainContext.save()
        #expect(try pending().count == 3)
        let server = FakeDestination()

        let result = await OutboxPusher(modelContainer: container).pushPending { _ in server }

        #expect(result.sent == 3)
        #expect(await server.statuses == [.read])
        #expect(await server.ratings == [4])
    }

    @Test func clearedStatusIsSentAsUnset() async throws {
        book.readStatus = nil
        BookOutbox.enqueue(.readStatus, bookID: book.id, in: container.mainContext)
        try container.mainContext.save()
        let server = FakeDestination()

        _ = await OutboxPusher(modelContainer: container).pushPending { _ in server }

        #expect(await server.statuses == [.unset])
    }

    @Test func backoffDoublesUpToAnHour() {
        #expect(OutboxPusher.backoff(attempts: 1) == 30)
        #expect(OutboxPusher.backoff(attempts: 2) == 60)
        #expect(OutboxPusher.backoff(attempts: 20) == 3600)
    }
}

@MainActor
@Suite struct PDFProgressOutboxTests {
    @Test func pdfPositionsGoOutAsPageNumbersFromOne() async throws {
        let container = try BowStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let account = Account(kind: .grimmory, displayName: "Home", serverURL: URL(string: "https://books.example.com"))
        let book = Book(account: account, remoteID: 6, title: "Field Notes")
        let progress = ReadingProgress(book: book, fraction: 5.0 / 12)
        progress.spineIndex = 4  // The fifth page.
        context.insert(account)
        context.insert(book)
        context.insert(BookFile(book: book, format: .pdf, remoteFileID: 60))
        context.insert(progress)
        BookOutbox.enqueue(.progress, bookID: book.id, in: context)
        try context.save()
        let server = FakeDestination()

        #expect(await OutboxPusher(modelContainer: container).pushPending { _ in server }.sent == 1)
        #expect(await server.pdfPages == [5])
        #expect(await server.sent.isEmpty)  // Not sent as an EPUB position.
    }
}
