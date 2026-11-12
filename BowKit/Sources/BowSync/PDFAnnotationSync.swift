import BowModel
import CoreGraphics
import Foundation
import GrimmoryAPI
import SwiftData

/// Where PDF annotations sync to. `GrimmoryClient` is the real one; tests use a fake.
public protocol PDFAnnotationRemote: Sendable {
    func pdfAnnotationData(bookID: Int64) async throws -> String?
    func savePDFAnnotationData(bookID: Int64, data: String) async throws
}

extension GrimmoryClient: PDFAnnotationRemote {}

/// A PDF highlight in Bow's store. PDFs reuse `Annotation`:
/// - `cfi` holds the EmbedPDF annotation id the web viewer uses,
/// - `spineIndex` the page (from 0),
/// - `kitCoords` the line rectangles as JSON (`[[x, y, width, height]]`, top-left origin, points),
/// - `note` the highlight's note.
public enum PDFHighlights {
    static let entityName = "Book.pdfAnnotations"

    public static func rects(of annotation: Annotation) -> [CGRect] {
        guard let json = annotation.kitCoords, let values = try? JSONDecoder().decode([[Double]].self, from: Data(json.utf8))
        else { return [] }
        return values.compactMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
    }

    static func encode(_ rects: [CGRect]) -> String {
        let values = rects.map { [$0.minX, $0.minY, $0.width, $0.height] }
        return String(decoding: (try? JSONEncoder().encode(values)) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// Adds a highlight to a PDF. `rects` are top-left-origin page rectangles, one per line.
    @discardableResult
    public static func add(to book: Book, page: Int, rects: [CGRect], text: String, color: String,
                           in context: ModelContext) -> Annotation {
        let annotation = Annotation(book: book, kind: .highlight, text: text)
        annotation.cfi = annotation.id.uuidString.lowercased()
        annotation.spineIndex = page
        annotation.kitCoords = encode(rects)
        annotation.colorHex = color
        context.insert(annotation)
        changed(annotation, in: context)
        return annotation
    }

    /// Call after changing a highlight's colour or note.
    public static func edited(_ annotation: Annotation, in context: ModelContext) {
        annotation.kindRaw = (annotation.note?.isEmpty == false ? Annotation.Kind.note : .highlight).rawValue
        annotation.updatedAt = Date()
        changed(annotation, in: context)
    }

    /// Keeps a tombstone until the next push takes it out of the server's document.
    public static func delete(_ annotation: Annotation, in context: ModelContext) {
        annotation.deletedAt = Date()
        changed(annotation, in: context)
    }

    /// What a book's pending entry carries: the annotations changed here, and a stamp that changes with every edit.
    struct Pending: Codable {
        var ids: Set<UUID> = []
        var stamp = UUID()
    }

    /// Records that `annotation` changed. One entry per book, listing the changed annotations: only those are
    /// sent, so a highlight deleted elsewhere isn't brought back by an unrelated change here.
    static func changed(_ annotation: Annotation, in context: ModelContext) {
        guard let book = annotation.book else { return }
        let name = entityName
        let id = book.id
        let descriptor = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.entityName == name && $0.entityID == id })
        let change = (try? context.fetch(descriptor).first) ?? {
            let change = PendingChange(entityName: name, entityID: id, operation: .update)
            context.insert(change)
            return change
        }()
        var pending = change.payload.flatMap { try? JSONDecoder().decode(Pending.self, from: $0) } ?? Pending()
        pending.ids.insert(annotation.id)
        pending.stamp = UUID()
        change.payload = try? JSONEncoder().encode(pending)
        change.isParked = false
        change.nextAttemptAt = nil
    }

    static func pending(for bookID: UUID, in context: ModelContext) -> PendingChange? {
        let name = entityName
        let descriptor = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.entityName == name && $0.entityID == bookID })
        return try? context.fetch(descriptor).first
    }
}

/// Syncs a PDF's highlights with Grimmory. The server keeps one document per book, so a push re-reads it, applies
/// this device's changes (by annotation id) and writes it back: highlights and drawings made elsewhere survive.
///
/// Like the EPUB annotation syncer, it works in the caller's (main) context.
public struct PDFAnnotationSyncer {
    let modelContext: ModelContext

    public init(context: ModelContext) {
        self.modelContext = context
    }

