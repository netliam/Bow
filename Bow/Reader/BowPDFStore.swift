import BookKit
import BowModel
import BowSync
import Foundation
import PDFKit
import SwiftData

/// Feeds BookKit's PDF reader from Bow's library, so its highlights and page sync with Grimmory:
/// - highlights are Bow `Annotation`s, which `PDFAnnotationSyncer` sends to Grimmory's web viewer;
/// - the position is the book's progress, sent as its page;
/// - bookmarks stay on this device (in BookKit's own store), as Grimmory keeps none for PDFs.
final class BowPDFStore: BKHighlightStoreProtocol, BKReadingPositionStoreProtocol {
    private let book: Book
    private let document: PDFDocument?
    /// From 0: this device's page, or the server's when the reader chose it.
    private let startPage: Int
    private let context: ModelContext
    private let sessions: ReadingSessionRecorder
    private let bookmarks = BKJSONReaderStore()
    /// Called after any change, to send it.
    private let onChange: () -> Void

    init(book: Book, url: URL, startPage: Int, context: ModelContext, sessions: ReadingSessionRecorder,
         onChange: @escaping () -> Void) {
        self.book = book
        self.document = PDFDocument(url: url)
        self.startPage = startPage
        self.context = context
        self.sessions = sessions
        self.onChange = onChange
        sessions.activity(progress: nil, location: String(startPage + 1))
    }

    // MARK: Highlights

    func highlights(bookId: String) async -> [BKHighlight] {
        let saved = book.annotations.filter { $0.cfi != nil && $0.deletedAt == nil }.compactMap { mark(from: $0, bookId: bookId) }
        return saved + (await bookmarks.highlights(bookId: bookId)).filter { $0.type == .bookMark }
    }

    func highlights(bookId: String, chapterId: String) async -> [BKHighlight] {
        await highlights(bookId: bookId).filter { $0.chapterId == chapterId }
    }

    func save(_ highlight: BKHighlight) async {
        if highlight.type == .bookMark {
            await bookmarks.save(highlight)
            return
        }
        let note = highlight.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let annotation = annotation(highlight.uuid) {
            annotation.colorHex = highlight.color
            annotation.note = note.isEmpty ? nil : note
            PDFHighlights.edited(annotation, in: context)
        } else if let location = BKPDFLocation(coords: highlight.coords) {
            let page = document?.page(at: location.pageIndex)
            let rects = location.rects.map { page?.embedRect(fromPage: $0) ?? $0 }
            let annotation = PDFHighlights.add(to: book, page: location.pageIndex, rects: rects, text: highlight.text,
                                               color: highlight.color, id: highlight.uuid, in: context)
            if !note.isEmpty {
                annotation.note = note
                PDFHighlights.edited(annotation, in: context)
            }
        }
        changed()
    }

    func delete(uuid: String) async {
        guard let annotation = annotation(uuid) else {
            await bookmarks.delete(uuid: uuid)
            return
        }
        PDFHighlights.delete(annotation, in: context)
        changed()
    }

    private func annotation(_ id: String) -> Annotation? {
        book.annotations.first { $0.deletedAt == nil && $0.cfi == id }
    }

    /// A Bow highlight as BookKit draws it: its rectangles go from EmbedPDF's top-left origin to PDFKit's page space.
    private func mark(from annotation: Annotation, bookId: String) -> BKHighlight? {
        guard let id = annotation.cfi else { return nil }
        let index = annotation.spineIndex ?? 0
        let page = document?.page(at: index)
        let rects = PDFHighlights.rects(of: annotation).map { page?.pageRect(fromEmbed: $0) ?? $0 }
        let note = annotation.note ?? ""
        return BKHighlight(uuid: id, bookId: bookId, chapterId: "page-\(index + 1)", spineIndex: index,
                           type: note.isEmpty ? .highlight : .note, text: annotation.text,
                           coords: BKPDFLocation(pageIndex: index, rects: rects).coords, note: note,
                           annotationStyle: .highlight, color: annotation.colorHex,
                           dateCreated: annotation.createdAt.timeIntervalSince1970,
                           dateUpdated: annotation.updatedAt.timeIntervalSince1970)
    }

    // MARK: Position

    func position(bookId: String) async -> BKReadingPosition? {
        BKReadingPosition(bookId: bookId, spineIndex: startPage, coords: BKPDFLocation(pageIndex: startPage).coords,
                          chapterId: "page-\(startPage + 1)")
    }

    /// Saves the page here and sends it (BookKit already waits for the reader to settle).
    func save(position: BKReadingPosition) async {
        let index = BKPDFLocation(coords: position.coords)?.pageIndex ?? position.spineIndex
        let count = document?.pageCount ?? 0
        sessions.activity(progress: count > 0 ? Double(index + 1) / Double(count) * 100 : nil, location: String(index + 1))
        // Opening at the stored page isn't reading: sending it could replace a newer position from elsewhere.
        if book.progress?.spineIndex == index { return }
        let progress = book.progress ?? {
            let progress = ReadingProgress(book: book)
            context.insert(progress)
            return progress
        }()
        progress.spineIndex = index
        progress.fraction = count > 0 ? Double(index + 1) / Double(count) : 0
        progress.updatedAt = Date()
        BookOutbox.enqueue(.progress, bookID: book.id, in: context)
        changed()
    }

    private func changed() {
        try? context.save()
        onChange()
    }
}

extension PDFPage {
    /// EmbedPDF (Grimmory's web viewer) measures from the crop box's top-left corner, y growing downwards; PDFKit
    /// from its bottom-left, y growing upwards. Rotated pages aren't handled yet.
    func embedRect(fromPage rect: CGRect) -> CGRect {
        let box = bounds(for: .cropBox)
        return CGRect(x: rect.minX - box.minX, y: box.height - (rect.maxY - box.minY), width: rect.width, height: rect.height)
    }

    func pageRect(fromEmbed rect: CGRect) -> CGRect {
        let box = bounds(for: .cropBox)
        return CGRect(x: box.minX + rect.minX, y: box.minY + box.height - rect.minY - rect.height,
                      width: rect.width, height: rect.height)
    }
}
