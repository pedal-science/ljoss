import Foundation

// Assertions for deciding how an edit reaches the engine.
//
// The rule being protected: a change is streamed as ramps only when the engine will
// ramp every part of it, and anything else is structural. A false "ramp" is the worse
// mistake — a patch the engine turns into a rebuild at every step of a drag — so most
// of these are cases that must come out structural.

// MARK: - Helpers

private let origin = Date(timeIntervalSince1970: 0)

private func rig(_ elements: [ChainElement], name: String = "Test") -> Rig {
    Rig(name: name, chains: [SignalChain(name: "Guitar", source: .guitar, elements: elements)],
        createdAt: origin, modifiedAt: origin)
}

/// The same rig with one value of the block at `index` changed.
private func setting(_ rig: Rig, block index: Int, _ key: String, _ value: ParamValue) -> Rig {
    var copy = rig
    guard case .block(var block) = copy.chains[0].elements[index] else { return copy }
    block.values[key] = value
    copy.chains[0].elements[index] = .block(block)
    return copy
}

private func blockID(_ rig: Rig, _ index: Int) -> String {
    rig.chains[0].elements[index].id.uuidString
}

private func document(_ rig: Rig) -> EngineDocument {
    guard let document = DocumentEncoder.encode(rig).document else {
        check(false, "the test rig encodes: \(DocumentEncoder.encode(rig).refusals.map(\.text))")
        return EngineDocument(name: "", chains: [])
    }
    return document
}

private func change(_ from: Rig, _ to: Rig, _ catalogue: EngineCatalogue = testCatalogue) -> DocumentChange {
    EngineEdits.change(from: document(from), to: document(to), catalogue: catalogue)
}

private func isStructural(_ change: DocumentChange) -> Bool { change == .structural }

private func edits(_ change: DocumentChange) -> [ParamEdit] {
    if case .ramps(let edits) = change { return edits }
    return []
}

/// `engine.schema` as the daemon writes it, trimmed to the types these tests use, with
/// the fields a client does not need here left in so decoding is shown to skip them.
private let schemaJSON = """
{ "ok": true, "id": "4", "protocol": 2, "max_chains": 8, "stereo": false, "nodes": [
  { "id": "nc.input", "kind": "primitive", "params": [] },
  { "id": "nc.output", "kind": "primitive", "params": [] },
  { "id": "nc.gain", "kind": "primitive", "name": "Gain", "category": "utility",
    "params": [ { "id": "gain_db", "kind": "number", "unit": "dB", "rampable": true },
                { "id": "gain", "kind": "number", "rampable": true, "hidden": true },
                { "id": "ramp_ms", "kind": "number", "unit": "ms", "rampable": false } ] },
  { "id": "nc.nam", "kind": "primitive",
    "params": [ { "id": "model", "kind": "option", "rampable": false, "options_from": "models",
                  "options": [ { "value": "A2", "label": "A2" } ] } ] },
  { "id": "nc.split", "kind": "primitive", "params": [ { "id": "outputs", "rampable": false } ] },
  { "id": "nc.mix", "kind": "primitive", "params": [ { "id": "inputs", "rampable": false } ] },
  { "id": "fx.amp.tonestack", "kind": "macro", "bypass": "roles",
    "roles": [ { "role": "bass", "type": "nc.eq.biquad" } ],
    "params": [ { "id": "bass", "rampable": true,
                  "targets": [ { "role": "bass", "param": "gain_db", "transform": "direct" } ] },
                { "id": "mid", "rampable": true }, { "id": "treble", "rampable": true },
                { "id": "mid_freq", "rampable": true } ] },
  { "id": "fx.eq.bands", "kind": "macro",
    "params": [ { "id": "bands", "rampable": false }, { "id": "freq1", "rampable": true },
                { "id": "gain1", "rampable": true }, { "id": "freq2", "rampable": true },
                { "id": "gain2", "rampable": true }, { "id": "q2", "rampable": true },
                { "id": "gain4", "rampable": true } ] },
  { "id": "fx.filter.cut", "kind": "macro",
    "params": [ { "id": "low_cut", "rampable": true },
                { "id": "low_slope", "kind": "option", "rampable": false },
                { "id": "high_cut", "rampable": true },
                { "id": "high_slope", "kind": "option", "rampable": false } ] },
  { "id": "fx.delay.feedback", "kind": "macro",
    "params": [ { "id": "time", "rampable": true }, { "id": "feedback", "rampable": true },
                { "id": "mix", "rampable": true } ] } ] }
"""

private let testCatalogue: EngineCatalogue = {
    let schema = (try? EngineCoding.decoder.decode(SchemaResponse.self, from: Data(schemaJSON.utf8)))
        ?? SchemaResponse()
    return EngineCatalogue(schema: schema)
}()

// MARK: - The catalogue

