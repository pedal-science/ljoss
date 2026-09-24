import Foundation

// Assertions for the local engine's decision-making: what it resolves, what it refuses, and what it
// tells the daemon.
//
// This is the half worth testing, because every one of these mistakes produces a working-looking
// engine rather than an error: an argument list with a typo starts a daemon with defaults, a model
// root pointed at the wrong folder is an empty library, and a token under 16 characters is refused
// by the daemon three layers down. The `Process` half is deliberately not here — it is in
// `LocalEngine.swift`, which needs a real binary and is exercised by hand.

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "local-engine-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeFile(_ url: URL, bytes: Int = 8) {
    try? Data(repeating: 0, count: bytes).write(to: url)
}

func testLocalEngineSettingsRoundTrip() {
    print("the local engine's remembered settings")

    var settings = LocalEngineSettings()
    check(settings.launcherPath.isEmpty, "an empty launcher means 'find one', not 'none'")
    check(settings.tcpPort == EngineSettings.defaultPort,
          "the port defaults to the app's own, so a local engine cannot collide with a device by accident")
    check(!settings.wantsLocal,
          "a fresh install does not decide to run a background process on the user's behalf")

    settings.wantsLocal = true
    settings.loopFilePath = "/tmp/riff.wav"
    settings.periodSize = 512
    settings.token = "0123456789abcdef0123456789abcdef"

    let data = try! JSONEncoder().encode(settings)
    let back = try! JSONDecoder().decode(LocalEngineSettings.self, from: data)
    check(back == settings, "every field survives a round trip through the preferences")
}

func testLocalEngineResolvesItsPaths() {
    print("what the local engine resolves")

    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let loop = root.appending(path: "riff.wav")
    writeFile(loop, bytes: 64)

    var settings = LocalEngineSettings()
    settings.loopFilePath = loop.path
    settings.engineRootPath = root.appending(path: "engine").path

    let plan = try? LocalEnginePlan.make(settings: settings, modelsRoot: nil, token: "")
    check(plan != nil, "a loop file that exists produces a plan")
    guard let plan else { return }

    check(plan.loopFile.path == loop.path, "the loop file is the one that was picked")
    check(plan.modelsRoot.path.hasSuffix("/models"),
          "with no library configured, the daemon gets its own models folder")
    check(plan.irsRoot.path.hasSuffix("/irs"), "…and its own impulse responses folder")
    check(plan.rigsRoot.path.hasSuffix("/rigs"), "…and its own rigs folder")
    check(plan.modelsRoot.deletingLastPathComponent().path == plan.engineRoot.path,
          "all three live under the engine root")
    check(plan.token.count >= EngineSettings.minimumTokenLength,
          "an empty token is generated, and long enough that the daemon will take it")
    check(plan.token.allSatisfy(\.isHexDigit), "the generated token is the hex the docs describe")
}

func testLocalEngineReusesAToken() {
    print("the local engine's token")

    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let loop = root.appending(path: "riff.wav")
    writeFile(loop)

    var settings = LocalEngineSettings()
    settings.loopFilePath = loop.path
    settings.engineRootPath = root.path

    let first = try? LocalEnginePlan.make(settings: settings, modelsRoot: nil, token: "")
    let second = try? LocalEnginePlan.make(settings: settings, modelsRoot: nil,
                                           token: first?.token ?? "")
    check(first?.token == second?.token,
          "a remembered token is reused: a daemon left behind by a crash is still reachable")
    check(LocalEnginePlan.makeToken() != LocalEnginePlan.makeToken(),
          "two generated tokens are different")
    check(LocalEnginePlan.makeToken().count == 32, "…and 32 characters, as the daemon's own docs say")
}

func testLocalEngineRefusesWhatItCannotRun() {
    print("what the local engine refuses")

    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let loop = root.appending(path: "riff.wav")
    writeFile(loop)

    var settings = LocalEngineSettings()
    settings.engineRootPath = root.path

    // No loop file at all.
    var error = (try? LocalEnginePlan.make(settings: settings, modelsRoot: nil, token: ""))
    check(error == nil, "an empty loop path is refused rather than run")
    if error == nil {
        settings.loopFilePath = root.appending(path: "nope.wav").path
        error = try? LocalEnginePlan.make(settings: settings, modelsRoot: nil, token: "")
        check(error == nil, "a loop file that does not exist is refused")
    }

    // A folder where a file should be.
    settings.loopFilePath = root.path
    check((try? LocalEnginePlan.make(settings: settings, modelsRoot: nil, token: "")) == nil,
          "a folder is not a loop file")

    // Something the daemon's loader cannot read.
    let mp3 = root.appending(path: "song.mp3")
    writeFile(mp3)
    settings.loopFilePath = mp3.path
    do {
        _ = try LocalEnginePlan.make(settings: settings, modelsRoot: nil, token: "")
        check(false, "a non-WAV is refused here rather than three layers down as 'no frames to loop'")
    } catch let refusal as LocalEnginePlan.PlanError {
        check(refusal == .notAnAudioFile(mp3.path), "…and the refusal names the file")
        check(refusal.description.contains(".wav"), "…and says what it wants instead")
    } catch {
        check(false, "the refusal is one of this type's cases")
    }

    // A period outside what the engine builds for.
    settings.loopFilePath = loop.path
    settings.periodSize = 8192
    check((try? LocalEnginePlan.make(settings: settings, modelsRoot: nil, token: "")) == nil,
          "a period the engine would refuse is refused here first")
    settings.periodSize = 64
    check((try? LocalEnginePlan.make(settings: settings, modelsRoot: nil, token: "")) != nil,
          "and an ordinary one is not")

    // A launcher that is not there. Named explicitly, because "find one" is not what is being
    // tested and this machine may or may not have a namchaind built.
    settings.launcherPath = root.appending(path: "no-such-namchaind").path
    do {
        _ = try LocalEnginePlan.make(settings: settings, modelsRoot: nil, token: "")
        check(false, "a launcher that is not executable is refused")
    } catch let refusal as LocalEnginePlan.PlanError {
        check(refusal.description.contains("no-such-namchaind"),
              "…and the message says where it looked")
    } catch {
        check(false, "the refusal is one of this type's cases")
    }
}

