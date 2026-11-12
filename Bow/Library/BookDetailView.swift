import BowLibrary
import BowModel
import BowSync
import GrimmoryAPI
import SwiftData
import SwiftUI

/// A book's page: read or download it, set its read status and rating (synced to Grimmory), and see what the
/// server knows about it. Works offline with what's stored; the description and publisher details load live.
struct BookDetailView: View {
    let book: Book

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(LibrarySync.self) private var librarySync
    @Environment(DownloadCenter.self) private var downloads
    @State private var detail: GrimmoryBookDetail?
    @State private var readerBook: Book?
    @State private var openWhenDownloaded = false
    @State private var isConfirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                readButton
                if let fraction = book.progress?.fraction, fraction > 0 {
                    ProgressView(value: min(fraction, 1)) {
                        Text("\(Int((min(fraction, 1) * 100).rounded()))% read")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                statusAndRating
                about
            }
            .padding()
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu }
        .task(id: book.remoteID) { await loadDetail() }
        .onChange(of: file?.downloadState) { _, state in
            if state == .downloaded, openWhenDownloaded {
                openWhenDownloaded = false
                read()
            }
        }
        .fullScreenCover(item: $readerBook) { book in
            ReaderScreen(book: book)
        }
        .confirmationDialog("Delete \(book.title) from this device?", isPresented: $isConfirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteLocalBook() }
        }
    }

    private var file: BookFile? { book.readableFile }
    private var isLocal: Bool { book.account?.kind == .local }
    /// Has a place in the book on this device: a CFI (EPUB) or a page (PDF).
    private var hasStarted: Bool { book.progress?.cfi != nil || book.progress?.spineIndex != nil }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            CoverView(book: book)
                .frame(width: 140)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.title2.bold())
                if let subtitle = detail?.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.headline).foregroundStyle(.secondary)
                }
                ForEach(book.authors, id: \.self) { author in
                    NavigationLink(value: BookCollection.author(author)) {
                        Text(author)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                    }
                    .accessibilityHint("Shows this author's books.")
                }
                if let series = book.seriesName {
                    NavigationLink(value: BookCollection.series(series)) {
                        Text(book.seriesNumber.map { "Book \($0.formatted()) of \(series)" } ?? series)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                    }
                    .accessibilityHint("Shows the series.")
                }
            }
        }
    }

    @ViewBuilder private var readButton: some View {
        if let file {
            switch file.downloadState {
            case .downloaded:
                Button { read() } label: {
                    Label(hasStarted ? "Continue Reading" : "Read", systemImage: "book")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            case .downloading:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: downloads.progress[file.id] ?? 0) { Text("Downloading…") }
                    Button("Cancel", role: .cancel) { downloads.cancel(file) }
                }
            case .remote, .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        openWhenDownloaded = true
                        downloads.download(file)
                    } label: {
                        Label("Download and Read", systemImage: "icloud.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if let failure = downloads.failures[file.id] {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        } else {
            Label("Bow opens EPUB and PDF books for now. Comic support is coming.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statusAndRating: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Status", selection: statusBinding) {
                ForEach(GrimmoryReadStatus.allCases, id: \.self) { status in
                    Text(status.title).tag(status)
                }
            }
            .pickerStyle(.menu)

            shelvesRow

            HStack(spacing: 4) {
                Text("Rating").foregroundStyle(.secondary)
                Spacer()
                ForEach(1...5, id: \.self) { star in
                    Button {
                        setRating(book.rating == star ? nil : star)  // Tapping the current rating clears it.
                    } label: {
                        Image(systemName: star <= (book.rating ?? 0) ? "star.fill" : "star")
                            .foregroundStyle(.yellow)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                }
            }
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    /// The account's regular shelves, to put the book on or take it off. Magic shelves are filters, so they're
    /// listed but can't be toggled.
    @ViewBuilder private var shelvesRow: some View {
        let all = (book.account?.shelves ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let regular = all.filter { $0.kind == .regular }
        if !isLocal, !all.isEmpty {
            HStack {
                Text("Shelves").foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(regular) { shelf in
                        Toggle(isOn: shelfBinding(shelf)) {
                            Label(shelf.name, systemImage: ShelfIcon.symbol(for: shelf))
                        }
                    }
                    let magic = all.filter { $0.kind == .magic && $0.books.contains { $0.id == book.id } }
                    if !magic.isEmpty {
                        Section("Magic Shelves") {
                            ForEach(magic) { shelf in
                                Label(shelf.name, systemImage: ShelfIcon.symbol(for: shelf))
                            }
                        }
                    }
                } label: {
                    Text(shelfSummary(regular))
                        .lineLimit(1)
                }
                .menuActionDismissBehavior(.disabled)
            }
        }
    }

    private func shelfSummary(_ regular: [Shelf]) -> String {
        let names = regular.filter { shelf in book.shelves.contains { $0.id == shelf.id } }.map(\.name)
        return names.isEmpty ? "None" : names.formatted(.list(type: .and))
    }

    private func shelfBinding(_ shelf: Shelf) -> Binding<Bool> {
        Binding {
            book.shelves.contains { $0.id == shelf.id }
        } set: { isOn in
            ShelfOutbox.set(book, on: shelf, isOn, in: modelContext)
            try? modelContext.save()
            Task { await librarySync.pushChanges(modelContext.container) }
        }
    }

    @ViewBuilder private var about: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 12) {
                if let description = detail.description.map(Self.plainText), !description.isEmpty {
                    Text(description)
                        .font(.body)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Publisher", detail.publisher)
                    row("Published", detail.publishedDate)
                    row("Pages", detail.pageCount.map(String.init))
                    row("Language", detail.language)
                    row("Library", detail.libraryName)
                    row("Categories", detail.categories.isEmpty ? nil : detail.categories.joined(separator: ", "))
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value)
            }
        }
    }

    @ToolbarContentBuilder private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu("More", systemImage: "ellipsis.circle") {
                if isLocal {
                    Button("Delete from Library", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                } else if let file, file.downloadState == .downloaded {
                    Button("Remove Download", systemImage: "trash") { downloads.removeDownload(file) }
                }
            }
        }
    }

    // MARK: Actions

    /// Opens the reader: in its own window on Mac, full screen elsewhere.
    private func read() {
        if ProcessInfo.processInfo.isMacCatalystApp {
            openWindow(id: ReaderWindow.id, value: book.id)
        } else {
            readerBook = book
        }
    }

    private var statusBinding: Binding<GrimmoryReadStatus> {
        Binding {
            book.readStatus.flatMap(GrimmoryReadStatus.init(rawValue:)) ?? .unset
        } set: { status in
            book.readStatus = status == .unset ? nil : status.rawValue
            queue(.readStatus)
        }
    }

    private func setRating(_ rating: Int?) {
        book.rating = rating
        queue(.rating)
    }

    private func queue(_ kind: BookOutbox.Kind) {
        BookOutbox.enqueue(kind, bookID: book.id, in: modelContext)
        try? modelContext.save()
        Task { await librarySync.pushChanges(modelContext.container) }
    }

    private func loadDetail() async {
        guard let remoteID = book.remoteID, let account = book.account,
              let client = GrimmoryAccounts.client(for: account)
        else { return }
        detail = try? await client.bookDetail(bookID: remoteID)
    }

    private func deleteLocalBook() {
        BookStorage.standard.removeFiles(for: book.id)
        modelContext.delete(book)
        try? modelContext.save()
        dismiss()
    }

    /// Grimmory descriptions are often HTML from metadata providers; show them as plain paragraphs.
    static func plainText(_ html: String) -> String {
        var text = html
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
