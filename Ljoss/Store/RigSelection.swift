import Foundation
import Observation

/// Which rig the window is showing.
///
/// The selection lives here rather than in `ContentView`'s own `@State` because two places
/// need it now. The list sets it and the editor is built from it, exactly as before — but
/// the File menu's **Export current rig …** also has to know which rig is "current", and a
/// menu command is in the app's `Commands`, not inside the window's view hierarchy, where a
/// `@State` in `ContentView` is not visible to it at all.
///
/// The alternative was `@FocusedValue`: the editor publishes the rig it is showing and the
/// menu reads it. It was rejected because focus is not selection. Clicking the sidebar would
/// empty the focused value and disable the menu item while the rig it names is still plainly
/// on screen in the detail pane — a menu that goes dead when the user clicks somewhere is
/// worse than one that is always there, and "which rig is current" is a fact about the
/// window, not about who has keyboard focus. One store, read by both, is also one thing to
/// test.
///
/// It holds an id and not a `Rig`: the library owns the rigs, and a copy kept here would go
/// stale the moment an edit landed, so the export would write the rig as it was when the row
/// was clicked. It deliberately does not know the library either — resolving an id is
/// `RigLibrary.rig(id:)`, and reaching for it here would drag an `@Observable` store that
/// owns the disk into this file, which is in the fast test set and has to compile without
/// one. See `RigProviding`, below, for the one thing an export needs from the library.
@MainActor
@Observable
final class RigSelection {

    /// The rig on screen, or nil before anything is picked.
    var current: UUID?

    init(current: UUID? = nil) {
        self.current = current
    }
}

/// The two things the export needs from wherever rigs are kept: read one, and settle any
/// pending write before reading it.
///
/// `RigLibrary` conforms, and lives beside the disk; this exists so the export path does not
/// have to carry it. That matters for the tests, which compile the export and its controller
/// with a plain `swiftc` and no `FileManager` store — and it is the honest boundary besides:
/// an export wants a rig, not a library that can also create, delete and rename them.
@MainActor
protocol RigProviding {
    func rig(id: UUID) -> Rig?
    /// Write anything still owed, so that what is read next is what is on disk.
    func flush()
}
