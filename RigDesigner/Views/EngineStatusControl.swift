import SwiftUI

// The device, as one small control that glows until it doesn't.
//
// `health` is one word the engine derives from its own issues, so the light and the
// list can never disagree. The codes are stable and machine-readable; this maps them
// to words of our own and shows the engine's message underneath, because the engine's
// prose names the node and lists the alternatives and re-deriving that here is how
// two clients end up saying different things.

struct EngineStatusControl: View {
    @Environment(EngineSession.self) private var session
    @State private var showingDetail = false
    @State private var showingSettings = false

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            Label {
                Text("Device")
            } icon: {
                HealthDot(health: session.health, isBusy: session.isSending || session.isAdopting)
            }
        }
        .help(summary)
        .accessibilityLabel(Text("Device"))
        .accessibilityValue(Text(summary))
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            EngineStatusDetail(editSettings: {
                // Dismiss the popover first: a sheet presented from inside one is
                // anchored to the popover, so it hangs off the window's edge instead
                // of sitting over the window the way a sheet should.
                showingDetail = false
                showingSettings = true
            })
            .environment(session)
            // Narrow on purpose: this hangs off a right-hand toolbar item, so a
            // wide popover runs off the edge of the window.
            .frame(width: 300)
            .frame(maxHeight: 520)
        }
        .sheet(isPresented: $showingSettings) {
            ConnectionSettingsView()
                .environment(session)
        }
    }

    private var summary: String {
        switch session.connection {
        case .offline: "No device connected"
        case .connecting: "Connecting…"
        case .failed(let why): why
        case .online:
            if !session.refusals.isEmpty { "\(session.refusals.count) thing(s) this device cannot play" }
            else if session.isAdopting { "Crossfading into the new rig" }
            else { session.issues.isEmpty ? "Connected and healthy" : session.issues[0].code }
        }
    }
}

/// The glow. Amber while a change is on its way in, because a structural edit is
/// dual-rendered and crossfaded rather than instant, and the player can hear it.
private struct HealthDot: View {
    let health: String
    let isBusy: Bool

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 11, height: 11)
            .overlay {
                Circle().strokeBorder(colour.opacity(0.35), lineWidth: isBusy ? 4 : 0)
            }
            .animation(.easeInOut(duration: 0.25), value: isBusy)
            .animation(.easeInOut(duration: 0.25), value: health)
    }

    private var colour: Color {
        switch health {
        case "ok": isBusy ? .orange : .green
        case "warn": .orange
        case "error": .red
        default: .secondary
        }
    }
}

// MARK: - The detail

struct EngineStatusDetail: View {
    @Environment(EngineSession.self) private var session

    /// Raised by the toolbar item, which lives in the window rather than in this
    /// popover, so the settings sheet is presented over the window.
    var editSettings: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connection
                if !session.refusals.isEmpty { refusals }
                if let failure = session.lastFailure { refusal(failure) }
                if !session.issues.isEmpty { issues }
                if let status = session.status { device(status) }
                actions
            }
            .padding(18)
        }
    }

    // MARK: Sections

    private var connection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let detail = connectionDetail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            return session.settings.isComplete ? address : "Set up a device to send this rig to one."
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

    /// What this app already knows the device cannot play, before anything is sent.
    private var refusals: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not sent", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(session.refusals, id: \.text) { refusal in
                Text(refusal.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The rest of the rig is held back until these are resolved: a document is applied whole or not at all.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The device's own words, shown verbatim.
    private func refusal(_ failure: EngineFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(EngineWords.title(for: failure.code), systemImage: "xmark.octagon.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text(failure.message)
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var issues: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Device").font(.subheadline.weight(.semibold))
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
            }
        }
    }

    /// Everything here is startup configuration on the device, in its
    /// `namchaind.json`. It is shown because it explains what a rig can ask for, and
    /// it is read-only because changing it means restarting the daemon.
    private func device(_ status: EngineStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio").font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                row("State", status.state ?? "—")
                if let rate = status.sampleRate, let period = status.periodSize {
                    row("Clock", "\(rate) Hz · \(period) frames")
                }
                row("Channels", "\(status.captureChannels ?? 1) in, \(status.playbackChannels ?? 1) out")
                if let xruns = status.xruns { row("Xruns", "\(xruns)") }
            }
            .font(.callout)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private var actions: some View {
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
            Button("Settings…", action: editSettings)
        }
        .frame(minHeight: Metrics.minTouchTarget)
    }
}

// MARK: - Words for the engine's codes

/// The engine publishes stable codes precisely so a client can say this in its own
/// words rather than pattern-matching English. An unknown code falls back to the code
/// itself, which is better than pretending to understand it.
enum EngineWords {

    static func title(for code: String) -> String {
        switch code {
        case "device_lost": "The audio device is not open"
        case "node_failed": "A block was taken out of the signal path"
        case "xruns": "The device has missed deadlines recently"
        case "render_errors": "The device reported render errors recently"
        case "not_realtime": "Not running at real-time priority"
        case "memory_not_locked": "Memory is not locked"
        case "transition": "Crossfading into the new rig"
        case "models_root_missing": "The amp model folder is missing"
        case "irs_root_missing": "The impulse response folder is missing"

        case "compile_failed": "The device could not build this rig"
        case "patch_rejected": "The device refused that change"
        case "asset_missing": "The device does not have that model"
        case "path_refused": "A file path was refused"
        case "unknown_chain": "The device does not have that chain"
        case "unauthorized": "The token was not accepted"
        case "message_too_large": "That rig is too large to send"
        case "too_many_connections": "The device has no free connections"
        case "unsupported_protocol": "The device speaks a different protocol version"
        default: code
        }
    }

    static func symbol(for severity: String?) -> String {
        switch severity {
        case "error": "xmark.octagon.fill"
        case "warn": "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    static func colour(for severity: String?) -> Color {
        switch severity {
        case "error": .red
        case "warn": .orange
        default: .secondary
        }
    }
}
