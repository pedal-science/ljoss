import SwiftUI

@main
struct RigDesignerApp: App {
    #if os(macOS)
    /// Only so the local engine's child process is stopped on the way out; see `AppDelegate`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @State private var library = RigLibrary()
    /// Engine state is not rig data: it lives here, beside the library, and never
    /// inside a `Rig`. Writing a generation or a health into the document would
    /// mark every rig modified and thrash the library's autosave.
    @State private var engine = EngineSession()
    /// The daemon this app can run itself: a `namchaind` on this Mac, looping a WAV into the
    /// output device, for auditioning a rig with no board attached. `shared` rather than a new
    /// instance, because one daemon per port is the whole point — see `LocalEngine.shared`.
    @State private var localEngine = LocalEngine.shared
    /// The user's own models and impulse responses, beside the rigs rather than in them:
    /// a rig names a model by the *device's* id, and nothing here is sent anywhere yet.
    @State private var assets = AssetLibrary()
    /// What the user has said about those models — their ratings, which they have used,
    /// and what they have searched for. Kept in the iCloud key-value store rather than
    /// in the app's own folder, because it belongs to the user rather than to this
    /// installation of the app.
    @State private var userData = ModelUserDataStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(engine)
                .environment(localEngine)
                .environment(assets)
                .environment(userData)
                .task {
                    // The folders are walked at launch, in the background, so the
                    // listing is normally re-read before anyone reaches
                    // Settings → Models & IRs. The entries restored from the last
                    // session are shown meanwhile, dimmed while this runs.
                    assets.scanIfNeeded()
                    // A device that was set up before is reconnected on launch;
                    // one that was not leaves the app exactly as it is today.
                    if engine.settings.isComplete { await engine.connect() }
                    // The local engine is remembered the same way, and brought back for the same
                    // reason: a user who was auditioning through it should find it there.
                    await startRememberedLocalEngine()
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
                // The local engine is not stopped when the app loses focus — that would cut the
                // audio the moment someone switched windows — so this is only here for the
                // launch-time case, where the phase can go active before the task has run.
                Task { await startRememberedLocalEngine() }
            }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        #endif
    }

    /// Bring the local engine up if the user's remembered choice says so, and reconnect the session
    /// to it. Does nothing when it is already running, so this is safe to call on every activation.
    private func startRememberedLocalEngine() async {
        let settings = LocalEngineStore.load()
        guard settings.wantsLocal, !localEngine.state.isUp, localEngine.state != .starting else { return }
        await localEngine.start(session: engine, settings: settings, library: assets)
    }
}
