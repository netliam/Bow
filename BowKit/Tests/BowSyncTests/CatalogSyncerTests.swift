import Foundation
import SwiftData
import Testing
@testable import BowModel
@testable import BowSync
@testable import GrimmoryAPI

/// A server catalog that can change between syncs.
private actor FakeCatalog: CatalogSource {
    var books: [GrimmoryBookSummary]
    private(set) var pagesServed = 0

    init(_ books: [GrimmoryBookSummary]) { self.books = books }

    func set(_ books: [GrimmoryBookSummary]) { self.books = books }

    func books(page: Int, pageSize: Int) async throws -> GrimmoryPage<GrimmoryBookSummary> {
        pagesServed += 1
        let start = page * pageSize
        let items = Array(books.dropFirst(start).prefix(pageSize))
        return GrimmoryPage(items: items, page: page, totalItems: books.count, hasNext: start + pageSize < books.count)
    }

    func allBookIDs() async throws -> [Int64] { books.map(\.id) }
}

private func summary(_ id: Int64, _ title: String, type: String = "EPUB", progress: Double? = nil) -> GrimmoryBookSummary {
    GrimmoryBookSummary(id: id, title: title, authors: ["Author \(id)"], seriesName: nil, seriesNumber: nil,
                        libraryID: 1, addedOn: nil, lastReadTime: nil, readProgress: progress, readStatus: "UNREAD",
                        personalRating: nil, primaryFileID: id * 10, primaryFileType: type, coverUpdatedOn: nil)
}

@MainActor
@Suite struct CatalogSyncerTests {
    let container: ModelContainer
    let accountID: UUID

    init() throws {
        container = try BowStore.makeContainer(inMemory: true)
        let account = Account(kind: .grimmory, displayName: "Home", serverURL: URL(string: "https://books.example.com"))
        accountID = account.id
        container.mainContext.insert(account)
        try container.mainContext.save()
    }

    private func books() throws -> [Book] {
        try container.mainContext.fetch(FetchDescriptor<Book>(sortBy: [SortDescriptor(\.title)]))
    }

    @Test func insertsEveryPage() async throws {
        let catalog = FakeCatalog((1...120).map { summary(Int64($0), String(format: "Book %03d", $0)) })

        let result = try await CatalogSyncer(modelContainer: container).sync(accountID: accountID, from: catalog)

        #expect(result == CatalogSyncResult(inserted: 120))
        #expect(await catalog.pagesServed == 3)  // 50 + 50 + 20
        let all = try books()
        #expect(all.count == 120)
        #expect(all.first?.account?.id == accountID)
        #expect(all.first?.files.first?.remoteFileID == 10)
        #expect(all.first?.files.first?.format == .epub)
    }

    @Test func secondSyncSkipsUnchangedAndUpdatesChanged() async throws {
        let catalog = FakeCatalog([summary(1, "Dune"), summary(2, "Emma")])
        let syncer = CatalogSyncer(modelContainer: container)
        _ = try await syncer.sync(accountID: accountID, from: catalog)

        await catalog.set([summary(1, "Dune"), summary(2, "Emma (Annotated)")])
        let result = try await syncer.sync(accountID: accountID, from: catalog)

        #expect(result == CatalogSyncResult(updated: 1, unchanged: 1))
        #expect(try books().map(\.title) == ["Dune", "Emma (Annotated)"])
        #expect(try books().count == 2)  // Updated in place, not duplicated.
    }

    @Test func booksGoneFromTheServerAreMarkedNotDeleted() async throws {
        let catalog = FakeCatalog([summary(1, "Dune"), summary(2, "Emma")])
        let syncer = CatalogSyncer(modelContainer: container)
        _ = try await syncer.sync(accountID: accountID, from: catalog)

        await catalog.set([summary(1, "Dune")])
        let result = try await syncer.sync(accountID: accountID, from: catalog)

        #expect(result.removed == 1)
        let emma = try #require(try books().first { $0.remoteID == 2 })
        #expect(emma.isRemovedOnServer)

        // And it comes back if the server lists it again.
        await catalog.set([summary(1, "Dune"), summary(2, "Emma")])
        _ = try await syncer.sync(accountID: accountID, from: catalog)
        #expect(try !(#require(try books().first { $0.remoteID == 2 })).isRemovedOnServer)
    }

