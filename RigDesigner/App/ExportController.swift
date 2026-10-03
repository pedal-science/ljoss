import Foundation

// The export itself, and the only thing it needs from the window.
//
// Three pieces, in the order they are asked for: the *current* rig (`RigSelection`, which
// the sidebar sets), a *place* to put the zip (`SavePanel`), and the archive itself
// (`RigExport`). What is left here is the "and then" — and where the failure goes when it
// does not work, because an export that fails silently is indistinguishable from one that
// worked.
//
// This file is not macOS-only even though the menu item is: the selection it reads is the
// window's on both platforms, and the rig it resolves is the library's. Only the save panel
// and the menu item are behind `#if os(macOS)`.

@MainActor
@Observable
final class ExportController {

    /// Which rig is current — the same object the window's list writes.
    let selection: RigSelection

    /// Set when an export could not be done, so the window can say so. Cleared by whoever
    /// presents it (the window's alert, on OK).
    var lastError: String?

    /// A seam: where the bytes actually go. The live one is `FolderZipSaver`.
    private let writer: any ZipSaving

    init(selection: RigSelection, writer: any ZipSaving = FolderZipSaver()) {
        self.selection = selection
        self.writer = writer
    }

    /// The rig an export would write: the current one, read through the library so that a
    /// rig edited since the row was clicked exports as it is now.
    ///
    /// Static and taking the library as an argument rather than reading one held here,
    /// because the library is the window's and this is the menu's — and because a selection
    /// outlives the rig it names (a delete clears the list but not the menu's idea of what is
    /// current), which is exactly the case this returns nil for.
    static func exportedRig(in library: any RigProviding, for selection: RigSelection) -> Rig? {
        guard let id = selection.current else { return nil }
        return library.rig(id: id)
    }

    /// The same thing for the menu's enabled state.
    static func canExport(_ library: any RigProviding, for selection: RigSelection) -> Bool {
        exportedRig(in: library, for: selection) != nil
    }

    /// Ask where to put it, then build and write the archive.
    ///
    /// Nothing is written until the user has chosen: a cancellation is not an error, and
    /// after a cancellation nothing has happened at all.
    func exportCurrentRig(_ library: any RigProviding) async {
        guard let rig = Self.exportedRig(in: library, for: selection) else {
            lastError = "There is no rig to export: pick one from the list first."
            return
        }
        // The library may still owe a debounced write for the last edit. The rig read here
        // is current either way, but flushing makes the file on disk agree with the file in
        // the zip — otherwise a rig edited a moment ago is exported one drag ahead of what a
        // crash would have left behind.
        library.flush()

        #if os(macOS)
        guard let destination = await SavePanel.zipDestination(
            suggestedName: RigExport.suggestedFileName(for: rig)
        ) else { return }

        do {
            try RigExport.export(rig, using: writer, to: destination)
            lastError = nil
        } catch let error as RigExportError {
            lastError = error.errorDescription ?? "The export failed."
        } catch {
            lastError = "The export failed: \(error.localizedDescription)"
        }
        #else
        // No menu bar to hang the item on, so there is no way to reach this on iOS yet.
        // Refusing loudly beats a menu item nobody can use or a silent no-op.
        lastError = "Exporting a rig is not available on this device yet."
        #endif
    }
}
