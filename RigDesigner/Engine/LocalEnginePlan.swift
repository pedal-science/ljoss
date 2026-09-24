import Foundation

// Running namchaind on this machine, so the app can be driven and heard without a board.
//
// This is the app-side half of the `coreaudio` backend: the daemon loops a WAV into the Mac's
// output device, so a rig can be auditioned with no interface, no guitar and no second machine.
// Everything about *what the daemon does* is namchain's business and is documented there
// (`docs/daemon.md`, §"The CoreAudio backend"); what lives here is only the decision of whether to
// run one, where its things are, and what to tell it.
//
// The file is deliberately free of SwiftUI and of `Process`, so `Tests/` can compile it with a
// plain `swiftc` invocation and assert the parts that are easy to get wrong: the argument list, the
// loop-file refusal, and the model-folder selection. `LocalEngine` next door is the half that
// actually spawns something.

// MARK: - What the user configured

/// The stored preferences for the local engine.
///
/// Everything has a default that resolves at the time it is used rather than at the time it is
/// stored, so a folder that moves does not have to be re-picked.
struct LocalEngineSettings: Codable, Equatable, Sendable {

    /// Whether the app should bring its own engine up at launch. The user's *intent*: a run that
    /// failed does not clear it, so a failure is not silently turned into a preference.
    var wantsLocal: Bool = false

    /// Whether an engine was up when the app last looked, so the panel can show what is going on
    /// rather than what was asked for.
    var enabled: Bool = false

    /// The `namchaind` to run. Empty means "find one" — see `LocalEnginePlan.defaultLauncher`.
    var launcherPath: String = ""

    /// The WAV looped into the rig. The signal, in place of an instrument.
    var loopFilePath: String = ""

    /// The token the daemon was last started with. Generated rather than typed, and kept so that a
    /// daemon left behind by a crash is adopted on the next launch instead of being unreachable
    /// (and so instead of a second one failing on a port that is already bound).
    var token: String = ""

    /// The port for the daemon's TCP control listener. The app's own default, so a local engine and
    /// a remembered device cannot collide by accident.
    var tcpPort: UInt16 = EngineSettings.defaultPort

    /// The ceiling the daemon compiles its plan for. See `LocalEnginePlan.periodSize` for why this is
    /// not the same thing as the device's period.
    var periodSize: UInt16 = 1024

    /// A CoreAudio device UID, or empty for the system's default output device.
    var deviceUID: String = ""

    /// Where the daemon's `models/`, `irs/` and `rigs/` live. Empty means the standard application
    /// support location.
    var engineRootPath: String = ""
}

// MARK: - What it resolves to

/// Everything the daemon needs to be told, resolved from the settings and the filesystem.
struct LocalEnginePlan: Equatable, Sendable {

    /// Resolved by the caller: the executable, the directories, the token and the port.
    var launcher: URL
    var engineRoot: URL
    var modelsRoot: URL
    var irsRoot: URL
    var rigsRoot: URL
    var loopFile: URL
    var tcpPort: UInt16
    var periodSize: UInt16
    var deviceUID: String
    var token: String

    /// Why a plan could not be made, in words a person can act on.
    enum PlanError: Error, Equatable, CustomStringConvertible {
        case launcherMissing(String)
        case loopFileMissing(String)
        case loopFileIsADirectory(String)
        case notAnAudioFile(String)
        case periodOutOfRange(UInt16)

        var description: String {
            switch self {
            case .launcherMissing(let path):
                """
                No namchaind at \(path.isEmpty ? "(nowhere)" : path). Build it — \
                `cmake -S . -B build -G Ninja && cmake --build build` in the namchain checkout — \
                or point this at the binary.
                """
            case .loopFileMissing(let path):
                "The loop file does not exist: \(path). Pick a WAV to play in place of an instrument."
            case .loopFileIsADirectory(let path):
                "The loop file is a folder: \(path)."
            case .notAnAudioFile(let path):
                "The loop file is not a .wav: \(path). namchaind loops a WAV and nothing else."
            case .periodOutOfRange(let frames):
                "A period of \(frames) frames is outside the range the engine builds for (32–4096)."
            }
        }
    }

    /// The range the engine's own configuration check accepts, repeated here so the app can refuse
    /// by name before spawning something that will fail by name.
    static let periodRange: ClosedRange<UInt16> = 32...4096

    // MARK: Building

