import BowLibrary
import BowModel
import BowSync
import GrimmoryAPI
import SwiftUI
import CoreImage
import UIKit

/// A book cover, loaded from the server once and kept on disk. Falls back to a title card.
struct CoverView: View {
    let book: Book
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 4))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
        .task(id: CoverRequest(book)) {
            image = await Self.image(for: book)
        }
    }

    /// The book's cover: from the server (cached), or for imported books, the copy kept next to the file.
    static func image(for book: Book) async -> UIImage? {
        if let request = CoverRequest(book) {
            return await CoverCache.shared.image(for: request)
        }
        let cover = BookStorage.standard.directory(for: book.id).appending(path: "cover")
        return UIImage(contentsOfFile: cover.path(percentEncoded: false))
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Text(book.title)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }
}

/// What the cover cache needs from a `Book`, copied out on the main actor so the SwiftData object never leaves it.
struct CoverRequest: Hashable, Sendable {
    let key: String
    let remoteID: Int64
    let accountID: UUID
    let serverURL: URL

    init?(_ book: Book) {
        guard let remoteID = book.remoteID, let account = book.account, let serverURL = account.serverURL else {
            return nil
        }
        self.key = "\(book.id.uuidString)-\(Int(book.coverUpdatedOn?.timeIntervalSince1970 ?? 0))"
        self.remoteID = remoteID
        self.accountID = account.id
        self.serverURL = serverURL
    }
}

/// Disk cache for cover thumbnails, keyed by book and `coverUpdatedOn` so a changed cover is fetched again.
actor CoverCache {
    static let shared = CoverCache()

    private let directory: URL = {
        let url = URL.cachesDirectory.appending(path: "Covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    /// Evicted by the system under memory pressure; covers are on disk too.
    private let memory = NSCache<NSString, UIImage>()
    /// Downloads in progress, so two views showing the same cover share one request.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(for request: CoverRequest) async -> UIImage? {
        if let image = memory.object(forKey: request.key as NSString) { return image }

        let file = directory.appending(path: request.key + ".jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: request.key as NSString)
            return image
        }

        if let task = inFlight[request.key] { return await task.value }
        let task = Task<UIImage?, Never> {
            let client = GrimmoryAccounts.client(serverURL: request.serverURL, accountID: request.accountID)
            guard let data = try? await client.thumbnail(bookID: request.remoteID), let image = UIImage(data: data)
            else { return nil }
            try? data.write(to: file, options: .atomic)
            return image
        }
        inFlight[request.key] = task
        let image = await task.value
        inFlight[request.key] = nil
        if let image { memory.setObject(image, forKey: request.key as NSString) }
        return image
    }
}

extension UIImage {
    /// The image's average colour, darkened enough for white text on top. Used to tint cards to match a cover.
    func readableTint() -> UIColor? {
        guard let input = CIImage(image: self) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent),
        ])
        guard let output = filter?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )
        let average = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                              blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return UIColor(hue: hue, saturation: min(saturation * 1.2, 0.8), brightness: min(brightness, 0.42), alpha: 1)
    }
}
