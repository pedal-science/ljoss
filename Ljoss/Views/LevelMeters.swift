import Observation
import SwiftUI

// The meters: a bar that shows where the signal is, without pretending to be a scope.
//
// **Ballistics are the client's job.** The engine reports whatever the last window held — a
// peak and an RMS over the block or two since the previous read — so a meter that drew those
// numbers raw would flicker: a peak that lasts one block would appear for a single frame and
// vanish. What a player reads is a *decaying* value: jump up instantly, fall slowly, which is
// what every hardware meter does and what makes a level legible (ITU-R BS.1770's "peak hold",
// and the same reason a VU's needle has mass).
//
// So the decay lives here, in the view, over the samples it is given. At 20 Hz that is a
// handful of updates per decay, which is all it needs.
//
// **One reading, shared.** Every meter reads `EngineSession.levels`, so the number of meters on
// screen changes nothing about how often the device is asked. The decay is recomputed per view
// from the same samples, which costs a multiplication per redraw and keeps the bars in step.

// MARK: - Thresholds

/// Where a level is "good", "hot" and "too much", and the colours to say so.
///
/// One place, because a bar whose green means something different from the bar beside it is
/// worse than no bar at all. The numbers are the usual ones for a guitar signal into a 48 kHz
/// converter: -18 dBFS is where a digital meter's nominal sits, so everything below it has
/// headroom to spare; -6 is where a transient starts to have nowhere to go; 0 is the encode's
/// clamp, which the engine counts.
enum MeterScale {
    /// \brief The bottom of the scale, and the point below which a meter says nothing at all.
    ///
    /// -70 dBFS: a quiet guitar into a 1 MΩ input is around -60, so a floor at -60 would sit above
    /// real signal and call it silence — a fault this caught in its own tests, where a pedal idling
    /// at -61.5 dBFS read as "no level". It is also high enough that a meter decays to silence in
    /// about three seconds rather than looking stuck.
    static let floor: Double = -70
    static let nominal: Double = -18
    static let hot: Double = -6
    static let clip: Double = 0

    /// How far a peak falls per second, in dB, once the signal has gone. About 20 dB/s reads as
    /// a real meter: fast enough that silence is clearly silence, slow enough to see a note.
    static let releaseDbPerSecond: Double = 24

    /// \brief What counts as a reading rather than as the engine saying "nothing here".
    ///
    /// The engine quotes digital silence as -200 (its own floor, chosen so JSON can carry it), so
    /// a channel nothing is routed to arrives as -200 rather than as a missing entry. A meter that
    /// treated that as a level would draw a bar at its floor for every unused channel — and would
    /// then have to explain why a silent channel looks like a very quiet one. It is not the same
    /// statement, and the difference is this number: well below any real signal, well above the
    /// engine's floor, and reached by a decaying meter within about eight seconds.
    static let engineFloor: Double = -190

    /// 0 at the floor, 1 at full scale, so a bar's width is a level.
    static func fraction(_ db: Double?) -> Double {
        guard let db else { return 0 }
        return min(1, max(0, (db - floor) / (clip - floor)))
    }

    static func isHot(_ db: Double?) -> Bool { (db ?? -200) >= hot }
    static func isClipping(_ db: Double?) -> Bool { (db ?? -200) >= -0.1 }

    static func colour(_ db: Double?) -> Color {
        guard let db else { return .secondary.opacity(0.4) }
        if db >= -0.1 { return .red }
        if db >= hot { return .orange }
        if db >= nominal { return .yellow }
        return .green
    }
}

/// A peak that falls when the signal does. A value type so each meter owns its own decay.
///
/// \brief **Read as: take the louder of the new reading and the released old one.**
///
/// It does not go nil, and that is deliberate: a value that disappears is indistinguishable from
/// a display that stopped updating, and every caller would have to invent the same "is this
/// nothing, or is it quiet?" test. The peak falls to the bottom of the scale and stops there, and
/// a view asks \ref isAudible before it draws anything. One rule, in one place.
struct MeterBallistics: Equatable {
    /// The level to show, in dBFS. Starts at the floor, because a meter that has never been given
    /// a reading has nothing to show and that is not the same as showing silence.
    private(set) var peak: Double = MeterScale.floor
    /// The last bottom the peak was allowed to reach. A test sets it so a decay can be checked
    /// without waiting for one; the app never changes it.
    var floor: Double = MeterScale.floor

