import BowModel
import Foundation
import GrimmoryAPI
import SwiftData

/// Where shelves sync to. `GrimmoryClient` is the real one; tests use a fake.
public protocol ShelfRemote: Sendable {
    func shelves() async throws -> [GrimmoryShelf]
    func bookIDs(onShelf shelf: GrimmoryShelf) async throws -> [Int64]
    func assignShelves(bookIDs: [Int64], add: [Int64], remove: [Int64]) async throws
}

extension GrimmoryClient: ShelfRemote {}

/// Records shelf changes made on this device for `ShelfSyncer` to send. One pending entry per book, holding the
/// shelves to add it to and take it off (Grimmory's IDs), so changes made offline collapse into one call.
public enum ShelfOutbox {
    static let entityName = "Book.shelves"

    struct Delta: Codable, Equatable {
        var add: Set<Int64> = []
        var remove: Set<Int64> = []
    }

    /// Puts `book` on `shelf` or takes it off, here and (on the next push) on the server. Magic shelves are
    /// filters, so they can't be changed this way.
    public static func set(_ book: Book, on shelf: Shelf, _ isOn: Bool, in context: ModelContext) {
        guard shelf.kind == .regular, book.shelves.contains(where: { $0.id == shelf.id }) != isOn else { return }
        if isOn { book.shelves.append(shelf) } else { book.shelves.removeAll { $0.id == shelf.id } }

        let change = pending(for: book.id, in: context) ?? {
            let change = PendingChange(entityName: entityName, entityID: book.id, operation: .update)
            context.insert(change)
            return change
        }()
        var delta = change.payload.flatMap { try? JSONDecoder().decode(Delta.self, from: $0) } ?? Delta()
        // Relative to the server as it was before the first unsent change: undoing a change just drops it.
        if isOn {
            if delta.remove.remove(shelf.remoteID) == nil { delta.add.insert(shelf.remoteID) }
        } else {
            if delta.add.remove(shelf.remoteID) == nil { delta.remove.insert(shelf.remoteID) }
        }
        change.payload = try? JSONEncoder().encode(delta)
        change.isParked = false
        change.nextAttemptAt = nil
    }

    static func pending(for bookID: UUID, in context: ModelContext) -> PendingChange? {
        let name = entityName
        let descriptor = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.entityName == name && $0.entityID == bookID })
        return try? context.fetch(descriptor).first
    }

    static func pendingBookIDs(in context: ModelContext) -> Set<UUID> {
        let name = entityName
        let descriptor = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.entityName == name })
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.entityID))
    }
}

/// Mirrors an account's shelves and their books, and sends shelf changes made here.
///
/// Like `AnnotationSyncer`, it works in the caller's context (the main context), where the detail page changes a
/// book's shelves.
public struct ShelfSyncer {
    let modelContext: ModelContext

    public init(context: ModelContext) {
        self.modelContext = context
    }

    public struct PullResult: Sendable, Equatable {
        public var shelves = 0
        public var removed = 0
    }

    // MARK: Pull

    /// Run after catalog sync, so the books the shelves point at exist.
    public func pull(accountID: UUID, from server: any ShelfRemote,
                     isolation: isolated (any Actor)? = #isolation) async throws -> PullResult {
        guard let account = try modelContext.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.id == accountID })).first
        else { return PullResult() }

        let remote = try await server.shelves()
        var members: [[Int64]] = []  // In the order of `remote`.
        for shelf in remote {
            members.append(try await server.bookIDs(onShelf: shelf))
        }

        let booksByRemoteID = Dictionary(account.books.compactMap { book in book.remoteID.map { ($0, book) } },
                                         uniquingKeysWith: { first, _ in first })
        let pending = ShelfOutbox.pendingBookIDs(in: modelContext)
        var local = Dictionary(account.shelves.map { (Key($0.kind, $0.remoteID), $0) }, uniquingKeysWith: { first, _ in first })
        var result = PullResult()

        for (index, item) in remote.enumerated() {
            let kind: Shelf.Kind = item.isMagic ? .magic : .regular
            let shelf = local.removeValue(forKey: Key(kind, item.id)) ?? {
                let shelf = Shelf(account: account, remoteID: item.id, kind: kind, name: item.name)
                modelContext.insert(shelf)
                return shelf
            }()
            if shelf.name != item.name { shelf.name = item.name }
            if shelf.icon != item.icon { shelf.icon = item.icon }
            if shelf.isPublic != item.isPublic { shelf.isPublic = item.isPublic }

            var books = members[index].compactMap { booksByRemoteID[$0] }
            if kind == .regular {
                // A book whose shelves changed here, and hasn't been sent yet, keeps this device's answer.
                books.removeAll { pending.contains($0.id) }
                books += shelf.books.filter { pending.contains($0.id) }
            }
            if Set(books.map(\.id)) != Set(shelf.books.map(\.id)) { shelf.books = books }
            result.shelves += 1
        }
        for shelf in local.values {  // Deleted on the server.
            modelContext.delete(shelf)
            result.removed += 1
        }
        try modelContext.save()
        return result
    }

    private struct Key: Hashable {
        let kind: Shelf.Kind
        let id: Int64
        init(_ kind: Shelf.Kind, _ id: Int64) {
            self.kind = kind
            self.id = id
        }
    }

    // MARK: Push

    public func pushPending(
        to destination: (_ accountID: UUID) -> (any ShelfRemote)?,
        now: Date = Date(),
        isolation: isolated (any Actor)? = #isolation
    ) async -> OutboxPushResult {
        let name = ShelfOutbox.entityName
        let descriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate { $0.entityName == name && !$0.isParked },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        var result = OutboxPushResult()
        for change in (try? modelContext.fetch(descriptor)) ?? [] {
            if let next = change.nextAttemptAt, next > now { continue }
            let bookID = change.entityID
            guard let book = try? modelContext.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })).first,
                  let remoteID = book.remoteID, let accountID = book.account?.id, let server = destination(accountID),
                  let payload = change.payload,
                  let delta = try? JSONDecoder().decode(ShelfOutbox.Delta.self, from: payload)
            else {
                modelContext.delete(change)
                continue
            }
            if delta.add.isEmpty, delta.remove.isEmpty {
                modelContext.delete(change)  // Changed and changed back.
                continue
            }

            do {
                try await server.assignShelves(bookIDs: [remoteID], add: delta.add.sorted(), remove: delta.remove.sorted())
                if change.payload == payload { modelContext.delete(change) }  // Else it changed while sending.
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
            try? modelContext.save()
        }
        try? modelContext.save()
        return result
    }
}
