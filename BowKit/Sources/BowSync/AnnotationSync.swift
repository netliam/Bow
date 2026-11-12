import BowModel
import Foundation
import GrimmoryAPI
import SwiftData

/// Where annotations and bookmarks sync to. `GrimmoryClient` is the real one; tests use a fake.
public protocol AnnotationRemote: Sendable {
    func annotations(bookID: Int64) async throws -> [GrimmoryAnnotation]
    func createAnnotation(bookID: Int64, cfi: String, text: String, color: String?, style: String?, note: String?,
                          chapterTitle: String?) async throws -> Int64
    func updateAnnotation(id: Int64, color: String?, style: String?, note: String?) async throws
    func deleteAnnotation(id: Int64) async throws
    func bookmarks(bookID: Int64) async throws -> [GrimmoryBookmark]
    func createBookmark(bookID: Int64, cfi: String, title: String?) async throws -> Int64
    func updateBookmark(id: Int64, cfi: String?, title: String?) async throws
    func deleteBookmark(id: Int64) async throws
}

extension GrimmoryClient: AnnotationRemote {}

/// Records annotation changes for `AnnotationSyncer` to send (ADR-0002). Keeps at most one pending entry per
/// annotation; the values sent are read from the annotation at push time.
///
/// Highlights and notes map to Grimmory annotations, bookmarks to Grimmory bookmarks.
public enum AnnotationOutbox {
    static let entityName = "Annotation"

    /// Call after creating or editing `annotation`, in the same save. Whether that's a create or an update on the
    /// server is decided when it's sent, from `remoteID` then.
    public static func changed(_ annotation: Annotation, in context: ModelContext) {
        annotation.deletedAt = nil
        record(.update, for: annotation.id, in: context)
    }

    /// Call instead of deleting `annotation`. It stays as a tombstone (`deletedAt`) until the push: then it's
    /// deleted on the server if the server has it, and here.
    public static func deleted(_ annotation: Annotation, in context: ModelContext) {
        annotation.deletedAt = Date()
        record(.delete, for: annotation.id, in: context)
    }

    private static func record(_ operation: PendingChange.Operation, for id: UUID, in context: ModelContext) {
        let change = pending(for: id, in: context) ?? {
            let change = PendingChange(entityName: entityName, entityID: id, operation: operation)
            context.insert(change)
            return change
        }()
        change.operationRaw = operation.rawValue
        change.isParked = false
        change.nextAttemptAt = nil
        // A new stamp on every change, so a push that was already sending an older version keeps this one queued.
        change.payload = Data(UUID().uuidString.utf8)
    }

    static func pending(for id: UUID, in context: ModelContext) -> PendingChange? {
        let name = entityName
        let descriptor = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.entityName == name && $0.entityID == id })
        return try? context.fetch(descriptor).first
    }

    static func pendingIDs(in context: ModelContext) -> Set<UUID> {
        let name = entityName
        let descriptor = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.entityName == name })
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.entityID))
    }
}

/// Sends annotation changes to Grimmory and brings in the server's.
///
/// Grimmory's annotation timestamps have no time zone, so there's no last-write-wins: the server's copy wins
/// unless this device has a change for that annotation waiting to go out.
///
/// It works in the caller's context (the app's main context), not a context of its own. The reader edits
/// annotations in the main context, and objects it already holds wouldn't see another context's `remoteID`s:
/// the next edit would create a duplicate on the server.
public struct AnnotationSyncer {
    let modelContext: ModelContext

    public init(context: ModelContext) {
        self.modelContext = context
    }

    // MARK: Push