    private var lastUpdate: Date?

    /// Whether there is a level here at all. A peak at the floor is a meter with nothing to say —
    /// an unused device channel, a block that has been quiet for ten seconds — and a bar drawn for
    /// it would claim a signal that is not there.
    var isAudible: Bool { peak > floor }

    /// Fold one reading in. \p now is the caller's clock, so one timestamp can drive several
    /// meters and their decay stays in step.
    ///
    /// \p fresh is nil for a window that measured nothing — the engine's probes are read and
    /// reset, so that happens whenever anything else asks the engine a question — and nil releases
    /// rather than resets, which is what makes a gap in the numbers look like a note ending
    /// instead of a glitch. A reading at or below \ref MeterScale.engineFloor is the engine saying
    /// "digital silence" and is treated the same way.
    mutating func update(_ fresh: Double?, now: Date) {
        let elapsed = max(0, now.timeIntervalSince(lastUpdate ?? now))
        lastUpdate = now
        let released = peak - MeterScale.releaseDbPerSecond * elapsed
        let reading = (fresh.flatMap { $0 > MeterScale.engineFloor ? $0 : nil }) ?? floor
        // The floor is a floor for what is *shown*, which is what `isAudible` and a nil reading
        // take care of; letting the released value fall past it is what keeps a quiet meter's
        // motion the same as a loud one's.
        peak = max(reading, released)
    }
}

// MARK: - The bar

// MARK: - The bar

/// One horizontal level bar: 0 dBFS at the right-hand end, a floor at the left.
struct LevelBar: View {
    let db: Double?
    /// A thin bar under a block tile, or a taller one on a cap.
    var height: CGFloat = 6
    /// Room for the tick at -18 dBFS, which is what makes a level readable rather than a number.
    var showsNominalTick = true

    private var fraction: Double { MeterScale.fraction(db) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(MeterScale.colour(db))
                    .frame(width: max(0, width * fraction))
                if showsNominalTick {
                    let x = width * MeterScale.fraction(MeterScale.nominal)
                    Rectangle()
                        .fill(.primary.opacity(0.35))
                        .frame(width: 1)
                        .offset(x: x)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text("Level"))
        .accessibilityValue(Text(db.map { String(format: "%.1f dBFS", $0) } ?? "silent"))
    }
}

/// A pair of bars with a label: one channel of the device, or one block.
///
/// `C` is what a `[Double]` of peaks becomes on screen — the caps show one bar per channel,
/// because which channel is silent is a wiring question and a summed bar cannot answer it.
struct LevelBars: View {
    let values: [Double?]
    var height: CGFloat = 6
    var spacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, db in
                LevelBar(db: db, height: height)
            }
        }
    }
}

// MARK: - Reading the model

/// Which end of the device a meter is showing.
///
/// Deliberately not `EndpointTile.Kind`: that lives in a view, and this file is unit-tested
/// without one. The two are kept in step by `EndpointTile.channels`, which is the only place
/// that maps them.
enum MeterSide: Hashable, Sendable {
    case input
    case output
}

/// One meter's worth of readings, pulled from the session's levels and decayed for display.
///
/// A view uses this through `MeterReader`, which applies the release to whatever it is given.
@MainActor
@Observable
final class MeterReader {
    /// Per device channel, because "which channel is silent" is a wiring question that a summed
    /// bar cannot answer. The input is the ADC's own signal (before any chain routing), the output
    /// is the sum every chain has been added into.
    var inputChannels: [MeterBallistics]
    var outputChannels: [MeterBallistics]
    /// Per chain: the chain's own output.
    var chains: [String: MeterBallistics]
    /// Per element: the loudest node's level, which is the block's level.
    var blocks: [UUID: MeterBallistics]
    /// A latched clip, cleared when the player asks: a clip that comes and goes in one frame is
    /// a clip nobody sees, and the whole point of showing it is that it happened.
    private(set) var clipped = false
    private(set) var clippingChannels: Set<Int> = []

