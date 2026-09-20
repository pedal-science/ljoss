import Foundation

// The rig tree, flattened into the graph namchain runs.
//
// The split of work is fixed by docs/ui-integration-plan.md §1.9 and must not drift:
// **this app flattens the topology, the engine lowers the blocks.** A parallel
// section becomes one `nc.split`, the lanes, and one `nc.mix`; a block becomes one or
// two engine nodes and the engine expands those into biquads and gains itself.
//
// The convention the engine's tests are written against:
//
//   a parallel section is one `nc.split` with `outputs = lane count`, one `nc.mix`
//   with `inputs = lane count`, lane i on port i, the parallel element id on both.
//
// No SwiftUI here: this file is in the source list of `Tests/run-model-tests.sh`.

// MARK: - Refusals

/// Why a rig cannot be sent, in words that name the thing to change.
///
/// Refusals are collected rather than thrown at the first one: a player who has to
/// pick a model for three amps should be told about all three at once.
struct EncodeRefusal: Hashable, Sendable {
    var chain: String
    var subject: String?
    var message: String

    var text: String {
        if let subject {
            "\(chain) · \(subject) \(message)"
        } else {
            "\(chain): \(message)"
        }
    }
}

struct EncodeResult: Sendable {
    /// Nil when anything was refused. A half-encodable rig is not a rig to send.
    var document: EngineDocument?
    var refusals: [EncodeRefusal]

    /// Chains the current layout does not draw. They are **sent anyway** — `layout`
    /// is a viewing preference and a layout tap must not silently change what is
    /// audible — and then muted with `engine.mute`, visibly.
    var hiddenChainIDs: [String]

    var isSendable: Bool { document != nil }
}

// MARK: - The encoder

enum DocumentEncoder {

    /// Where a signal currently is: a node id and one of its output ports.
    private struct Port {
        var node: String
        var index: Int
    }

    static func encode(_ rig: Rig) -> EncodeResult {
        var refusals: [EncodeRefusal] = []
        var chains: [EngineChain] = []

        for (index, chain) in rig.chains.enumerated() {
            chains.append(encode(chain, at: index, refusals: &refusals))
        }

        let visible = rig.activeChains.map { $0.id }
        let hidden = rig.chains.filter { !visible.contains($0.id) }.map { $0.id.uuidString }

        return EncodeResult(
            document: refusals.isEmpty ? EngineDocument(name: rig.name, chains: chains) : nil,
            refusals: refusals,
            hiddenChainIDs: hidden)
    }

    // MARK: One chain

    private static func encode(_ chain: SignalChain,
                               at index: Int,
                               refusals: inout [EncodeRefusal]) -> EngineChain {
        var nodes: [EngineNode] = []
        var connections: [EngineConnection] = []

        nodes.append(EngineNode(id: "in", type: "nc.input", element: chain.input.id.uuidString))
        var here = Port(node: "in", index: 0)

        here = emit(chain.elements,
                    from: here,
                    into: &nodes,
                    connections: &connections,
                    chain: chain.name,
                    refusals: &refusals)

        // The output fader is a node, not a parameter on `nc.output`: the plan's
        // output *is* the buffer feeding `nc.output`, which another consumer may also
        // read, so a gain on that node would scale a shared buffer in place
        // (docs/ui-integration-plan.md §6, sub-decision 7).
        if let level = IOMapping.outputLevel(of: chain.output), level != 0 {
            let id = "\(chain.output.id.uuidString)-level"
            nodes.append(EngineNode(id: id, type: "nc.gain",
                                    element: chain.output.id.uuidString,
                                    params: ["gain_db": .number(level)]))
            connections.append(EngineConnection(from: here.node, fromPort: here.index, to: id))
            here = Port(node: id, index: 0)
        }

        nodes.append(EngineNode(id: "out", type: "nc.output", element: chain.output.id.uuidString))
        connections.append(EngineConnection(from: here.node, fromPort: here.index, to: "out"))

        // One chain per device channel, by position. A chain naming a channel the
        // device does not have is refused by the daemon, naming the chain; the app
        // pre-flights that against `engine.status` before it sends.
        return EngineChain(id: chain.id.uuidString,
                           name: chain.name,
                           inputChannel: index,
                           outputChannel: index,
                           nodes: nodes,
                           connections: connections)
    }

