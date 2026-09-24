import SwiftUI
import UniformTypeIdentifiers

// The device: where it is, the secret that gets in, what it is doing, and what it will
// not play.
//
// All of this used to be a popover hanging off the toolbar's Device button, with the
// address and the token one sheet further in. It is a settings page now: the popover is
// gone, and the Device button is a shortcut to here. What the split cost is that the
// health dot still lives on that button — which is the whole point of the dot.

struct HardwareSettingsView: View {
    @Environment(EngineSession.self) private var session
    @Environment(LocalEngine.self) private var engine
    @Environment(AssetLibrary.self) private var library

    @State private var host = ""
    @State private var port = String(EngineSettings.defaultPort)
    @State private var token = ""
    @State private var keychainComplaint: String?
    @State private var local = LocalEngineStore.load()

    /// The file picker, and which of the two paths it is filling in.
    ///
    /// Two pieces of state rather than one optional, because `fileImporter`'s own parameters must not
    /// change while it is open: with `allowedContentTypes` derived from the optional, opening the
    /// picker changed the modifier's configuration, SwiftUI treated it as a different importer, and
    /// the sheet came back with its result dropped — a file chosen and then ignored, which is exactly
    /// how it was reported. The type list is now constant and the *mode* is read from state.
    @State private var pickingFile = false
    @State private var pickMode: LocalPath = .loopFile

    private enum LocalPath: Sendable {
        case launcher
        case loopFile
    }

    /// What the picker will offer. A constant, for the reason above. `.wav` for the input and not
    /// `.audio`: the daemon loops a WAV and refuses anything else by name, so offering an MP3 would
    /// be offering a file that cannot work.
    private static let pickerTypes: [UTType] = [.wav, .executable]

