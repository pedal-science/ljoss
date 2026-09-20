import Foundation

// Assertions for the engine document encoder.
//
// Two kinds of thing are checked here. The first is the flattening convention the
// engine's own tests are written against — split/mix shape, lane ports, the dry path
// — because if it drifts the rig still sends and simply sounds wrong. The second is
// the honesty property: a mapped block must account for **every** parameter it
// exposes, either by routing it or by naming it out-of-band with a reason. That one
// fails the build rather than a run, which is the point.

// MARK: - Helpers

private func rig(_ chains: [SignalChain], layout: RigLayout = .single, name: String = "Test") -> Rig {
    Rig(name: name, layout: layout, chains: chains,
        createdAt: Date(timeIntervalSince1970: 0),
        modifiedAt: Date(timeIntervalSince1970: 0))
}

private func guitar(_ elements: [ChainElement]) -> SignalChain {
    SignalChain(name: "Guitar", source: .guitar, elements: elements)
}

/// A block with values already set, so a test does not have to reach through the
/// catalogue to say "this delay is at 1500 ms".
private func block(_ componentID: String, _ values: [String: ParamValue] = [:]) -> Block {
    Block(componentID: componentID, values: values)
}

private func element(_ componentID: String, _ values: [String: ParamValue] = [:]) -> ChainElement {
    .block(block(componentID, values))
}

/// An amp with a model chosen, which is the only way an amp encodes at all.
private func amp(_ componentID: String = "amp.brit800", model: String = "tweed/deluxe") -> Block {
    block(componentID, ["engine.model": .option(model)])
}

private func cab(_ componentID: String = "cab.412brit", ir: String = "cab-b") -> Block {
    block(componentID, ["engine.ir": .option(ir)])
}

private extension EngineChain {
    func node(_ id: String) -> EngineNode? { nodes.first { $0.id == id } }
    func nodes(ofType type: String) -> [EngineNode] { nodes.filter { $0.type == type } }
    /// Every connection into `id`, as `(fromNode, fromPort, toPort)`.
    func edges(into id: String) -> [(String, Int, Int)] {
        connections.filter { $0.to == id }.map { ($0.from, $0.fromPort, $0.toPort) }
    }
    func edge(from: String, fromPort: Int, to: String, toPort: Int) -> Bool {
        connections.contains { $0.from == from && $0.fromPort == fromPort
                            && $0.to == to && $0.toPort == toPort }
    }
}

private extension EncodeResult {
    var refusalText: String { refusals.map(\.text).joined(separator: " / ") }
}

private func number(_ node: EngineNode?, _ param: String) -> Double? {
    guard case .number(let n)? = node?.params[param] else { return nil }
    return n
}

private func text(_ node: EngineNode?, _ param: String) -> String? {
    guard case .string(let s)? = node?.params[param] else { return nil }
    return s
}

// MARK: - The mapping table accounts for everything

func testMappingIsComplete() {
    print("the mapping table accounts for every parameter it claims")

    var orphanedParams: [String] = []
    var phantomKeys: [String] = []
    var unknownComponents: [String] = []
    var reservedCollisions: [String] = []

    for id in BlockMappings.mappedIDs {
        guard let mapping = BlockMappings.mapping(for: id) else { continue }

        guard let spec = Catalogue.component(id) else {
            unknownComponents.append(id)
            continue
        }

        let routed = Set(mapping.nodes.flatMap { $0.routes.keys })
        let declared = Set(mapping.outOfBand.keys)
        let actual = Set(spec.params.map(\.id))

        // Every knob the block shows either reaches the engine or says why not.
        for param in actual.subtracting(routed).subtracting(declared).sorted() {
            orphanedParams.append("\(id).\(param)")
        }
        // …and nothing names a knob the block does not have, which is how a rename
        // in the catalogue turns into a silent no-op here.
        for param in routed.union(declared).subtracting(actual).sorted() {
            phantomKeys.append("\(id).\(param)")
        }
        // A parameter named like a reserved key would be swallowed by the parser.
        for template in mapping.nodes {
            for key in Set(template.routes.values.map(\.to)).union(template.fixed.keys)
                                                            .union(template.assets.keys) {
                if EngineNode.reservedKeys.contains(key) { reservedCollisions.append("\(id).\(key)") }
            }
        }
    }

    check(unknownComponents.isEmpty,
          "every mapped id is a real component\(unknownComponents.isEmpty ? "" : ": \(unknownComponents)")")
    check(orphanedParams.isEmpty,
          "no parameter is silently dropped\(orphanedParams.isEmpty ? "" : ": \(orphanedParams)")")
    check(phantomKeys.isEmpty,
          "no mapping names a parameter the block does not have\(phantomKeys.isEmpty ? "" : ": \(phantomKeys)")")
    check(reservedCollisions.isEmpty,
          "no engine parameter collides with a reserved key\(reservedCollisions.isEmpty ? "" : ": \(reservedCollisions)")")
    check(BlockMappings.mappedIDs.count > 20, "the table is not empty")
}