    init() {
        inputChannels = []
        outputChannels = []
        chains = [:]
        blocks = [:]
    }

    /// The reading for one direction, per channel, for a view to draw. Nil for a channel with
    /// nothing to show — a bar at the floor would claim a signal that is not there.
    func channels(for side: MeterSide) -> [Double?] {
        let source = side == .input ? inputChannels : outputChannels
        return source.map { $0.isAudible ? $0.peak : nil }
    }

    func tick(_ levels: EngineLevels?, now: Date = Date()) {
        guard let levels else { return }

        update(&inputChannels, from: levels.input, now: now)
        update(&outputChannels, from: levels.output, now: now)

        // A clip that comes and goes in one frame is a clip nobody sees, and showing it is the
        // whole point: latched per channel until the player clears it.
        if let channels = levels.output?.clipped {
            for (index, count) in channels.enumerated() where count > 0 {
                clippingChannels.insert(index)
                clipped = true
            }
        }

        for chain in levels.chains ?? [] {
            guard let id = chain.id else { continue }
            var ballistics = chains[id] ?? MeterBallistics()
            ballistics.update(chain.out?.peak, now: now)
            chains[id] = ballistics
        }

        // Per element: the loudest node, because a macro's primitives are in series and the one
        // that matters is where the level has got to, not whichever happens to be last.
        var peakByElement: [UUID: Double] = [:]
        for chain in levels.chains ?? [] {
            for node in chain.nodes ?? [] {
                guard let element = node.element, let uuid = UUID(uuidString: element),
                      let peak = node.peak, peak > MeterScale.engineFloor else { continue }
                peakByElement[uuid] = max(peakByElement[uuid] ?? -999, peak)
            }
        }
        // Every block that was already on screen is released first, **including the ones this
        // window did not mention**: a block whose window was empty, or which the engine has
        // stopped reporting at all, should fall like a level going quiet rather than vanish. A bar
        // that disappears reads as a fault; one that falls reads as the sound stopping.
        //
        // Written back explicitly rather than through a dictionary's own subscript because
        // `ballistics` is a **copy** of the value in it (`for (_, var x) in dict`), so the update
        // would otherwise be thrown away. That mistake is why this comment is here.
        for (uuid, held) in blocks {
            var ballistics = held
            ballistics.update(peakByElement[uuid], now: now)
            blocks[uuid] = ballistics
        }
        for (uuid, peak) in peakByElement where blocks[uuid] == nil {
            var ballistics = MeterBallistics()
            ballistics.update(peak, now: now)
            blocks[uuid] = ballistics
        }
    }

    /// The player has seen it: forget the latched clip and let the next one light up again.
    func clearClip() {
        clipped = false
        clippingChannels.removeAll()
    }

    /// Fold one direction's per-channel peaks into the ballistics, growing the array when the
    /// device reports more channels than last time (it can: the engine is opened with a channel
    /// count and can come back with a different one).
    private func update(_ ballistics: inout [MeterBallistics], from side: EngineSideLevels?, now: Date) {
        guard let peaks = side?.peak, !peaks.isEmpty else { return }
        while ballistics.count < peaks.count { ballistics.append(MeterBallistics()) }
        for index in peaks.indices {
            ballistics[index].update(peaks[index], now: now)
        }
    }

    func block(_ id: UUID) -> Double? {
        guard let meter = blocks[id], meter.isAudible else { return nil }
        return meter.peak
    }

    func chain(_ id: String) -> Double? {
        guard let meter = chains[id], meter.isAudible else { return nil }
        return meter.peak
    }
}


