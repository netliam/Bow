import BowModel
import Foundation
import GrimmoryAPI
import SwiftData
import Testing
@testable import BowSync

/// An in-memory Grimmory for annotations and bookmarks.
actor FakeAnnotationServer: AnnotationRemote {
    var annotations: [Int64: GrimmoryAnnotation] = [:]
    var bookmarks: [Int64: GrimmoryBookmark] = [:]
    private(set) var calls: [String] = []
    private var nextID: Int64 = 100
    var error: (any Error)?

    private var hook: (@MainActor () -> Void)?

    func fail(with error: (any Error)?) { self.error = error }
    func onCall(_ hook: (@MainActor () -> Void)?) { self.hook = hook }
    func put(_ annotation: GrimmoryAnnotation) { annotations[annotation.id] = annotation }
    func put(_ bookmark: GrimmoryBookmark) { bookmarks[bookmark.id] = bookmark }
    func remove(annotation id: Int64) { annotations[id] = nil }

    private func record(_ call: String) async throws {
        if let error { throw error }
        calls.append(call)
        if let hook { await hook() }
    }

    func annotations(bookID _: Int64) async throws -> [GrimmoryAnnotation] {
        try await record("list annotations")
        return annotations.values.sorted { $0.id < $1.id }
    }

    func createAnnotation(bookID _: Int64, cfi: String, text: String, color: String?, style: String?,
                          note: String?, chapterTitle: String?) async throws -> Int64 {
        try await record("create annotation")
        nextID += 1
        annotations[nextID] = GrimmoryAnnotation(id: nextID, cfi: cfi, text: text, color: color, style: style,
                                                 note: note, chapterTitle: chapterTitle)
        return nextID
    }

    func updateAnnotation(id: Int64, color: String?, style: String?, note: String?) async throws {
        try await record("update annotation \(id)")
        guard annotations[id] != nil else { throw GrimmoryError.notFound }
        annotations[id]?.color = color
        annotations[id]?.style = style
        annotations[id]?.note = note
    }

    func deleteAnnotation(id: Int64) async throws {
        try await record("delete annotation \(id)")
        guard annotations.removeValue(forKey: id) != nil else { throw GrimmoryError.notFound }
    }

    func bookmarks(bookID _: Int64) async throws -> [GrimmoryBookmark] {
        try await record("list bookmarks")
        return bookmarks.values.sorted { $0.id < $1.id }
    }

    func createBookmark(bookID _: Int64, cfi: String, title: String?) async throws -> Int64 {
        try await record("create bookmark")
        nextID += 1
        bookmarks[nextID] = GrimmoryBookmark(id: nextID, cfi: cfi, title: title)
        return nextID
    }

    func updateBookmark(id: Int64, cfi: String?, title: String?) async throws {
        try await record("update bookmark \(id)")
        bookmarks[id] = GrimmoryBookmark(id: id, cfi: cfi, title: title)
    }

    func deleteBookmark(id: Int64) async throws {
        try await record("delete bookmark \(id)")
        guard bookmarks.removeValue(forKey: id) != nil else { throw GrimmoryError.notFound }
    }
}

@MainActor
@Suite struct AnnotationSyncTests {
    let container: ModelContainer
    let book: Book
    let server = FakeAnnotationServer()

    init() throws {
        container = try BowStore.makeContainer(inMemory: true)
        let account = Account(kind: .grimmory, displayName: "Home", serverURL: URL(string: "https://books.example.com"))
        book = Book(account: account, remoteID: 5, title: "Moby-Dick")
        container.mainContext.insert(account)
        container.mainContext.insert(book)
        try container.mainContext.save()
    }

    private var context: ModelContext { container.mainContext }

    private func highlight(_ text: String = "Call me Ishmael", cfi: String? = "epubcfi(/6/4!/4/2,/1:0,/1:15)") throws -> Annotation {
        let annotation = Annotation(book: book, kind: .highlight, text: text)
        annotation.cfi = cfi
        annotation.colorHex = "#FACC15"
        context.insert(annotation)
        AnnotationOutbox.changed(annotation, in: context)
        try context.save()
        return annotation
    }

    private func push() async -> OutboxPushResult {
        let server = server
        return await AnnotationSyncer(context: context).pushPending { _ in server }
    }

    private func pull() async throws -> AnnotationSyncer.PullResult {
        try await AnnotationSyncer(context: context).pull(bookID: book.id, from: server)
    }

    private func annotations() throws -> [Annotation] {
        try context.fetch(FetchDescriptor<Annotation>(sortBy: [SortDescriptor(\.text)]))
    }

    private func pending() throws -> [PendingChange] {
        try context.fetch(FetchDescriptor<PendingChange>())
    }

    // MARK: Push

    @Test func createsThenUpdatesInOnePush() async throws {
        let annotation = try highlight()
        annotation.note = "Opening line"
        AnnotationOutbox.changed(annotation, in: context)  // Still one pending create, which sends the note.
        try context.save()

        #expect(try pending().count == 1)
        #expect(await push() == OutboxPushResult(sent: 1))
        #expect(await server.calls == ["create annotation"])
        #expect(await server.annotations[101]?.note == "Opening line")
        #expect(try annotations().first?.remoteID == 101)
        #expect(try pending().isEmpty)
    }

