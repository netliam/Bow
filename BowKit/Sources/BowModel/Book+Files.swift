import Foundation

extension BowSchemaV2.Book {
    /// The file Bow opens: the EPUB if there is one, else the PDF. Comics and other formats aren't readable yet.
    public var readableFile: BookFile? {
        files.first { $0.format == .epub } ?? files.first { $0.format == .pdf }
    }
}
