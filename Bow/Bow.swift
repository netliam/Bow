import BowModel
import SwiftData
import SwiftUI

@main struct Bow: App {
    private let container: ModelContainer

    init() {
        do {
            container = try BowStore.makeContainer()
        } catch {
            // A store that can't open (e.g. a failed migration) leaves the app with nothing to show.
            fatalError("Couldn't open Bow's library store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
