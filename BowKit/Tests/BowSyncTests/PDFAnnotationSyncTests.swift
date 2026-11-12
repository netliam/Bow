import BowModel
import CoreGraphics
import Foundation
import GrimmoryAPI
import SwiftData
import Testing
@testable import BowSync

actor FakePDFAnnotationServer: PDFAnnotationRemote {
    var data: String?
    private(set) var saves = 0

    init(data: String? = nil) { self.data = data }

    func pdfAnnotationData(bookID _: Int64) async throws -> String? { data }
    func savePDFAnnotationData(bookID _: Int64, data: String) async throws {
        self.data = data
        saves += 1
    }
}

/// A document as Grimmory's web viewer writes it: a highlight with a note, and an ink drawing Bow doesn't model.
private let webDocument = #"""
{"format":"embedpdf","version":1,"annotations":[
 {"annotation":{"type":9,"id":"web-1","pageIndex":2,"rect":{"origin":{"x":72,"y":100},"size":{"width":200,"height":14}},
  "segmentRects":[{"origin":{"x":72,"y":100},"size":{"width":200,"height":14}}],"strokeColor":"#4ade80","opacity":0.5,
  "contents":"from the web","author":"tester"}},
 {"annotation":{"type":15,"id":"ink-1","pageIndex":0,"inkList":[{"points":[{"x":1,"y":2}]}],"color":"#000000"}}
]}
"""#

@MainActor
@Suite struct PDFAnnotationSyncTests {
    let container: ModelContainer
    let book: Book

    init() throws {
        container = try BowStore.makeContainer(inMemory: true)
        let account = Account(kind: .grimmory, displayName: "Home", serverURL: URL(string: "https://books.example.com"))
        book = Book(account: account, remoteID: 6, title: "Field Notes")
        container.mainContext.insert(account)
        container.mainContext.insert(book)
        container.mainContext.insert(BookFile(book: book, format: .pdf, remoteFileID: 60))
        try container.mainContext.save()
    }

    private var context: ModelContext { container.mainContext }
    private var syncer: PDFAnnotationSyncer { PDFAnnotationSyncer(context: context) }

    private func document(_ server: FakePDFAnnotationServer) async -> PDFAnnotationDocument {
        PDFAnnotationDocument(data: await server.data)
    }

    @Test func pullsTheWebViewersHighlights() async throws {
        let server = FakePDFAnnotationServer(data: webDocument)

        try await syncer.pull(bookID: book.id, from: server)

        let annotation = try #require(book.annotations.first)
        #expect(book.annotations.count == 1)  // The ink drawing isn't a highlight.
        #expect(annotation.cfi == "web-1")
        #expect(annotation.spineIndex == 2)
        #expect(annotation.colorHex == "#4ADE80")
        #expect(annotation.note == "from the web")
        #expect(annotation.kind == .note)
        #expect(PDFHighlights.rects(of: annotation) == [CGRect(x: 72, y: 100, width: 200, height: 14)])
    }

    @Test func pushKeepsWhatTheWebViewerDrew() async throws {
        let server = FakePDFAnnotationServer(data: webDocument)
        try await syncer.pull(bookID: book.id, from: server)

        PDFHighlights.add(to: book, page: 4, rects: [CGRect(x: 10, y: 20, width: 30, height: 12)], text: "mine",
                          color: "#38BDF8", in: context)
        try context.save()
        try await syncer.push(bookID: book.id, to: server)

        let saved = await document(server)
        #expect(saved.highlights.map(\.id).count == 2)
        #expect(saved.highlights.contains { $0.pageIndex == 4 && $0.color == "#38BDF8" })
        let raw = try #require(await server.data)
        #expect(raw.contains("ink-1"))  // The drawing survived.
        #expect(raw.contains("\"author\":\"tester\""))  // And so did fields Bow doesn't model.
        #expect(PDFHighlights.pending(for: book.id, in: context) == nil)
    }

    @Test func editsAndDeletesGoOut() async throws {
        let server = FakePDFAnnotationServer(data: webDocument)
        try await syncer.pull(bookID: book.id, from: server)
        let annotation = try #require(book.annotations.first)

        annotation.colorHex = "#F472B6"
        annotation.note = nil
        PDFHighlights.edited(annotation, in: context)
        try await syncer.push(bookID: book.id, to: server)
        #expect(await document(server).highlights.first?.color == "#F472B6")
        #expect(await document(server).highlights.first?.contents == nil)

        PDFHighlights.delete(annotation, in: context)
        try await syncer.push(bookID: book.id, to: server)
        #expect(await document(server).highlights.isEmpty)
        #expect(book.annotations.isEmpty)
        #expect(await server.data?.contains("ink-1") == true)
    }

    @Test func pullRemovesHighlightsDeletedElsewhereButSkipsUnsentBooks() async throws {
        let server = FakePDFAnnotationServer(data: webDocument)
        try await syncer.pull(bookID: book.id, from: server)

        PDFHighlights.add(to: book, page: 0, rects: [], text: "unsent", color: "#FACC15", in: context)
        await server.setEmpty()
        try await syncer.pull(bookID: book.id, from: server)
        #expect(book.annotations.count == 2)  // Unsent changes: the pull waits for the push.

        try await syncer.push(bookID: book.id, to: server)
        try await syncer.pull(bookID: book.id, from: server)
        #expect(book.annotations.map(\.text) == ["unsent"])  // web-1 was deleted on the server.
    }

    @Test func noAnnotationsYetStartsANewDocument() async throws {
        let server = FakePDFAnnotationServer()
        PDFHighlights.add(to: book, page: 1, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)], text: "first",
                          color: "#FACC15", in: context)

        try await syncer.push(bookID: book.id, to: server)

        let raw = try #require(await server.data)
        #expect(raw.contains("\"format\":\"embedpdf\""))
        #expect(await document(server).highlights.count == 1)
    }

    @Test func legacyDocumentsAreLeftAlone() async throws {
        let server = FakePDFAnnotationServer(data: #"[{"annotationType":9,"pageIndex":0,"rect":[0,0,10,10]}]"#)
        PDFHighlights.add(to: book, page: 0, rects: [], text: "x", color: "#FACC15", in: context)

        await #expect(throws: PDFAnnotationSyncer.Failure.legacyFormat) {
            try await syncer.push(bookID: book.id, to: server)
        }
        #expect(await server.saves == 0)
        #expect(PDFHighlights.pending(for: book.id, in: context)?.isParked == true)
    }
}

extension FakePDFAnnotationServer {
    func setEmpty() { data = #"{"format":"embedpdf","version":1,"annotations":[]}"# }
}
