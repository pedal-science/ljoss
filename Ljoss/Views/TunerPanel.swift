import SwiftUI

// The tuner, in the left column: the note, a strobe, and the switch.
//
// While this is on screen the app is mounting a tuner node after each chain's input and that node's
// output is silence, so the rig is muted for exactly as long as the panel is up (namchain
// docs/tuner.md; `EngineSession.setTunerVisible` is what does it). The switch opens it: the input then
// passes through unchanged and the display carries on, which is how a player tunes with the rig
// audible. Closing the panel unmounts the node again.
//
// The strobe is the part that makes it a strobe tuner: three rows for partials 1, 2 and 4 of the
// note, labelled 1x, 2x and 4x. Row k drifts k times as fast as the fundamental, so the bottom row
// shows an error the top one barely shows, and in tune every row stands still. The law is in
// `TunerStrobe` (Foundation only, tested); this file draws bands and nothing else.
//
// The panel reads three separate facts and never confuses them: `available` (the engine has
// answered), `running` (the engine really is running the node) and `valid` (there is a note the
// engine trusts). The middle one is the one a player must not be left guessing about.
struct TunerPanel: View {
    @Environment(EngineSession.self) private var session

    private var reading: TunerReading { session.tuner.reading }
    private var strobe: TunerStrobe { session.tuner.strobe }
    private var muted: Bool { session.tunerMuted }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            note
            needleBar
            StrobeRows(strobe: strobe, valid: reading.valid)
                .frame(height: 52)
            numbers
            switchRow
            stateLine
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Tuner", systemImage: "tuningfork")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if !reading.a4Text.isEmpty {
                Text(reading.a4Text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var note: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(reading.noteText.isEmpty ? "—" : reading.noteText)
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .foregroundStyle(reading.inTune ? Color.green : (reading.valid ? Color.primary : Color.secondary))
                .monospacedDigit()
            if !reading.centsText.isEmpty {
                Text(reading.centsText)
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(reading.inTune ? Color.green : Color.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(reading.noteText.isEmpty ? "No note" : "\(reading.noteText), \(reading.centsText) cents"))
    }

    /// The coarse read: half a semitone either side, with the in-tune band drawn rather than said.
    private var needleBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let half = width / 2
            let bandRotation = (TunerReading.inTuneCents / TunerReading.maxCents) * half
            ZStack {
                Capsule().fill(.quaternary).frame(height: 6)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: bandRotation * 2, height: 18)
                Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1, height: 18)
                if let needle = reading.needle {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(reading.inTune ? Color.green : Color.accentColor)
                        .frame(width: 3, height: 18)
                        .offset(x: needle * half)
                }
            }
            .frame(width: width, height: 18)
            .animation(.easeOut(duration: 0.05), value: reading.needle)
        }
        .frame(height: 18)
        .opacity(reading.running ? 1 : 0.4)
    }

    private var numbers: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(reading.hzText).font(.subheadline).monospacedDigit()
                Spacer()
                Text(reading.levelText)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // The input's level, so "nothing is plugged in" is visible as an empty bar.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(reading.levelFraction > 0.95 ? Color.red
                              : reading.levelFraction > 0.8 ? Color.yellow : Color.green)
                        .frame(width: geometry.size.width * reading.levelFraction)
                }
            }
            .frame(height: 6)
        }
        .opacity(reading.running ? 1 : 0.4)
    }

    /// The switch. It shows the player's intent, which is the session's; the engine's own answer is
    /// `reading.muted`, and the two disagreeing is what a refused patch looks like.
    private var switchRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await session.setTunerMuted(!muted) }
            } label: {
                Label(muted ? "Muted" : "Audible",
                      systemImage: muted ? "speaker.slash" : "speaker.wave.2")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(muted ? .secondary : .orange)
            .help(muted ? "Open the tuner's switch: the rig is audible while the display carries on"
                        : "Close the switch: the tuner mutes the rig")
            .disabled(!session.tuner.isSupported || !reading.running)
            Spacer()
        }
    }

    @ViewBuilder
    private var stateLine: some View {
        if !reading.running {
            // The failure that matters: the panel is up and the amp is still audible.
            Text(reading.status)
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if !reading.valid {
            Text(reading.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if !muted {
            Text("The rig is audible while this panel is open")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            Text("The rig is muted while this panel is open")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - The strobe

/// Three rows of bands that drift right when the note is sharp, left when it is flat, and stand still
/// in tune — partials 1, 2 and 4, labelled `1x`, `2x` and `4x` as the reference implementation labels
/// them (squatch-tuner's `hosts/web/strobe.js`).
///
/// One `Canvas` per row rather than a view per band: a frame of this is 40 bands, and forty shapes in
/// a gradient redraw is what a drift should cost. The labels are `Text` beside them, so a font is a
/// font and the chip is a rounded rectangle rather than a paragraph drawn into the canvas.
private struct StrobeRows: View {
    let strobe: TunerStrobe
    let valid: Bool

    /// One band period, and how much of it is ink. Fixed rather than proportional to the width: the
    /// drift law is in periods per second, so the period is what a cent is worth on screen.
    private let period: Double = 34
    private let bandFraction: Double = 0.55

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<TunerStrobe.partials.count, id: \.self) { row in
                HStack(spacing: 6) {
                    Text(TunerStrobe.labels[row])
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .leading)
                    Canvas { context, size in
                        let rect = CGRect(origin: .zero, size: size)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2),
                                     with: .color(Color.primary.opacity(0.06)))
                        // The bands, offset by the row's phase. One whole period is drawn off the
                        // left edge so the row stays covered as the phase grows; sharp drifts right.
                        var path = Path()
                        var x = -period + strobe.offset(row, period: period)
                        while x < size.width {
                            path.addRect(CGRect(x: x, y: 0, width: period * bandFraction,
                                                height: size.height))
                            x += period
                        }
                        context.fill(path, with: .color(Color.primary.opacity(0.55 * strobe.activity)))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(valid ? "Strobe" : "Strobe, no note"))
    }
}