// MARK: - The flattening convention

func testParallelShape() {
    print("a parallel section becomes split, lanes, mix")

    let wet = Lane(elements: [element("delay.slapback")])
    var dry = Lane()
    let section = ParallelSection(lanes: [wet, dry])
    dry = section.lanes[1]

    let result = DocumentEncoder.encode(rig([guitar([.parallel(section)])]))
    guard let chain = result.document?.chains.first else {
        check(false, "the rig encodes at all: \(result.refusalText)")
        return
    }

    let parallel = section.id.uuidString
    let split = "\(parallel)-split"
    let mix = "\(parallel)-mix"

    check(chain.node(split)?.type == "nc.split", "there is one nc.split")
    check(chain.node(mix)?.type == "nc.mix", "there is one nc.mix")
    check(number(chain.node(split), "outputs") == 2, "outputs is the lane count")
    check(number(chain.node(mix), "inputs") == 2, "inputs is the lane count")
    check(chain.node(split)?.element == parallel && chain.node(mix)?.element == parallel,
          "the parallel's element id is on both nodes")

    let delayNode = "\(wet.elements[0].id.uuidString)-delay"
    check(chain.edge(from: split, fromPort: 0, to: delayNode, toPort: 0),
          "lane 0 hangs off split port 0")
    check(chain.edge(from: delayNode, fromPort: 0, to: mix, toPort: 0),
          "…and rejoins on mix port 0")

    // The empty lane is this app's wet/dry split: it carries the *dry signal*, so it
    // is wired straight through. Leaving it unconnected would bind it to silence,
    // which is a different thing and not what the canvas is showing.
    check(chain.edge(from: split, fromPort: 1, to: mix, toPort: 1),
          "an empty lane is wired split-to-mix — the dry path, not silence")
    check(chain.edges(into: mix).count == 2, "every lane reaches the mixer exactly once")
}

func testLaneMixing() {
    print("a lane's level, mute and polarity become a gain node")

    var quiet = Lane(elements: [element("util.gain")])
    quiet.level = -6
    var flipped = Lane(elements: [element("util.gain")])
    flipped.invertPhase = true
    var muted = Lane(elements: [element("util.gain")])
    muted.isMuted = true
    let plain = Lane(elements: [element("util.gain")])

    let section = ParallelSection(lanes: [quiet, flipped, muted, plain])
    let result = DocumentEncoder.encode(rig([guitar([.parallel(section)])]))
    guard let chain = result.document?.chains.first else {
        check(false, "the rig encodes at all: \(result.refusalText)")
        return
    }

    let level = number(chain.node("\(section.lanes[0].id.uuidString)-gain"), "gain") ?? .nan
    check(abs(level - 0.5011872336) < 1e-6, "-6 dB is a linear 0.501")
    check(number(chain.node("\(section.lanes[1].id.uuidString)-gain"), "gain") == -1,
          "inverted phase is a negative gain")
    check(number(chain.node("\(section.lanes[2].id.uuidString)-gain"), "gain") == 0,
          "a muted lane is a zero gain")
    check(chain.node("\(section.lanes[3].id.uuidString)-gain") == nil,
          "a lane at its defaults costs no node at all")
}

