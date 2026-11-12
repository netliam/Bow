import BowModel
import BowSync
import PDFKit
import SwiftData
import SwiftUI

/// A downloaded PDF in PDFKit: one page at a time, swiping to turn. The page is saved as the book's position and
/// queued for Grimmory, which shows it as the PDF's place in the web viewer too.
struct PDFReaderView: View {
    let book: Book
    let url: URL
    /// From 0.
    let startPage: Int
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(LibrarySync.self) private var librarySync
    @State private var page = 0
    @State private var pageCount = 0
    @State private var showsControls = true
    @State private var pushTask: Task<Void, Never>?

    var body: some View {
        PDFKitView(url: url, startPage: startPage) { index, count in
            pageCount = count
            guard index != page || count == 0 else { return }
            page = index
            save(page: index, of: count)
        }
        .ignoresSafeArea(edges: .bottom)
        .onTapGesture { withAnimation { showsControls.toggle() } }
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
            if showsControls, pageCount > 0 {
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
        .onAppear { page = startPage }
    }

    /// Saves the page here, and sends it a moment after the reader settles on it.
    private func save(page index: Int, of count: Int) {
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

/// PDFKit's `PDFView`, reporting the current page (from 0) and the page count.
private struct PDFKitView: UIViewRepresentable {
    let url: URL
    let startPage: Int
    let onPageChange: (Int, Int) -> Void

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
        context.coordinator.observe(view)
        // After this view update: SwiftUI ignores state changes made during one, so the page count wouldn't show.
        Task { @MainActor [coordinator = context.coordinator] in coordinator.report(view) }
        return view
    }

    func updateUIView(_: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPageChange: onPageChange) }

    @MainActor
    final class Coordinator: NSObject {
        var onPageChange: (Int, Int) -> Void

        init(onPageChange: @escaping (Int, Int) -> Void) {
            self.onPageChange = onPageChange
        }

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)),
                                                   name: .PDFViewPageChanged, object: view)
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            report(view)
        }

        func report(_ view: PDFView) {
            guard let document = view.document, let page = view.currentPage else { return }
            onPageChange(document.index(for: page), document.pageCount)
        }
    }
}
