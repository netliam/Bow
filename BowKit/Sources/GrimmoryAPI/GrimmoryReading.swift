import Foundation

/// Where a reader is in an EPUB, as Grimmory stores it.
public struct GrimmoryEpubProgress: Sendable, Equatable {
    public var cfi: String?
    public var href: String?
    /// 0–100.
    public var percentage: Double
    /// When the server last recorded reading. Grimmory's spec merges two `EpubProgress` classes and drops their
    /// `updatedAt`, so this is the book's `lastReadTime`.
    public var lastReadTime: Date?
}

/// Where a reader is in a PDF, as Grimmory stores it.
public struct GrimmoryPDFProgress: Sendable, Equatable {
    /// From 1, as Grimmory's web viewer counts.
    public var page: Int
    /// 0–100.
    public var percentage: Double
    /// When the server last recorded reading (the book's `lastReadTime`).
    public var lastReadTime: Date?
}

extension GrimmoryClient {
    // MARK: Reading progress

    public func epubProgress(bookID: Int64) async throws -> GrimmoryEpubProgress? {
        let output = try await unwrapped { try await client.getBookProgress(path: .init(bookId: bookID)) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        let dto = try ok.body.json
        guard let epub = dto.epubProgress else { return nil }
        return GrimmoryEpubProgress(cfi: epub.cfi, href: epub.href, percentage: Double(epub.percentage),
                                    lastReadTime: dto.lastReadTime)
    }

    public func pdfProgress(bookID: Int64) async throws -> GrimmoryPDFProgress? {
        let output = try await unwrapped { try await client.getBookProgress(path: .init(bookId: bookID)) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        let dto = try ok.body.json
        guard let pdf = dto.pdfProgress else { return nil }
        return GrimmoryPDFProgress(page: Int(pdf.page), percentage: Double(pdf.percentage), lastReadTime: dto.lastReadTime)
    }

    /// Records the page a reader is on in a PDF. Grimmory reads `positionData` as the page number, from 1.
    public func updatePDFProgress(bookID: Int64, fileID: Int64, page: Int, percentage: Double) async throws {
        try await updateEpubProgress(bookID: bookID, fileID: fileID, cfi: String(page), href: nil, percentage: percentage)
    }

    /// Records where the reader is in one file of a book. `cfi` is what Grimmory's web reader resumes from.
    public func updateEpubProgress(bookID: Int64, fileID: Int64, cfi: String?, href: String?,
                                   percentage: Double) async throws {
        let progress = Components.Schemas.BookFileProgress(
            bookFileId: fileID, positionData: cfi, positionHref: href,
            progressPercent: Float(min(max(percentage, 0), 100))
        )
        let output = try await unwrapped {
            try await client.updateBookProgress(path: .init(bookId: bookID), body: .json(.init(fileProgress: progress)))
        }
        guard case .ok = output else { throw GrimmoryError(status: statusCode(of: output)) }
    }
}