func testChannelsAndHiddenChains() {
    print("chains bind to channels by position, and a hidden one still goes")

    let both = rig([guitar([element("util.gain")]),
                    SignalChain(name: "Vocal", source: .vocal, elements: [element("util.gain")])],
                   layout: .dual)
    let dual = DocumentEncoder.encode(both)
    check(dual.document?.chains.count == 2, "two chains")
    check(dual.document?.chains[0].inputChannel == 0 && dual.document?.chains[0].outputChannel == 0,
          "the first chain is on channel 0")
    check(dual.document?.chains[1].inputChannel == 1 && dual.document?.chains[1].outputChannel == 1,
          "the second chain is on channel 1")
    check(dual.hiddenChainIDs.isEmpty, "a dual layout hides nothing")

    // layout is a viewing preference: hiding a chain must not silently change what
    // is audible, so it is still sent and then muted, visibly.
    var hidden = both
    hidden.layout = .single
    let single = DocumentEncoder.encode(hidden)
    check(single.document?.chains.count == 2, "a hidden chain is still sent")
    check(single.hiddenChainIDs == [both.chains[1].id.uuidString],
          "…and is reported so it can be muted")
}

func testEndpoints() {
    print("the chain endpoints")

    let plain = DocumentEncoder.encode(rig([guitar([element("util.gain")])]))
    guard let chain = plain.document?.chains.first else {
        check(false, "the rig encodes at all: \(plain.refusalText)")
        return
    }
    check(chain.node("in")?.type == "nc.input", "a chain starts at nc.input")
    check(chain.node("out")?.type == "nc.output", "…and ends at nc.output")
    check(chain.nodes(ofType: "nc.gain").count == 1,
          "an output at unity costs no fader node")

    var loud = guitar([])
    loud.output.values["level"] = .number(-9)
    guard let faded = DocumentEncoder.encode(rig([loud])).document?.chains.first else {
        check(false, "a rig with an output level encodes")
        return
    }
    let fader = faded.node("\(loud.output.id.uuidString)-level")
    check(number(fader, "gain_db") == -9, "an output level becomes a nc.gain in dB")
    check(faded.edge(from: fader?.id ?? "", fromPort: 0, to: "out", toPort: 0),
          "…sitting just before nc.output")
}

// MARK: - Blocks

func testBlockLowering() {
    print("a block becomes engine nodes")

    let a = amp()
    let result = DocumentEncoder.encode(rig([guitar([.block(a), .block(cab())])]))
    guard let chain = result.document?.chains.first else {
        check(false, "an amp with a model encodes: \(result.refusalText)")
        return
    }

    let nam = chain.node("\(a.id.uuidString)-nam")
    let tone = chain.node("\(a.id.uuidString)-tone")
    check(nam?.type == "nc.nam" && tone?.type == "fx.amp.tonestack",
          "an amp is a NAM capture then a tone stack")
    check(nam?.element == a.id.uuidString && tone?.element == a.id.uuidString,
          "both carry the block's element id")
    check(text(nam, "model") == "tweed/deluxe", "the model goes by library id, not by path")
    check(chain.edge(from: nam?.id ?? "", fromPort: 0, to: tone?.id ?? "", toPort: 0),
          "…wired in series")

    // brit800's knobs default to bass 5, mid 5, treble 6 — the centre detent is flat.
    check(number(tone, "bass") == 0, "a tone knob at its centre is 0 dB")
    check(abs((number(tone, "treble") ?? .nan) - 2.4) < 1e-9, "…and one notch up is 2.4 dB")

    // A block stores only what the user changed, so the encoder has to read the
    // catalogue's default for everything else.
    let tilt = block("eq.tilt")
    guard let defaults = DocumentEncoder.encode(rig([guitar([.block(tilt)])])).document?.chains.first else {
        check(false, "a block with no stored values encodes")
        return
    }
    let eq = defaults.node("\(tilt.id.uuidString)-eq")
    check(number(eq, "tilt") == 0 && number(eq, "freq") == 900,
          "an untouched block sends the catalogue's defaults, not nothing")
}

