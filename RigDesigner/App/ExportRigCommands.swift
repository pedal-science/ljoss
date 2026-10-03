import SwiftUI

#if os(macOS)

// **File > Export current rig …**
//
// In the File menu beside New/Open/Save. There is no "Save" in this app — rigs save
// themselves as they are edited — so this is the only item in that region about the
// document, and it belongs there by the user's own words rather than by SwiftUI's
// grouping.
//
// The state it reads comes from `RigDesignerApp` as parameters rather than from the
// environment: a `Commands` body is not inside the window's view hierarchy, which is
// exactly the problem `RigSelection` exists to solve.
struct ExportRigCommands: Commands {

    let controller: ExportController
    let library: RigLibrary

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Export current rig …") {
                Task { await controller.exportCurrentRig(library) }
            }
            // Disabled, not hidden: a menu item that comes and goes is harder to find than
            // one that is visibly waiting for a rig to be picked.
            .disabled(!ExportController.canExport(library, for: controller.selection))
            .help("Save this rig and its namchain document together in one zip file")
        }
    }
}

#endif