    @Test func anEditWhileSendingStaysQueued() async throws {
        let annotation = try highlight()
        let syncer = AnnotationSyncer(context: context)
        let server = server
        // The edit lands while the create is on its way to the server.
        await server.onCall { [context] in
            annotation.note = "added meanwhile"
            AnnotationOutbox.changed(annotation, in: context)
        }

        _ = await syncer.pushPending { _ in server }
        await server.onCall(nil)
        #expect(try pending().count == 1)
        _ = await syncer.pushPending { _ in server }

        #expect(await server.calls == ["create annotation", "update annotation 101"])
        #expect(await server.annotations[101]?.note == "added meanwhile")
    }

    @Test func editsAfterCreateAreUpdates() async throws {
        let annotation = try highlight()
        _ = await push()
        annotation.colorHex = "#4ADE80"
        annotation.style = "underline"
        AnnotationOutbox.changed(annotation, in: context)
        try context.save()

        _ = await push()

        #expect(await server.calls == ["create annotation", "update annotation 101"])
        #expect(await server.annotations[101]?.style == "underline")
    }

    @Test func deletingAnUnsentAnnotationNeverTellsTheServer() async throws {
        let annotation = try highlight()
        AnnotationOutbox.deleted(annotation, in: context)
        try context.save()

        #expect(await push() == OutboxPushResult())
        #expect(await server.calls.isEmpty)
        #expect(try annotations().isEmpty)
        #expect(try pending().isEmpty)
    }

    @Test func deletesSyncThroughATombstone() async throws {
        let annotation = try highlight()
        _ = await push()
        AnnotationOutbox.deleted(annotation, in: context)
        try context.save()
        #expect(try annotations().first?.deletedAt != nil)

        #expect(await push().sent == 1)
        #expect(await server.calls.last == "delete annotation 101")
        #expect(try annotations().isEmpty)
    }

    @Test func deleteOfSomethingAlreadyGoneCounts() async throws {
        let annotation = try highlight()
        _ = await push()
        await server.remove(annotation: 101)
        AnnotationOutbox.deleted(annotation, in: context)
        try context.save()

        #expect(await push().sent == 1)
        #expect(try annotations().isEmpty)
    }

    @Test func bookmarksUseTheBookmarkAPI() async throws {
        let bookmark = Annotation(book: book, kind: .bookmark, text: "")
        bookmark.cfi = "epubcfi(/6/4!/4/10)"
        bookmark.chapterTitle = "Loomings"
        context.insert(bookmark)
        AnnotationOutbox.changed(bookmark, in: context)
        try context.save()

        _ = await push()

        #expect(await server.calls == ["create bookmark"])
        #expect(await server.bookmarks[101] == GrimmoryBookmark(id: 101, cfi: "epubcfi(/6/4!/4/10)", title: "Loomings"))
    }

    @Test func annotationsWithoutACFIAreParked() async throws {
        _ = try highlight(cfi: nil)

        #expect(await push().parked == 1)
        #expect(await server.calls.isEmpty)
        #expect(try pending().first?.isParked == true)
    }

    @Test func networkFailuresRetryLater() async throws {
        _ = try highlight()
        await server.fail(with: URLError(.notConnectedToInternet))

        #expect(await push().failed == 1)
        #expect(try pending().first?.nextAttemptAt != nil)
        #expect(try annotations().first?.remoteID == nil)
    }

    // MARK: Pull

    @Test func pullAddsUpdatesAndRemoves() async throws {
        let kept = try highlight("kept")
        let gone = try highlight("gone")
        _ = await push()  // kept = 101, gone = 102
        await server.remove(annotation: 102)
        await server.put(GrimmoryAnnotation(id: 101, cfi: "epubcfi(/6/4!/4/2,/1:0,/1:4)", text: "kept",
                                            color: "#f472b6", style: "squiggly", note: "from the web"))
        await server.put(GrimmoryAnnotation(id: 200, cfi: "epubcfi(/6/6!/4/8,/1:3,/1:9)", text: "new one"))
        await server.put(GrimmoryBookmark(id: 300, cfi: "epubcfi(/6/6!/4/2)", title: "Chapter 2"))
        kept.kitCoords = "0001/0000:0,0001/0000:4"
        try context.save()

        let result = try await pull()

        #expect(result == .init(added: 2, updated: 1, removed: 1))
        let byText = Dictionary(try annotations().map { ($0.text, $0) }, uniquingKeysWith: { $1 })
        #expect(byText["gone"] == nil)
        #expect(gone.isDeleted || byText["gone"] == nil)
        #expect(byText["kept"]?.kind == .note)
        #expect(byText["kept"]?.colorHex == "#F472B6")
        #expect(byText["kept"]?.style == "squiggly")
        #expect(byText["kept"]?.kitCoords == nil)  // The CFI changed, so the reader recomputes them.
        #expect(byText["new one"]?.remoteID == 200)
        #expect(byText["Chapter 2"]?.kind == .bookmark)
    }

    @Test func pullKeepsChangesThatHaventGoneOut() async throws {
        let annotation = try highlight()
        _ = await push()
        annotation.note = "mine"
        AnnotationOutbox.changed(annotation, in: context)
        try context.save()
        await server.put(GrimmoryAnnotation(id: 101, cfi: annotation.cfi!, text: annotation.text, note: "theirs"))

        #expect(try await pull() == .init())
        #expect(try annotations().first?.note == "mine")
    }

    @Test func unchangedAnnotationsAreLeftAlone() async throws {
        _ = try highlight()
        _ = await push()

        #expect(try await pull() == .init())
    }
}