func testSchemaCatalogue() {
    print("what the engine ramps, from engine.schema")

    let schema = try? EngineCoding.decoder.decode(SchemaResponse.self, from: Data(schemaJSON.utf8))
    check(schema?.nodes?.count == 10, "the schema decodes, skipping what this does not read")

    check(testCatalogue.ramps("nc.gain", "gain_db"), "a rampable parameter ramps")
    check(!testCatalogue.ramps("nc.gain", "ramp_ms"), "…and one marked not rampable does not")
    check(!testCatalogue.ramps("nc.nam", "model"), "a model is a rebuild")
    check(!testCatalogue.ramps("fx.filter.cut", "low_slope"), "…and so is a cut's slope")
    check(!testCatalogue.ramps("nc.unknown", "gain_db"), "a type the schema does not list ramps nothing")
    check(testCatalogue.isMacro("fx.amp.tonestack") && !testCatalogue.isMacro("nc.gain"),
          "macros are told apart from primitives by kind")

    var learned = testCatalogue
    learned.stopRamping("nc.gain", "gain_db")
    check(!learned.ramps("nc.gain", "gain_db") && learned.ramps("nc.gain", "gain"),
          "a parameter the engine rebuilt for stops streaming, and only that one")
}

// MARK: - What streams

func testWhatStreams() {
    print("which edits stream as ramps")

    // A primitive, named by the id this app gave it.
    let gain = rig([.block(Block(componentID: "util.gain"))])
    let louder = setting(gain, block: 0, "gain", .number(-3))
    check(change(gain, gain) == .none, "an unchanged rig sends nothing")
    check(change(gain, louder) == .ramps([ParamEdit(
              chain: gain.chains[0].id.uuidString, target: .node("\(blockID(gain, 0))-gain"),
              param: "gain_db", value: -3, type: "nc.gain")]),
          "a gain knob is one ramp, addressed to its node")

    // A macro, named by its element: its own node is expanded away when the engine compiles.
    var ampBlock = Block(componentID: "amp.brit800")
    ampBlock.values[AssetKind.model.valueKey] = .option("A2")
    let amp = rig([.block(ampBlock)])
    let bassier = setting(amp, block: 0, "bass", .number(7))
    let bass = edits(change(amp, bassier))
    check(bass.count == 1 && bass.first?.target == .element(blockID(amp, 0))
              && bass.first?.param == "bass" && bass.first?.type == "fx.amp.tonestack",
          "an amp's tone knob is a ramp on the tone stack, addressed by element")
    check(abs((bass.first?.value ?? 0) - 4.8) < 1e-9,
          "…carrying the engine's value after the block's transform, not the knob's")
    check(change(amp, setting(amp, block: 0, "gain", .number(9))) == .none,
          "a knob that is not sent (an amp's gain) sends nothing")

    // Two knobs moved between one call and the next.
    let eq = rig([.block(Block(componentID: "eq.parametric"))])
    let shaped = setting(setting(eq, block: 0, "lowgain", .number(3)), block: 0, "midgain", .number(-2))
    let both = edits(change(eq, shaped))
    check(both.map(\.param) == ["gain1", "gain2"]
              && both.allSatisfy { $0.target == .element(blockID(eq, 0)) },
          "two knobs of one block are two ramps")

    // The cases that must not stream.
    check(isStructural(change(amp, setting(amp, block: 0, AssetKind.model.valueKey, .option("B7")))),
          "a model change is structural")
    var bypassed = gain
    if case .block(var block) = bypassed.chains[0].elements[0] {
        block.isEnabled = false
        bypassed.chains[0].elements[0] = .block(block)
    }
    check(isStructural(change(gain, bypassed)), "a bypass is structural, for now")
    var longer = gain
    longer.chains[0].elements.append(.block(Block(componentID: "util.gain")))
    check(isStructural(change(gain, longer)), "adding a block is structural")
    let cut = rig([.block(Block(componentID: "eq.lowcut"))])
    check(isStructural(change(cut, setting(cut, block: 0, "slope", .option("24 dB")))),
          "a cut's slope is structural")
    check(!edits(change(cut, setting(cut, block: 0, "freq", .number(120)))).isEmpty,
          "…while its frequency streams")
    var renamed = gain
    renamed.name = "Renamed"
    check(isStructural(change(gain, renamed)), "a rig's name needs the whole document")
    check(isStructural(change(gain, louder, EngineCatalogue(rampable: [:], macros: []))),
          "a device that ramps nothing gets whole documents")
}

func testLaneLevelStreams() {
    print("a lane's level streams once its node exists")

    let section = ParallelSection(lanes: [Lane(elements: [.block(Block(componentID: "util.gain"))]), Lane()])
    let flat = rig([.parallel(section)])

    func level(_ rig: Rig, _ decibels: Double) -> Rig {
        var copy = rig
        guard case .parallel(var parallel) = copy.chains[0].elements[0] else { return copy }
        parallel.lanes[1].level = decibels
        copy.chains[0].elements[0] = .parallel(parallel)
        return copy
    }

    // At 0 dB a lane has no gain node, so the first move adds one.
    let down3 = level(flat, -3)
    check(isStructural(change(flat, down3)), "leaving 0 dB adds a node, which is structural")

    let down6 = level(flat, -6)
    let lane = section.lanes[1].id.uuidString
    let moved = edits(change(down3, down6))
    check(moved.count == 1 && moved.first?.target == .node("\(lane)-gain") && moved.first?.param == "gain",
          "after that it is a ramp on the lane's gain node")
    check(abs((moved.first?.value ?? 0) - pow(10, -6.0 / 20)) < 1e-12, "…as a linear gain")
}