    var body: some View {
        Form {
            connection
            localEngine
            inputFile
            localEngineDevice
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
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: Self.pickerTypes) { result in
            guard case .success(let url) = result else { return }
            var updated = local
            switch pickMode {
            case .launcher: updated.launcherPath = url.path
            case .loopFile: updated.loopFilePath = url.path
            }
            local = updated
            LocalEngineStore.save(updated)
            // A file chosen is a decision, and the engine should be running the thing the field now
            // says. Restarting is what makes the choice audible without a second trip to the toggle;
            // an engine that was off stays off.
            if engine.state.isUp {
                engine.stop()
                Task { await engine.start(session: session, settings: updated, library: library) }
            }
        }
    }

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
                        .disabled(!session.settings.isComplete)
                }
                Spacer()
            }
            .frame(minHeight: Metrics.minTouchTarget)
        } header: {
            Text("Connection")
        }
    }

    private var title: String {
        switch session.connection {
        case .offline: "No Device"
        case .connecting: "Connecting…"
        case .online: session.status?.rigName.map { "Playing “\($0)”" } ?? "Connected"
        case .failed: "Could Not Connect"
        }
    }

    private var connectionDetail: String? {
        let address = "\(session.settings.host):\(session.settings.port)"
        switch session.connection {
        case .offline:
            return session.settings.isComplete ? address : "Set up a device below to send this rig to one."
        case .connecting:
            return address
        case .failed(let why):
            return why
        case .online:
            guard let status = session.status, let generation = status.generation else { return address }
            // A reply is an acknowledgement; `audible_generation` catching up is the
            // completion, and during a crossfade the two differ.
            return status.isAdopted
                ? "\(address) · generation \(generation), adopted"
                : "\(address) · generation \(generation), crossfading in"
        }
    }

    // MARK: - The engine this app can run itself

    /// The local engine: a `namchaind` on this machine, looping a WAV into the Mac's output device.
    ///
    /// It is here rather than in a settings area of its own because it is an alternative *device*,
    /// and this page is what the app knows about the device. Turning it on points the session at
    /// `127.0.0.1` and **does not touch the address below**: a user with a board configured keeps it,
    /// and turning the local engine off leaves them pointed at it again.
    @ViewBuilder
    private var localEngine: some View {
        #if os(macOS)
        localEngineForm
        #else
        Section {
            Text("The local engine runs namchaind on this machine, which needs CoreAudio output "
                 + "and a binary the app can start. Neither exists on iOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Local Engine")
        }
        #endif
    }

    #if os(macOS)
    private var localEngineForm: some View {
        Section {
            Toggle("Run namchaind on this Mac", isOn: localToggle)
                .frame(minHeight: Metrics.minTouchTarget)
            LocalEngineStatus(engine: engine)
        } header: {
            Text("Local Engine")
        } footer: {
            Text("Plays a rig through this Mac's output device with no interface attached. The "
                 + "address below is left alone: the local engine is a mode, not a device you have "
                 + "to undo.")
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: local) { _, updated in LocalEngineStore.save(updated) }
    }

    /// The device side of the local engine — which binary, which port, which output. Folded away
    /// until the engine is asked for, because none of it is required to switch the engine on.
    @ViewBuilder
    private var localEngineDevice: some View {
        if local.wantsLocal || engine.state.isUp {
            Section {
                pathRow("namchaind", text: $local.launcherPath,
                        prompt: foundLauncher ?? "Build it, or choose the binary",
                        pick: .launcher)

                LabeledContent("Port") {
                    TextField("Port", value: $local.tcpPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Output device") {
                    TextField("Output device", text: $local.deviceUID,
                              prompt: Text("System default"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Period ceiling") {
                    TextField("Period", value: $local.periodSize, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Engine")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The period is a ceiling rather than a request — the daemon measures the "
                         + "device's own period and uses that, so 1024 is a safe default.")
                    if let log = engine.logURL {
                        Text("The daemon's output is at \(log.path)")
                            .textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: local) { _, updated in LocalEngineStore.save(updated) }
        }
    }

    /// The toggle is a *request*, so it calls the engine rather than writing a flag: "on" means a
    /// process was started (or an existing daemon adopted), and "off" means it was stopped. A run
    /// that failed leaves the switch where the state says it is, with the reason underneath.
    private var localToggle: Binding<Bool> {
        Binding(get: { engine.state.isUp || (local.wantsLocal && engine.state == .starting) },
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
                    }
                })
    }

    /// \brief The input: which WAV the engine loops in place of an instrument.
    ///
    /// Shown whether or not the engine is running, because it is the one thing a person has to
    /// supply. The engine starts with namchain's own example capture already in the field when there
    /// is one, so "switch it on and listen" works without a decision being made first.
    private var inputFile: some View {
        Section {
            pathRow("File", text: $local.loopFilePath,
                    prompt: exampleLoopFile.map { "Example: \(($0.path as NSString).lastPathComponent)" }
                        ?? "A WAV, played in place of an instrument",
                    pick: .loopFile)
            HStack(spacing: 10) {
                Button("Use Example Capture", action: useExampleLoopFile)
                    .disabled(exampleLoopFile == nil || local.loopFilePath == exampleLoopFile?.path)
                Spacer()
            }
            .frame(minHeight: Metrics.minTouchTarget)
        } header: {
            Text("Input")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Looped for as long as the engine runs. A 48 kHz mono or stereo WAV; anything "
                     + "else is refused by name rather than played at the wrong speed.")
                if exampleLoopFile == nil {
                    Text("namchain's example capture was not found beside the namchaind binary, so "
                         + "there is nothing to fall back to — choose a WAV.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The binary the app would find for itself, shown as the prompt so "empty" is not a mystery.
    private var foundLauncher: String? {
        LocalEnginePlan.defaultLauncher()?.path
    }

    /// The example capture that would be used, if there is one. Shown as a hint so a blank field is
    /// not a mystery, and it is what decides whether the reset button does anything.
    private var exampleLoopFile: URL? {
        LocalEnginePlan.defaultLoopFile(launcher: local.launcherPath)
    }

    private func useExampleLoopFile() {
        guard let example = exampleLoopFile else { return }
        var updated = local
        updated.loopFilePath = example.path
        local = updated
        LocalEngineStore.save(updated)
    }

    private func pathRow(_ name: String, text: Binding<String>, prompt: String,
                         pick: LocalPath) -> some View {
        LabeledContent(name) {
            HStack(spacing: 8) {
                TextField(name, text: text, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .truncationMode(.head)
                Button("Choose…") { pickMode = pick; pickingFile = true }
                    .controlSize(.small)
            }
        }
    }
    #else
    /// iOS has no local engine, so there is no input to choose. See `localEngine`.
    @ViewBuilder
    private var inputFile: some View { EmptyView() }

    @ViewBuilder
    private var localEngineDevice: some View { EmptyView() }
    #endif

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
            Text("The address of the machine running namchaind, and its tcp_port.")
        }
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
                Text("The token is the one in the device's namchaind.json, or the first line "
                     + "of its tcp_token_file. The connection is not encrypted and the token "
                     + "travels in it: off a network you trust, tunnel it.")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Saving is a button rather than every keystroke: the token goes to the keychain, and
    /// writing it once per character is not what a keychain is for.
    private var save: some View {
        Section {
            HStack(spacing: 10) {
                Button("Save") { save(andConnect: false) }
                    .disabled(proposed == session.settings)
                Button("Connect") { save(andConnect: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!proposed.isComplete)
                Spacer()
            }
            .frame(minHeight: Metrics.minTouchTarget)
        } footer: {
            Text(proposed == session.settings
                 ? "These are the settings the app is using."
                 : "Save remembers them; Connect saves them and connects now.")
        }
    }

    private var proposed: EngineSettings {
        EngineSettings(host: host.trimmingCharacters(in: .whitespaces),
                       port: UInt16(port) ?? EngineSettings.defaultPort,
                       token: token)
    }

    private func load() {
        host = session.settings.host
        port = String(session.settings.port)
        token = session.settings.token
        // The input field shows what the engine would loop, so an empty one is filled with the
        // example the moment the page is opened — the engine does the same at start, and a field
        // that disagrees with it is worse than one that is ahead of it. Resolved rather than read
        // from the macOS-only helper above, because this runs on both platforms and the local
        // engine's preferences are in the store either way.
        if local.loopFilePath.trimmingCharacters(in: .whitespaces).isEmpty,
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
