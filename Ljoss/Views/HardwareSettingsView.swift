import SwiftUI
import UniformTypeIdentifiers

// The device: where it is, the secret that gets in, what it is doing, and what it will
// not play.
//
// All of this used to be a popover hanging off the toolbar's Device button, with the
// address and the token one sheet further in. It is a settings page now: the popover is
// gone, and the Device button is a shortcut to here. What the split cost is that the
// health dot still lives on that button — which is the whole point of the dot.
//
// The page has two ways of being a device, and they are alternatives. **Connect to this
// computer** runs `namchaind` on this Mac and points the session at it; the address, port and
// token are for a board somewhere else. While the first is on, the second is disabled rather
// than hidden (the configuration is kept, not discarded) and both "Connect" buttons go with
// it — one of them would otherwise save `127.0.0.1` and this daemon's token over the device's
// settings, which is the failure the mode has to avoid.

struct HardwareSettingsView: View {
    @Environment(EngineSession.self) private var session
    @Environment(LocalEngine.self) private var engine
    @Environment(AssetLibrary.self) private var library

    @State private var host = ""
    @State private var port = String(EngineSettings.defaultPort)
    @State private var token = ""
    @State private var keychainComplaint: String?

    /// The local engine's preferences, held as state so the page redraws when they change; the store
    /// is written on every change, because a choice that is not written down is not a choice the next
    /// launch can honour.
    @State private var local = LocalEngineStore.load()
    /// The Mac's devices, read when the page appears and when the mode is switched on. Held rather
    /// than read in `body`: each read is a HAL round trip, and a view body is not the place for one.
    ///
    /// Behind `os(macOS)` because the type exists only there: `CoreAudioDevices.swift` is the HAL's
    /// device list, and iOS has neither that enumeration nor a `namchaind` to hand it to. These two
    /// declarations, not CoreAudio itself, were the whole of the iOS build's failure — the page's
    /// iOS half stubs the pickers below and never reads either list.
    #if os(macOS)
    @State private var inputs: [CoreAudioDevice] = []
    @State private var outputs: [CoreAudioDevice] = []
    #endif
    /// The two file pickers. Separate booleans rather than one with a mode, because a picker's own
    /// parameters must not change while it is open: sharing one importer between the WAV and the
    /// binary made SwiftUI treat it as a different importer and drop the chosen file (the parked
    /// work's note, and the reason this is spelled out).
    @State private var pickingLoopFile = false
    @State private var pickingLauncher = false