func testMacroAddressing() {
    print("a macro is addressed by element only when the element has one")

    func chain(_ macros: [(String, String)]) -> EngineDocument {
        var nodes = [EngineNode(id: "in", type: "nc.input", element: "i")]
        var connections: [EngineConnection] = []
        var previous = "in"
        for (id, type) in macros {
            nodes.append(EngineNode(id: id, type: type, element: "x", params: ["gain1": .number(0)]))
            connections.append(EngineConnection(from: previous, to: id))
            previous = id
        }
        nodes.append(EngineNode(id: "out", type: "nc.output", element: "o"))
        connections.append(EngineConnection(from: previous, to: "out"))
        return EngineDocument(name: "T", chains: [EngineChain(id: "c", name: "C", inputChannel: 0,
                                                              outputChannel: 0, nodes: nodes,
                                                              connections: connections)])
    }

    func turned(_ document: EngineDocument) -> EngineDocument {
        var copy = document
        copy.chains[0].nodes[1].params["gain1"] = .number(3)
        return copy
    }

    let one = chain([("x-eq", "fx.eq.bands")])
    check(EngineEdits.change(from: one, to: turned(one), catalogue: testCatalogue)
              == .ramps([ParamEdit(chain: "c", target: .element("x"), param: "gain1", value: 3,
                                   type: "fx.eq.bands")]),
          "one macro in the element: a ramp by element")

    // The engine takes the element's first macro, so with two it would guess.
    let two = chain([("x-eq", "fx.eq.bands"), ("x-cut", "fx.filter.cut")])
    check(EngineEdits.change(from: two, to: turned(two), catalogue: testCatalogue) == .structural,
          "two macros in one element: structural rather than a guess")
}

// MARK: - Waiting, and how often

func testPendingEdits() {
    print("ramps waiting to be sent")

    func edit(_ chain: String, _ node: String, _ value: Double) -> ParamEdit {
        ParamEdit(chain: chain, target: .node(node), param: "gain_db", value: value, type: "nc.gain")
    }

    var pending = PendingEdits()
    check(pending.isEmpty && pending.take().isEmpty, "nothing waiting is nothing to send")

    pending.add([edit("a", "g1", 1), edit("a", "g2", 2)])
    pending.add([edit("b", "g3", 3), edit("a", "g1", 4)])
    let batches = pending.take()
    check(batches.map(\.chain) == ["a", "b"], "one batch per chain, in the order they first moved")
    check(batches.first?.edits.map(\.value) == [4, 2],
          "a control that moved twice is sent once, at its latest value, in its first place")
    check(pending.isEmpty, "taking leaves nothing behind")
}

func testStreamGate() {
    print("how often a ramp goes")

    let start = ContinuousClock.now
    var gate = StreamGate(interval: .milliseconds(10))
    check(gate.wait(at: start) == .zero, "the first patch goes at once")
    gate.sent(at: start)
    check(gate.wait(at: start + .milliseconds(3)) == .milliseconds(7),
          "the next waits out the rest of the interval")
    check(gate.wait(at: start + .milliseconds(12)) == .zero, "…and not a moment more")
}

func testPatchEncoding() {
    print("a patch on the wire")

    var patch = PatchBatch(chain: "c1", edits: [
        ParamEdit(chain: "c1", target: .node("g1"), param: "gain_db", value: -3, type: "nc.gain"),
        ParamEdit(chain: "c1", target: .element("b7"), param: "bass", value: 4.5, type: "fx.amp.tonestack"),
    ]).request
    patch.id = "9"
    let data = (try? EngineCoding.encoder.encode(patch)) ?? Data()
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let ops = object["ops"] as? [[String: Any]], ops.count == 2 else {
        check(false, "a patch encodes to an object with two ops")
        return
    }
    check(object["method"] as? String == "rig.patch" && object["chain"] as? String == "c1",
          "a patch names its method and its chain")
    check(ops.allSatisfy { $0["op"] as? String == "set_param" }, "every op is a set_param")
    check(ops[0]["node"] as? String == "g1" && ops[0]["element"] == nil,
          "a primitive is named by node, with no element beside it")
    check(ops[1]["element"] as? String == "b7" && ops[1]["node"] == nil,
          "a macro by element, with no node beside it")
    check(ops[1]["value"] as? Double == 4.5 && ops[1]["param"] as? String == "bass",
          "…each with its parameter and a number")
}
