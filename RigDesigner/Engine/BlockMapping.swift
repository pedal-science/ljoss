import Foundation

// Which catalogue blocks the engine can actually render, and how.
//
// The engine has eleven primitives and seven macros; this app has 102 blocks. The
// gap is real DSP that has not been written, and the whole point of this table is to
// be honest about it: a block appears here only when **every** parameter it exposes
// either reaches the engine or is named in `outOfBand` with a reason. A knob that
// looks live and is not is exactly the lie namchain's schema work exists to kill
// (docs/schema.md), and `Tests/EncoderTests.swift` fails the build if one appears.
//
// No SwiftUI here: this file is in the source list of `Tests/run-model-tests.sh`.

// MARK: - Transforms

/// How a catalogue value reaches an engine parameter.
///
/// A closed set, for the same reason the engine's own macro transforms are a closed
/// set: an expression language here would be one more place for the two sides to
/// disagree about what a knob means.
enum ParamTransform: Hashable, Sendable {

    /// Send the number unchanged. The units already agree.
    case direct

    /// A 0…10 knob centred at 5, onto ±`span` dB. A freshly dragged block whose knob
    /// sits at 5 is therefore flat.
    case knobDecibels(span: Double)

    /// A 0…10 knob onto `0…top`.
    case knobFraction(top: Double)

    /// A 0…10 knob onto `floor…0` dB — a volume pedal, unity at 10 and silent at 0.
    case knobAttenuation(floor: Double)

    /// Multiply. A 0–100 % mix onto the engine's 0…1 is `.multiplied(by: 0.01)`.
    case multiplied(by: Double)

    /// A picked option onto the engine's own option value. An option this app offers
    /// and the engine does not is **absent from the map**, and refused by name — the
    /// same "declare and refuse" rule the engine applies to a split mode it has not
    /// built.
    case option([String: String])
}

/// The outcome of a transform. The encoder adds the block context to a refusal.
enum TransformResult: Sendable {
    case value(EngineValue)
    case refused(String)
}

extension ParamTransform {

    func apply(_ stored: ParamValue) -> TransformResult {
        switch self {
        case .direct:
            guard let n = stored.doubleValue else { return .refused(wrongKind("a number")) }
            return .value(.number(n))

        case .knobDecibels(let span):
            guard let n = stored.doubleValue else { return .refused(wrongKind("a number")) }
            return .value(.number((n - 5) / 5 * span))

        case .knobFraction(let top):
            guard let n = stored.doubleValue else { return .refused(wrongKind("a number")) }
            return .value(.number(n / 10 * top))

        case .knobAttenuation(let floor):
            guard let n = stored.doubleValue else { return .refused(wrongKind("a number")) }
            return .value(.number(floor - n / 10 * floor))

        case .multiplied(let factor):
            guard let n = stored.doubleValue else { return .refused(wrongKind("a number")) }
            return .value(.number(n * factor))

        case .option(let map):
            guard let picked = stored.optionValue else { return .refused(wrongKind("a choice")) }
            guard let engineValue = map[picked] else {
                let offered = map.keys.sorted().joined(separator: ", ")
                return .refused("is set to “\(picked)”, which this engine does not have; it takes \(offered)")
            }
            return .value(.string(engineValue))
        }
    }

    private func wrongKind(_ expected: String) -> String {
        "should be \(expected), and the catalogue does not say so — the mapping table is wrong"
    }
}

// MARK: - Routes and assets

/// One catalogue parameter's route to one engine parameter.
struct ParamRoute: Hashable, Sendable {

    /// The engine parameter id.
    var to: String

    var transform: ParamTransform = .direct

    /// The engine's own bounds, when they are tighter than this app's. Checked here,
    /// naming both numbers, rather than letting the compiler reject the document with
    /// less context about which block it came from.
    var engineRange: ClosedRange<Double>? = nil

