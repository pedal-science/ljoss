import SwiftUI

@main
struct RigDesignerApp: App {
    @State private var library = RigLibrary()
    /// Engine state is not rig data: it lives here, beside the library, and never
    /// inside a `Rig`. Writing a generation or a health into the document would
    /// mark every rig modified and thrash the library's autosave.
    @State private var engine = EngineSession()
    /// The user's own models and impulse responses, beside the rigs rather than in them:
    /// a rig names a model by the *device's* id, and nothing here is sent anywhere yet.
    @State private var assets = AssetLibrary()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(engine)
                .environment(assets)
                .task {
                    // A device that was set up before is connected on launch, and
                    // tried again until it answers (EngineSession); one that was not
                    // leaves the app exactly as it is today.
                    if engine.settings.isComplete { await engine.connect() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Debounced autosaves must not be lost on the way out.
            if phase != .active {
                library.flush()
                // Nothing to poll for while nobody is looking. A device that went
                // away meanwhile is noticed on the next call.
                engine.pause()
            } else {
                engine.resume()
            }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        #endif
    }
}
