import BowModel
import BowSync
import GrimmoryAPI
import SwiftData
import SwiftUI

/// Author photos and bios from Grimmory, looked up by name and kept for the session. Books only carry author names,
/// so each author is found by searching the accounts that have their books.
@MainActor
@Observable
final class AuthorDirectory {
    struct Entry {
        var author: GrimmoryAuthor?
        var photo: UIImage?
    }

    private(set) var entries: [String: Entry] = [:]
    private var loading: Set<String> = []

    /// Looks the author up once; later calls return straight away. Servers that are offline leave no entry, so
    /// the next appearance tries again.
    func load(_ name: String, from accounts: [Account]) async {
        guard entries[name] == nil, !loading.contains(name) else { return }
        loading.insert(name)
        defer { loading.remove(name) }

        var reachedAServer = false
        for account in accounts where account.kind == .grimmory {
            guard let client = GrimmoryAccounts.client(for: account) else { continue }
            do {
                guard let author = try await client.author(named: name) else {
                    reachedAServer = true
                    continue
                }
                var photo: UIImage?
                if author.hasPhoto, let data = try? await client.authorPhoto(id: author.id) {
                    photo = UIImage(data: data)
                }
                entries[name] = Entry(author: author, photo: photo)
                return
            } catch {
                continue
            }
        }
        if reachedAServer { entries[name] = Entry() }  // No server knows them: don't ask again this session.
    }
}

/// An author's photo, or their initials until (or unless) Grimmory has one.
struct AuthorAvatar: View {
    let name: String
    var size: CGFloat = 40

    @Environment(AuthorDirectory.self) private var directory
    @Query private var accounts: [Account]

    var body: some View {
        Group {
            if let photo = directory.entries[name]?.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(AuthorNames.initials(name))
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
        .task(id: name) { await directory.load(name, from: accounts) }
    }
}

/// The top of an author's page: photo, name and, when Grimmory has one, their bio.
struct AuthorHeader: View {
    let name: String
    let bookCount: Int

    @Environment(AuthorDirectory.self) private var directory
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                AuthorAvatar(name: name, size: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title2.bold())
                    Text(bookCount == 1 ? "1 book" : "\(bookCount) books")
                        .foregroundStyle(.secondary)
                }
            }
            if let bio = directory.entries[name]?.author?.description.map(BookDetailView.plainText), !bio.isEmpty {
                Text(bio)
                    .font(.callout)
                    .lineLimit(isExpanded ? nil : 4)
                    .onTapGesture { withAnimation { isExpanded.toggle() } }
                    .accessibilityHint(isExpanded ? "" : "Shows the whole biography.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .top])
    }
}