    // MARK: A series of elements

    private static func emit(_ elements: [ChainElement],
                             from source: Port,
                             into nodes: inout [EngineNode],
                             connections: inout [EngineConnection],
                             chain: String,
                             refusals: inout [EncodeRefusal]) -> Port {
        var here = source
        for element in elements {
            switch element {
            case .block(let block):
                here = emit(block, from: here, into: &nodes, connections: &connections,
                            chain: chain, refusals: &refusals)
            case .parallel(let section):
                here = emit(section, from: here, into: &nodes, connections: &connections,
                            chain: chain, refusals: &refusals)
            }
        }
        return here
    }

    // MARK: One block

    private static func emit(_ block: Block,
                             from source: Port,
                             into nodes: inout [EngineNode],
                             connections: inout [EngineConnection],
                             chain: String,
                             refusals: inout [EncodeRefusal]) -> Port {
        let spec = Catalogue.resolve(block.componentID)

        guard let mapping = BlockMappings.mapping(for: block.componentID) else {
            refusals.append(EncodeRefusal(
                chain: chain, subject: spec.name,
                message: "has no engine equivalent on this device"))
            // The signal passes straight through, so the rest of the graph still
            // builds and the rest of its problems are still reported.
            return source
        }

        var here = source
        for template in mapping.nodes {
            let id = "\(block.id.uuidString)-\(template.suffix)"
            var params = template.fixed

            for (engineParam, asset) in template.assets {
                guard case .option(let identifier)? = block.values[asset.valueKey],
                      !identifier.isEmpty else {
                    refusals.append(EncodeRefusal(
                        chain: chain, subject: spec.name,
                        message: "needs an \(asset.noun) chosen from the device's library"))
                    continue
                }
                params[engineParam] = .string(identifier)
            }

            for (sourceParam, route) in template.routes {
                guard let stored = effectiveValue(sourceParam, of: block, spec: spec) else { continue }
                switch route.transform.apply(stored) {
                case .refused(let why):
                    refusals.append(EncodeRefusal(
                        chain: chain, subject: "\(spec.name) · \(label(sourceParam, in: spec))",
                        message: why))
                case .value(let value):
                    if case .number(let n) = value, let range = route.engineRange, !range.contains(n) {
                        refusals.append(EncodeRefusal(
                            chain: chain, subject: "\(spec.name) · \(label(sourceParam, in: spec))",
                            message: "is \(trimmed(n)), and the engine takes "
                                   + "\(trimmed(range.lowerBound)) to \(trimmed(range.upperBound))"))
                        continue
                    }
                    params[route.to] = value
                }
            }

            nodes.append(EngineNode(id: id, type: template.type,
                                    element: block.id.uuidString,
                                    // A bypassed node keeps running and passes its dry
                                    // input, so its state stays warm: dimmed, not off.
                                    bypass: !block.isEnabled,
                                    params: params))
            connections.append(EngineConnection(from: here.node, fromPort: here.index, to: id))
            here = Port(node: id, index: 0)
        }
        return here
    }

    // MARK: One parallel section

