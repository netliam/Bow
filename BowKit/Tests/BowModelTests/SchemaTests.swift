import Foundation
import SwiftData
import Testing
@testable import BowModel

@MainActor
@Suite struct SchemaTests {
    @Test func storesABookWithItsFilesProgressAndAnnotations() throws {
        let context = ModelContext(try BowStore.makeContainer(inMemory: true))
        let account = Account(kind: .grimmory, displayName: "Home", serverURL: URL(string: "https://books.example.com"),
                              username: "alice")
        let book = Book(account: account, remoteID: 12, title: "Dune", authors: ["Frank Herbert"])
        let file = BookFile(book: book, format: .epub, remoteFileID: 99, fileName: "dune.epub")
        let progress = ReadingProgress(book: book, fraction: 0.42)
        progress.cfi = "epubcfi(/6/4[ch1]!/4/2/1:5)"
        let highlight = Annotation(book: book, kind: .highlight, text: "Fear is the mind-killer.")
        highlight.colorHex = "#FACC15"
        context.insert(account)
        context.insert(book)
        context.insert(file)
        context.insert(progress)
        context.insert(highlight)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.remoteID == 12 })).first)
        #expect(fetched.account?.kind == .grimmory)
        #expect(fetched.files.first?.format == .epub)
        #expect(fetched.files.first?.downloadState == .remote)
        #expect(fetched.progress?.cfi == "epubcfi(/6/4[ch1]!/4/2/1:5)")
        #expect(fetched.annotations.first?.kind == .highlight)
        #expect(fetched.annotations.first?.style == "highlight")
    }

    @Test func deletingAnAccountDeletesItsBooks() throws {
        let context = ModelContext(try BowStore.makeContainer(inMemory: true))
        let account = Account(kind: .grimmory, displayName: "Home")
        let book = Book(account: account, remoteID: 1, title: "Dune")
        context.insert(account)
        context.insert(book)
        context.insert(BookFile(book: book, format: .epub))
        context.insert(ReadingProgress(book: book))
        try context.save()

        context.delete(account)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BookFile>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ReadingProgress>()) == 0)
    }

    @Test func outboxEntriesQueueInOrder() throws {
        let context = ModelContext(try BowStore.makeContainer(inMemory: true))
        let id = UUID()
        context.insert(PendingChange(entityName: "Annotation", entityID: id, operation: .create))
        context.insert(PendingChange(entityName: "Annotation", entityID: id, operation: .update))
        try context.save()

        let queue = try context.fetch(FetchDescriptor<PendingChange>(
            predicate: #Predicate { !$0.isParked },
            sortBy: [SortDescriptor(\.createdAt)]
        ))
        #expect(queue.map(\.operation) == [.create, .update])
    }
}

@Suite struct MigrationTests {
    /// A store written by schema V1 opens with the current schema, its data intact.
    @Test func v1StoresOpenWithTheCurrentSchema() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bow-migration-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let schema = Schema(versionedSchema: BowSchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = ModelContext(container)
            let account = BowSchemaV1.Account(kind: .grimmory, displayName: "Home")
            context.insert(account)
            context.insert(BowSchemaV1.Book(account: account, remoteID: 7, title: "Dune"))
            try context.save()
        }

        let schema = Schema(versionedSchema: BowSchemaV2.self)
        let container = try ModelContainer(for: schema, migrationPlan: BowMigrationPlan.self,
                                           configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = ModelContext(container)
        let book = try #require(try context.fetch(FetchDescriptor<Book>()).first)
        #expect(book.title == "Dune")
        #expect(book.account?.displayName == "Home")
        #expect(book.shelves.isEmpty)

        let shelf = Shelf(account: book.account, remoteID: 1, kind: .regular, name: "Favorites")
        context.insert(shelf)
        shelf.books = [book]
        try context.save()
        #expect(book.shelves.map(\.name) == ["Favorites"])
    }
}
