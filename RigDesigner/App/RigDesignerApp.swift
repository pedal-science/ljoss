import SwiftUI

@main
struct RigDesignerApp: App {
    @State private var library = RigLibrary()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
        }
        .onChange(of: scenePhase) { _, phase in
            // Debounced autosaves must not be lost on the way out.
            if phase != .active { library.flush() }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        #endif
    }
}
