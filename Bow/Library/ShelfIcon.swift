import BowModel

/// SF Symbols for the Lucide icons Grimmory's web app gives shelves. Unknown icons get a generic one.
enum ShelfIcon {
    static func symbol(for shelf: Shelf) -> String {
        if let icon = shelf.icon, let symbol = symbols[icon] { return symbol }
        return shelf.kind == .magic ? "sparkles" : "books.vertical"
    }

    private static let symbols: [String: String] = [
        "heart": "heart",
        "star": "star",
        "bookmark": "bookmark",
        "book": "book.closed",
        "book-open": "book",
        "book-marked": "book.closed",
        "books": "books.vertical",
        "library": "books.vertical",
        "clock": "clock",
        "flame": "flame",
        "sparkles": "sparkles",
        "trophy": "trophy",
        "flag": "flag",
        "tag": "tag",
        "folder": "folder",
        "archive": "archivebox",
        "check": "checkmark",
        "circle-check": "checkmark.circle",
        "eye": "eye",
        "ghost": "theatermasks",
        "rocket": "airplane",
        "sword": "shield",
        "sun": "sun.max",
        "moon": "moon",
        "music": "music.note",
        "graduation-cap": "graduationcap",
        "brain": "brain",
        "globe": "globe",
        "user": "person",
        "users": "person.2",
        "gift": "gift",
        "coffee": "cup.and.saucer",
    ]
}
