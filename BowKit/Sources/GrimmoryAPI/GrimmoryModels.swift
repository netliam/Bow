import Foundation

/// What Bow learns about a server before signing in.
public struct GrimmoryServerInfo: Sendable, Equatable {
    public var version: String?
    public var oidc: OIDCProvider?
    /// Password login is hidden when the admin forces OIDC-only sign-in.
    public var passwordLoginAllowed: Bool

    public struct OIDCProvider: Sendable, Equatable {
        public var name: String?
        public var issuer: URL
        public var clientID: String
        public var scopes: String
    }
}

public struct GrimmoryUser: Sendable, Equatable {
    public var id: Int64
    public var username: String
    public var name: String?
    public var email: String?
    public var permissions: GrimmoryPermissions
    /// The account still has the password the admin set; the web app asks the user to change it.
    public var hasDefaultPassword: Bool
}

/// The permissions Bow's UI is gated on. Grimmory has more (bulk and admin tools); add them as features need them.
public struct GrimmoryPermissions: Sendable, Equatable {
    public var isAdmin = false
    public var canDownload = false
    public var canUpload = false
    public var canEditMetadata = false
    public var canEmailBook = false
    public var canDeleteBook = false
    public var canAccessBookdrop = false
    public var canAccessUserStats = false
    public var canManageLibrary = false

    public init() {}
}

public struct GrimmoryPage<Item: Sendable>: Sendable {
    public var items: [Item]
    public var page: Int
    public var totalItems: Int
    public var hasNext: Bool
}

public struct GrimmoryBookSummary: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var title: String
    public var authors: [String]
    public var seriesName: String?
    public var seriesNumber: Double?
    public var libraryID: Int64?
    public var addedOn: Date?
    public var lastReadTime: Date?
    /// 0–100, as Grimmory reports it.
    public var readProgress: Double?
    public var readStatus: String?
    public var personalRating: Int?
    public var primaryFileID: Int64?
    /// e.g. `EPUB`, `PDF`, `CBX`, `AUDIOBOOK`.
    public var primaryFileType: String?
    /// Changes whenever the cover does, so it doubles as the cover cache key.
    public var coverUpdatedOn: Date?
}
