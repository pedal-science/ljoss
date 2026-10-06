import Foundation

/// The rigs the two device tools apply, in one place.
///
/// They were defined twice — once in each tool — and the copies drifted immediately: asking
/// `check-device` for the amp got a gain block, because its table had no amp in it and the
/// fall-through built one. A tool whose whole job is to say what the engine received must not be
/// able to send something other than what it was asked for, so there is one table.
enum TestRigs {

    /// One chain, nothing in it: `nc.input` straight to `nc.output`. The null test.
    static func empty() -> Rig {
        RigFactory.emptyRig(name: "Empty", layout: .single)
    }

    /// One chain, one Gain block. Left at the catalogue default it is 0 dB, which lowers to
    /// `nc.gain` with `gain_db: 0` — exactly unity, so this is a null test too. Given a value it
    /// is the control: a test that cannot fail is not measuring anything.
    static func gain(decibels: Double?) -> Rig {
        var rig = RigFactory.emptyRig(name: decibels == nil ? "Gain" : "Gain \(decibels!)",
                                      layout: .single)
        var block = Block(componentID: "util.gain")
        if let decibels { block.values["gain"] = .number(decibels) }
        rig.chains[0].elements = [.block(block)]
        return rig
    }

    /// One chain, one amp, which lowers to `nc.nam` plus `fx.amp.tonestack`.
    ///
    /// The model is an **id** from the device's library, never a path: a document arriving over TCP
    /// may not name an absolute path at all (`path_refused`), and the app has no business knowing
    /// the device's filesystem. `AMP_MODEL` chooses which id, because which ids exist is a fact
    /// about the device rather than about this app.
    static func amp(model: String? = nil) -> Rig {
        var rig = RigFactory.emptyRig(name: "Amp", layout: .single)
        var block = Block(componentID: "amp.brit800")
        block.values[AssetKind.model.valueKey] =
            .option(model ?? ProcessInfo.processInfo.environment["AMP_MODEL"] ?? "A2")
        rig.chains[0].elements = [.block(block)]
        return rig
    }

    /// One chain holding one Y-split parallel section: a unity Gain in the first lane, the rest
    /// empty. An empty lane is the dry path, so every lane carries the input unchanged and the
    /// mixer's output is exactly `lanes × input` — a prediction, not a tolerance.
    ///
    /// Three lanes is the case that measures `nc.split`'s `outputs`: its default is 2, so a two-lane
    /// split passes whether or not the parameter is read at all.
    static func split(lanes: Int, invertingLast: Bool = false) -> Rig {
        var rig = RigFactory.emptyRig(name: "Split \(lanes)", layout: .single)
        var gain = Lane()
        gain.elements = [.block(Block(componentID: "util.gain"))]
        var all = [gain] + (1..<lanes).map { _ in Lane() }
        if invertingLast { all[all.count - 1].invertPhase = true }
        rig.chains[0].elements = [.parallel(ParallelSection(lanes: all))]
        return rig
    }

    /// One chain of three blocks whose knobs the engine ramps: a Gain (a primitive), a
    /// Parametric EQ and a Digital Delay (both macros, so their knobs are addressed by
    /// element). `check-streaming` turns all three at once.
    static func streaming() -> Rig {
        var rig = RigFactory.emptyRig(name: "Streaming", layout: .single)
        rig.chains[0].elements = [
            .block(Block(componentID: "util.gain")),
            .block(Block(componentID: "eq.parametric")),
            .block(Block(componentID: "delay.digital")),
        ]
        return rig
    }

    /// One chain of three Gains at values chosen so every node's reported level is a prediction
    /// rather than a tolerance: 0 dB (the node's level *is* the chain's input), −12 dB, +12 dB, so
    /// the three nodes and the chain output should read `in`, `in − 12`, `in` and `in`.
    ///
    /// This is the rig the level campaign applies (`Tools/levels/campaign.py`), which is why the
    /// values are round numbers: a graph of reported node levels against input level is a set of
    /// parallel lines, and any node that is not parallel is a bug in the level plumbing rather than
    /// a property of the audio.
    static func levels() -> Rig {
        var rig = RigFactory.emptyRig(name: "Levels", layout: .single)
        rig.chains[0].elements = [0.0, -12.0, 12.0].map { decibels in
            var block = Block(componentID: "util.gain")
            block.values["gain"] = .number(decibels)
            return .block(block)
        }
        return rig
    }

    static let byName: [String: @Sendable () -> Rig] = [
        "empty": empty,
        "gain0": { gain(decibels: nil) },
        "gain6": { gain(decibels: 6.0) },
        "amp": { amp() },
        "levels": levels,
        "split2": { split(lanes: 2) },
        "split3": { split(lanes: 3) },
        // x + (−x): the lanes cancel to the sample, so the split, the mixer and the lane's
        // polarity node together make a null test.
        "splitnull": { split(lanes: 2, invertingLast: true) },
        "streaming": streaming,
    ]

    static let names = byName.keys.sorted().joined(separator: "|")
}
