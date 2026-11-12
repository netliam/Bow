import BowModel
import Foundation
import ZIPFoundation

/// Where book files live on disk: `<root>/<book id>/book.<ext>`, with EPUBs unzipped next to it in `epub/` for
/// the reader. Paths stored in SwiftData are relative to `root`, so the app container can move between installs.
///
/// The root is excluded from iCloud backup: downloaded books can always be fetched from the server again.
public struct BookStorage: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `Application Support/Books`.
    public static let standard = BookStorage(root: .applicationSupportDirectory.appending(path: "Books", directoryHint: .isDirectory))

    public func directory(for bookID: UUID) -> URL {
        root.appending(path: bookID.uuidString, directoryHint: .isDirectory)
    }

    public func url(forRelativePath path: String) -> URL {
        root.appending(path: path)
    }

    /// Moves a finished download into place, replacing any older copy. Returns the relative path to store.
    public func store(downloaded file: URL, bookID: UUID, format: BookFile.Format) throws -> String {
        try prepareRoot()
        let directory = directory(for: bookID)
        try? FileManager.default.removeItem(at: directory)  // An older copy and its unzipped pages.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "book.\(Self.fileExtension(for: format))"
        try FileManager.default.moveItem(at: file, to: directory.appending(path: name))
        return "\(bookID.uuidString)/\(name)"
    }

    /// The unzipped EPUB folder the reader opens, unzipping on first use.
    public func unzippedEPUB(relativePath: String) throws -> URL {
        let file = url(forRelativePath: relativePath)
        let folder = file.deletingLastPathComponent().appending(path: "epub", directoryHint: .isDirectory)
        let marker = folder.appending(path: ".complete")
        if FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) { return folder }

        // Unzip into a scratch folder and rename, so an interrupted unzip never looks finished.
        let scratch = file.deletingLastPathComponent().appending(path: "epub-unzipping", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: file, to: scratch)
        try Data().write(to: scratch.appending(path: ".complete"))
        try FileManager.default.moveItem(at: scratch, to: folder)
        return folder
    }

    public func removeFiles(for bookID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: bookID))
    }

    private func prepareRoot() throws {
        guard !FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var root = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    static func fileExtension(for format: BookFile.Format) -> String {
        switch format {
        case .epub: "epub"
        case .pdf: "pdf"
        case .cbx: "cbz"
        case .other: "bin"
        }
    }
}

/// How far through a book a reader is, estimated like Grimmory's web reader (foliate-js) does: each spine item
/// counts in proportion to its size. Positions inside a chapter count from the chapter's start until the reader
/// can report a finer position.
public enum ReadingFraction {
    public static func estimate(chapterSizes: [Int], spineIndex: Int) -> Double {
        let total = chapterSizes.reduce(0, +)
        guard total > 0, spineIndex > 0 else { return 0 }
        let before = chapterSizes.prefix(min(spineIndex, chapterSizes.count)).reduce(0, +)
        return min(Double(before) / Double(total), 1)
    }
}