    public enum Failure: Error, Equatable {
        /// The server's document is in pdf.js's old format, which the web viewer converts the next time it opens
        /// the book. Bow won't write over it.
        case legacyFormat
    }

    /// A PDF book's annotations are all PDF highlights; `cfi` (the EmbedPDF id) is set on every one.
    private func annotations(of book: Book) -> [Annotation] {
        book.annotations.filter { $0.cfi != nil }
    }

    /// Pushes every book with unsent PDF annotation changes. Failures stay queued for the next sync.
    public func pushAll(to destination: (_ accountID: UUID) -> (any PDFAnnotationRemote)?,
                        isolation: isolated (any Actor)? = #isolation) async {
        let name = PDFHighlights.entityName
        let descriptor = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.entityName == name && !$0.isParked })
        for change in (try? modelContext.fetch(descriptor)) ?? [] {
            let bookID = change.entityID
            guard let book = try? modelContext.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })).first,
                  let accountID = book.account?.id, let server = destination(accountID)
            else {
                modelContext.delete(change)
                continue
            }
            try? await push(bookID: bookID, to: server)
        }
        try? modelContext.save()
    }

    /// Sends this device's changes for one book, if it has any.
    public func push(bookID: UUID, to server: any PDFAnnotationRemote,
                     isolation: isolated (any Actor)? = #isolation) async throws {
        guard let change = PDFHighlights.pending(for: bookID, in: modelContext),
              let book = try modelContext.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })).first,
              let remoteID = book.remoteID
        else { return }
        let stamp = change.payload

        var document = PDFAnnotationDocument(data: try await server.pdfAnnotationData(bookID: remoteID))
        if document.isLegacy {
            change.isParked = true
            change.lastError = "The server's PDF annotations are in an older format. Open the book once in Grimmory's web viewer to update them."
            try? modelContext.save()
            throw Failure.legacyFormat
        }

        let changedIDs = stamp.flatMap { try? JSONDecoder().decode(PDFHighlights.Pending.self, from: $0) }?.ids ?? []
        let mine = annotations(of: book).filter { changedIDs.contains($0.id) }
        let deleted = mine.filter { $0.deletedAt != nil }
        let live = mine.filter { $0.deletedAt == nil }
        document.remove(ids: Set(deleted.compactMap(\.cfi)))
        document.upsert(live.compactMap(Self.highlight))
        try await server.savePDFAnnotationData(bookID: remoteID, data: try document.encoded())

        for annotation in deleted { modelContext.delete(annotation) }
        if change.payload == stamp { modelContext.delete(change) }  // Else it changed while sending.
        try modelContext.save()
    }

    /// Brings one book's highlights in line with the server. Push first: a book with unsent changes is skipped.
    public func pull(bookID: UUID, from server: any PDFAnnotationRemote,
                     isolation: isolated (any Actor)? = #isolation) async throws {
        guard PDFHighlights.pending(for: bookID, in: modelContext) == nil,
              let book = try modelContext.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })).first,
              let remoteID = book.remoteID
        else { return }

        let document = PDFAnnotationDocument(data: try await server.pdfAnnotationData(bookID: remoteID))
        guard !document.isLegacy else { return }
        var local = Dictionary(annotations(of: book).compactMap { a in a.cfi.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })

        for highlight in document.highlights {
            let annotation = local.removeValue(forKey: highlight.id) ?? {
                let annotation = Annotation(book: book, kind: .highlight, text: "")
                annotation.cfi = highlight.id
                modelContext.insert(annotation)
                return annotation
            }()
            annotation.spineIndex = highlight.pageIndex
            annotation.kitCoords = PDFHighlights.encode(highlight.rects)
            annotation.colorHex = highlight.color
            annotation.note = highlight.contents
            annotation.kindRaw = (highlight.contents == nil ? Annotation.Kind.highlight : .note).rawValue
            annotation.deletedAt = nil
        }
        for annotation in local.values { modelContext.delete(annotation) }  // Deleted elsewhere.
        try modelContext.save()
    }

    static func highlight(_ annotation: Annotation) -> PDFAnnotationDocument.Highlight? {
        guard let id = annotation.cfi, let page = annotation.spineIndex else { return nil }
        return .init(id: id, pageIndex: page, rects: PDFHighlights.rects(of: annotation),
                     color: annotation.colorHex ?? "#FACC15", contents: annotation.note)
    }
}
