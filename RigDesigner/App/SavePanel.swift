import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Where the user wants the zip.
//
// A save *panel* rather than SwiftUI's `.fileExporter`, because the menu item is the whole
// feature here: a `File > Export current rig …` that then opened an exporter *sheet* would
// ask the same question twice, and the panel is where a Mac user's filename, folder and
// "replace this one?" habits already live. `.fileExporter` does exist for both platforms
// and would have been less code; it is not what a File-menu item is expected to do.
//
// No SwiftUI here: this file is in the source list of `Tests/run-model-tests.sh` on
// macOS, where AppKit is present.

enum SavePanel {

    /// Ask for a place to write `name`.zip and hand back the chosen URL, or nil when the
    /// user cancelled.
    ///
    /// Main-actor isolated, because a panel is a view: both implementations must be
    /// presented from the main thread, and marking it so is what lets the live one touch
    /// `NSApp` at all under the build's complete concurrency checking.
    @MainActor
    static func zipDestination(suggestedName: String) async -> URL? {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export Rig"
        panel.message = "The rig and its namchain document are saved together in one zip file."
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(suggestedName).zip"
        // A save panel cannot be given a UTI for zip without an extension fight, and `.zip`
        // is understood by the system: it will offer to hide it, and will not double it.
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true

        // Sheet-modal when there is a window to hang it on, because a free-floating panel
        // can end up behind the app that opened it; the windowless call is for a scene
        // whose window has not been made yet (launch, or a restored state).
        let response = if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            await panel.beginSheetModal(for: window)
        } else {
            await panel.begin()
        }
        // `.OK` and `.continue` both mean "chose a place": a panel with no accessory view
        // never returns `.continue`, and treating it as a cancel would silently do nothing.
        guard response == .OK || response == .continue else { return nil }
        return panel.url
        #else
        // Unreachable on iOS: that half of the feature is a menu item, and `Commands` is
        // macOS's menu bar. A placeholder rather than a `UIDocumentPickerViewController`
        // for a file that does not exist yet — a picker built for exporting nothing is a
        // bug waiting for whoever wires up the iOS trigger. Cancelled is the honest answer
        // until there is one.
        nil
        #endif
    }
}