    init(to: String, transform: ParamTransform = .direct, engineRange: ClosedRange<Double>? = nil) {
        self.to = to
        self.transform = transform
        self.engineRange = engineRange
    }
}

/// A parameter whose value is a file on the device, chosen by the user from
/// `engine.assets` and named by its library **id** — never a path, which a network
/// client may not send at all (docs/assets.md).
enum AssetKind: String, Hashable, Sendable, CaseIterable {
    case model
    case ir

    /// Where the chosen id lives in `Block.values`. The `engine.` prefix keeps it
    /// from ever colliding with a catalogue parameter id, and the catalogue-driven
    /// inspector ignores keys it does not recognise — the same forward-compatibility
    /// argument `docs/ARCHITECTURE.md` makes for `componentID` being a `String`.
    var valueKey: String { "engine.\(rawValue)" }

    var noun: String {
        switch self {
        case .model: "amp model"
        case .ir: "impulse response"
        }
    }
}

// MARK: - Node templates

/// One engine node a block lowers to.
struct NodeTemplate: Hashable, Sendable {

    /// Appended to the block's UUID to make the node id, and what names the node in a
    /// refusal. Not the engine's `role`: that word belongs to a macro's own lowering
    /// and is the engine's to declare.
    var suffix: String

    var type: String

    /// Parameters with a fixed value this lowering needs.
    var fixed: [String: EngineValue] = [:]

    /// Catalogue parameter id → where it goes on this node.
    var routes: [String: ParamRoute] = [:]

    /// Engine parameter id → which device asset fills it. Always required: a cab with
    /// no impulse response is not a cab.
    var assets: [String: AssetKind] = [:]

    init(suffix: String,
         type: String,
         fixed: [String: EngineValue] = [:],
         routes: [String: ParamRoute] = [:],
         assets: [String: AssetKind] = [:]) {
        self.suffix = suffix
        self.type = type
        self.fixed = fixed
        self.routes = routes
        self.assets = assets
    }
}

/// How one catalogue component becomes engine nodes.
struct BlockMapping: Hashable, Sendable {

    /// In signal order. The first node's input is the block's input, the last node's
    /// output is the block's output, and consecutive nodes are wired in series.
    var nodes: [NodeTemplate]

    /// Catalogue parameter ids this app knowingly does not send, and why. Shown in
    /// the inspector so a knob that cannot reach the device says so.
    var outOfBand: [String: String]

    /// Every asset this block needs the user to choose before it can be sent.
    var requiredAssets: [AssetKind] {
        nodes.flatMap { $0.assets.values }
    }
}

// MARK: - The table

enum BlockMappings {

    static func mapping(for componentID: String) -> BlockMapping? { table[componentID] }

    /// Whether the engine can render this block at all.
    static func isMapped(_ componentID: String) -> Bool { table[componentID] != nil }

    static var mappedIDs: [String] { table.keys.sorted() }

    // MARK: Reasons, written once so they read the same everywhere

    private static let noDrive = """
        a NAM capture is a fixed operating point: there is no drive or master control \
        to turn, and mapping a 0–10 knob onto input level would be inventing the amp's \
        gain structure rather than modelling it
        """
    private static let noPresence =
        "the engine's tone stack is bass, mid and treble; a presence control is a different filter"
    private static let noMicPosition =
        "the engine loads an impulse response; mic choice and placement are baked into the capture"
    private static let noTape =
        "a tape delay's wow and age are modulation and saturation, and the engine has neither"
    private static let noTone =
        "a bucket-brigade tone control is a filter inside the repeats, which the feedback delay does not have"
    private static let noTempo =
        "there is no transport or tempo on the device, so a synced time has nothing to sync to"

    /// ±12 dB for a 0–10 amp tone knob, inside the tone stack's own ±18 dB. Chosen so
    /// a knob at its centre detent is flat and the ends are a usable amount of tilt
    /// rather than the engine's extreme.
    private static let ampToneSpan = 12.0

