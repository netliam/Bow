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
    /// Annotations get their own: a converter holds one chapter at a time, and a position and a highlight
    /// converting at once could each load the other's chapter.
    private let annotationConverter: DCCFIConverter
    private var annotationConversion: Task<String?, Never>?
    /// Called after a change (position, annotation) is saved and queued for the server.
    private let onChangeQueued: () -> Void
    private var cfiTask: Task<Void, Never>?

    /// Converting to a CFI loads the chapter off screen, so wait for the reader to settle on a page first.
    static let cfiDelay: Duration = .seconds(2)

    init(context: ModelContext, bookID: UUID, epub: DCEpubBook, onChangeQueued: @escaping () -> Void) {
        self.context = context
        self.bookID = bookID
        self.epub = epub
        self.converter = DCCFIConverter(book: epub)
        self.annotationConverter = DCCFIConverter(book: epub)
        self.onChangeQueued = onChangeQueued
    }

    private var book: Book? {
        let id = bookID
        return try? context.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: Position

    func handleCoords(book _: DCEpubBook, spineIndex: Int, coords: String, chapterURL: URL?, isBookMark: Bool) {
        // Bookmarks arrive through `save(highlight:)` as `.bookMark` marks; this call is only the position.
        guard !isBookMark, let book else { return }
        // The reader reports where it opened, too. That isn't reading: pushing it would replace a newer
        // position from another device on the server, and bumping `updatedAt` would hide that position.
        if book.progress?.kitCoords == coords, book.progress?.spineIndex == spineIndex { return }
        let progress = book.progress ?? {
            let progress = ReadingProgress(book: book)
            context.insert(progress)
            return progress
        }()
        progress.kitCoords = coords
        progress.spineIndex = spineIndex
        progress.href = href(forSpineIndex: spineIndex)
        progress.updatedAt = Date()
        try? context.save()

        cfiTask?.cancel()
        cfiTask = Task { [weak self] in
            try? await Task.sleep(for: Self.cfiDelay)
            guard let self, !Task.isCancelled else { return }
            if let cfi = await converter.cfi(fromCoords: coords, spineIndex: spineIndex), !Task.isCancelled {
                progress.cfi = cfi
            }
            BookOutbox.enqueue(.progress, bookID: bookID, in: context)
            try? context.save()
            onChangeQueued()
        }
    }

    /// The whole-book fraction, as the reader's progress bar shows it ("11 of 39"). Arrives right after
    /// `handleCoords`, so it's in place before the delayed CFI push reads it.
    func handleProgress(book _: DCEpubBook, progress readerProgress: DCReaderProgress) {
        guard let progress = book?.progress else { return }
        progress.fraction = min(max(readerProgress.fraction, 0), 1)
        try? context.save()
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
        let existing = book.annotations.first { $0.id == id }
        // Grimmory places annotations by CFI. Only a new or moved one needs converting; edits keep theirs.
        let needsCFI = existing?.cfi == nil || existing?.kitCoords != highlight.coords
            || existing?.spineIndex != highlight.spineIndex
        let annotation = existing ?? {
            let annotation = Annotation(id: id, book: book, kind: GrimmoryHighlights.kind(highlight.type), text: highlight.text)
            annotation.createdAt = Date(timeIntervalSince1970: highlight.dateCreated)
            context.insert(annotation)
            return annotation
        }()
        annotation.kindRaw = GrimmoryHighlights.kind(highlight.type).rawValue
        annotation.text = highlight.text
        annotation.kitCoords = highlight.coords
        annotation.spineIndex = highlight.spineIndex
        annotation.note = highlight.note.isEmpty ? nil : highlight.note
        annotation.chapterTitle = highlight.chapterTitle.isEmpty ? nil : highlight.chapterTitle
        annotation.style = highlight.annotationStyle.rawValue
        annotation.colorHex = highlight.color.uppercased()
        annotation.updatedAt = Date()
        try? context.save()

        if needsCFI {
            annotation.cfi = await annotationCFI(coords: highlight.coords, spineIndex: highlight.spineIndex)
        }
        AnnotationOutbox.changed(annotation, in: context)
        try? context.save()
        onChangeQueued()
    }

    /// One conversion at a time, in order.
    private func annotationCFI(coords: String, spineIndex: Int) async -> String? {
        let previous = annotationConversion
        let converter = annotationConverter
        let task = Task<String?, Never> {
            _ = await previous?.value
            return await converter.cfi(fromCoords: coords, spineIndex: spineIndex)
        }
        annotationConversion = task
        return await task.value
    }

    func deleteHighlight(uuid: String, book _: DCEpubBook) async {
        guard let id = UUID(uuidString: uuid), let annotation = book?.annotations.first(where: { $0.id == id }) else {
            return
        }
        AnnotationOutbox.deleted(annotation, in: context)
        try? context.save()
        onChangeQueued()
    }

    func highlights(for _: DCEpubBook) async -> [DCHighlight]? {
        // Annotations from the server whose CFI couldn't be placed in this edition have no coords to draw.
        (book?.annotations ?? []).filter { $0.deletedAt == nil && $0.kitCoords != nil }.map(kitHighlight)
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
            type: GrimmoryHighlights.markType(annotation.kind),
            text: annotation.text,
            coords: annotation.kitCoords ?? "",
            note: annotation.note ?? "",
            chapterTitle: annotation.chapterTitle ?? "",
            annotationStyle: GrimmoryHighlights.style(annotation.style),
            color: annotation.colorHex ?? GrimmoryHighlights.defaultColor(for: annotation.style),
            dateCreated: annotation.createdAt.timeIntervalSince1970,
            dateUpdated: annotation.updatedAt.timeIntervalSince1970
        )
    }
}

/// Grimmory's annotation styles and colours, exactly as its web reader offers them
/// (`frontend/.../ebook-reader/shared/selection-popup.component.ts`), so annotations look the same in both.
enum GrimmoryHighlights {
    static let highlightColors: [(String, String)] = [
        ("Yellow", "#FACC15"), ("Green", "#4ADE80"), ("Blue", "#38BDF8"), ("Pink", "#F472B6"), ("Orange", "#FB923C"),
    ]
    /// Underline, squiggly and strikethrough use a darker set.
    static let lineColors: [(String, String)] = [
        ("Dark Gold", "#B8860B"), ("Forest Green", "#228B22"), ("Dodger Blue", "#1E90FF"),
        ("Crimson", "#DC143C"), ("Dark Orange", "#FF8C00"),
    ]

    /// In the web reader's order.
    static let palettes: [DCHighlightPalette] = [
        DCHighlightPalette(style: .highlight, colors: highlightColors),
        DCHighlightPalette(style: .underline, colors: lineColors),
        DCHighlightPalette(style: .squiggly, colors: lineColors),
        DCHighlightPalette(style: .strikethrough, colors: lineColors),
    ]

    /// Grimmory's style names are the kit's raw values; anything unknown draws as a highlight.
    static func style(_ name: String) -> DCAnnotationStyle {
        DCAnnotationStyle(rawValue: name) ?? .highlight
    }

    /// For annotations stored without a colour: the web reader's first colour for the style.
    static func defaultColor(for style: String) -> String {
        (self.style(style) == .highlight ? highlightColors : lineColors)[0].1
    }

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
}
