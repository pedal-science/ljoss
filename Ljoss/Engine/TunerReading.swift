import Foundation

// The tuner's reading, as the app draws it, decoded from the `rig.state` entry of the `nc.tuner`
// node the session mounted (namchain docs/tuner.md). Foundation only, so the test runner compiles
// it: the arithmetic a needle needs is the part that can be wrong without a window.
//
// Three facts the view needs and must not confuse:
//
//   * `available` — the engine has answered at all. Before this, "waiting" is the honest label.
//   * `running` — the engine's document holds a tuner node, so the rig really is silent. False is
//     the one failure a player must not be left guessing about: the tuner is on screen and the amp
//     is still audible, because a publish was refused or an engine too old for the node is running.
//   * `valid` — the engine has a note it trusts. It withholds one it does not (a string decaying
//     into the room's hum), and then the state omits the note rather than repeating the last one.
struct TunerReading: Equatable, Sendable {

    /// How far either side of the note the needle's scale goes, in cents: `cents` is the offset from
    /// the *nearest* note, so it is always inside this.
    static let maxCents = 50.0
    /// What counts as in tune. A UI choice: the engine reports a number and nothing more.
    static let inTuneCents = 5.0
    /// The level a meter draws, in dBFS: below this is "nothing is arriving".
    static let levelFloorDb = -60.0

    var available = false
    var running = false
    var valid = false
    var noteText = ""            // "A2", empty with no note
    var centsText = ""           // "+2.4", "-1.7", "0.0"
    var hzText = ""              // "440.0 Hz"
    var levelText = "-120 dB"
    var a4Text = ""              // "A4 = 440 Hz"
    var inTune = false
    /// The node's switch, from the engine's state: true means its output is silence. The panel's
    /// control is the session's intent; this is the engine's answer, so a refused patch leaves the
    /// two visibly disagreeing rather than silently lying.
    var muted = true
    var status = ""              // one line, when the rig is not muted or there is no note

    /// The needle's position across the scale, -1 … 1 (0 is in tune), or nil with no note.
    var needle: Double? {
        guard valid, let cents else { return nil }
        return max(-1, min(1, cents / Self.maxCents))
    }
    /// The offset from the nearest note, signed — what the needle and the strobe both read.
    private(set) var cents: Double?

    /// The input's level as a bar's fill, 0 … 1 over `levelFloorDb` … 0 dBFS.
    var levelFraction: Double { levelDb.map { max(0, min(1, ($0 - Self.levelFloorDb) / -Self.levelFloorDb)) } ?? 0 }
    private var levelDb: Double?

    /// What a view starts with, and what leaving it returns to.
    static let waiting = TunerReading(status: "Waiting for the engine")

    /// Digest one `rig.state` reply. The first `nc.tuner` node wins: a rig has one per chain, and
    /// the others hear the same instrument on their own channel.
    static func decoding(_ response: StateResponse) -> TunerReading {
        let entry = response.nodes?.first { $0.type == DocumentEncoder.tunerNodeType }
        guard let entry else {
            // No tuner node in what the engine is running: the rig is not muted.
            var reading = TunerReading()
            reading.available = true
            reading.status = "The rig is not muted — the engine is running no tuner node"
            return reading
        }
        var reading = TunerReading()
        reading.available = true
        reading.running = true
        let state = entry.state
        reading.valid = state?["valid"]?.bool ?? false
        reading.muted = state?["mute"]?.bool ?? true
        reading.levelDb = state?["level_db"]?.double
        reading.levelText = Self.dbText(reading.levelDb ?? -120)
        reading.a4Text = "A4 = " + Self.numberText(state?["a4"]?.double ?? 440, decimals: 0) + " Hz"
        guard reading.valid else {
            reading.status = "No note"
            return reading
        }
        let note = state?["note"]?.string ?? ""
        let octave = state?["octave"]?.double.map { Int($0) }
        if !note.isEmpty, let octave {
            reading.noteText = note + String(octave)
        }
        if let cents = state?["cents"]?.double {
            reading.cents = cents
            reading.centsText = Self.centsText(cents)
            reading.inTune = abs(cents) <= Self.inTuneCents
        }
        if let hz = state?["hz"]?.double {
            reading.hzText = Self.numberText(hz, decimals: 1) + " Hz"
        }
        return reading
    }

    private init() {}

    private init(status: String) {
        self.status = status
    }

    static func centsText(_ cents: Double) -> String {
        if abs(cents) < 0.05 { return "0.0" }
        return (cents > 0 ? "+" : "-") + numberText(abs(cents), decimals: 1)
    }

    private static func dbText(_ db: Double) -> String {
        numberText(db, decimals: 0) + " dB"
    }

    // Integer formatting rather than a locale-formatted number: a cents value of "1,5" in a locale
    // that writes a comma would be a different number to anyone reading it.
    private static func numberText(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}

// The strobe's three rows, ported from squatch-tuner's reference implementation
// (`hosts/web/strobe.js`, and namchain docs/tuner.md, "The strobe"): partials 1, 2 and 4 of the note,
// row k drifting k times as fast as the fundamental, at 0.5 band periods per second per cent, and no
// faster than 12 — which is what would alias at a display's frame rate.
//
// A value type fed the interval between frames rather than a tick count: a dropped frame moves the
// bands further, not slower, and a stalled one (a suspension) is clamped instead of teleporting a
// whole period. Foundation only, so the test runner checks the law without a window.
struct TunerStrobe: Equatable, Sendable {

    static let partials = [1.0, 2.0, 4.0]
    static let labels = ["1x", "2x", "4x"]
    static let driftPerCent = 0.5
    static let maxDrift = 12.0
    /// What a frame is assumed to be when the clock says something impossible.
    static let fallbackInterval = 1.0 / 60.0
    /// The longest interval honoured: anything more is a stall, not a slow frame.
    static let maxInterval = 0.25
    /// The bands' presence, and how fast it follows whether there is a note: the reference's own
    /// gesture for "the strings have stopped" is to settle and fade rather than to blank.
    static let settledActivity = 0.22
    static let activityTimeConstant = 0.25

    private(set) var phases = [0.0, 0.0, 0.0]
    private(set) var activity = TunerStrobe.settledActivity

    /// One frame. `cents` is drawn only when there is a reading the engine trusts: no note means no
    /// drift, because a row animating a reading that is not there is a lie with motion in it.
    mutating func advance(seconds: Double, cents: Double?, valid: Bool) {
        var dt = seconds
        if !(dt > 0) || dt > Self.maxInterval { dt = Self.fallbackInterval }
        let offset = (valid ? cents : nil) ?? 0
        for row in phases.indices {
            let speed = valid
                ? max(-Self.maxDrift, min(Self.maxDrift, Self.driftPerCent * offset * Self.partials[row]))
                : 0
            var phase = phases[row] + speed * dt
            phase -= (phase).rounded(.down)
            phases[row] = phase
        }
        let target = valid ? 1.0 : Self.settledActivity
        activity += (target - activity) * (1 - exp(-dt / Self.activityTimeConstant))
    }

    /// Where a row's bands sit, in the same units as `period` (pixels, if the view passes its band
    /// width): sharp drifts right, which is the reference's direction, so the offset is positive.
    func offset(_ row: Int, period: Double) -> Double {
        phases.indices.contains(row) ? phases[row] * period : 0
    }

    mutating func reset() {
        phases = [0, 0, 0]
        activity = Self.settledActivity
    }
}
