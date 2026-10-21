import Foundation

// The tuner's two Foundation-only halves: the node the encoder mounts around the panel, and the
// reading `rig.state` carries back.
//
// What is asserted is what a bug would look like from the outside: a tuner node in the wrong place
// in the chain (muting the wrong thing, or nothing), a node that reached a document with the panel
// closed, a `rig.state` reply the decoder rejects because a rig also holds a flowEQ (the heterogeneous
// `state` object), and a reading the engine withheld being drawn as the last note played.

// MARK: - The node the encoder mounts

private func rig(_ chains: [SignalChain], layout: RigLayout = .single, name: String = "Test") -> Rig {
    Rig(name: name, layout: layout, chains: chains,
        createdAt: Date(timeIntervalSince1970: 0),
        modifiedAt: Date(timeIntervalSince1970: 0))
}

private func guitar(_ elements: [ChainElement]) -> SignalChain {
    SignalChain(name: "Guitar", source: .guitar, elements: elements)
}

private func block(_ componentID: String, _ values: [String: ParamValue] = [:]) -> Block {
    Block(componentID: componentID, values: values)
}

private func amp(_ componentID: String = "amp.brit800", model: String = "tweed/deluxe") -> Block {
    block(componentID, ["engine.model": .option(model)])
}

private extension EngineChain {
    func node(_ id: String) -> EngineNode? { nodes.first { $0.id == id } }
    func tunerIndex() -> Int? { nodes.firstIndex { $0.type == DocumentEncoder.tunerNodeType } }
}

func testTunerNodeIsFirstAfterTheInput() {
    let ampChain = guitar([.block(amp())])
    let encoded = DocumentEncoder.encode(rig([ampChain]), tuner: true)
    guard let document = encoded.document, let chain = document.chains.first else {
        check(false, "a rig with a tuner splice still encodes")
        return
    }
    check(chain.nodes.first?.type == "nc.input", "the chain still starts with its input")
    // An amp is two nodes (its model and its tone stack), which is why the count is what it is: the
    // point is the position of the tuner, not anybody's idea of how many nodes an amp makes.
    check(chain.nodes.count == 5, "input, tuner, the amp's two, output (got \(chain.nodes.count))")
    check(chain.nodes[1].type == DocumentEncoder.tunerNodeType,
          "the tuner is the first node after the input")
    check(chain.nodes[1].meta["ephemeral"] == DocumentEncoder.tunerMarker,
          "the node is marked as the client's, so a resume record can leave it out")
    check(chain.nodes[1].element == DocumentEncoder.tunerElement, "and names where it came from")

    // The wiring: everything the input fed now hangs off the tuner, which is what makes the chain
    // silent rather than merely different.
    let intoTuner = chain.connections.filter { $0.to == chain.nodes[1].id }
    check(intoTuner.count == 1 && intoTuner.first?.from == "in",
          "the input's only consumer is the tuner")
    let outOfTuner = chain.connections.filter { $0.from == chain.nodes[1].id }
    check(outOfTuner.count == 1 && outOfTuner.first?.to == chain.nodes[2].id,
          "and the tuner feeds what the input used to")
    check(!chain.connections.contains { $0.from == "in" && $0.to != chain.nodes[1].id },
          "no connection skips the tuner, which would keep the old path audible")
}

func testTunerNodeIsNotInTheDocumentWithThePanelClosed() {
    // The default is what every other caller gets -- the export, the refusal encode -- and the
    // tuner must never reach a saved document or a zip.
    let encoded = DocumentEncoder.encode(rig([guitar([.block(amp())])]))
    guard let document = encoded.document else {
        check(false, "the rig encodes")
        return
    }
    check(!document.chains.contains { $0.tunerIndex() != nil }, "no tuner node with the panel closed")
}

func testTunerNodeInEveryChainAndAnEmptyOne() {
    // Two chains get one each, with per-chain ids: `in`/`out` are the only ids the encoder reuses,
    // and a duplicate would be ambiguous in `rig.get`.
    let dual = rig([guitar([.block(amp())]), SignalChain(name: "Vocal", source: .vocal, elements: [])],
                   layout: .dual)
    let encoded = DocumentEncoder.encode(dual, tuner: true)
    guard let document = encoded.document else {
        check(false, "the dual rig encodes")
        return
    }
    check(document.chains.count == 2, "two chains")
    check(document.chains.allSatisfy { $0.tunerIndex() == 1 }, "one after each chain's input")
    let ids = document.chains.compactMap { chain in chain.tunerIndex().map { chain.nodes[$0].id } }
    check(ids.count == 2 && Set(ids).count == 2, "with distinct ids, so `rig.get` can name one (got \(ids))")

    // A chain with no blocks: input, tuner, output, and the tuner's output is the output.
    if let empty = document.chains.last {
        check(empty.nodes.count == 3, "an empty chain is input, tuner, output (got \(empty.nodes.count))")
        check(empty.connections.contains { $0.from == empty.nodes[1].id && $0.to == "out" },
              "the tuner feeds the output directly")
    }
}

