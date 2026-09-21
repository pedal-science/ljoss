import SwiftUI

// The device: where it is, the secret that gets in, what it is doing, and what it will
// not play.
//
// All of this used to be a popover hanging off the toolbar's Device button, with the
// address and the token one sheet further in. It is a settings page now: the popover is
// gone, and the Device button is a shortcut to here. What the split cost is that the
// health dot still lives on that button — which is the whole point of the dot.

struct HardwareSettingsView: View {
    @Environment(EngineSession.self) private var session

    @State private var host = ""
    @State private var port = String(EngineSettings.defaultPort)
    @State private var token = ""
    @State private var keychainComplaint: String?

    var body: some View {
        Form {
            connection
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
