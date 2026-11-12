import Foundation

/// A shelf the user can see: their own, or a public one. Magic shelves are saved filters; the server works out
/// their books.
public struct GrimmoryShelf: Sendable, Equatable {
    public var id: Int64
    public var name: String
    /// A Lucide icon name (`heart`, `book-open`), as the web app shows it.
    public var icon: String?
    public var isPublic: Bool
    public var isMagic: Bool

    public init(id: Int64, name: String, icon: String? = nil, isPublic: Bool = false, isMagic: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isPublic = isPublic
        self.isMagic = isMagic
    }
}

extension GrimmoryClient {
    // MARK: Shelves

    /// Regular shelves, then magic shelves.
    public func shelves() async throws -> [GrimmoryShelf] {
        let regular = try await unwrapped { try await client.appGetShelves() }
        guard case .ok(let regularOK) = regular else { throw GrimmoryError(status: statusCode(of: regular)) }
        let magic = try await unwrapped { try await client.appGetMagicShelves() }
        guard case .ok(let magicOK) = magic else { throw GrimmoryError(status: statusCode(of: magic)) }

        let shelves = try regularOK.body.json.compactMap { dto in
            dto.id.map { GrimmoryShelf(id: $0, name: dto.name ?? "Shelf", icon: dto.icon, isPublic: dto.publicShelf ?? false) }
        }
        let magicShelves = try magicOK.body.json.compactMap { dto in
            dto.id.map {
                GrimmoryShelf(id: $0, name: dto.name ?? "Magic Shelf", icon: dto.icon, isPublic: dto.publicShelf ?? false,
                              isMagic: true)
            }
        }
        return shelves + magicShelves
    }

    /// The IDs of every book on a shelf, or matching a magic shelf.
    public func bookIDs(onShelf shelf: GrimmoryShelf) async throws -> [Int64] {
        let query: Operations.AppGetAllBookIds.Input.Query = shelf.isMagic
            ? .init(magicShelfId: shelf.id) : .init(shelfId: shelf.id)
        let output = try await unwrapped { try await client.appGetAllBookIds(query: query) }
        guard case .ok(let ok) = output else { throw GrimmoryError(status: statusCode(of: output)) }
        return try ok.body.json
    }

    /// Puts books on shelves and takes them off, in one call. Only regular shelves: magic ones are filters.
    public func assignShelves(bookIDs: [Int64], add: [Int64], remove: [Int64]) async throws {
        let body = Components.Schemas.ShelvesAssignmentRequest(bookIds: bookIDs, shelvesToAssign: add, shelvesToUnassign: remove)
        let output = try await unwrapped { try await client.addBookToShelf(body: .json(body)) }
        guard case .ok = output else { throw GrimmoryError(status: statusCode(of: output)) }
    }
}