    @Test func unsentLocalStatusAndRatingSurviveASync() async throws {
        let catalog = FakeCatalog([summary(1, "Dune")])
        let syncer = CatalogSyncer(modelContainer: container)
        _ = try await syncer.sync(accountID: accountID, from: catalog)

        // Marked read with 5 stars on this device; not sent yet.
        let dune = try #require(try books().first)
        dune.readStatus = "READ"
        dune.rating = 5
        BookOutbox.enqueue(.readStatus, bookID: dune.id, in: container.mainContext)
        BookOutbox.enqueue(.rating, bookID: dune.id, in: container.mainContext)
        try container.mainContext.save()

        // The server still says unread, and something else about the book changed.
        var changed = summary(1, "Dune (Revised)")
        changed.personalRating = 2
        await catalog.set([changed])
        _ = try await syncer.sync(accountID: accountID, from: catalog)

        let synced = try #require(try books().first)
        #expect(synced.title == "Dune (Revised)")
        #expect(synced.readStatus == "READ")
        #expect(synced.rating == 5)
    }

    @Test func mapsFileTypes() {
        #expect(CatalogSyncer.format("EPUB") == .epub)
        #expect(CatalogSyncer.format("pdf") == .pdf)
        #expect(CatalogSyncer.format("CBX") == .cbx)
        #expect(CatalogSyncer.format("AUDIOBOOK") == .other)
        #expect(CatalogSyncer.format(nil) == .other)
    }

    @Test func serverProgressFillsInButNeverOverridesLocalReading() async throws {
        let catalog = FakeCatalog([summary(1, "Dune", progress: 30), summary(2, "Emma", progress: 10)])
        let syncer = CatalogSyncer(modelContainer: container)
        _ = try await syncer.sync(accountID: accountID, from: catalog)
        #expect(try books().first { $0.remoteID == 1 }?.progress?.fraction == 0.3)

        // Read Emma on this device: it now has a CFI, so the server's number no longer applies.
        let emma = try #require(try books().first { $0.remoteID == 2 })
        emma.progress?.cfi = "epubcfi(/6/8!/4/2:0)"
        emma.progress?.fraction = 0.5
        try container.mainContext.save()

        await catalog.set([summary(1, "Dune", progress: 60), summary(2, "Emma", progress: 20)])
        _ = try await syncer.sync(accountID: accountID, from: catalog)

        #expect(try books().first { $0.remoteID == 1 }?.progress?.fraction == 0.6)
        #expect(try books().first { $0.remoteID == 2 }?.progress?.fraction == 0.5)
    }

    @Test func oneClientPerAccount() {
        let id = UUID()
        let server = URL(string: "https://books.example.com")!
        let first = GrimmoryAccounts.client(serverURL: server, accountID: id)
        #expect(GrimmoryAccounts.client(serverURL: server, accountID: id) === first)
        GrimmoryAccounts.forget(accountID: id)
        #expect(GrimmoryAccounts.client(serverURL: server, accountID: id) !== first)
        GrimmoryAccounts.forget(accountID: id)
    }

    @Test func normalizesServerURLs() {
        #expect(GrimmoryAccounts.normalizedServerURL("books.example.com")?.absoluteString == "https://books.example.com")
        #expect(GrimmoryAccounts.normalizedServerURL(" http://nas.local:6060/ ")?.absoluteString == "http://nas.local:6060")
        #expect(GrimmoryAccounts.normalizedServerURL("https://example.com/grimmory/")?.absoluteString
                == "https://example.com/grimmory")
        #expect(GrimmoryAccounts.normalizedServerURL("") == nil)
        #expect(GrimmoryAccounts.normalizedServerURL("ftp://example.com") == nil)
    }
}
