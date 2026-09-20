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

    static let byName: [String: @Sendable () -> Rig] = [
        "empty": empty,
        "gain0": { gain(decibels: nil) },
        "gain6": { gain(decibels: 6.0) },
        "amp": { amp() },
    ]

    static let names = byName.keys.sorted().joined(separator: "|")
}