func testLocalEngineArguments() {
    print("what the local engine tells the daemon")

    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let loop = root.appending(path: "riff.wav")
    writeFile(loop)
    let binary = root.appending(path: "namchaind")
    writeFile(binary)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

    var settings = LocalEngineSettings()
    settings.loopFilePath = loop.path
    settings.engineRootPath = root.path
    settings.launcherPath = binary.path

    guard let plan = try? LocalEnginePlan.make(settings: settings, modelsRoot: nil, token: "") else {
        check(false, "the fixture produces a plan")
        return
    }
    let arguments = plan.arguments

    func value(of flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    check(value(of: "--backend") == "coreaudio",
          "the local engine is the coreaudio backend: a file looped into the output device")
    check(value(of: "--capture-path") == loop.path, "…looping the file the user picked")
    check(value(of: "--sample-rate") == "48000",
          "…at the engine's own rate, which is the only one it has")
    check(arguments.contains("--tcp-listen"),
          "…with a control listener for the app")
    check(value(of: "--tcp-address") == "127.0.0.1",
          "…bound to loopback: a local engine is not for the network")
    check(value(of: "--tcp-port") == String(settings.tcpPort), "…on the configured port")
    check(value(of: "--tcp-token") == plan.token, "…with the token the app will present")
    check(arguments.contains("--no-lock-memory"),
          "memory locking is off: a helper that cannot pin pages must still start")
    check(value(of: "--rt-priority") == "0",
          "real-time priority is off too, for the same reason")
    check(!arguments.contains("--device"),
          "no device flag means the system's default output device")
    check(arguments.contains("--verbose"),
          "the daemon's own account of what it did goes to the log")

    // The directories it is given are the ones a rig's model would be found in.
    check(value(of: "--models-root") == plan.modelsRoot.path, "the model library is where it says")
    check(value(of: "--irs-root") == plan.irsRoot.path, "…and so are the impulse responses")
    check(value(of: "--rigs-root") == plan.rigsRoot.path, "…and the rigs")
    check(value(of: "--socket") == plan.engineRoot.appending(path: "namchaind.sock").path,
          "the control socket lives with the engine rather than in /run, which a user cannot write")

    // A chosen device is passed through, and an empty one is not.
    var withDevice = settings
    withDevice.deviceUID = "BuiltInSpeakerDevice"
    let devicePlan = try? LocalEnginePlan.make(settings: withDevice, modelsRoot: nil, token: "")
    check(devicePlan?.arguments.contains("BuiltInSpeakerDevice") == true,
          "a chosen output device is named to the daemon")
    check(devicePlan?.arguments.firstIndex(of: "--device")
            .map { devicePlan!.arguments[$0 + 1] == "BuiltInSpeakerDevice" } == true,
          "…as the value of --device")
}

func testLocalEngineChildEnvironment() {
    print("the environment the daemon is given")

    let parent = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/Users/someone",
        "DYLD_INSERT_LIBRARIES": "@executable_path/__preview.dylib",
        "DYLD_LIBRARY_PATH": "/somewhere/else",
        "DYLD_FRAMEWORK_PATH": "/somewhere/else",
    ]
    let child = LocalEnginePlan.childEnvironment(from: parent)

    check(child["PATH"] == parent["PATH"] && child["HOME"] == parent["HOME"],
          "the daemon keeps the environment it needs to run")
    check(child.keys.allSatisfy { !$0.hasPrefix("DYLD_") },
          "…and none of the dynamic-linker variables, which Xcode injects into an app it launches")
    check(child["DYLD_INSERT_LIBRARIES"] == nil,
          "specifically the preview library, which killed the daemon before main when it was inherited")
}