    /// \brief Resolve \p settings against the filesystem, or explain what is missing.
    ///
    /// Refuses rather than guessing: a wrong path that becomes an empty library looks like a working
    /// engine with no amps, and that is a much longer trail to follow than a sentence here.
    ///
    /// \param token a token to reuse. An empty one is generated, so a relaunch keeps the token the
    ///        app's keychain already holds instead of leaving it behind.
    static func make(settings: LocalEngineSettings,
                     modelsRoot: URL?,
                     token: String,
                     fileManager: FileManager = .default) throws -> LocalEnginePlan {
        guard periodRange.contains(settings.periodSize) else {
            throw PlanError.periodOutOfRange(settings.periodSize)
        }

        let launcher = try resolveLauncher(settings.launcherPath, fileManager: fileManager)
        let loop = try resolveLoopFile(settings.loopFilePath, fileManager: fileManager)
        let root = engineRoot(settings.engineRootPath)

        // The two library roots are the daemon's, not the app's: it lists what is under them and a
        // rig names a model by its id. `modelsRoot` is the user's configured model folder when there
        // is one, so the palette's amps are the ones the local engine can actually play.
        let models = modelsRoot ?? root.appending(path: "models", directoryHint: .isDirectory)
        let irs = root.appending(path: "irs", directoryHint: .isDirectory)
        let rigs = root.appending(path: "rigs", directoryHint: .isDirectory)

        return LocalEnginePlan(launcher: launcher,
                               engineRoot: root,
                               modelsRoot: models,
                               irsRoot: irs,
                               rigsRoot: rigs,
                               loopFile: loop,
                               tcpPort: settings.tcpPort,
                               periodSize: settings.periodSize,
                               deviceUID: settings.deviceUID,
                               token: token.isEmpty ? makeToken() : token)
    }

    /// \brief The `namchaind` to run when none was named.
    ///
    /// The three places a working copy is actually found: beside this checkout's sibling `namchain`
    /// in its build directory, and the two prefixes a `make install` uses. Guessing is confined to
    /// this function so that "which binary did it run" always has an answer.
    ///
    /// There is no home directory to guess at on iOS — the platform has no `namchaind` and no
    /// CoreAudio output a child process could use — so those two candidates are macOS-only and the
    /// rest of the function is shared, which is what keeps the tests able to cover it everywhere.
    static func defaultLauncher(fileManager: FileManager = .default) -> URL? {
        var candidates: [URL] = []
        #if os(macOS)
        let home = fileManager.homeDirectoryForCurrentUser
        candidates.append(home.appending(path: "code.local/namchain/build/namchaind"))
        candidates.append(home.appending(path: "namchain/build/namchaind"))
        #endif
        candidates.append(URL(filePath: "/usr/local/bin/namchaind"))
        candidates.append(URL(filePath: "/opt/homebrew/bin/namchaind"))
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func resolveLauncher(_ path: String, fileManager: FileManager = .default) throws -> URL {
        let text = path.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let url = URL(filePath: text)
            guard fileManager.isExecutableFile(atPath: url.path) else {
                throw PlanError.launcherMissing(text)
            }
            return url
        }
        guard let found = defaultLauncher(fileManager: fileManager) else {
            throw PlanError.launcherMissing("")
        }
        return found
    }