func testBypass() {
    print("isEnabled becomes bypass, on every node of the block")

    var off = amp()
    off.isEnabled = false
    guard let chain = DocumentEncoder.encode(rig([guitar([.block(off)])])).document?.chains.first else {
        check(false, "a bypassed amp encodes")
        return
    }
    let mine = chain.nodes.filter { $0.element == off.id.uuidString }
    check(mine.count == 2 && mine.allSatisfy(\.bypass),
          "both of the amp's nodes carry the flag, so the chain stays transparent")
    check(chain.node("in")?.bypass == false, "and nothing else does")
}

// MARK: - Refusals

func testRefusals() {
    print("what the engine cannot do is refused by name")

    let unmapped = DocumentEncoder.encode(rig([guitar([element("drive.green")])]))
    check(unmapped.document == nil, "a rig with an unrenderable block does not encode")
    check(unmapped.refusalText.contains("Green Overdrive")
          && unmapped.refusalText.contains("no engine equivalent"),
          "…and the refusal names the block")

    let modelless = DocumentEncoder.encode(rig([guitar([element("amp.brit800")])]))
    check(modelless.document == nil && modelless.refusalText.contains("amp model"),
          "an amp with no model chosen is refused, naming what it needs")

    let crossover = ParallelSection(lanes: [Lane(elements: [element("util.gain")]), Lane()],
                                    splitMode: .crossover)
    let split = DocumentEncoder.encode(rig([guitar([.parallel(crossover)])]))
    check(split.document == nil && split.refusalText.contains("Crossover"),
          "a split mode the engine has not built is refused rather than flattened to a Y")

    let long = DocumentEncoder.encode(rig([guitar([element("delay.digital", ["time": .number(1500)])])]))
    check(long.document == nil
          && long.refusalText.contains("1500") && long.refusalText.contains("1000"),
          "a delay past the engine's line length is refused, naming both numbers")

    let shallow = DocumentEncoder.encode(rig([guitar([element("eq.lowcut", ["slope": .option("6 dB")])])]))
    check(shallow.document == nil && shallow.refusalText.contains("6 dB"),
          "a slope the engine's cuts do not reach is refused by name")

    // Everything wrong at once, so a player fixes it in one pass rather than in six.
    let messy = DocumentEncoder.encode(rig([guitar([
        element("drive.green"), element("verb.hall"), element("amp.brit800"),
    ])]))
    check(messy.refusals.count == 3, "every refusal is collected, not just the first")
}

func testStarterRigsAreHonest() {
    print("the starter rigs say what they cannot play")

    for starter in RigFactory.starterRigs() {
        let result = DocumentEncoder.encode(starter)
        check(result.document == nil && !result.refusals.isEmpty,
              "“\(starter.name)” is refused rather than half-sent")
        check(result.refusals.allSatisfy { !$0.text.isEmpty },
              "…with a reason for each block")
    }
}

// MARK: - The wire

func testDocumentIsStable() {
    print("the encoded document is stable and well formed")

    let source = rig([guitar([.block(amp()), .block(cab()), element("delay.slapback")])],
                     name: "Crunch")
    let result = DocumentEncoder.encode(source)
    guard let document = result.document else {
        check(false, "the rig encodes: \(result.refusalText)")
        return
    }

    let once = try? document.jsonData()
    let twice = try? DocumentEncoder.encode(source).document?.jsonData()
    check(once != nil && once == twice, "encoding twice gives the same bytes")

    let json = (try? document.jsonString()) ?? ""
    check(json.contains("\"chains\"") && json.contains("\"input_channel\""),
          "the chain envelope uses the engine's spelling")
    check(json.contains("\"nc.nam\"") && !json.contains("\"params\""),
          "parameters are written inline, as the engine's own rig files write them")

    // Ids have to be unique inside a chain: the engine resolves a connection by name.
    let ids = document.chains.flatMap { $0.nodes.map(\.id) }
    check(Set(ids).count == ids.count, "no two nodes share an id")

    // Nothing may name a node that is not there.
    let known = Set(ids)
    let dangling = document.chains.flatMap { $0.connections }
        .filter { !known.contains($0.from) || !known.contains($0.to) }
    check(dangling.isEmpty, "no connection names a node that does not exist")
}
