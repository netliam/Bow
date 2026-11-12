import BowLibrary
import DCEpubReaderKit
import UIKit

/// The few things SwiftUI still routes through an app delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// One background session per process, shared by the download center.
    static let transfer = BackgroundURLSessionTransfer()

    /// The system relaunched Bow to deliver finished background downloads.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundURLSessionTransfer.identifier else {
            completionHandler()
            return
        }
        nonisolated(unsafe) let completion = completionHandler
        Self.transfer.setBackgroundEventsCompletion { completion() }
    }

    /// The reader's rotation lock, per window (DCEpubReaderKit 0.1.0).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        DCReaderOrientationLock.supportedOrientations(for: window)
    }
}