func testTunerNodeSurvivesAParallelSection() {
    // A parallel section is a split, its lanes and a mix; the tuner is before the split, so both
    // lanes are silent, not one.
    let parallel = ChainElement.parallel(ParallelSection(lanes: [Lane(elements: [.block(amp())]), Lane()]))
    let encoded = DocumentEncoder.encode(rig([guitar([parallel])]), tuner: true)
    guard let chain = encoded.document?.chains.first, let tuner = chain.tunerIndex() else {
        check(false, "the parallel rig encodes with a tuner")
        return
    }
    check(tuner == 1, "the tuner is before the split")
    let split = chain.nodes.firstIndex { $0.type == "nc.split" }
    check(split != nil && chain.connections.contains { $0.from == chain.nodes[1].id && $0.to == chain.nodes[split!].id },
          "the split is fed by the tuner")
}

private func mountedNode(_ document: EngineDocument?, _ chain: Int = 0) -> EngineNode? {
    guard let chain = document?.chains[safe: chain] else { return nil }
    return chain.nodes.first { $0.type == DocumentEncoder.tunerNodeType }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

func testTunerNodeCarriesTheSwitch() {
    // The node's default is silence, so a muted tuner says nothing and an open one has to say so --
    // the engine builds the node from what the document asks (namchain docs/tuner.md).
    let dual = rig([guitar([.block(amp())]), SignalChain(name: "Vocal", source: .vocal, elements: [])],
                   layout: .dual)
    let muted = DocumentEncoder.encode(dual, tuner: true)
    let open = DocumentEncoder.encode(dual, tuner: true, tunerMute: false)

    for chain in 0..<2 {
        guard let mutedNode = mountedNode(muted.document, chain),
              let openNode = mountedNode(open.document, chain) else {
            check(false, "both documents carry a tuner in every chain")
            continue
        }
        check(mutedNode.params.isEmpty, "a muted tuner declares no parameters")
        check(openNode.params[DocumentEncoder.tunerMuteParam] == .number(0),
              "an open one says so (got \(String(describing: openNode.params)))")
        check(openNode.meta["ephemeral"] == DocumentEncoder.tunerMarker,
              "and is still marked as the client's")
    }
}

// MARK: - The reading

private func stateReply(_ state: JSONValue?, type: String = "nc.tuner") -> StateResponse {
    let node = EngineNodeState(chain: "main", node: "tuner", element: "tuner", role: "", type: type, state: state)
    return StateResponse(generation: 1, nodes: [node])
}

private func tunerState(valid: Bool, note: String = "", octave: Int = 0, cents: Double = 0,
                       hz: Double = 0, levelDb: Double = -18, a4: Double = 440,
                       muted: Bool = true) -> JSONValue {
    var fields: [String: JSONValue] = [
        "a4": .number(a4), "blocks": .number(1500), "valid": .bool(valid), "level_db": .number(levelDb),
        "mute": .bool(muted),
    ]
    if valid {
        fields["note"] = .string(note)
        fields["octave"] = .number(Double(octave))
        fields["midi"] = .number(45)
        fields["cents"] = .number(cents)
        fields["hz"] = .number(hz)
        fields["steady_hz"] = .number(hz)
        fields["clarity"] = .number(0.93)
        fields["uncertainty_cents"] = .number(0.08)
        fields["partials"] = .number(5)
    }
    return .object(fields)
}

func testTunerReadingCarriesTheSwitch() {
    // The panel's button shows the player's intent; this is the engine's answer, and the two
    // disagreeing is what a refused patch looks like.
    let open = tunerState(valid: true, note: "A", octave: 4, cents: 0, hz: 440, muted: false)
    check(!TunerReading.decoding(stateReply(open)).muted, "the switch is read as the engine has it")

    // A node that predates the switch, or a state with it missing: muted is the node's default, and
    // a panel that guessed "audible" would claim a mute it does not have.
    check(TunerReading.decoding(stateReply(.object(["valid": .bool(true)]))).muted,
          "no key means the default, which is muted")

    // A flag arrives as 0/1 sometimes, which is the same answer.
    let asNumber = stateReply(.object(["valid": .bool(true), "mute": .number(0)]))
    check(!TunerReading.decoding(asNumber).muted, "0 is open, however it is spelled")
}

func testTunerReadingDecodes() {
    let reading = TunerReading.decoding(stateReply(tunerState(valid: true, note: "A", octave: 2,
                                                            cents: -1.73, hz: 109.56)))
    check(reading.available && reading.running && reading.valid, "a note is a note")
    check(reading.noteText == "A2", "the note and its octave (got \(reading.noteText))")
    check(reading.centsText == "-1.7", "cents, one decimal, signed (got \(reading.centsText))")
    check(reading.inTune, "1.7 cents is in tune")
    check(reading.hzText == "109.6 Hz", "the frequency (got \(reading.hzText))")
    check(reading.levelText == "-18 dB", "the input level (got \(reading.levelText))")
    check(reading.a4Text == "A4 = 440 Hz", "the reference (got \(reading.a4Text))")
    if let needle = reading.needle {
        check(abs(needle - (-1.73 / 50)) < 1e-9, "the needle sits left of centre by its cents")
    } else {
        check(false, "a valid reading has a needle")
    }
    check(abs(reading.levelFraction - 0.7) < 0.01, "and the level is a fraction of its meter")
}

func testTunerReadingWithholdsANote() {
    // The engine omits the note keys when it has none: no stale "A" on screen, and no needle, which
    // would read as in tune.
    let reading = TunerReading.decoding(stateReply(tunerState(valid: false, levelDb: -74)))
    check(reading.available && reading.running, "the node is there")
    check(!reading.valid, "and has no note")
    check(reading.noteText.isEmpty && reading.centsText.isEmpty && reading.hzText.isEmpty,
          "nothing note-shaped is drawn")
    check(reading.needle == nil, "no needle")
    check(reading.status == "No note", "the panel says so (got \(reading.status))")
}

func testTunerReadingWhenTheNodeIsNotRunning() {
    // The failure that matters: the panel is open and the amp is still audible, because a publish
    // was refused or the engine is too old for the node.
    let reply = StateResponse(generation: 2, nodes: [])
    let reading = TunerReading.decoding(reply)
    check(reading.available, "the engine answered")
    check(!reading.running, "but it is running no tuner node")
    check(reading.status.contains("not muted"), "and the panel says the rig is not muted (got \(reading.status))")
    check(!reading.valid && reading.needle == nil, "with nothing to draw")
}

func testTunerReadingIgnoresOtherNodes() {
    // `rig.state` carries every reporting node: flowEQ's state has arrays and objects in it, and a
    // fixed decoder for the tuner's shape would fail the whole reply (EngineClient turns that into
    // `.malformed`). This is the reply that proves the JSONValue detour works.
    let flow = EngineNodeState(chain: "main", node: "eq", element: "eq", role: "", type: "nc.eq.flow",
                               state: .object(["model": .string("vae3d_beta_0.0010"),
                                               "bands": .array([.object(["gain_db": .number(-0.25)])]),
                                               "curve": .object(["points": .array([.number(1), .number(2), .number(3)])])]))
    let tuner = EngineNodeState(chain: "main", node: "tuner", element: "tuner", role: "",
                                type: "nc.tuner",
                                state: tunerState(valid: true, note: "E", octave: 2, cents: 0.4, hz: 82.41))
    let reading = TunerReading.decoding(StateResponse(generation: 3, nodes: [flow, tuner]))
    check(reading.valid && reading.noteText == "E2", "the tuner's entry is the one read")
}

// MARK: - The strobe

func testStrobeDriftsByCentsAndPartial() {
    // Ported law (namchain docs/tuner.md, "The strobe"): row k drifts 0.5 * cents * k periods per
    // second, clamped at 12. Ten cents sharp for a tenth of a second is 0.5, 1 and 2 periods, so the
    // first row lands half way, the second comes back round, and the fourth is clamped to 12
    // periods a second and lands at a fifth.
    var strobe = TunerStrobe()
    strobe.advance(seconds: 0.1, cents: 10, valid: true)
    check(abs(strobe.phases[0] - 0.5) < 0.01, "the fundamental half a period (got \(strobe.phases[0]))")
    check(abs(strobe.phases[1]) < 0.01 || abs(strobe.phases[1] - 1) < 0.01, "the octave a whole one")
    check(abs(strobe.phases[2] - 0.2) < 0.01, "the fourth clamped, at a fifth (got \(strobe.phases[2]))")
    check(strobe.activity > TunerStrobe.settledActivity + 0.1,
          "and the bands have come up while there is a note (got \(strobe.activity))")

    // Flat drifts the other way, which is the row leaning left.
    var flat = TunerStrobe()
    flat.advance(seconds: 0.1, cents: -10, valid: true)
    check(abs(flat.phases[0] - 0.5) < 0.01, "flat wraps the other way to the same half way")

    // In tune: every row stands still, which is the reading a player tunes to.
    var tuned = TunerStrobe()
    tuned.advance(seconds: 0.3, cents: 0, valid: true)
    check(tuned.phases == [0, 0, 0], "a perfect note does not drift")

    // No note: nothing to drift, and the bands settle rather than animating a reading that is not
    // there.
    var idle = TunerStrobe()
    idle.advance(seconds: 0.3, cents: 30, valid: false)
    check(idle.phases == [0, 0, 0], "no note, no drift")
    check(idle.activity < TunerStrobe.settledActivity + 0.01, "and the rows have faded")
}

func testStrobeClampsAndSurvivesAStall() {
    // 50 cents unclamped is 25 periods a second. A quarter of a second is six periods, which wraps
    // to nothing; the clamp's twelve is three whole periods, so the row is back at the start either
    // way -- so the check is on the *rate*, which is what the clamp is for.
    var strobe = TunerStrobe()
    strobe.advance(seconds: 1.0 / 24.0, cents: 50, valid: true) // 12 / 24 = half a period
    check(abs(strobe.phases[0] - 0.5) < 0.01, "the clamp's twelve periods a second (got \(strobe.phases[0]))")

    // A stalled clock (a suspension, a debugger) must not teleport the bands a whole period, and a
    // zero or negative interval must not divide by it.
    let before = strobe.phases[0]
    strobe.advance(seconds: 30, cents: 50, valid: true)
    check(strobe.phases[0] < 1 && strobe.phases[0] >= 0, "a stall is clamped, not taken literally")
    check(strobe.phases[0] != before || before == 0, "and it still moves a frame's worth")
    strobe.advance(seconds: 0, cents: 50, valid: true)
    check(strobe.phases[0] >= 0 && strobe.phases[0] < 1, "a zero interval is a frame, not a crash")
}

func testStrobeOffsetIsTheDirectionAPlayerReads() {
    // Sharp drifts right: the view's offset grows with the phase, and the reference has the bands
    // moving right too (hosts/web/strobe.js translates by +phase * period).
    var strobe = TunerStrobe()
    strobe.advance(seconds: 0.1, cents: 10, valid: true) // ten cents: half a period, no wrap
    check(strobe.offset(0, period: 100) > 0, "a sharp note puts the bands to the right")
    check(abs(strobe.offset(0, period: 100) - strobe.phases[0] * 100) < 0.001,
          "the offset is the phase in the view's own units")
    check(strobe.offset(9, period: 100) == 0, "a row that is not there has no offset")
}

func testTunerStateDecodesThroughJSON() {
    // The wire, end to end: a real `rig.state` body, snake_case keys and all, decoded by the same
    // decoder `EngineClient` uses.
    let body = """
    {"ok":true,"generation":7,"nodes":[
      {"chain":"main","node":"eq","element":"eq","role":"","type":"nc.eq.flow",
       "state":{"model":"vae3d_beta_0.0010","latent":[0.5,0.0,0.0],"curve":{"points":[1,2,3]}}},
      {"chain":"main","node":"tuner","element":"tuner","role":"","type":"nc.tuner",
       "state":{"a4":440.0,"blocks":1450,"valid":true,"level_db":-17.2,"midi":45,"note":"A",
                "octave":2,"cents":-1.73,"hz":109.56,"steady_hz":109.98,"clarity":0.93,
                "uncertainty_cents":0.08,"partials":5}}]}
    """
    guard let response = try? EngineCoding.decoder.decode(StateResponse.self, from: Data(body.utf8)) else {
        check(false, "a real rig.state body decodes, flowEQ's arrays and objects included")
        return
    }
    check(response.nodes?.count == 2, "both reporting nodes decode")
    let reading = TunerReading.decoding(response)
    check(reading.noteText == "A2" && reading.centsText == "-1.7",
          "and the tuner's is the reading")
}
