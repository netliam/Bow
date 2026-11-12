import BowModel
import BowSync
import PDFKit
import SwiftData
import SwiftUI

/// A downloaded PDF in PDFKit: one page at a time, swiping to turn. The page is saved as the book's position and
/// queued for Grimmory, which shows it as the PDF's place in the web viewer too.
///
/// Select text to highlight it in one of Grimmory's colours; tap a highlight to recolour it, add a note or delete
/// it. Highlights sync with the web viewer's PDF annotations (`PDFAnnotationSyncer`).
struct PDFReaderView: View {
    let book: Book
    let url: URL
    /// From 0.
    let startPage: Int
    let sessions: ReadingSessionRecorder
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @State private var page = 0
    @State private var pageCount = 0
    @State private var showsControls = true
    @State private var pushTask: Task<Void, Never>?
    @State private var selection: PDFSelection?
    @State private var clearSelection = 0
    @State private var tappedHighlight: Annotation?
    @State private var noteDraft = ""
    @State private var isEditingNote = false

    /// The book's PDF highlights, minus ones waiting to be deleted on the server.
    private var highlights: [Annotation] {
        book.annotations.filter { $0.cfi != nil && $0.deletedAt == nil }
    }

    var body: some View {
        PDFKitView(url: url, startPage: startPage, highlights: highlights.map(DrawnHighlight.init),
                   clearSelection: clearSelection) { index, count in
            pageCount = count
            page = index
            // `save` skips the page already stored, but not one the reader jumped to (another device's).
            save(page: index, of: count)
        } onSelection: { newSelection in
            selection = newSelection
        } onTap: { highlightID in
            if let highlightID, let annotation = highlights.first(where: { $0.cfi == highlightID }) {
                tappedHighlight = annotation
            } else {
                withAnimation { showsControls.toggle() }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) {
            if showsControls {
                HStack {
                    Button("Close", systemImage: "xmark", action: onClose)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                    Spacer()
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let selection, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                highlightBar(for: selection)
            } else if showsControls, pageCount > 0 {
                Text("\(page + 1) of \(pageCount)")
                    .font(.footnote.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .accessibilityLabel("Page \(page + 1) of \(pageCount)")
            }
        }
        .confirmationDialog("Highlight", isPresented: .init(get: { tappedHighlight != nil && !isEditingNote },
                                                             set: { if !$0, !isEditingNote { tappedHighlight = nil } }),
                            presenting: tappedHighlight) { annotation in
            ForEach(GrimmoryHighlights.highlightColors, id: \.1) { name, hex in
                Button(annotation.colorHex == hex ? "\(name) ✓" : name) { recolour(annotation, hex) }
            }
            Button(annotation.note == nil ? "Add Note…" : "Edit Note…") {
                noteDraft = annotation.note ?? ""
                isEditingNote = true
            }
            Button("Delete Highlight", role: .destructive) { delete(annotation) }
        } message: { annotation in
            if let note = annotation.note { Text(note) }
        }
        .alert("Note", isPresented: $isEditingNote) {
            TextField("Note", text: $noteDraft, axis: .vertical)
            Button("Save") {
                if let annotation = tappedHighlight { setNote(annotation, noteDraft) }
                tappedHighlight = nil
            }
            Button("Cancel", role: .cancel) { tappedHighlight = nil }
        }
        .onAppear {
            page = startPage
            sessions.activity(progress: nil, location: String(startPage + 1))
        }
    }

    private func highlightBar(for selection: PDFSelection) -> some View {
        HStack(spacing: 16) {
            Text("Highlight").font(.subheadline.weight(.semibold))
            ForEach(GrimmoryHighlights.highlightColors, id: \.1) { name, hex in
                Button {
                    highlight(selection, color: hex)
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Highlight in \(name)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Highlights

    /// One highlight per page the selection covers, with a rectangle per line.
    private func highlight(_ selection: PDFSelection, color: String) {
        guard let document = selection.pages.first?.document else { return }
        var linesByPage: [Int: [CGRect]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let index = document.index(for: page)
                linesByPage[index, default: []].append(page.embedRect(fromPage: line.bounds(for: page)))
            }
        }
        let text = selection.string ?? ""
        for (index, rects) in linesByPage.sorted(by: { $0.key < $1.key }) {
            PDFHighlights.add(to: book, page: index, rects: rects, text: text, color: color, in: modelContext)
        }
        clearSelection += 1
        self.selection = nil
        changed()
    }

    private func recolour(_ annotation: Annotation, _ hex: String) {
        annotation.colorHex = hex
        PDFHighlights.edited(annotation, in: modelContext)
        changed()
    }

    private func setNote(_ annotation: Annotation, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        annotation.note = trimmed.isEmpty ? nil : trimmed
        PDFHighlights.edited(annotation, in: modelContext)
        changed()
    }

    private func delete(_ annotation: Annotation) {
        PDFHighlights.delete(annotation, in: modelContext)
        tappedHighlight = nil
        changed()
    }

    private func changed() {
        try? modelContext.save()
        Task { await librarySync.pushChanges(modelContext.container) }
    }

    // MARK: Position

    /// Saves the page here, and sends it a moment after the reader settles on it.
    private func save(page index: Int, of count: Int) {
        sessions.activity(progress: count > 0 ? Double(index + 1) / Double(count) * 100 : nil, location: String(index + 1))
        // Opening at the stored page isn't reading: sending it could replace a newer position from elsewhere.
        if book.progress?.spineIndex == index { return }
        let progress = book.progress ?? {
            let progress = ReadingProgress(book: book)
            modelContext.insert(progress)
            return progress
        }()
        progress.spineIndex = index
        progress.fraction = count > 0 ? Double(index + 1) / Double(count) : 0
        progress.updatedAt = Date()
        try? modelContext.save()

        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            BookOutbox.enqueue(.progress, bookID: book.id, in: modelContext)
            try? modelContext.save()
            await librarySync.pushChanges(modelContext.container)
        }
    }
}

/// What the PDF view draws for one highlight.
private struct DrawnHighlight: Equatable {
    let id: String
    let page: Int
    let rects: [CGRect]
    let color: String
    let hasNote: Bool

    init(_ annotation: Annotation) {
        id = annotation.cfi ?? ""
        page = annotation.spineIndex ?? 0
        rects = PDFHighlights.rects(of: annotation)
        color = annotation.colorHex ?? "#FACC15"
        hasNote = annotation.note != nil
    }
}

/// PDFKit's `PDFView`: reports the page (from 0) and page count, text selections, and taps (with the highlight
/// tapped, if any), and draws Bow's highlights.
private struct PDFKitView: UIViewRepresentable {
    let url: URL
    let startPage: Int
    let highlights: [DrawnHighlight]
    /// Changing it clears the text selection.
    let clearSelection: Int
    let onPageChange: (Int, Int) -> Void
    let onSelection: (PDFSelection?) -> Void
    let onTap: (String?) -> Void

    static let marker = "bow-highlight:"

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true)
        view.backgroundColor = .systemBackground
        view.document = PDFDocument(url: url)
        if let document = view.document, let page = document.page(at: min(max(startPage, 0), document.pageCount - 1)) {
            view.go(to: page)
        }
        context.coordinator.attach(to: view)
        // After this view update: SwiftUI ignores state changes made during one, so the page count wouldn't show.
        Task { @MainActor [coordinator = context.coordinator] in coordinator.report(view) }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.drawn != highlights {
            coordinator.draw(highlights, in: view)
        }
        if coordinator.clearedSelection != clearSelection {
            coordinator.clearedSelection = clearSelection
            view.clearSelection()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView
        var drawn: [DrawnHighlight]?
        var clearedSelection = 0

        init(parent: PDFKitView) {
            self.parent = parent
            self.clearedSelection = parent.clearSelection
        }

        func attach(to view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)),
                                                   name: .PDFViewPageChanged, object: view)
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)),
                                                   name: .PDFViewSelectionChanged, object: view)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.delegate = self
            view.addGestureRecognizer(tap)
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            report(view)
        }

        @objc private func selectionChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            parent.onSelection(view.currentSelection)
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PDFView else { return }
            let point = recognizer.location(in: view)
            guard let page = view.page(for: point, nearest: false) else {
                parent.onTap(nil)
                return
            }
            let pagePoint = view.convert(point, to: page)
            let hit = page.annotations.first {
                $0.userName?.hasPrefix(PDFKitView.marker) == true && $0.bounds.contains(pagePoint)
            }
            parent.onTap(hit?.userName.map { String($0.dropFirst(PDFKitView.marker.count)) })
        }

        // Let PDFView keep its own gestures (selection, paging).
        func gestureRecognizer(_: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool { true }

        func report(_ view: PDFView) {
            guard let document = view.document, let page = view.currentPage else { return }
            parent.onPageChange(document.index(for: page), document.pageCount)
        }

        /// Replaces Bow's highlight annotations on every page. Annotations already in the PDF file are untouched.
        func draw(_ highlights: [DrawnHighlight], in view: PDFView) {
            drawn = highlights
            guard let document = view.document else { return }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for annotation in page.annotations where annotation.userName?.hasPrefix(PDFKitView.marker) == true {
                    page.removeAnnotation(annotation)
                }
            }
            for highlight in highlights {
                guard let page = document.page(at: highlight.page) else { continue }
                for rect in highlight.rects {
                    let annotation = PDFAnnotation(bounds: page.pageRect(fromEmbed: rect), forType: .highlight,
                                                   withProperties: nil)
                    annotation.color = UIColor(Color(hex: highlight.color)).withAlphaComponent(0.45)
                    annotation.userName = PDFKitView.marker + highlight.id
                    page.addAnnotation(annotation)
                }
            }
        }
    }
}

// MARK: Coordinates

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

extension Color {
    /// `#RRGGBB`; anything else is yellow.
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFACC15
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
