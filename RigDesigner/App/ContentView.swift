import SwiftUI

struct ContentView: View {
    @Environment(RigLibrary.self) private var library
    @Environment(EngineSession.self) private var engine
    @State private var selection: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var useSplitView: Bool { sizeClass != .compact }
    #else
    private var useSplitView: Bool { true }
    #endif

    var body: some View {
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
                        .navigationDestination(item: $selection) { id in
                            editor(for: id)
                        }
                }
            }
        }
        .onAppear {
            if selection == nil { selection = library.rigs.first?.id }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, library.rig(id: selection) != nil {
            NavigationStack {
                editor(for: selection)
            }
        } else {
            ContentUnavailableView(
                "No Rig Selected",
                systemImage: "guitars",
                description: Text("Pick a rig from the list, or create a new one.")
            )
        }
    }

    @ViewBuilder
    private func editor(for id: UUID) -> some View {
        if let rig = library.rig(id: id) {
            // Keyed by rig id so switching rigs builds a fresh editor rather
            // than carrying the previous rig's drag and selection state over.
            RigEditorView(rig: rig, library: library, engine: engine)
                .id(id)
        } else {
            ContentUnavailableView("Rig Unavailable", systemImage: "questionmark.folder")
        }
    }
}
