import SwiftUI

// The tuner, in the left column: the note, how far off it is, and how loud the input is.
//
// While this is on screen the app is mounting a tuner node after each chain's input and that node's
// output is silence, so the rig is muted for exactly as long as the panel is up (namchain
// docs/tuner.md; `EngineSession.setTunerVisible` is what does it). Closing the panel unmounts the
// node again.
//
// The panel reads `TunerModel`, which polls `rig.state` only while the panel is visible, and it
// draws three separate facts: `available` (the engine has answered), `running` (the engine really is
// running the node, so the rig really is silent) and `valid` (there is a note the engine trusts).
// The middle one is the one a player must not be left guessing about.
struct TunerPanel: View {
    @Environment(EngineSession.self) private var session

    private var reading: TunerReading { session.tuner.reading }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            note
            centsScale
            numbers
            stateLine
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Tuner", systemImage: "tuningfork")
                .font(.system(size: 15, weight: .semibold))
                .labelStyle(.titleAndIcon)
            Spacer()
            if !reading.a4Text.isEmpty {
                Text(reading.a4Text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var note: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(reading.noteText.isEmpty ? "—" : reading.noteText)
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .foregroundStyle(reading.inTune ? Color.green : (reading.valid ? Color.primary : Color.secondary))
                .monospacedDigit()
            if !reading.centsText.isEmpty {
                Text(reading.centsText)
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundStyle(reading.inTune ? Color.green : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(reading.noteText.isEmpty ? "No note" : "\(reading.noteText), \(reading.centsText) cents"))
    }

    /// Half a semitone either side of the note, with the in-tune band drawn rather than said.
    private var centsScale: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let mid = width / 2
            let halfBar = width / 2
            let fraction = reading.needle ?? 0
            ZStack(alignment: .center) {
                // The in-tune band.
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: halfBar * (TunerReading.inTuneCents / TunerReading.maxCents) * 2, height: 44)

                // The centre, and the ends.
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1, height: 56)
                HStack {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1, height: 20)
                    Spacer()
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1, height: 20)
                }

                // The needle, and only with a note: a needle at rest would read as "in tune".
                if reading.needle != nil {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(reading.inTune ? Color.green : Color.accentColor)
                        .frame(width: 4, height: 52)
                        .offset(x: fraction * halfBar)
                }
                Text("−\(Int(TunerReading.maxCents))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("+\(Int(TunerReading.maxCents))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: width, height: geometry.size.height, alignment: .center)
            .animation(.easeOut(duration: 0.05), value: fraction)
        }
        .frame(height: 56)
    }

    private var numbers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(reading.hzText)
                    .font(.title3)
                    .monospacedDigit()
                Spacer()
                Text(reading.levelText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // The input's level, so "nothing is plugged in" is visible as an empty bar.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(reading.levelFraction > 0.95 ? Color.red
                              : reading.levelFraction > 0.8 ? Color.yellow : Color.green)
                        .frame(width: geometry.size.width * reading.levelFraction)
                }
            }
            .frame(height: 8)
        }
        .opacity(reading.running ? 1 : 0.4)
    }

    @ViewBuilder
    private var stateLine: some View {
        if !reading.running {
            // The failure that matters: the panel is up and the amp is still audible.
            Text(reading.status)
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if !reading.valid, !reading.status.isEmpty {
            Text(reading.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text("The rig is muted while this panel is open")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