    var body: some View {
        Form {
            localEngine
            connection
            if localMode { localEngineSettings }
            if localMode && local.inputDeviceUID.isEmpty { localLoopFile }
            address
            tokenSection

            if let keychainComplaint {
                Section {
                    Label(keychainComplaint, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            save

            if !session.refusals.isEmpty { refusals }
            if let failure = session.lastFailure { refusal(failure) }
            if !session.issues.isEmpty { issues }
            if let status = session.status { device(status) }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: local.wantsLocal) { _, on in
            // The device fields show one thing or the other depending on this, so they are re-read
            // when it flips rather than left showing the mode that is no longer in play.
            load()
            if on { refreshDevices() }
        }
        .fileImporter(isPresented: $pickingLoopFile, allowedContentTypes: [.wav]) { result in
            guard case .success(let url) = result else { return }
            var updated = local
            updated.loopFilePath = url.path
            apply(updated, restarting: true)
        }
        .fileImporter(isPresented: $pickingLauncher, allowedContentTypes: [.executable]) { result in
            guard case .success(let url) = result else { return }
            var updated = local
            updated.launcherPath = url.path
            apply(updated, restarting: true)
        }
    }

    // MARK: - Connecting to this computer

    /// True while this app is the device. The user's *intent*, not the daemon's state: a run that
    /// failed leaves the switch on with the reason under it, which is what somebody who just turned it
    /// on needs to see. `LocalEngineStatus` is what says whether it worked.
    private var localMode: Bool { local.wantsLocal }

    @ViewBuilder
    private var localEngine: some View {
        #if os(macOS)
        Section {
            Toggle("Connect to this computer", isOn: localToggle)
                .frame(minHeight: Metrics.minTouchTarget)
            if localMode {
                inputPicker
                outputPicker
            }
            LocalEngineStatus(engine: engine)
        } header: {
            Text("This Mac")
        } footer: {
            Text("Runs namchaind here and plays the rig through an audio device on this Mac — no board, "
                 + "no network. Pick the input your instrument is plugged into and the output you listen "
                 + "on; they are often the same interface. The address and token below are a different "
                 + "device and are not used while this is on.")
            .fixedSize(horizontal: false, vertical: true)
        }
        .task { refreshDevices() }
        #else
        EmptyView()
        #endif
    }

    #if os(macOS)
    /// The switch is a *request*: on means "start one (or use the one that is already there)", off
    /// means "stop it and let go of the audio device". It reads the stored intent rather than the
    /// daemon's state so that it does not flick back under the hand of someone who just turned it on.
    private var localToggle: Binding<Bool> {
        Binding(get: { local.wantsLocal },
                set: { wanted in
                    var updated = local
                    updated.wantsLocal = wanted
                    local = updated
                    LocalEngineStore.save(updated)
                    if wanted {
                        Task { await engine.start(session: session, settings: updated, library: library) }
                    } else {
                        engine.stop()
                        session.disconnect()
                        // The session was pointed at 127.0.0.1 with the daemon's token. Put the device
                        // this app remembers back, so a later Connect talks to the board rather than to
                        // a daemon that is no longer running — and so the fields below are the device's
                        // again rather than the loopback address.
                        session.settings = EngineSettingsStore.load()
                        load()
                    }
                })
    }

    /// \brief Which input the daemon captures, or none.
    ///
    /// "None" is a real choice and not an absence: it means the engine loops a WAV instead, which is
    /// what makes the mode useful on a Mac with no interface attached (and on a machine whose
    /// microphone one would rather not open). It is the empty UID, which is exactly what the daemon's
    /// `--capture-path` form means.
    private var inputPicker: some View {
        LabeledContent("Audio input") {
            Picker("Audio input", selection: inputSelection) {
                Text("None — loop a WAV").tag("")
                ForEach(inputs) { device in
                    Text(label(for: device, channels: device.inputChannels, suffix: "in")).tag(device.uid)
                }
                // A device that has been unplugged since it was chosen: kept in the list, and named,
                // so the choice is visible rather than silently becoming "None".
                if !local.inputDeviceUID.isEmpty,
                   !inputs.contains(where: { $0.uid == local.inputDeviceUID }) {
                    Text("\(local.inputDeviceName.isEmpty ? local.inputDeviceUID : local.inputDeviceName) (not connected)")
                        .tag(local.inputDeviceUID)
                }
            }
            .labelsHidden()
        }
    }

    private var outputPicker: some View {
        LabeledContent("Audio output") {
            Picker("Audio output", selection: outputSelection) {
                Text("System default").tag("")
                ForEach(outputs) { device in
                    Text(label(for: device, channels: device.outputChannels, suffix: "out")).tag(device.uid)
                }
            }
            .labelsHidden()
        }
    }

    private func label(for device: CoreAudioDevice, channels: Int, suffix: String) -> String {
        channels > 1 ? "\(device.name) (\(channels) \(suffix))" : device.name
    }

    private var inputSelection: Binding<String> {
        Binding(get: { local.inputDeviceUID },
                set: { uid in
                    var updated = local
                    updated.inputDeviceUID = uid
                    // The name is kept beside the UID so the page can say what was chosen without
                    // asking the HAL, and so a device that has gone still has a name to show.
                    updated.inputDeviceName = inputs.first { $0.uid == uid }?.name ?? ""
                    apply(updated, restarting: true)
                })
    }

    private var outputSelection: Binding<String> {
        Binding(get: { local.outputDeviceUID },
                set: { uid in
                    var updated = local
                    updated.outputDeviceUID = uid
                    apply(updated, restarting: true)
                })
    }

    /// What the daemon is started with: which binary, which port, and the period *ceiling* (the
    /// backend measures the device's own period, so this is not a request).
    private var localEngineSettings: some View {
        Section {
            LabeledContent("namchaind") {
                HStack(spacing: 8) {
                    TextField("namchaind", text: launcherBinding,
                              prompt: Text(LocalEnginePlan.defaultLauncher()?.path ?? "Build it, or choose the binary"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Choose…") { pickingLauncher = true }
                        .controlSize(.small)
                }
            }
            LabeledContent("Port") {
                TextField("Port", value: portBinding, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Period ceiling") {
                TextField("Period", value: periodBinding, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Device buffer") {
                Picker("Device buffer", selection: bufferBinding) {
                    ForEach(Self.bufferChoices, id: \.self) { frames in
                        Text("\(frames) frames · \(Self.milliseconds(frames)) ms").tag(frames)
                    }
                    // A value that was set by hand, or stored by an older build: kept so the picker
                    // shows what is actually in force rather than silently choosing something else.
                    if !Self.bufferChoices.contains(local.deviceBufferFrames) {
                        Text("\(local.deviceBufferFrames) frames").tag(local.deviceBufferFrames)
                    }
                }
                .labelsHidden()
            }
            HStack(spacing: 10) {
                Button("Refresh Devices", action: refreshDevices)
                Spacer()
            }
            .frame(minHeight: Metrics.minTouchTarget)
        } header: {
            Text("Engine")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("The device buffer is what the daemon asks the interface for, and it is most of the "
                     + "latency you feel: 32 frames is under a millisecond, 512 is eleven. The daemon puts "
                     + "the device's previous value back when it stops. The period ceiling is a limit on "
                     + "the plan, not a request — the Audio row below shows the period the device actually "
                     + "gave. The binary, port and ceiling are used the next time the engine starts; turn "
                     + "the switch off and on to restart it.")
                if let log = engine.logURL {
                    Text("The daemon's output is at \(log.path)")
                        .textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The WAV the engine loops when no input device is chosen. Shown whether or not the engine is
    /// running, because it is the one thing a person has to supply in that case.
    private var localLoopFile: some View {
        Section {
            LabeledContent("WAV") {
                HStack(spacing: 8) {
                    TextField("WAV", text: loopFileBinding,
                              prompt: Text(exampleLoopFile.map { "Example: \(($0.path as NSString).lastPathComponent)" }
                                           ?? "A WAV, played in place of an instrument"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Choose…") { pickingLoopFile = true }
                        .controlSize(.small)
                }
            }
            HStack(spacing: 10) {
                Button("Use Example Capture", action: useExampleLoopFile)
                    .disabled(exampleLoopFile == nil || local.loopFilePath == exampleLoopFile?.path)
                Spacer()
            }
            .frame(minHeight: Metrics.minTouchTarget)
        } header: {
            Text("Input File")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Looped for as long as the engine runs. A 48 kHz mono or stereo WAV; anything else "
                     + "is refused by name rather than played at the wrong speed.")
                if exampleLoopFile == nil {
                    Text("namchain's example capture was not found beside the namchaind binary, so there "
                         + "is nothing to fall back to — choose a WAV.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var launcherBinding: Binding<String> {
        Binding(get: { local.launcherPath },
                set: { path in
                    var updated = local
                    updated.launcherPath = path
                    apply(updated, restarting: false)
                })
    }

    private var portBinding: Binding<UInt16> {
        Binding(get: { local.tcpPort },
                set: { value in
                    var updated = local
                    updated.tcpPort = value
                    apply(updated, restarting: false)
                })
    }

    /// rief The buffer sizes worth offering. 32 is the default and the point of the exercise (0.67
    /// ms at 48 kHz); 15 is the SSL 2+ Mk II's floor and is not offered because a period that short
    /// leaves almost nothing for the engine to work in; the larger values are there for an interface
    /// that will not go lower, and 0 means "leave my device alone".
    private static let bufferChoices: [UInt16] = [0, 32, 64, 128, 256, 512]

    private static func milliseconds(_ frames: UInt16) -> String {
        String(format: "%.2f", Double(frames) / 48.0)
    }

    private var bufferBinding: Binding<UInt16> {
        Binding(get: { local.deviceBufferFrames },
                set: { frames in
                    var updated = local
                    updated.deviceBufferFrames = frames
                    apply(updated, restarting: true)
                })
    }

    private var periodBinding: Binding<UInt16> {
        Binding(get: { local.periodSize },
                set: { value in
                    var updated = local
                    updated.periodSize = value
                    apply(updated, restarting: false)
                })
    }

    private var loopFileBinding: Binding<String> {
        Binding(get: { local.loopFilePath },
                set: { path in
                    var updated = local
                    updated.loopFilePath = path
                    apply(updated, restarting: false)
                })
    }

    /// The example capture that would be used, if there is one: shown as a prompt so a blank field is
    /// not a mystery, and it is what decides whether the reset button does anything.
    private var exampleLoopFile: URL? {
        LocalEnginePlan.defaultLoopFile(launcher: local.launcherPath)
    }

    private func useExampleLoopFile() {
        guard let example = exampleLoopFile else { return }
        var updated = local
        updated.loopFilePath = example.path
        apply(updated, restarting: true)
    }

    /// Write a changed preference down, and — for a choice that someone made in order to *hear*
    /// something different — restart the engine so the change is audible without a second trip to the
    /// switch. A change that only matters at startup (the binary, the port, the period) is written and
    /// left for the next start; the footer says so.
    private func apply(_ updated: LocalEngineSettings, restarting: Bool) {
        local = updated
        LocalEngineStore.save(updated)
        guard restarting, engine.state.isUp || engine.state == .starting else { return }
        engine.stop()
        Task { await engine.start(session: session, settings: updated, library: library) }
    }

    private func refreshDevices() {
        inputs = CoreAudioDevices.inputs()
        outputs = CoreAudioDevices.outputs()
        // Nothing chosen yet: prefer the interface the guitar is most likely plugged into — a device
        // that has both directions, and the one the system calls the default if there is one. A
        // default is a convenience here, not an assumption: it is written down like any other choice
        // and the picker shows it.
        //
        // Only while the mode is on. Merely opening this page is not a decision to run a daemon, and
        // a preference written before it was asked for is one the user never made.
        if localMode, local.inputDeviceUID.isEmpty {
            let preferred = inputs.first { $0.inputChannels > 0 && $0.outputChannels > 0 }
                ?? inputs.first { $0.uid == CoreAudioDevices.defaultInputUID() }
                ?? inputs.first
            if let preferred {
                var updated = local
                updated.inputDeviceUID = preferred.uid
                updated.inputDeviceName = preferred.name
                local = updated
                LocalEngineStore.save(updated)
            }
        }
    }
    #else
    /// iOS has no `namchaind` and no device for a child process to hold, so there is nothing to show
    /// and nothing to pick. See `localEngine`.
    private var inputPicker: some View { EmptyView() }
    private var outputPicker: some View { EmptyView() }
    private var localEngineSettings: some View { EmptyView() }
    private var localLoopFile: some View { EmptyView() }
    private var localToggle: Binding<Bool> { .constant(false) }
    private func apply(_ updated: LocalEngineSettings, restarting: Bool) {}
    private func refreshDevices() {}
    #endif

    // MARK: - Connection

    private var connection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                HealthDot(health: session.health, isBusy: session.isSending || session.isAdopting)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    if let detail = connectionDetail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                if session.connection.isOnline {
                    Button("Re-send Rig") { Task { await session.resend() } }
                        .disabled(session.isSending)
                    Button("Disconnect") { session.disconnect() }
                } else {
                    Button("Connect") { Task { await session.connect() } }
                        .buttonStyle(.borderedProminent)
                        // A device connection is not what this page is doing while this Mac is the
                        // device: the switch above is, and there is nothing to type.
                        .disabled(!session.settings.isComplete || localMode)
                }
                Spacer()
            }
            .frame(minHeight: Metrics.minTouchTarget)
        } header: {
            Text("Connection")
        }
    }

    private var title: String {
        if localMode, !session.connection.isOnline { return "This Mac" }
        return switch session.connection {
        case .offline: "No Device"
        case .connecting: "Connecting…"
        case .online: session.status?.rigName.map { "Playing “\($0)”" } ?? "Connected"
        case .failed: localMode ? "This Mac" : "Could Not Connect"
        }
    }

    private var connectionDetail: String? {
        let address = "\(session.settings.host):\(session.settings.port)"
        switch session.connection {
        case .offline:
            if localMode { return "namchaind on 127.0.0.1:\(local.tcpPort)" }
            return session.settings.isComplete ? address : "Set up a device below to send this rig to one."
        case .connecting:
            return localMode ? "Starting namchaind and connecting to it…" : address
        case .failed(let why):
            return session.isRetrying ? "\(why) Trying again." : why
        case .online:
            guard let status = session.status, let generation = status.generation else { return address }
            // A reply is an acknowledgement; `audible_generation` catching up is the
            // completion, and during a crossfade the two differ.
            return status.isAdopted
                ? "\(address) · generation \(generation), adopted"
                : "\(address) · generation \(generation), crossfading in"
        }
    }

    // MARK: - Where it is

    private var address: some View {
        Section {
            LabeledContent("Host") {
                // `labelsHidden` plus an explicit prompt: a bare `TextField(title, text:)`
                // inside a `LabeledContent` draws its title *beside* the value rather than
                // as a placeholder, so the field ends up saying everything twice.
                TextField("Host", text: $host, prompt: Text("studio.local"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
            }
            LabeledContent("Port") {
                TextField("Port", text: $port, prompt: Text(String(EngineSettings.defaultPort)))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
        } header: {
            Text("Address")
        } footer: {
            Text(localMode
                 ? "Not used while Connect to this computer is on. These are the device this app remembers."
                 : "The address of the machine running namchaind, and its tcp_port.")
        }
        .disabled(localMode)
    }

    private var tokenSection: some View {
        Section {
            SecureField("Token", text: $token, prompt: Text("Paste the device's token"))
                .labelsHidden()
                .frame(minHeight: Metrics.minTouchTarget)
        } header: {
            Text("Token")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if !token.isEmpty && token.count < EngineSettings.minimumTokenLength {
                    Text("\(token.count) of \(EngineSettings.minimumTokenLength) characters. "
                         + "The device refuses a shorter one.")
                        .foregroundStyle(.orange)
                }
                if localMode {
                    Text("Not used while Connect to this computer is on: the daemon this app starts is "
                         + "given a token of its own, and this one is not touched.")
                } else {
                    Text("The token is the one in the device's namchaind.json, or the first line "
                         + "of its tcp_token_file. The connection is not encrypted and the token "
                         + "travels in it: off a network you trust, tunnel it.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(localMode)
    }

    /// Saving is a button rather than every keystroke: the token goes to the keychain, and
    /// writing it once per character is not what a keychain is for.
    private var save: some View {
        Section {
            HStack(spacing: 10) {
                Button("Save") { save(andConnect: false) }
                    .disabled(proposed == session.settings || localMode)
                Button("Connect") { save(andConnect: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!proposed.isComplete || localMode)
                Spacer()
            }
            .frame(minHeight: Metrics.minTouchTarget)
        } footer: {
            Text(localMode
                 ? "Not used while Connect to this computer is on."
                 : (proposed == session.settings
                    ? "These are the settings the app is using."
                    : "Save remembers them; Connect saves them and connects now."))
        }
    }

    private var proposed: EngineSettings {
        EngineSettings(host: host.trimmingCharacters(in: .whitespaces),
                       port: UInt16(port) ?? EngineSettings.defaultPort,
                       token: token)
    }

    private func load() {
        // Which settings these fields are *of* depends on the mode. While this Mac is the device the
        // session holds `127.0.0.1` and the daemon's generated token, and showing those here would
        // both mislead and invite the Save button to write them over the real device — so they are the
        // app's stored device instead, which is exactly what turning the mode off goes back to.
        let shown = localMode ? EngineSettingsStore.load() : session.settings
        host = shown.host
        port = String(shown.port)
        token = shown.token

        // The input field shows what the engine would loop, so an empty one is filled with the
        // example the moment the page is opened — the engine does the same at start, and a field
        // that disagrees with it is worse than one that is ahead of it.
        if local.inputDeviceUID.isEmpty,
           local.loopFilePath.trimmingCharacters(in: .whitespaces).isEmpty,
           let example = LocalEnginePlan.defaultLoopFile(launcher: local.launcherPath) {
            local.loopFilePath = example.path
            LocalEngineStore.save(local)
        }
    }

    private func save(andConnect connect: Bool) {
        let settings = proposed
        keychainComplaint = EngineSettingsStore.save(settings)
        session.settings = settings
        // A failed keychain write is worth saying, but it does not stop this session
        // working — it only means the token is gone on the next launch.
        guard connect else { return }
        Task { await session.connect() }
    }

    // MARK: - What the device says

    /// What this app already knows the device cannot play, before anything is sent.
    private var refusals: some View {
        Section {
            ForEach(session.refusals, id: \.text) { refusal in
                Text(refusal.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Label("Not Sent", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } footer: {
            Text("The rest of the rig is held back until these are resolved: a document is applied whole or not at all.")
        }
    }

    /// The device's own words, shown verbatim.
    private func refusal(_ failure: EngineFailure) -> some View {
        Section {
            Text(failure.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Label(EngineWords.title(for: failure.code), systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var issues: some View {
        Section {
            ForEach(session.issues) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: EngineWords.symbol(for: issue.severity))
                        .foregroundStyle(EngineWords.colour(for: issue.severity))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(EngineWords.title(for: issue.code)).font(.callout)
                        if let message = issue.message {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if let count = issue.count, count > 1 {
                        Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: Metrics.minTouchTarget)
            }
        } header: {
            Text("Device")
        }
    }

    /// Everything here is startup configuration on the device, in its `namchaind.json`. It
    /// is shown because it explains what a rig can ask for, and it is read-only because
    /// changing it means restarting the daemon.
    private func device(_ status: EngineStatus) -> some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                row("State", status.state ?? "—")
                if let rate = status.sampleRate, let period = status.periodSize {
                    row("Clock", "\(rate) Hz · \(period) frames")
                }
                row("Channels", "\(status.captureChannels ?? 1) in, \(status.playbackChannels ?? 1) out")
                if let xruns = status.xruns { row("Xruns", "\(xruns)") }
            }
            .font(.callout)
        } header: {
            Text("Audio")
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
