import SwiftUI

/// The window's shell: rigs in a two-column layout, or settings in the same shape.
///
/// Settings is a **mode**, not a sheet or a scene of its own. The rig library's column
/// becomes the list of settings areas and the rig editor's pane becomes the selected
/// area, so the same window does both jobs and coming back leaves the rig exactly where
/// it was. The rig `selection` is deliberately untouched across the swap: the editor is
/// keyed on the rig id, so it is rebuilt on return the same way switching rigs rebuilds
/// it, and `RigEditor` writes every edit through `RigLibrary` immediately.
struct ContentView: View {
    @Environment(RigLibrary.self) private var library
    @Environment(EngineSession.self) private var engine
    @Environment(ModelUserDataStore.self) private var userData

    @State private var selection: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingSettings = false
    /// The area the detail shows. Defaults to the first one, which is what settings opens
    /// on the first time; after that it is wherever the user last was.
    @State private var settingsArea: SettingsArea? = SettingsArea.allCases.first
    /// So leaving settings puts the sidebar back the way the user had it.
    @State private var visibilityBeforeSettings: NavigationSplitViewVisibility?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var useSplitView: Bool { sizeClass != .compact }
    #else
    private var useSplitView: Bool { true }
    #endif

    var body: some View {
        Group {
            if showingSettings {
                settingsShell
            } else {
                rigShell
            }
        }
        .onAppear {
            if selection == nil { selection = library.rigs.first?.id }
        }
        .onChange(of: selection) { outgoing, incoming in
            // Leaving a rig with a model picked in one of its nodes is using that model.
            // This is the only one of the three moments the editor cannot see: the rig
            // that is being left is the shell's `selection`, not the editor's.
            guard outgoing != incoming,
                  let outgoing,
                  let rig = library.rig(id: outgoing) else { return }
            userData.markUsed(ModelUsage.pickedModels(in: rig))
        }
    }

    // MARK: - Rigs

    private var rigShell: some View {
        Group {
            if useSplitView {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    RigLibraryView(selection: $selection)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
                } detail: {
                    detail
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack {
                    RigLibraryView(selection: $selection)
                        .settingsToolbarItem(isOpen: false) { openSettings() }
                        .navigationDestination(item: $selection) { id in
                            editor(for: id)
                        }
                }
            }
        }
    }

    /// The detail column. The settings button is attached to the content *inside* the
    /// stack rather than to the stack, because that is where a toolbar item is collected
    /// from — and attached here rather than in `RigEditorView` so it is there for the
    /// empty state too, which is where a window with no rigs starts.
    private var detail: some View {
        NavigationStack {
            Group {
                if let selection, library.rig(id: selection) != nil {
                    editor(for: selection)
                } else {
                    ContentUnavailableView(
                        "No Rig Selected",
                        systemImage: "guitars",
                        description: Text("Pick a rig from the list, or create a new one.")
                    )
                }
            }
            .settingsToolbarItem(isOpen: false) { openSettings() }
        }
    }

    @ViewBuilder
    private func editor(for id: UUID) -> some View {
        if let rig = library.rig(id: id) {
            // Keyed by rig id so switching rigs builds a fresh editor rather
            // than carrying the previous rig's drag and selection state over.
            RigEditorView(rig: rig, library: library, engine: engine) { openSettings(.hardware) }
                .id(id)
        } else {
            ContentUnavailableView("Rig Unavailable", systemImage: "questionmark.folder")
        }
    }

    // MARK: - Settings

    private var settingsShell: some View {
        Group {
            if useSplitView {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SettingsAreasList(selection: $settingsArea)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
                } detail: {
                    NavigationStack {
                        SettingsDetailView(area: settingsArea ?? .hardware)
                            .settingsToolbarItem(isOpen: true) { closeSettings() }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                // No column to replace on an iPhone: the areas are the stack's root and a
                // row pushes its page, which is what a list of settings areas is there.
                NavigationStack {
                    SettingsAreasList(selection: $settingsArea, pushes: true)
                        .settingsToolbarItem(isOpen: true) { closeSettings() }
                        .navigationDestination(for: SettingsArea.self) { area in
                            SettingsDetailView(area: area)
                        }
                }
            }
        }
    }

    /// Open settings where the user last was, or on the first area. This is what the
    /// toolbar button does: it is the app's settings, so it does not presume a page.
    private func openSettings() {
        openSettings(settingsArea ?? SettingsArea.allCases.first ?? .hardware)
    }

    /// Open settings on one area. The device control names Hardware, because Hardware is
    /// what the device control is about.
    private func openSettings(_ area: SettingsArea) {
        settingsArea = area
        if visibilityBeforeSettings == nil { visibilityBeforeSettings = columnVisibility }
        // The areas list *is* the sidebar in this mode, so a collapsed one would leave
        // the user in a page they cannot navigate out of.
        columnVisibility = .all
        showingSettings = true
    }

    private func closeSettings() {
        showingSettings = false
        if let previous = visibilityBeforeSettings { columnVisibility = previous }
        visibilityBeforeSettings = nil
    }
}
