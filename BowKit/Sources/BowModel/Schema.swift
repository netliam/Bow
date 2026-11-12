import Foundation
import SwiftData

// Bow's on-device store (ADR-0002). The UI reads only from here; the network only feeds it.
//
// Models live inside a `VersionedSchema` from day one so later changes are explicit migrations. Enums are stored
// as raw strings (SwiftData predicates on enum attributes are unreliable) with typed accessors.

public typealias Account = BowSchemaV2.Account
public typealias Book = BowSchemaV2.Book
public typealias BookFile = BowSchemaV2.BookFile
public typealias ReadingProgress = BowSchemaV2.ReadingProgress
public typealias Annotation = BowSchemaV2.Annotation
public typealias PendingChange = BowSchemaV2.PendingChange
public typealias Shelf = BowSchemaV2.Shelf

public enum BowSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [Account.self, Book.self, BookFile.self, ReadingProgress.self, Annotation.self, PendingChange.self, Shelf.self]
    }

    /// Where books come from. A `.local` account always exists for imported files. Tokens are never stored here;
    /// they live in the Keychain.
    @Model
    public final class Account {
        public enum Kind: String, Codable, Sendable { case local, grimmory }

        @Attribute(.unique) public var id: UUID
        public var kindRaw: String
        public var serverURL: URL?
        public var username: String?
        public var displayName: String
        public var createdAt: Date
        @Relationship(deleteRule: .cascade, inverse: \Book.account) public var books: [Book] = []
        @Relationship(deleteRule: .cascade, inverse: \Shelf.account) public var shelves: [Shelf] = []

        public var kind: Kind { Kind(rawValue: kindRaw) ?? .local }

        public init(id: UUID = UUID(), kind: Kind, displayName: String, serverURL: URL? = nil, username: String? = nil) {
            self.id = id
            self.kindRaw = kind.rawValue
            self.displayName = displayName
            self.serverURL = serverURL
            self.username = username
            self.createdAt = Date()
        }
    }

    @Model
    public final class Book {
        #Index<Book>([\.remoteID], [\.title])

        @Attribute(.unique) public var id: UUID
        public var account: Account?
        /// Grimmory's book id; `nil` for local imports.
        public var remoteID: Int64?
        public var title: String
        public var authors: [String]
        public var seriesName: String?
        public var seriesNumber: Double?
        public var addedOn: Date?
        public var readStatus: String?
        public var rating: Int?
        /// Cover cache key. Grimmory bumps `coverUpdatedOn` whenever the cover changes.
        public var coverUpdatedOn: Date?
        /// Hash of the last server summary applied, so a full sync can skip unchanged books (Grimmory has no
        /// "changed since" query).
        public var summaryHash: String?
        /// The server no longer lists this book. Its downloaded file stays until the user deletes it.
        public var isRemovedOnServer: Bool
        @Relationship(deleteRule: .cascade, inverse: \BookFile.book) public var files: [BookFile] = []
        @Relationship(deleteRule: .cascade, inverse: \ReadingProgress.book) public var progress: ReadingProgress?
        @Relationship(deleteRule: .cascade, inverse: \Annotation.book) public var annotations: [Annotation] = []
        /// Regular and magic shelves this book is on. Magic shelf membership is the server's answer as of the last sync.
        public var shelves: [Shelf] = []

        public init(id: UUID = UUID(), account: Account?, remoteID: Int64? = nil, title: String, authors: [String] = []) {
            self.id = id
            self.account = account
            self.remoteID = remoteID
            self.title = title
            self.authors = authors
            self.isRemovedOnServer = false
        }
    }

    @Model
    public final class BookFile {
        public enum Format: String, Codable, Sendable { case epub, pdf, cbx, other }
        public enum DownloadState: String, Codable, Sendable { case remote, downloading, downloaded, failed }

        @Attribute(.unique) public var id: UUID
        public var book: Book?
        public var formatRaw: String
        /// Grimmory's file id (`primaryFileId` / additional file id).
        public var remoteFileID: Int64?
        public var fileName: String?
        public var sizeBytes: Int64?
        /// Relative to the app's books directory, so the container can move between installs.
        public var localRelativePath: String?
        public var downloadStateRaw: String

        public var format: Format { Format(rawValue: formatRaw) ?? .other }
        public var downloadState: DownloadState {
            get { DownloadState(rawValue: downloadStateRaw) ?? .remote }
            set { downloadStateRaw = newValue.rawValue }
        }

        public init(id: UUID = UUID(), book: Book?, format: Format, remoteFileID: Int64? = nil, fileName: String? = nil) {
            self.id = id
            self.book = book
            self.formatRaw = format.rawValue
            self.remoteFileID = remoteFileID
            self.fileName = fileName
            self.downloadStateRaw = DownloadState.remote.rawValue
        }
    }

    /// Where the reader is in a book (ADR-0003). The CFI is canonical for sync; `kitCoords` and `spineIndex` are
    /// DCEpubReaderKit's own position, cached for an exact reopen on this device.
    @Model
    public final class ReadingProgress {
        public var book: Book?
        public var cfi: String?
        public var href: String?
        public var kitCoords: String?
        /// EPUB: the chapter's spine index. PDF: the page index, from 0.
        public var spineIndex: Int?
        /// 0–1.
        public var fraction: Double
        /// When this device last moved the position.
        public var updatedAt: Date
        /// The server's `updatedAt` for the progress Bow last pulled, compared only with other server timestamps.
        public var serverUpdatedAt: Date?

        public init(book: Book?, fraction: Double = 0, updatedAt: Date = Date()) {
            self.book = book
            self.fraction = fraction
            self.updatedAt = updatedAt
        }
    }

    /// A highlight, note or bookmark. Grimmory keeps highlights/notes and bookmarks as separate resources with
    /// `Int64` ids, so `remoteID` is set once the first push returns. Deletes are tombstones so they can sync.
    @Model
    public final class Annotation {
        public enum Kind: String, Codable, Sendable { case highlight, note, bookmark }

        @Attribute(.unique) public var id: UUID
        public var book: Book?
        public var remoteID: Int64?
        public var kindRaw: String
        public var cfi: String?
        public var kitCoords: String?
        public var spineIndex: Int?
        public var text: String
        public var note: String?
        /// `#RRGGBB`, matching Grimmory's palette.
        public var colorHex: String?
        /// Grimmory's style: `highlight`, `underline`, `strikethrough`, `squiggly`. Kept even when the kit can't draw it.
        public var style: String
        public var chapterTitle: String?
        public var createdAt: Date
        public var updatedAt: Date
        public var deletedAt: Date?

        public var kind: Kind { Kind(rawValue: kindRaw) ?? .highlight }

        public init(id: UUID = UUID(), book: Book?, kind: Kind, text: String, style: String = "highlight") {
            self.id = id
            self.book = book
            self.kindRaw = kind.rawValue
            self.text = text
            self.style = style
            self.createdAt = Date()
            self.updatedAt = Date()
        }
    }

    /// The outbox (ADR-0002): written in the same save as the change it describes, drained by the sync engine.
    @Model
    public final class PendingChange {
        public enum Operation: String, Codable, Sendable { case create, update, delete }

        @Attribute(.unique) public var id: UUID
        public var createdAt: Date
        /// The model type, e.g. `"Annotation"`, `"ReadingProgress"`, `"Book.readStatus"`. Not named `entity`,
        /// which Core Data (under SwiftData) reserves.
        public var entityName: String
        public var entityID: UUID
        public var operationRaw: String
        public var payload: Data?
        public var attempts: Int
        public var lastError: String?
        public var nextAttemptAt: Date?
        /// A 4xx the server will keep refusing; shown under "Sync issues" instead of being retried.
        public var isParked: Bool

        public var operation: Operation { Operation(rawValue: operationRaw) ?? .update }

        public init(entityName: String, entityID: UUID, operation: Operation, payload: Data? = nil) {
            self.id = UUID()
            self.createdAt = Date()
            self.entityName = entityName
            self.entityID = entityID
            self.operationRaw = operation.rawValue
            self.payload = payload
            self.attempts = 0
            self.isParked = false
        }
    }

    /// A Grimmory shelf: one the user fills by hand, or a magic shelf (a saved filter the server evaluates).
    @Model
    public final class Shelf {
        public enum Kind: String, Codable, Sendable { case regular, magic }

        @Attribute(.unique) public var id: UUID
        public var account: Account?
        /// Grimmory's id. Regular and magic shelves are numbered separately, so it's unique only with `kind`.
        public var remoteID: Int64
        public var kindRaw: String
        public var name: String
        /// A Lucide icon name from the web app (`heart`, `book-open`).
        public var icon: String?
        public var isPublic: Bool
        @Relationship(inverse: \Book.shelves) public var books: [Book] = []

        public var kind: Kind { Kind(rawValue: kindRaw) ?? .regular }

        public init(id: UUID = UUID(), account: Account?, remoteID: Int64, kind: Kind, name: String) {
            self.id = id
            self.account = account
            self.remoteID = remoteID
            self.kindRaw = kind.rawValue
            self.name = name
            self.isPublic = false
        }
    }
}

public enum BowMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [BowSchemaV1.self, BowSchemaV2.self] }
    /// V2 adds `Shelf` and the book–shelf relationship: nothing to convert.
    public static var stages: [MigrationStage] { [.lightweight(fromVersion: BowSchemaV1.self, toVersion: BowSchemaV2.self)] }
}

public enum BowStore {
    /// The app's model container. `inMemory` is for tests and previews.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: BowSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, migrationPlan: BowMigrationPlan.self, configurations: [configuration])
    }
}