    /// An amp: a NAM capture, then a three-band tone stack.
    ///
    /// The four-band amps (`amp.bassrock`) lose a knob here. `fx.eq.bands` would fit
    /// them exactly and is the upgrade path, at the cost of amps no longer all
    /// lowering the same way.
    private static func amp(bass: String? = "bass",
                            mid: String? = "mid",
                            treble: String? = "treble",
                            alsoUnmapped: [String: String] = [:]) -> BlockMapping {
        var routes: [String: ParamRoute] = [:]
        if let bass { routes[bass] = ParamRoute(to: "bass", transform: .knobDecibels(span: ampToneSpan)) }
        if let mid { routes[mid] = ParamRoute(to: "mid", transform: .knobDecibels(span: ampToneSpan)) }
        if let treble { routes[treble] = ParamRoute(to: "treble", transform: .knobDecibels(span: ampToneSpan)) }

        var unmapped = alsoUnmapped
        unmapped["gain"] = noDrive
        unmapped["master"] = noDrive

        return BlockMapping(
            nodes: [
                NodeTemplate(suffix: "nam", type: "nc.nam", assets: ["model": .model]),
                NodeTemplate(suffix: "tone", type: "fx.amp.tonestack", routes: routes),
            ],
            outOfBand: unmapped)
    }

    /// A fixed cabinet: an impulse response the user picks, and a level.
    private static func cabinet(hasAxis: Bool) -> BlockMapping {
        var unmapped = ["mic": noMicPosition, "distance": noMicPosition]
        if hasAxis { unmapped["axis"] = noMicPosition }
        return BlockMapping(
            nodes: [
                NodeTemplate(suffix: "cab", type: "fx.cab.ir",
                             routes: ["level": ParamRoute(to: "level_db", engineRange: -24...12)],
                             assets: ["ir": .ir]),
            ],
            outOfBand: unmapped)
    }

    /// A delay: the engine's one feedback delay, whose line tops out at 1000 ms.
    private static func delay(alsoUnmapped: [String: String] = [:]) -> BlockMapping {
        BlockMapping(
            nodes: [
                NodeTemplate(suffix: "delay", type: "fx.delay.feedback", routes: [
                    "time": ParamRoute(to: "time", engineRange: 1...1000),
                    "feedback": ParamRoute(to: "feedback", transform: .knobFraction(top: 0.95)),
                    "mix": ParamRoute(to: "mix", transform: .multiplied(by: 0.01)),
                ]),
            ],
            outOfBand: alsoUnmapped)
    }

    /// The engine's cuts start at 12 dB/oct, so a 6 dB pick has nowhere to go and is
    /// refused by name rather than quietly steepened.
    private static let cutSlopes = ParamTransform.option(["12 dB": "12", "24 dB": "24"])

