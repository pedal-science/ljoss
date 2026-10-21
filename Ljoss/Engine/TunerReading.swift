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
    var status = ""              // one line, when the rig is not muted or there is no note

    /// The needle's position across the scale, -1 … 1 (0 is in tune), or nil with no note.
    var needle: Double? {
        guard valid, let cents else { return nil }
        return max(-1, min(1, cents / Self.maxCents))
    }
    /// The needle's arithmetic before it becomes a position: the raw cents, for the tests.
    private var cents: Double?

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
