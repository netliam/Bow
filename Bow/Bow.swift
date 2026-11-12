import BackgroundTasks
import BowLibrary
import BowModel
import BowSync
import SwiftData
import SwiftUI

@main struct Bow: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    @State private var librarySync = LibrarySync()
    @State private var authors = AuthorDirectory()
    @State private var downloads: DownloadCenter
    @State private var importer: LocalImporter
    @State private var intake: BookIntake

    nonisolated static let refreshTaskID = "app.bow.refresh"

    init() {
        Self.useSerifLargeTitles()
        do {
            let container = try BowStore.makeContainer()
            self.container = container
            _downloads = State(initialValue: DownloadCenter(context: container.mainContext,
                                                            transfer: AppDelegate.transfer) { account in
                GrimmoryAccounts.client(for: account)
            })
            let importer = LocalImporter(context: container.mainContext)
            _importer = State(initialValue: importer)
            _intake = State(initialValue: BookIntake(context: container.mainContext, importer: importer))
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
                .environment(importer)
                .environment(authors)
                .environment(intake)
                .onOpenURL { url in intake.receive([url]) }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await Self.scheduleRefresh() } }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) { [container, librarySync] in
            await Self.scheduleRefresh()
            await librarySync.syncAll(container)
        }

        // On Mac, each book opens in a window of its own.
        WindowGroup("Reader", id: ReaderWindow.id, for: UUID.self) { $bookID in
            ReaderWindow(bookID: bookID)
                .environment(librarySync)
                .environment(downloads)
                .environment(authors)
        }
        .modelContainer(container)
    }

    /// Asks for a background refresh in about an hour: push this device's changes, then refresh the catalog.
    nonisolated static func scheduleRefresh() async {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? await BGTaskScheduler.shared.submitTaskRequest(request)
    }
}

extension Bow {
    /// Large navigation titles in the serif face the section headers use, for a bookish feel.
    static func useSerifLargeTitles() {
        let base = UIFont.preferredFont(forTextStyle: .largeTitle)
        guard let descriptor = base.fontDescriptor.withDesign(.serif)?.withSymbolicTraits(.traitBold) else { return }
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: UIFont(descriptor: descriptor, size: 0)]
    }
}
