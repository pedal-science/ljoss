import Foundation
import Observation

// Running namchaind as a child of this app.
//
// The decision of *whether* and *with what* is in LocalEnginePlan, which is deliberately free of
// `Process` so the test harness can compile and check it. This is the half that actually starts
// something: it makes the directories the daemon expects, writes its output to a log somebody can
// read, and stops it when the app goes away.
//
// Three deliberate choices, because each has an alternative that looks tidier and behaves worse:
//
//  * **A child process, not a launchd agent.** A LaunchAgent is the standard way to run a per-user
//    daemon and it is the wrong one here: it survives quitting the app, it needs an installer to
//    remove, and "so I can test without a real device" is not a thing that should outlive the test.
//  * **A child, and not an in-process engine.** namchaind is C++ with its own real-time thread and
//    its own failure modes; a crash in it must cost the session, not the app's unsaved rig.
//  * **An adopted daemon is a success, not a conflict.** If something is already listening on the
//    port — a leftover from a crashed app, or an operator's own daemon — the app uses it. Starting a
//    second one would fail with "address in use", which reads as the app being broken when the thing
//    the user wanted is right there.
//
// The daemon is stopped when the app terminates and not before. Stopping it when the app merely
// loses focus would cut the audio the moment the user went to read a manual, and the thing this
// exists to prevent — a daemon outliving the app that started it — is caught by the termination hook
// rather than by guessing at the scene lifecycle.
//
// iOS has no `namchaind` and no CoreAudio output a child process could use, so on that platform the
// engine is a stub that reports why rather than a form that cannot work.

@MainActor
@Observable
final class LocalEngine {

    /// The one engine this process runs.
    ///
    /// A singleton because the constraint is physical: one daemon per TCP port, one audio device
    /// held, one child to reap. A second instance would either fail to bind or fight the first, so
    /// making it impossible to construct is more honest than making it merely discouraged. It is
    /// also what lets the app-termination hook stop the engine without the delegate having to be
    /// handed one.
    static let shared = LocalEngine()

    enum State: Equatable, Sendable {
        case stopped
        case starting
        /// Running as this app's child, with its pid.
        case running(pid: Int32)
        /// Running but not ours: something was already listening on the port and answered.
        case adopted
        case failed(String)

        var isUp: Bool {
            switch self {
            case .running, .adopted: true
            case .stopped, .starting, .failed: false
            }
        }
    }

    private(set) var state: State = .stopped

    /// Where the daemon's directories and its log live. Set once a plan has been made.
    private(set) var engineRoot: URL?

    /// The daemon's own words, for the panel and for a bug report.
    var logURL: URL? { engineRoot?.appending(path: "namchaind.log") }

    #if os(macOS)
    private var process: Process?
    private var logHandle: FileHandle?
    #endif

    /// Private because `shared` is the only one there can usefully be: a second would either fail to
    /// bind the port or fight the first for the audio device. See the note on `shared`.
    private init() {}

    // MARK: - The calls the UI makes

    /// \brief Bring a local engine up and point \p session at it.
    ///
    /// On success the session is connected to `127.0.0.1` with the daemon's token, and the caller has
    /// nothing left to do. The app's stored device settings are deliberately **not** rewritten: the
    /// local engine is a mode, and turning it off should leave whatever device was configured alone.
    ///
    /// \param settings the resolved preferences. Its `token` is reused when there is one, so a
    ///        daemon left behind by a crash is still reachable — and so the adoption probe below is
    ///        asking with the secret the daemon was actually started with.
    func start(session: EngineSession,
               settings: LocalEngineSettings,
               library: AssetLibrary? = nil) async {
        guard !state.isUp, state != .starting else { return }
        state = .starting

        // A token is made once and kept: see `LocalEngineSettings.token`.
        var settings = settings
        if settings.token.count < EngineSettings.minimumTokenLength {
            settings.token = LocalEnginePlan.makeToken()
        }
        // And a capture, if the user has not chosen one: namchain's own example, from the checkout
        // the launcher came from. Filled in here, at the moment it is needed, so a checkout that
        // moves or appears is picked up rather than remembered as broken — and written back, so the
        // field shows what is actually being looped rather than staying blank.
        if settings.loopFilePath.trimmingCharacters(in: .whitespaces).isEmpty,
           let example = LocalEnginePlan.defaultLoopFile(launcher: settings.launcherPath) {
            settings.loopFilePath = example.path
            LocalEngineStore.save(settings)
        }

        do {
            try await bringUp(session: session, settings: settings, library: library)
        } catch {
            LocalEngineStore.save(marked(settings, live: false))
            state = .failed(String(describing: error))
        }
    }

