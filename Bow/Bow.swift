import BowLibrary
import BowModel
import BowSync
import SwiftData
import SwiftUI

@main struct Bow: App {
    private let container: ModelContainer
    @State private var librarySync = LibrarySync()
    @State private var downloads: DownloadCenter

    init() {
        do {
            let container = try BowStore.makeContainer()
            self.container = container
            _downloads = State(initialValue: DownloadCenter(context: container.mainContext) { account in
                GrimmoryAccounts.client(for: account)
            })
        } catch {
            // A store that can't open (e.g. a failed migration) leaves the app with nothing to show.
            fatalError("Couldn't open Bow's library store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(librarySync)
                .environment(downloads)
        }
        .modelContainer(container)
    }
}
