import BowModel
import CryptoKit
import Foundation
import GrimmoryAPI
import SwiftData

/// What catalog sync needs from a server. `GrimmoryClient` is the real one; tests use a fake.
public protocol CatalogSource: Sendable {
    func books(page: Int, pageSize: Int) async throws -> GrimmoryPage<GrimmoryBookSummary>
    func allBookIDs() async throws -> [Int64]
}

extension GrimmoryClient: CatalogSource {}

public struct CatalogSyncResult: Sendable, Equatable {
    public var inserted = 0
    public var updated = 0
    public var unchanged = 0
    public var removed = 0
}

/// Mirrors an account's Grimmory catalog into SwiftData.
///
/// Grimmory has no "changed since" query, so this pages through everything (50 per page) and skips books whose
/// summary hash hasn't changed. Books the server no longer lists are marked `isRemovedOnServer`, not deleted, so a
/// downloaded copy survives until the user removes it.
@ModelActor
public actor CatalogSyncer {
    public func sync(accountID: UUID, from source: any CatalogSource) async throws -> CatalogSyncResult {
        guard let account = try modelContext.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.id == accountID })).first
        else { return CatalogSyncResult() }

        var existing: [Int64: Book] = [:]
        for book in account.books {
            if let remoteID = book.remoteID { existing[remoteID] = book }
        }

        var result = CatalogSyncResult()
        var page = 0
        while true {
            let batch = try await source.books(page: page, pageSize: 50)
            for summary in batch.items {
                let hash = Self.hash(summary)
                if let book = existing[summary.id] {
                    book.isRemovedOnServer = false
                    if book.summaryHash == hash {
                        result.unchanged += 1
                        continue
                    }
                    apply(summary, hash: hash, to: book)
                    result.updated += 1
                } else {
                    let book = Book(account: account, remoteID: summary.id, title: summary.title)
                    modelContext.insert(book)
                    apply(summary, hash: hash, to: book)
                    existing[summary.id] = book
                    result.inserted += 1
                }
            }
            try modelContext.save()
            guard batch.hasNext, !batch.items.isEmpty else { break }
            page += 1
        }

        let onServer = Set(try await source.allBookIDs())
        for (remoteID, book) in existing where !onServer.contains(remoteID) && !book.isRemovedOnServer {
            book.isRemovedOnServer = true
            result.removed += 1
        }
        try modelContext.save()
        return result
    }

    private func apply(_ summary: GrimmoryBookSummary, hash: String, to book: Book) {
        book.title = summary.title
        book.authors = summary.authors
        book.seriesName = summary.seriesName
        book.seriesNumber = summary.seriesNumber
        book.addedOn = summary.addedOn
        book.readStatus = summary.readStatus
        book.rating = summary.personalRating
        book.coverUpdatedOn = summary.coverUpdatedOn
        book.summaryHash = hash

        if let fileID = summary.primaryFileID {
            if let file = book.files.first(where: { $0.remoteFileID == fileID }) {
                file.formatRaw = Self.format(summary.primaryFileType).rawValue
            } else {
                modelContext.insert(BookFile(book: book, format: Self.format(summary.primaryFileType), remoteFileID: fileID))
            }
        }

        // Server progress only fills in books this device hasn't read; once Bow has its own position (a CFI),
        // progress sync decides which side wins.
        if let percent = summary.readProgress {
            if let progress = book.progress {
                if progress.cfi == nil { progress.fraction = percent / 100 }
            } else {
                modelContext.insert(ReadingProgress(book: book, fraction: percent / 100, updatedAt: .distantPast))
            }
        }
    }

    static func format(_ type: String?) -> BookFile.Format {
        switch type?.uppercased() {
        case "EPUB": .epub
        case "PDF": .pdf
        case "CBX", "CBZ", "CBR", "CB7": .cbx
        default: .other
        }
    }

    static func hash(_ s: GrimmoryBookSummary) -> String {
        let fields: [String?] = [
            s.title, s.authors.joined(separator: "\u{1F}"), s.seriesName, s.seriesNumber.map { "\($0)" },
            s.addedOn.map { "\($0.timeIntervalSince1970)" }, s.readStatus, s.personalRating.map(String.init),
            s.readProgress.map { "\($0)" }, s.primaryFileID.map(String.init), s.primaryFileType,
            s.coverUpdatedOn.map { "\($0.timeIntervalSince1970)" },
        ]
        let joined = fields.map { $0 ?? "\u{0}" }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
