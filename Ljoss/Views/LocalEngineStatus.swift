import SwiftUI

// What the local engine is doing, in one line.
//
// It exists as its own view because the same sentence is needed in two places — under the toggle,
// and in the connection header when the session is pointed at the local daemon — and because the
// interesting states are the ones that are not obvious from a switch: adopted (something was already
// there), and failed (with the daemon's own reason).

struct LocalEngineStatus: View {
    /// Taken as a parameter rather than from the environment: this is shown in the settings page,
    /// where the engine is already in hand, and a view that can be handed what it draws is easier to
    /// reason about than one that reaches for it.
    var engine: LocalEngine

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(colour)
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Metrics.minTouchTarget)
    }

    private var colour: Color {
        switch engine.state {
        case .running, .adopted: .green
        case .starting: .yellow
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private var title: String {
        switch engine.state {
        case .stopped: "Not running"
        case .starting: "Starting…"
        case .running: "Running as this app's child"
        case .adopted: "Using a daemon that was already running"
        case .failed: "Could not start"
        }
    }

    private var detail: String? {
        switch engine.state {
        case .stopped:
            "The Mac's output device is not being held by this app."
        case .starting:
            "Waiting for the daemon to answer on its control port."
        case .running(let pid):
            "pid \(pid). Stop the engine here, or quit the app; either closes the device."
        case .adopted:
            "Something was already listening on this port and answered. It was not started by this "
            + "app, so quitting the app will not stop it."
        case .failed(let why):
            why
        }
    }
}