    private static func emit(_ section: ParallelSection,
                             from source: Port,
                             into nodes: inout [EngineNode],
                             connections: inout [EngineConnection],
                             chain: String,
                             refusals: inout [EncodeRefusal]) -> Port {
        // Only a Y split is routing. A/B is two mixer gains, a crossover is a
        // Linkwitz-Riley, and a dynamic split reads a detector — all DSP the engine
        // has not built, so they are refused by name rather than quietly flattened
        // into a Y, which would look like it worked.
        guard section.splitMode == .yCable else {
            refusals.append(EncodeRefusal(
                chain: chain, subject: "a \(section.splitMode.displayName) split",
                message: "is not built on this device; only a Y split is"))
            return source
        }

        let element = section.id.uuidString
        let splitID = "\(element)-split"
        let mixID = "\(element)-mix"
        let lanes = section.lanes.count

        nodes.append(EngineNode(id: splitID, type: "nc.split", element: element,
                                params: ["outputs": .number(Double(lanes))]))
        connections.append(EngineConnection(from: source.node, fromPort: source.index, to: splitID))

        let mix = EngineNode(id: mixID, type: "nc.mix", element: element,
                             params: ["inputs": .number(Double(lanes))])

        for (index, lane) in section.lanes.enumerated() {
            // An empty lane is the dry path — this app's wet/dry split — so it is
            // wired straight from the split to the mixer. It is *not* left
            // unconnected: an unconnected mixer input is bound to silence, which is a
            // different thing and not what the canvas is showing.
            var here = emit(lane.elements,
                            from: Port(node: splitID, index: index),
                            into: &nodes, connections: &connections,
                            chain: chain, refusals: &refusals)

            if let gain = laneGain(lane) {
                let id = "\(lane.id.uuidString)-gain"
                nodes.append(EngineNode(id: id, type: "nc.gain",
                                        element: lane.id.uuidString,
                                        params: ["gain": .number(gain)]))
                connections.append(EngineConnection(from: here.node, fromPort: here.index, to: id))
                here = Port(node: id, index: 0)
            }

            connections.append(EngineConnection(from: here.node, fromPort: here.index,
                                                to: mixID, toPort: index))
        }

        // Appended after the lanes so the graph reads in signal order in a dump.
        nodes.append(mix)
        return Port(node: mixID, index: 0)
    }

    /// A lane's level, mute and polarity as one linear gain.
    ///
    /// The mixer's per-port level, mute and polarity are **runtime** state and a
    /// document cannot set them (docs/schema.md), so the lane carries a `nc.gain` of
    /// its own instead. Linear rather than dB because polarity needs the sign, and
    /// the engine's linear `gain` reaches down to -8.
    ///
    /// `pan` is not here: the engine declares one channel per port and refuses more.
    private static func laneGain(_ lane: Lane) -> Double? {
        guard lane.level != 0 || lane.isMuted || lane.invertPhase else { return nil }
        let magnitude = lane.isMuted ? 0 : pow(10, lane.level / 20)
        return lane.invertPhase ? -magnitude : magnitude
    }

    // MARK: Reading a block's values

    /// A block stores only what the user changed, so an absent value falls back to
    /// the catalogue's default — the *effective* value is what the engine must be
    /// told about, not just the overrides.
    private static func effectiveValue(_ id: String, of block: Block, spec: ComponentSpec) -> ParamValue? {
        block.values[id] ?? spec.params.first { $0.id == id }?.defaultValue
    }

    private static func label(_ id: String, in spec: ComponentSpec) -> String {
        spec.params.first { $0.id == id }?.name ?? id
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }
}

// MARK: - The fixed endpoints

/// What the chain endpoints send, and what they deliberately do not.
///
/// Phantom power, a pad, an input impedance and an output destination are **hardware**
/// (decision 7): they are remembered in the document and labelled as out-of-band, and
/// never sent as engine parameters. A knob that looks live and is not is the failure
/// this whole integration is written to avoid.
enum IOMapping {

    static let inputOutOfBand: [String: String] = [
        "source": "which socket the signal arrives on is set on the device",
        "gain": "a preamp gain is analogue and lives on the interface, not in the graph",
        "impedance": "input impedance is a property of the socket",
        "pad": "a pad is analogue, ahead of the converter",
        "phantom": "phantom power is the interface's to supply",
        "lowcut": "the preamp's high-pass is analogue; use a Low Cut block for a digital one",
    ]

    static let outputOutOfBand: [String: String] = [
        "destination": "where the output goes is the device's routing, not the rig's",
        "pan": "the engine is mono end to end and declares one channel per port",
        "mono": "there is nothing to sum: the engine is mono end to end",
    ]

    /// The one output parameter that does reach the engine, as a `nc.gain`.
    static func outputLevel(of output: IONode) -> Double? {
        guard let value = output.values["level"] ?? Catalogue.outputParams.first(where: { $0.id == "level" })?.defaultValue,
              let level = value.doubleValue else { return nil }
        return (-60...24).contains(level) ? level : nil
    }
}
