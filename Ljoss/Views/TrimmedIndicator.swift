import SwiftUI

// The two places the cost table becomes something a player can see.
//
// **The rig being heard may not be the rig it names.** D6: trimming is Full → Lite, the two are
// separately trained networks measured 9 to 40 dB apart, so a trimmed rig sounds different from
// the one the document describes. The engine reports it; this shows it — in the toolbar, beside
// the device control, because the whole point is that it is readable *while playing* and a
// detail view is one nobody has open.
//
// **The rig being edited may be one the device will not play at all.** P5: a rig over the
// table's headroom even with its dearest models on Lite is refused, so it is never sent. It
// stays editable — that is how it gets fixed — and the notice over the canvas is what says
// which of the two the player is looking at.

/// The running rig has at least one model on Lite: a different network, so a different sound
/// from the one the rig names (D6).
///
/// Added to the toolbar only while there is something to say, so the chip is not a permanently
/// empty control.
struct TrimmedIndicator: View {
    @Environment(EngineSession.self) private var session
    /// The document this app last sent, which is what turns the engine's block ids back into
    /// the names on the tiles. Nil has an answer too: the model reference.
    var rig: Rig?

    var body: some View {
        if let trimmed = session.status?.trimmedRig(in: rig) {
            Label {
                Text(trimmed.label)
            } icon: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .help(trimmed.detail)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Playing trimmed"))
            .accessibilityValue(Text(trimmed.detail))
        }
    }
}

/// The rig on the canvas is one the device will not publish: over the cost table's headroom
/// even after trimming (P5).
///
/// It is **editable and not playing**, and both halves of that matter. The device is still on
/// the rig it had, so nothing has been lost and nothing has to be undone; and the rig is still
/// open, because removing the block that made it too big is the fix, and a rig nobody can open
/// is a rig nobody can fix.
struct RigCostNotice: View {
    @Environment(EngineSession.self) private var session
    var rig: Rig

    var body: some View {
        if let report = session.costReport(for: rig.id), report.isOver {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Too big for this device — not playing")
                        .font(.subheadline.weight(.semibold))
                    Text(report.refusalReason
                         + " The device is still playing the rig it had; this one plays as soon as it fits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.orange.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous))
            .padding(.horizontal, Metrics.canvasPadding)
            .padding(.top, 12)
            .accessibilityElement(children: .combine)
        }
    }
}
