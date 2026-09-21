import SwiftUI

// The device, as one small control that glows until it doesn't.
//
// `health` is one word the engine derives from its own issues, so the light and the
// list can never disagree. The codes are stable and machine-readable; `EngineWords`
// maps them to words of our own, because the engine's prose names the node and lists
// the alternatives and re-deriving that here is how two clients end up saying
// different things.
//
// It used to open a popover holding everything about the device, with the address and
// the token one sheet further in. That is Settings → Hardware now, and this button is
// the shortcut to it: one control, one destination, and the dot still says at a glance
// what the page says in full.

struct EngineStatusControl: View {
    @Environment(EngineSession.self) private var session

    /// Raised by the toolbar item, which lives in the window rather than on this page.
    var openSettings: () -> Void = {}

    var body: some View {
        Button(action: openSettings) {
            Label {
                Text("Device")
            } icon: {
                HealthDot(health: session.health, isBusy: session.isSending || session.isAdopting)
            }
        }
        .help(summary)
        .accessibilityLabel(Text("Device"))
        .accessibilityValue(Text(summary))
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
///
/// Not private any more: the Hardware settings page shows the same dot next to the
/// words, so the two can never draw a different colour for the same health.
struct HealthDot: View {
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
