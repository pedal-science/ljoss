import SwiftUI

#if os(macOS)
/// The one thing SwiftUI has no hook for.
///
/// `scenePhase` reaches `.background` when the app is hidden, which is not the same moment as
/// quitting, and it never reaches a "terminated" state at all — so without this the daemon this app
/// started would outlive it and hold the audio device until something killed it. `willTerminate` is
/// the documented last word before the process goes away, and it is what makes "the app owns the
/// daemon" true rather than aspirational.
///
/// It is deliberately the *only* thing this delegate does: everything else about the local engine
/// lives in `LocalEngine`, where it can be tested.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        LocalEngine.shared.stop()
    }
}
#endif
