import CoreGraphics
import Foundation

extension GrimmoryClient {
    // MARK: PDF annotations

    /// The book's PDF annotations as Grimmory's web viewer stored them: one JSON document for the whole book (see
    /// `PDFAnnotationDocument`), or `nil` when there are none.
    public func pdfAnnotationData(bookID: Int64) async throws -> String? {
        let output = try await unwrapped { try await client.getAnnotations(path: .init(bookId: bookID)) }
        switch output {
        case .ok(let ok): return try ok.body.json.additionalProperties["data"]
        case .noContent: return nil
        default: throw GrimmoryError(status: statusCode(of: output))
        }
    }

    /// Replaces the book's PDF annotations.
    public func savePDFAnnotationData(bookID: Int64, data: String) async throws {
        let output = try await unwrapped {
            try await client.saveAnnotations(path: .init(bookId: bookID),
                                             body: .json(.init(additionalProperties: ["data": data])))
        }
        switch output {
        case .noContent: return
        default:
            let status = statusCode(of: output)
            if (200..<300).contains(status) { return }
            throw GrimmoryError(status: status)
        }
    }
}

/// Grimmory's PDF annotation document. The web viewer (EmbedPDF) writes `{format: "embedpdf", version: 1,
/// annotations: [{annotation: {…}, ctx?: {…}}]}`, whole, for each book.
///
/// Bow reads and writes only highlights (`type` 9) and keeps every other item — ink, notes, stamps — exactly as it
/// found it, so saving from Bow never loses what the web viewer drew.
///
/// Coordinates are EmbedPDF's: points from the page's top-left corner (its crop box), y growing downwards.
public struct PDFAnnotationDocument: @unchecked Sendable {
    public struct Highlight: Sendable, Equatable {
        public var id: String
        /// From 0.
        public var pageIndex: Int
        /// One rectangle per line, top-left origin, in points.
        public var rects: [CGRect]
        /// `#RRGGBB`.
        public var color: String
        public var opacity: Double
        /// The highlight's note.
        public var contents: String?

        public init(id: String, pageIndex: Int, rects: [CGRect], color: String, opacity: Double = 0.4,
                    contents: String? = nil) {
            self.id = id
            self.pageIndex = pageIndex
            self.rects = rects
            self.color = color
            self.opacity = opacity
            self.contents = contents
        }
    }

    /// The document is in pdf.js's old format, which only the web viewer converts. Bow doesn't write over it.
    public private(set) var isLegacy = false
    private var items: [[String: Any]] = []

    static let highlightType = 9

    public init() {}

    public init(data: String?) {
        guard let data, let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) else { return }
        if let envelope = json as? [String: Any], envelope["format"] as? String == "embedpdf",
           let items = envelope["annotations"] as? [[String: Any]] {
            self.items = items
        } else if let legacy = json as? [Any], !legacy.isEmpty {
            isLegacy = true
        }
    }

    public var highlights: [Highlight] {
        items.compactMap { item in
            guard let annotation = item["annotation"] as? [String: Any],
                  annotation["type"] as? Int == Self.highlightType,
                  let id = annotation["id"] as? String,
                  let page = annotation["pageIndex"] as? Int
            else { return nil }
            let rects = (annotation["segmentRects"] as? [[String: Any]])?.compactMap(Self.rect)
                ?? (annotation["rect"] as? [String: Any]).flatMap(Self.rect).map { [$0] } ?? []
            let color = (annotation["strokeColor"] as? String) ?? (annotation["color"] as? String) ?? "#FFFF00"
            let contents = (annotation["contents"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Highlight(id: id, pageIndex: page, rects: rects, color: color.uppercased(),
                             opacity: annotation["opacity"] as? Double ?? 0.4, contents: contents)
        }
    }

    /// Adds or updates highlights, keeping anything else an existing item carries.
    public mutating func upsert(_ highlights: [Highlight]) {
        for highlight in highlights {
            let index = items.firstIndex { ($0["annotation"] as? [String: Any])?["id"] as? String == highlight.id }
            var item = index.map { items[$0] } ?? [:]
            var annotation = item["annotation"] as? [String: Any] ?? [:]
            annotation["type"] = Self.highlightType
            annotation["id"] = highlight.id
            annotation["pageIndex"] = highlight.pageIndex
            annotation["segmentRects"] = highlight.rects.map(Self.json)
            // The bounding box. A highlight with no rectangles gets a zero one: `CGRect.null` is infinite, which
            // JSON can't hold.
            let bounds = highlight.rects.isEmpty ? .zero : highlight.rects.reduce(CGRect.null) { $0.union($1) }
            annotation["rect"] = Self.json(bounds)
            annotation["strokeColor"] = highlight.color
            annotation["color"] = highlight.color
            annotation["opacity"] = highlight.opacity
            annotation["contents"] = highlight.contents ?? ""
            item["annotation"] = annotation
            if let index { items[index] = item } else { items.append(item) }
        }
    }

    public mutating func remove(ids: Set<String>) {
        items.removeAll { ids.contains(($0["annotation"] as? [String: Any])?["id"] as? String ?? "") }
    }

    public func encoded() throws -> String {
        let envelope: [String: Any] = ["format": "embedpdf", "version": 1, "annotations": items]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func rect(_ json: [String: Any]) -> CGRect? {
        guard let origin = json["origin"] as? [String: Any], let size = json["size"] as? [String: Any],
              let x = (origin["x"] as? NSNumber)?.doubleValue, let y = (origin["y"] as? NSNumber)?.doubleValue,
              let width = (size["width"] as? NSNumber)?.doubleValue, let height = (size["height"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func json(_ rect: CGRect) -> [String: Any] {
        ["origin": ["x": Double(rect.minX), "y": Double(rect.minY)],
         "size": ["width": Double(rect.width), "height": Double(rect.height)]]
    }
}