    func stop() {
        #if os(macOS)
        if let process, process.isRunning {
            // SIGTERM rather than SIGKILL: the daemon closes its device and removes its socket on
            // the way out, and killing it leaves both behind.
            process.terminate()
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        #endif
        state = .stopped
    }

    // MARK: - Bringing it up

    private func bringUp(session: EngineSession,
                         settings: LocalEngineSettings,
                         library: AssetLibrary?) async throws {
        engineRoot = LocalEnginePlan.engineRoot(settings.engineRootPath)

        // An existing daemon on the port wins. This is checked before anything is spawned, and it is
        // the whole reason `adopted` is a state rather than an error.
        if await session.reachesLocalDaemon(port: settings.tcpPort, token: settings.token) {
            session.adoptLocalEngine(port: settings.tcpPort, token: settings.token)
            LocalEngineStore.save(marked(settings, live: true))
            // The daemon's own directory is where it was started from; a leftover one may differ
            // from what the settings now say, so the log path is only a guess here.
            state = .adopted
            return
        }

        let models = library.flatMap { localEngineModelsRoot(roots: $0.roots, entries: $0.entries) }
        let plan = try LocalEnginePlan.make(settings: settings, modelsRoot: models, token: settings.token)

        try makeDirectories(plan)
        #if os(macOS)
        let pid = try launch(plan)
        session.adoptLocalEngine(port: plan.tcpPort, token: plan.token)
        LocalEngineStore.save(marked(settings, live: true))
        state = .running(pid: pid)
        #endif
    }

    /// Three directories, because the daemon treats a missing root as an empty library rather than a
    /// failure — which is the right behaviour for an appliance and a confusing one here: "no amps
    /// installed" would be the app's fault, not the user's.
    private func makeDirectories(_ plan: LocalEnginePlan) throws {
        let fileManager = FileManager.default
        for directory in [plan.engineRoot, plan.modelsRoot, plan.irsRoot, plan.rigsRoot] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// What gets written back after a run: what the user asked for, and what actually happened.
    /// `wantsLocal` is carried through untouched, so a failure never rewrites the preference.
    private func marked(_ settings: LocalEngineSettings, live: Bool) -> LocalEngineSettings {
        var updated = settings
        updated.enabled = live
        return updated
    }

    #if os(macOS)
    /// \return the child's pid.
    private func launch(_ plan: LocalEnginePlan) throws -> Int32 {
        let fileManager = FileManager.default
        let log = plan.engineRoot.appending(path: "namchaind.log")
        if !fileManager.fileExists(atPath: log.path) {
            fileManager.createFile(atPath: log.path, contents: nil)
        }
        // Appended, not truncated: a previous run's crash is the most useful thing in this file.
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        logHandle = handle

        let child = Process()
        child.executableURL = plan.launcher
        child.arguments = plan.arguments
        child.currentDirectoryURL = plan.engineRoot
        child.standardOutput = handle
        child.standardError = handle
        child.standardInput = FileHandle.nullDevice
        // The parent's environment without the dynamic-linker variables, which is what makes this
        // work when the app is launched from Xcode. See `childEnvironment`.
        child.environment = LocalEnginePlan.childEnvironment(from: ProcessInfo.processInfo.environment)

        let command = ([plan.launcher.path] + plan.arguments).joined(separator: " ")
        handle.write(Data("\n$ \(command)\n".utf8))

        // The handler hops back to the main actor because `state` is main-actor isolated. The process
        // is captured rather than read from `self`, so a stop-and-start cannot make an old exit look
        // like a new one.
        child.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                self.process = nil
                try? self.logHandle?.close()
                self.logHandle = nil
                guard finished.terminationStatus != 0 else {
                    self.state = .stopped
                    return
                }
                // The daemon's own last words, because the interesting failures have a sentence of
                // their own — "address already in use" is the one that otherwise reads as the app
                // being broken when the fix is a port number.
                var why = "namchaind exited with status \(finished.terminationStatus)."
                if let said = self.lastWordsFromLog() { why += "\n" + said }
                why += "\nIts log is at \(self.logURL?.path ?? "the engine folder")."
                self.state = .failed(why)
            }
        }

        try child.run()
        process = child
        return child.processIdentifier
    }

    /// The last few non-empty lines the daemon wrote, for a failure message that says what happened
    /// rather than where to read about it.
    private func lastWordsFromLog() -> String? {
        guard let logURL, let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("$ ") }
        guard let last = lines.last else { return nil }
        // One line, and a short one: a dyld failure is two long lines of its own and the message is
        // shown in a settings row, not a console.
        return last.count > 300 ? String(last.prefix(300)) + "…" : last
    }
    #endif
}
