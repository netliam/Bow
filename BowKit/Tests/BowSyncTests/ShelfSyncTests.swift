import BowModel
import Foundation
import GrimmoryAPI
import SwiftData
import Testing
@testable import BowSync

actor FakeShelfServer: ShelfRemote {
    var shelves: [GrimmoryShelf] = []
    var members: [String: [Int64]] = [:]
    private(set) var assignments: [String] = []
    var error: (any Error)?

    func set(_ shelves: [GrimmoryShelf], members: [String: [Int64]]) {
        self.shelves = shelves
        self.members = members
    }
    func fail(with error: (any Error)?) { self.error = error }

    static func key(_ shelf: GrimmoryShelf) -> String { "\(shelf.isMagic ? "magic" : "shelf") \(shelf.id)" }

    func shelves() async throws -> [GrimmoryShelf] {
        if let error { throw error }
        return shelves
    }

    func bookIDs(onShelf shelf: GrimmoryShelf) async throws -> [Int64] {
        members[Self.key(shelf)] ?? []
    }

    func assignShelves(bookIDs: [Int64], add: [Int64], remove: [Int64]) async throws {
        if let error { throw error }
        assignments.append("books \(bookIDs) +\(add) -\(remove)")
    }
}

@MainActor
@Suite struct ShelfSyncTests {
    let container: ModelContainer
    let account: Account
    let dune: Book
    let emma: Book
    let server = FakeShelfServer()

    init() throws {
        container = try BowStore.makeContainer(inMemory: true)
        account = Account(kind: .grimmory, displayName: "Home", serverURL: URL(string: "https://books.example.com"))
        dune = Book(account: account, remoteID: 1, title: "Dune")
        emma = Book(account: account, remoteID: 2, title: "Emma")
        container.mainContext.insert(account)
        container.mainContext.insert(dune)
        container.mainContext.insert(emma)
        try container.mainContext.save()
    }

    private var context: ModelContext { container.mainContext }
    private var syncer: ShelfSyncer { ShelfSyncer(context: context) }

    private func shelf(_ name: String) throws -> Shelf {
        try #require(try context.fetch(FetchDescriptor<Shelf>(predicate: #Predicate { $0.name == name })).first)
    }

    private func titles(_ shelf: Shelf) -> [String] { shelf.books.map(\.title).sorted() }

    @Test func pullsShelvesAndMagicShelvesWithTheirBooks() async throws {
        // Regular shelf 1 and magic shelf 1 share an ID: they're different shelves.
        await server.set([GrimmoryShelf(id: 1, name: "Favorites", icon: "heart"),
                          GrimmoryShelf(id: 1, name: "Reading", icon: "book-open", isMagic: true)],
                         members: ["shelf 1": [1, 2], "magic 1": [2]])

        #expect(try await syncer.pull(accountID: account.id, from: server) == .init(shelves: 2))

        #expect(titles(try shelf("Favorites")) == ["Dune", "Emma"])
        #expect(try shelf("Reading").kind == .magic)
        #expect(titles(try shelf("Reading")) == ["Emma"])
        #expect(emma.shelves.count == 2)
    }

    @Test func followsRenamesMembershipChangesAndDeletes() async throws {
        await server.set([GrimmoryShelf(id: 1, name: "Favorites"), GrimmoryShelf(id: 2, name: "Old")],
                         members: ["shelf 1": [1], "shelf 2": [1]])
        _ = try await syncer.pull(accountID: account.id, from: server)
        await server.set([GrimmoryShelf(id: 1, name: "Loved")], members: ["shelf 1": [2]])

        #expect(try await syncer.pull(accountID: account.id, from: server) == .init(shelves: 1, removed: 1))

        #expect(titles(try shelf("Loved")) == ["Emma"])
        #expect(try context.fetch(FetchDescriptor<Shelf>()).count == 1)
        #expect(dune.shelves.isEmpty)
    }

    @Test func changesHereGoOutAsOneCallPerBook() async throws {
        await server.set([GrimmoryShelf(id: 1, name: "Favorites"), GrimmoryShelf(id: 3, name: "To Read")],
                         members: ["shelf 3": [1]])
        _ = try await syncer.pull(accountID: account.id, from: server)

        ShelfOutbox.set(dune, on: try shelf("Favorites"), true, in: context)
        ShelfOutbox.set(dune, on: try shelf("To Read"), false, in: context)
        try context.save()

        let server = server
        #expect(await syncer.pushPending { _ in server } == OutboxPushResult(sent: 1))
        #expect(await server.assignments == ["books [1] +[1] -[3]"])
        #expect(try context.fetch(FetchDescriptor<PendingChange>()).isEmpty)
    }

    @Test func changingBackSendsNothing() async throws {
        await server.set([GrimmoryShelf(id: 1, name: "Favorites")], members: [:])
        _ = try await syncer.pull(accountID: account.id, from: server)
        ShelfOutbox.set(dune, on: try shelf("Favorites"), true, in: context)
        ShelfOutbox.set(dune, on: try shelf("Favorites"), false, in: context)
        try context.save()

        let server = server
        #expect(await syncer.pushPending { _ in server } == OutboxPushResult())
        #expect(await server.assignments.isEmpty)
    }

    @Test func pullKeepsUnsentChanges() async throws {
        await server.set([GrimmoryShelf(id: 1, name: "Favorites")], members: [:])
        _ = try await syncer.pull(accountID: account.id, from: server)
        ShelfOutbox.set(dune, on: try shelf("Favorites"), true, in: context)
        try context.save()

        _ = try await syncer.pull(accountID: account.id, from: server)  // The server doesn't have it yet.

        #expect(titles(try shelf("Favorites")) == ["Dune"])
    }

    @Test func magicShelvesCantBeChangedByHand() async throws {
        await server.set([GrimmoryShelf(id: 1, name: "Reading", isMagic: true)], members: [:])
        _ = try await syncer.pull(accountID: account.id, from: server)

        ShelfOutbox.set(dune, on: try shelf("Reading"), true, in: context)

        #expect(dune.shelves.isEmpty)
        #expect(try context.fetch(FetchDescriptor<PendingChange>()).isEmpty)
    }
}