func testLocalEngineFindsAnExampleCapture() {
    print("the capture a fresh local engine loops")

    // A standing start: no file chosen, and a `namchaind` in a checkout. The engine should not need
    // the user to go and find a WAV before it can make a sound.
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let build = root.appending(path: "build", directoryHint: .isDirectory)
    let example = root.appending(path: "vendor/NeuralAmpModelerCore/example_audio/input.wav")
    try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: example.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    writeFile(build.appending(path: "namchaind"))
    writeFile(example, bytes: 44)

    let found = LocalEnginePlan.defaultLoopFile(launcher: build.appending(path: "namchaind").path)
    check(found?.path == example.path,
          "the example capture is found by walking up from the binary that will run")

    // Nothing to walk up to: an installed binary outside a checkout must come back empty rather than
    // inventing a path the app then fails on. Started from `temporaryDirectory()` and not the fixture
    // root, because walking up from the fixture reaches the home directory — which on a machine with
    // a checkout really does answer, and would make this pass for the wrong reason.
    let elsewhere = FileManager.default.temporaryDirectory
        .appending(path: "namchain-no-checkout-\(UUID().uuidString)/bin/namchaind")
    try? FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    writeFile(elsewhere)
    check(LocalEnginePlan.defaultLoopFile(launcher: elsewhere.path) == nil,
          "a binary with no checkout around it finds no example, and says so by returning nothing")

    check(LocalEnginePlan.defaultLoopFile(launcher: "") == nil
            || LocalEnginePlan.defaultLoopFile(launcher: "") != nil,
          "an empty launcher path is answered rather than trapped")
}

func testTheExampleCaptureIsLoadable() {
    // The real file, when this machine has the checkout: it has to be something the daemon will
    // accept at the engine's own rate, or "Use Example Capture" is a button that produces a refusal
    // three layers down.
    guard let example = LocalEnginePlan.defaultLoopFile(launcher: LocalEnginePlan.defaultLauncher()?.path ?? "")
    else {
        print("  skip  no namchain checkout on this machine, so there is no example to check")
        return
    }

    guard let format = wavFormat(at: example) else {
        check(false, "the example capture is a readable WAV (\(example.path))")
        return
    }

    check(true, "the example capture is a readable WAV (\(example.path))")
    check(format.rate == 48000, "…at 48 kHz, the only rate the engine runs at (got \(format.rate))")
    check(format.channels >= 1, "…with at least one channel (got \(format.channels))")
}

/// Read a WAV's `fmt ` chunk: the sample rate and channel count.
///
/// Walked rather than assumed to be the first chunk, because a file written by another tool may put
/// a `LIST` or a `JUNK` ahead of it — which is exactly the kind of file a person picks by hand. This
/// is a dozen lines instead of a call into namchain's own C++ reader because the test harness is a
/// bare `swiftc` invocation, and a C bridge is more machinery than the question deserves.
private func wavFormat(at url: URL) -> (rate: Double, channels: UInt32)? {
    guard let data = try? Data(contentsOf: url), data.count > 12 else { return nil }
    func fourCC(_ offset: Int) -> String? {
        guard offset + 4 <= data.count else { return nil }
        return String(bytes: data[offset..<(offset + 4)], encoding: .ascii)
    }
    func u32(_ offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return data[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    guard fourCC(0) == "RIFF", fourCC(8) == "WAVE" else { return nil }

    var offset = 12
    while offset + 8 <= data.count {
        guard let tag = fourCC(offset), let size = u32(offset + 4) else { return nil }
        if tag == "fmt ", size >= 16, offset + 24 <= data.count {
            let channels = data[offset + 10..<offset + 12].reversed()
                .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard let rate = u32(offset + 12) else { return nil }
            return (Double(rate), channels)
        }
        // Chunks are word-aligned: an odd size is followed by a pad byte.
        offset += 8 + Int(size) + Int(size % 2)
    }
    return nil
}

func testLocalEngineModelRoot() {
    print("which folder the local engine's models come from")

    let first = AssetRoot(path: "/Users/someone/empty")
    let second = AssetRoot(path: "/Users/someone/models")
    let third = AssetRoot(path: "/Users/someone/irs")

    func entry(_ root: AssetRoot, _ relative: String, _ kind: AssetKind) -> AssetEntry {
        AssetEntry(rootID: root.id, relative: relative, kind: kind,
                   name: relative, make: "", model: nil, architecture: nil,
                   sampleRate: nil, channels: nil, frames: nil, size: 0,
                   modified: Date(), addedAt: Date())
    }

    check(localEngineModelsRoot(roots: [], entries: []) == nil,
          "no folders configured means the daemon gets its own empty one")

    // The interesting case: a folder with nothing in it must not shadow one that has the models.
    let entries = [entry(second, "deluxe.nam", .model), entry(third, "cab.wav", .ir)]
    check(localEngineModelsRoot(roots: [first, second, third], entries: entries)?.path == second.path,
          "the first folder that actually holds a model is the one chosen")
    check(localEngineIRsRoot(roots: [first, second, third], entries: entries)?.path == third.path,
          "…and the impulse responses are chosen the same way, independently")

    check(localEngineModelsRoot(roots: [first, third], entries: entries) == nil,
          "a library with no models in it leaves the daemon on its own folder")
    check(localEngineIRsRoot(roots: [first, third], entries: []) == nil,
          "…and so does one with no impulse responses")
}
