import BowLibrary
import BowModel
import BowSync
import DCEpubReaderKit
import Foundation
import SwiftData

/// Connects DCEpubReaderKit to Bow's SwiftData store (ADR-0002): positions go to `ReadingProgress` (plus a CFI
/// for Grimmory, ADR-0003) and highlights, notes and bookmarks to `Annotation`. Replaces the kit's JSON store, so
/// there's one store and one sync queue.
@MainActor
final class BowReaderDelegate: DCReaderCoordsProtocol {
    private let context: ModelContext
    private let bookID: UUID
    private let epub: DCEpubBook
    private let converter: DCCFIConverter
    private let chapterSizes: [Int]
    /// Called after a position is saved and queued for the server.
    private let onProgressQueued: () -> Void
    private var cfiTask: Task<Void, Never>?

    /// Converting to a CFI loads the chapter off screen, so wait for the reader to settle on a page first.
    static let cfiDelay: Duration = .seconds(2)

    init(context: ModelContext, bookID: UUID, epub: DCEpubBook, onProgressQueued: @escaping () -> Void) {
        self.context = context
        self.bookID = bookID
        self.epub = epub
        self.converter = DCCFIConverter(book: epub)
        self.chapterSizes = epub.spine.indices.map { index in
            guard let url = epub.chapterURL(forSpineIndex: index),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber)?.intValue
            else { return 0 }
            return size
        }
        self.onProgressQueued = onProgressQueued
    }

    private var book: Book? {
        let id = bookID
        return try? context.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: Position

    func handleCoords(book _: DCEpubBook, spineIndex: Int, coords: String, chapterURL: URL?, isBookMark: Bool) {
        // Bookmarks arrive through `save(highlight:)` as `.bookMark` marks; this call is only the position.
        guard !isBookMark, let book else { return }
        let progress = book.progress ?? {
            let progress = ReadingProgress(book: book)
            context.insert(progress)
            return progress
        }()
        progress.kitCoords = coords
        progress.spineIndex = spineIndex
        progress.href = href(forSpineIndex: spineIndex)
        progress.fraction = ReadingFraction.estimate(chapterSizes: chapterSizes, spineIndex: spineIndex)
        progress.updatedAt = Date()
        try? context.save()

        cfiTask?.cancel()
        cfiTask = Task { [weak self] in
            try? await Task.sleep(for: Self.cfiDelay)
            guard let self, !Task.isCancelled else { return }
            if let cfi = await converter.cfi(fromCoords: coords, spineIndex: spineIndex), !Task.isCancelled {
                progress.cfi = cfi
            }
            ProgressOutbox.enqueue(bookID: bookID, in: context)
            try? context.save()
            onProgressQueued()
        }
    }

    /// The chapter's path inside the EPUB, as Grimmory's web reader names sections (relative to the zip root).
    private func href(forSpineIndex index: Int) -> String? {
        guard epub.spine.indices.contains(index) else { return nil }
        let idref = epub.spine[index].idref
        guard let href = epub.manifest.first(where: { $0.id == idref })?.href else { return nil }
        let opfDirectory = (epub.packagePath as NSString).deletingLastPathComponent
        return opfDirectory.isEmpty ? href : "\(opfDirectory)/\(href)"
    }

    // MARK: Highlights, notes, bookmarks

    func save(highlight: DCHighlight) async {
        guard let book, let id = UUID(uuidString: highlight.uuid) else { return }
        let annotation = book.annotations.first { $0.id == id } ?? {
            let annotation = Annotation(id: id, book: book, kind: HighlightMapping.kind(highlight.type), text: highlight.text)
            annotation.createdAt = Date(timeIntervalSince1970: highlight.dateCreated)
            context.insert(annotation)
            return annotation
        }()
        annotation.kindRaw = HighlightMapping.kind(highlight.type).rawValue
        annotation.text = highlight.text
        annotation.kitCoords = highlight.coords
        annotation.spineIndex = highlight.spineIndex
        annotation.note = highlight.note.isEmpty ? nil : highlight.note
        annotation.chapterTitle = highlight.chapterTitle.isEmpty ? nil : highlight.chapterTitle
        (annotation.colorHex, annotation.style) = HighlightMapping.grimmoryStyle(highlight.displayStyle,
                                                                                keeping: annotation.style)
        annotation.updatedAt = Date()
        annotation.deletedAt = nil
        try? context.save()
    }

    func deleteHighlight(uuid: String, book _: DCEpubBook) async {
        guard let id = UUID(uuidString: uuid), let annotation = book?.annotations.first(where: { $0.id == id }) else {
            return
        }
        if annotation.remoteID == nil {
            context.delete(annotation)  // Never reached the server: nothing to tell it.
        } else {
            annotation.deletedAt = Date()  // Tombstone, so the delete can sync.
        }
        try? context.save()
    }

    func highlights(for _: DCEpubBook) async -> [DCHighlight]? {
        (book?.annotations ?? []).filter { $0.deletedAt == nil }.map(kitHighlight)
    }

    func highlights(for _: DCEpubBook, chapterId: String) async -> [DCHighlight]? {
        await highlights(for: epub)?.filter { $0.chapterId == chapterId }
    }

    private func kitHighlight(_ annotation: Annotation) -> DCHighlight {
        let spineIndex = annotation.spineIndex ?? 0
        return DCHighlight(
            uuid: annotation.id.uuidString,
            bookId: bookID.uuidString,
            chapterId: epub.chapterURL(forSpineIndex: spineIndex)?.lastPathComponent ?? "",
            spineIndex: spineIndex,
            type: HighlightMapping.markType(annotation.kind),
            text: annotation.text,
            coords: annotation.kitCoords ?? "",
            note: annotation.note ?? "",
            chapterTitle: annotation.chapterTitle ?? "",
            style: HighlightMapping.kitStyle(colorHex: annotation.colorHex, style: annotation.style),
            dateCreated: annotation.createdAt.timeIntervalSince1970,
            dateUpdated: annotation.updatedAt.timeIntervalSince1970
        )
    }
}

/// Between the kit's highlight styles and Grimmory's `color` + `style`. Grimmory's web palette is yellow, green,
/// blue, pink and orange; the kit has purple instead of orange (kit follow-up #14).
enum HighlightMapping {
    static let colors: [DCHighlightStyle: String] = [
        .yellow: "#FACC15", .green: "#4ADE80", .blue: "#38BDF8", .pink: "#F472B6", .purple: "#A78BFA",
    ]

    static func kind(_ type: DCHighlight.MarkType) -> Annotation.Kind {
        switch type {
        case .highlight: .highlight
        case .note: .note
        case .bookMark: .bookmark
        }
    }

    static func markType(_ kind: Annotation.Kind) -> DCHighlight.MarkType {
        switch kind {
        case .highlight: .highlight
        case .note: .note
        case .bookmark: .bookMark
        }
    }

    /// Keeps a Grimmory-only style (`strikethrough`, `squiggly`) unless the reader changed it to underline.
    static func grimmoryStyle(_ style: DCHighlightStyle, keeping current: String) -> (colorHex: String?, style: String) {
        if style == .underline { return (nil, "underline") }
        let keep = current == "strikethrough" || current == "squiggly"
        return (colors[style], keep ? current : "highlight")
    }

    /// Colors the kit can't draw (orange, the web's darker variants) show as yellow; the stored color is kept.
    static func kitStyle(colorHex: String?, style: String) -> DCHighlightStyle {
        if style == "underline" { return .underline }
        guard let hex = colorHex?.uppercased() else { return .yellow }
        return colors.first { $0.value == hex }?.key ?? .yellow
    }
}