    /// - Parameter destination: The server for a book's account, or `nil` for local books.
    public func pushPending(
        to destination: (_ accountID: UUID) -> (any AnnotationRemote)?,
        now: Date = Date(),
        isolation: isolated (any Actor)? = #isolation
    ) async -> OutboxPushResult {
        let name = AnnotationOutbox.entityName
        let descriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate { $0.entityName == name && !$0.isParked },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        var result = OutboxPushResult()
        for change in (try? modelContext.fetch(descriptor)) ?? [] {
            if let next = change.nextAttemptAt, next > now { continue }
            let id = change.entityID
            guard let annotation = try? modelContext.fetch(FetchDescriptor<Annotation>(predicate: #Predicate { $0.id == id })).first,
                  let book = annotation.book, let bookID = book.remoteID, let accountID = book.account?.id,
                  let server = destination(accountID)
            else {
                // Nothing to send it to (a local book, or the annotation is gone). Finish a delete here.
                if let annotation = try? modelContext.fetch(FetchDescriptor<Annotation>(predicate: #Predicate { $0.id == id })).first,
                   annotation.deletedAt != nil {
                    modelContext.delete(annotation)
                }
                modelContext.delete(change)
                continue
            }

            let operation = change.operation
            let stamp = change.payload
            if operation == .delete, annotation.remoteID == nil {
                modelContext.delete(annotation)  // The server never had it.
                modelContext.delete(change)
                continue
            }
            do {
                try await send(operation, annotation, bookID: bookID, to: server)
                if change.payload == stamp {
                    if operation == .delete { modelContext.delete(annotation) }
                    modelContext.delete(change)
                }  // Otherwise it changed while sending: the next push sends the new version.
                result.sent += 1
            } catch GrimmoryError.notFound where change.operation != .create {
                // Already gone on the server: deleted there, or by the delete this was retrying.
                modelContext.delete(annotation)
                modelContext.delete(change)
                result.sent += 1
            } catch let error as GrimmoryError where OutboxPusher.isPermanent(error) {
                change.isParked = true
                change.lastError = "\(error)"
                result.parked += 1
            } catch MissingCFI.missing {
                change.isParked = true
                change.lastError = "No CFI for this annotation, so Grimmory can't place it."
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

    private enum MissingCFI: Error { case missing }

    private func send(_ operation: PendingChange.Operation, _ annotation: Annotation, bookID: Int64,
                      to server: any AnnotationRemote, isolation: isolated (any Actor)? = #isolation) async throws {
        let isBookmark = annotation.kind == .bookmark
        let title = annotation.chapterTitle ?? (annotation.text.isEmpty ? nil : annotation.text)
        switch (operation, annotation.remoteID) {
        case (.delete, let remoteID?):
            if isBookmark { try await server.deleteBookmark(id: remoteID) } else { try await server.deleteAnnotation(id: remoteID) }
        case (.delete, nil):
            break  // Never reached the server.
        case (_, let remoteID?):
            if isBookmark {
                try await server.updateBookmark(id: remoteID, cfi: annotation.cfi, title: title)
            } else {
                try await server.updateAnnotation(id: remoteID, color: annotation.colorHex, style: annotation.style,
                                                  note: annotation.note)
            }
        case (_, nil):
            guard let cfi = annotation.cfi else { throw MissingCFI.missing }
            if isBookmark {
                annotation.remoteID = try await server.createBookmark(bookID: bookID, cfi: cfi, title: title)
            } else {
                annotation.remoteID = try await server.createAnnotation(
                    bookID: bookID, cfi: cfi, text: annotation.text, color: annotation.colorHex,
                    style: annotation.style, note: annotation.note, chapterTitle: annotation.chapterTitle
                )
            }
        }
    }

    // MARK: Pull

    public struct PullResult: Sendable, Equatable {
        public var added = 0
        public var updated = 0
        public var removed = 0
    }

    /// Brings one book's annotations and bookmarks in line with the server, keeping local changes that haven't
    /// gone out yet. Annotations that arrive (or whose CFI changed) have no `kitCoords`: the reader computes them.
    public func pull(bookID: UUID, from server: any AnnotationRemote,
                     isolation: isolated (any Actor)? = #isolation) async throws -> PullResult {
        guard let book = try modelContext.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })).first,
              let remoteID = book.remoteID
        else { return PullResult() }

        let remote = try await (server.annotations(bookID: remoteID), server.bookmarks(bookID: remoteID))

        // Pending as of now, after the requests: a change made meanwhile is kept too.
        let pending = AnnotationOutbox.pendingIDs(in: modelContext)
        var result = PullResult()
        merge(remote.0.map(Incoming.init), into: book, bookmarks: false, pending: pending, result: &result)
        merge(remote.1.map(Incoming.init), into: book, bookmarks: true, pending: pending, result: &result)
        try modelContext.save()
        return result
    }

    /// The fields both kinds share, so one merge handles them.
    private struct Incoming {
        var id: Int64
        var cfi: String?
        var text: String
        var color: String?
        var style: String?
        var note: String?
        var chapterTitle: String?
        var kind: Annotation.Kind

        init(_ a: GrimmoryAnnotation) {
            let note = a.note?.isEmpty == false ? a.note : nil
            self.init(id: a.id, cfi: a.cfi, text: a.text, color: a.color?.uppercased(), style: a.style, note: note,
                      chapterTitle: a.chapterTitle, kind: note == nil ? .highlight : .note)
        }

        init(_ b: GrimmoryBookmark) {
            self.init(id: b.id, cfi: b.cfi, text: b.title ?? "", color: nil, style: nil, note: nil,
                      chapterTitle: b.title, kind: .bookmark)
        }

        init(id: Int64, cfi: String?, text: String, color: String?, style: String?, note: String?,
             chapterTitle: String?, kind: Annotation.Kind) {
            self.id = id
            self.cfi = cfi
            self.text = text
            self.color = color
            self.style = style
            self.note = note
            self.chapterTitle = chapterTitle
            self.kind = kind
        }
    }

    private func merge(_ incoming: [Incoming], into book: Book, bookmarks: Bool, pending: Set<UUID>,
                       result: inout PullResult) {
        // Annotation and bookmark IDs are separate sequences on the server.
        let local = book.annotations.filter { ($0.kind == .bookmark) == bookmarks && $0.remoteID != nil }
        var byRemoteID = Dictionary(local.map { ($0.remoteID!, $0) }, uniquingKeysWith: { first, _ in first })

        for item in incoming {
            if let annotation = byRemoteID.removeValue(forKey: item.id) {
                guard !pending.contains(annotation.id) else { continue }
                if apply(item, to: annotation) { result.updated += 1 }
            } else {
                let annotation = Annotation(book: book, kind: item.kind, text: item.text, style: item.style ?? "highlight")
                annotation.remoteID = item.id
                modelContext.insert(annotation)
                apply(item, to: annotation)
                result.added += 1
            }
        }
        // Left over: deleted on the server.
        for annotation in byRemoteID.values where !pending.contains(annotation.id) {
            modelContext.delete(annotation)
            result.removed += 1
        }
    }

    /// Returns whether anything changed.
    @discardableResult
    private func apply(_ item: Incoming, to annotation: Annotation) -> Bool {
        var changed = false
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Annotation, T>, _ value: T) {
            if annotation[keyPath: keyPath] != value {
                annotation[keyPath: keyPath] = value
                changed = true
            }
        }
        if annotation.cfi != item.cfi {
            set(\.cfi, item.cfi)
            set(\.kitCoords, nil)  // The reader recomputes them from the new CFI.
        }
        set(\.kindRaw, item.kind.rawValue)
        set(\.text, item.text)
        set(\.note, item.note)
        set(\.chapterTitle, item.chapterTitle)
        if let style = item.style { set(\.style, style) }
        if let color = item.color { set(\.colorHex, color) }
        set(\.deletedAt, nil)
        if changed { annotation.updatedAt = Date() }
        return changed
    }
}