    static let table: [String: BlockMapping] = [

        // MARK: Amps

        "amp.cleanblack": amp(alsoUnmapped: ["presence": noPresence]),
        "amp.tweed": amp(bass: nil, mid: nil, treble: nil, alsoUnmapped: [
            "tone": "one tone knob is a voicing, not a band — which of bass, mid and treble it moves is a guess",
        ]),
        "amp.britplexi": amp(alsoUnmapped: ["presence": noPresence]),
        "amp.brit800": amp(),
        "amp.rectified": amp(alsoUnmapped: ["presence": noPresence]),
        "amp.chime": amp(mid: nil, alsoUnmapped: ["cut": noPresence]),
        "amp.hiwattage": amp(alsoUnmapped: ["presence": noPresence]),
        "amp.leadchannel": amp(),
        "amp.bassflip": amp(),
        "amp.bassrock": amp(mid: "lowmid", alsoUnmapped: [
            "himid": "the engine's tone stack has one mid band, and this amp has two",
        ]),
        "amp.acoustic": amp(),

        // MARK: Cabs

        "cab.412brit": cabinet(hasAxis: true),
        "cab.212chime": cabinet(hasAxis: false),
        "cab.112open": cabinet(hasAxis: false),
        "cab.810bass": cabinet(hasAxis: false),
        "cab.ir": BlockMapping(
            nodes: [
                NodeTemplate(suffix: "cab", type: "fx.cab.ir", routes: [
                    "lowcut": ParamRoute(to: "low_cut", engineRange: 10...2000),
                    "highcut": ParamRoute(to: "high_cut", engineRange: 1000...24000),
                    "level": ParamRoute(to: "level_db", engineRange: -24...12),
                ], assets: ["ir": .ir]),
            ],
            outOfBand: [
                "slot": "a slot is this app's idea; the engine names an impulse response by its library id",
            ]),

        // MARK: EQ

        // Band 3 is left flat and band 4's corner at its default: `bands` counts from
        // the front, so every band stays live and a transparent one costs a biquad.
        "eq.parametric": BlockMapping(
            nodes: [
                NodeTemplate(suffix: "eq", type: "fx.eq.bands",
                             fixed: ["bands": .number(4)],
                             routes: [
                                 "lowfreq": ParamRoute(to: "freq1"),
                                 "lowgain": ParamRoute(to: "gain1"),
                                 "midfreq": ParamRoute(to: "freq2"),
                                 "midgain": ParamRoute(to: "gain2"),
                                 "midq": ParamRoute(to: "q2"),
                                 "highgain": ParamRoute(to: "gain4"),
                             ]),
            ],
            outOfBand: [:]),

        "eq.tilt": BlockMapping(
            nodes: [
                NodeTemplate(suffix: "eq", type: "fx.eq.tilt", routes: [
                    "tilt": ParamRoute(to: "tilt", engineRange: -12...12),
                    "pivot": ParamRoute(to: "freq", engineRange: 100...8000),
                ]),
            ],
            outOfBand: [:]),

        "eq.lowcut": BlockMapping(
            nodes: [
                NodeTemplate(suffix: "cut", type: "fx.filter.cut", routes: [
                    "freq": ParamRoute(to: "low_cut", engineRange: 10...2000),
                    "slope": ParamRoute(to: "low_slope", transform: cutSlopes),
                ]),
            ],
            outOfBand: [:]),

        "eq.highcut": BlockMapping(
            nodes: [
                NodeTemplate(suffix: "cut", type: "fx.filter.cut", routes: [
                    "freq": ParamRoute(to: "high_cut", engineRange: 1000...24000),
                    "slope": ParamRoute(to: "high_slope", transform: cutSlopes),
                ]),
            ],
            outOfBand: [:]),

        "eq.vocalair": BlockMapping(
            nodes: [
                NodeTemplate(suffix: "eq", type: "fx.eq.bands",
                             fixed: ["bands": .number(4)],
                             routes: [
                                 "freq": ParamRoute(to: "freq4"),
                                 "gain": ParamRoute(to: "gain4"),
                             ]),
            ],
            outOfBand: [:]),

        // MARK: Delays

        "delay.digital": delay(alsoUnmapped: ["sync": noTempo]),
        "delay.tape": delay(alsoUnmapped: ["wow": noTape, "age": noTape]),
        "delay.analog": delay(alsoUnmapped: ["tone": noTone]),
        "delay.slapback": delay(),

        // MARK: Utility

        "util.gain": BlockMapping(
            nodes: [
                NodeTemplate(suffix: "gain", type: "nc.gain", routes: [
                    "gain": ParamRoute(to: "gain_db", engineRange: -60...24),
                ]),
            ],
            outOfBand: [:]),

        "util.volume": BlockMapping(
            nodes: [
                NodeTemplate(suffix: "gain", type: "nc.gain", routes: [
                    "position": ParamRoute(to: "gain_db", transform: .knobAttenuation(floor: -60)),
                ]),
            ],
            outOfBand: [
                "taper": "the engine ramps a gain change on its own law; a pedal taper is not one of its parameters",
            ]),
    ]
}