    static func resolveLoopFile(_ path: String, fileManager: FileManager = .default) throws -> URL {
        let text = path.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw PlanError.loopFileMissing("") }
        let url = URL(filePath: text)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PlanError.loopFileMissing(text)
        }
        if isDirectory.boolValue { throw PlanError.loopFileIsADirectory(text) }
        // The daemon's loader takes a WAV and nothing else, so an .mp3 picked by mistake is refused
        // here rather than as "no frames to loop" from three layers down.
        guard url.pathExtension.lowercased() == "wav" else {
            throw PlanError.notAnAudioFile(text)
        }
        return url
    }

    /// \brief A capture to loop when the user has not chosen one.
    ///
    /// namchain ships one — a two-second mono 48 kHz guitar phrase, the same `input.wav` its own
    /// tests and soak runs use — and it lives in the checkout the launcher came from. Finding it
    /// means "the engine can be auditioned the moment it is switched on", which is the whole point of
    /// a local engine; requiring a file to be hunted down first is the opposite.
    ///
    /// The search walks up from *the binary that will run*, so a checkout anywhere works, and a
    /// relocated or installed `namchaind` simply finds nothing. That is not a failure: an empty
    /// result leaves the field for the user and the chooser, which is where it started — and a fixed
    /// list of "likely" checkout paths is deliberately not consulted, because a path this app
    /// guessed is worse than one the user picked.
    static func defaultLoopFile(launcher: String = "", fileManager: FileManager = .default) -> URL? {
        let relative = "vendor/NeuralAmpModelerCore/example_audio/input.wav"

        let text = launcher.trimmingCharacters(in: .whitespaces)
        let binary = text.isEmpty ? defaultLauncher(fileManager: fileManager) : URL(filePath: text)
        guard let binary else { return nil }

        var directory = binary.deletingLastPathComponent()
        // Seven levels is `build/` plus a few directories of a deeper build tree, and it stops before
        // this can wander to the filesystem root on a path that does not exist.
        for _ in 0..<7 {
            let candidate = directory.appending(path: relative)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    /// The daemon's own directories. Not created here — `LocalEngine` does that — so that this stays
    /// a pure function of the settings.
    static func engineRoot(_ path: String, fileManager: FileManager = .default) -> URL {
        let text = path.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return URL(filePath: text, directoryHint: .isDirectory) }
        let base = (try? fileManager.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: true))
            ?? fileManager.temporaryDirectory
        return base.appending(path: "Ljoss/LocalEngine", directoryHint: .isDirectory)
    }

    /// \brief A token for the daemon's control port.
    ///
    /// The daemon refuses to start a TCP listener without one and refuses one under 16 characters, so
    /// this is 32 hex characters of real randomness. It is generated rather than typed because the
    /// user has no reason to have an opinion about it: the app is the only client.
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        var text = ""
        text.reserveCapacity(32)
        for _ in 0..<16 {
            let byte = UInt8.random(in: 0...255, using: &generator)
            text += String(format: "%02x", byte)
        }
        return text
    }

    // MARK: What to tell the daemon

    /// The command line, in the order `--help` documents it.
    ///
    /// `--backend coreaudio` is the whole point: a WAV looped in and the output to a CoreAudio
    /// device, in the daemon's own process. `--period-size` is a *ceiling* rather than a request —
    /// the backend measures the device's own period and compiles for that — which is why 1024 is a
    /// safe default rather than a guess about the hardware.
    var arguments: [String] {
        var arguments = [
            "--backend", "coreaudio",
            "--capture-path", loopFile.path,
            "--sample-rate", "48000",
            "--period-size", String(periodSize),
            "--rigs-root", rigsRoot.path,
            "--models-root", modelsRoot.path,
            "--irs-root", irsRoot.path,
            "--socket", engineRoot.appending(path: "namchaind.sock").path,
            "--tcp-listen",
            "--tcp-address", "127.0.0.1",
            "--tcp-port", String(tcpPort),
            "--tcp-token", token,
            // The daemon is a helper of this app, not an appliance: it must not fight the app for
            // the interface or fail to start because a page could not be pinned. Both are reported
            // by `engine.status` if anyone asks.
            "--no-lock-memory",
            "--rt-priority", "0",
            "--verbose",
        ]
        // Only when one was chosen: empty means the system's default output device, which is what
        // the daemon does with an absent `--device`.
        if !deviceUID.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["--device", deviceUID.trimmingCharacters(in: .whitespaces)]
        }
        return arguments
    }

    /// The `tokens` a client needs: what the app tells its own connection settings.
    static func isLoopback(_ host: String) -> Bool {
        let text = host.trimmingCharacters(in: .whitespaces).lowercased()
        return text == "127.0.0.1" || text == "localhost" || text == "::1"
    }

    /// \brief The environment to hand the daemon.
    ///
    /// The parent's, minus the dynamic-linker variables. This is not hygiene for its own sake: Xcode
    /// injects `DYLD_INSERT_LIBRARIES=@executable_path/__preview.dylib` into an app it launches, the
    /// child inherits it by default, and dyld then kills `namchaind` before `main` because there is
    /// no `__preview.dylib` next to *its* executable:
    ///
    /// ```
    /// dyld[824]: terminating because inserted dylib '@executable_path/__preview.dylib' could not be loaded
    /// ```
    ///
    /// The symptom is "Run namchaind on this Mac" failing only while the app is launched from Xcode,
    /// which is precisely where it is being tested. `DYLD_LIBRARY_PATH` and friends go for the same
    /// reason: whatever they point at is the app's business, not the daemon's.
    static func childEnvironment(from parent: [String: String]) -> [String: String] {
        var environment = parent
        for key in environment.keys where key.hasPrefix("DYLD_") {
            environment.removeValue(forKey: key)
        }
        return environment
    }
}

// MARK: - Which folder the models come from

/// Pick the daemon's model root from the user's own library.
///
/// The local engine is only useful if its palette can play something, and the daemon lists `.nam`
/// files under **its** `models_root` — so the first folder the user has actually put a model in is
/// the right one to hand it. A folder is chosen only when an entry was found in it: an empty first
/// root would shadow a second one that has the models in it.
///
/// \return nil when the user has configured nothing, in which case the daemon gets its own empty
///         folder under the engine root rather than one of the app's.
func localEngineModelsRoot(roots: [AssetRoot], entries: [AssetEntry]) -> URL? {
    for root in roots {
        let hasModel = entries.contains { $0.rootID == root.id && $0.kind == .model }
        if hasModel { return root.url }
    }
    return nil
}

/// The same for impulse responses, so a cab block can name one.
func localEngineIRsRoot(roots: [AssetRoot], entries: [AssetEntry]) -> URL? {
    for root in roots {
        let hasIR = entries.contains { $0.rootID == root.id && $0.kind == .ir }
        if hasIR { return root.url }
    }
    return nil
}
