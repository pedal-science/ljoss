import SwiftUI

@main
struct LjossApp: App {
    #if os(macOS)
    /// Only so the local engine's child process is stopped on the way out; see `AppDelegate`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @State private var library: RigLibrary
    /// Which rig is on screen. Owned here rather than inside `ContentView` because the
    /// File menu's export needs it too — see `RigSelection`.
    @State private var selection: RigSelection
    /// The File menu's export and how it reports itself, handed to both the window (for the
    /// error) and the commands (for the menu item).
    @State private var exporter: ExportController
    /// Engine state is not rig data: it lives here, beside the library, and never
    /// inside a `Rig`. Writing a generation or a health into the document would
    /// mark every rig modified and thrash the library's autosave.
    @State private var engine = EngineSession()
    /// The daemon this app can run itself: a `namchaind` on this Mac, playing a rig through one of
    /// its audio devices. `shared` rather than a new instance, because one daemon per port is the
    /// whole point — see `LocalEngine.shared`.
    @State private var localEngine = LocalEngine.shared
    /// The user's own models and impulse responses, beside the rigs rather than in them:
    /// a rig names a model by the *device's* id, and nothing here is sent anywhere yet.
    @State private var assets = AssetLibrary()
    @Environment(\.scenePhase) private var scenePhase

    /// The library, the selection and the exporter are made here rather than with default
    /// values on the properties, because they are one object graph: the exporter is the
    /// selection, and a second `RigSelection` inside the exporter would leave the menu
    /// looking at an empty one while the window showed a rig.
    init() {
        let library = RigLibrary()
        let selection = RigSelection()
        _library = State(initialValue: library)
        _selection = State(initialValue: selection)
        _exporter = State(initialValue: ExportController(selection: selection))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(selection: selection)
                .environment(library)
                .environment(exporter)
                .environment(engine)
                .environment(localEngine)
                .environment(assets)
                .task {
                    // One device at a time, and the choice is made *before* the session is pointed at
                    // anything. A user who asked for this Mac starts namchaind and connects to it; a
                    // user with a board configured connects to that. Doing it the other way round —
                    // connecting to the remembered device first and adopting the local daemon after —
                    // spends the launch trying a device nobody asked for, failing, and then leaving
                    // the session unconnected behind the failure it just showed.
                    let local = LocalEngineStore.load()
                    if local.wantsLocal {
                        await localEngine.start(session: engine, settings: local, library: assets)
                    } else if engine.settings.isComplete {
                        // Tried again until it answers (EngineSession); a device that was never set
                        // up leaves the app exactly as it is today.
                        await engine.connect()
                    }
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
                // The local engine is not stopped when the app loses focus — that would cut the audio
                // the moment someone switched windows — so this is only here for the launch case,
                // where the phase can go active before the task above has run.
                Task { await startRememberedLocalEngine() }
            }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        .commands {
            ExportRigCommands(controller: exporter, library: library)
        }
        #endif
    }

    /// Bring the local engine up if the user's remembered choice says so, and point the session at it.
    /// Does nothing when it is already running, so this is safe to call on every activation.
    private func startRememberedLocalEngine() async {
        let settings = LocalEngineStore.load()
        guard settings.wantsLocal, !localEngine.state.isUp, localEngine.state != .starting else { return }
        await localEngine.start(session: engine, settings: settings, library: assets)
    }
}
