import Foundation

// The cost table's half of the client contract (D6, D9, P5): what the engine reports about a
// rig it is playing and one it is not, what this app makes of it, and when a verdict it has
// kept goes stale.
//
// The device itself is not here — `Tools/check-device.sh` is what needs a daemon — but every
// decision this app makes about the numbers is: which flag means "unusable", which model a
// block is playing instead of the one it names, and what invalidates an answer.

/// The status a real one has the shape of: a two-amp rig that fits only with the second amp on
/// Lite, and the block ids the app knows its own blocks by.
private let statusJSON = """
{ "ok": true, "id": "4", "status": {
    "state": "running", "rig_name": "Two Amp", "generation": 7, "audible_generation": 7,
    "health": "ok", "max_chains": 8,
    "cost": {
      "cost": 0.67, "full_cost": 1.02, "headroom": 0.8, "over": false,
      "verdict": "trimmed", "trimmed": true,
      "table": "/etc/namchain/cost.json", "table_ok": true, "table_rows": 13,
      "table_measured": "2026-10-07T15:00:00Z", "table_host": "vip",
      "nodes": [
        { "chain": "gtr", "node": "AMP1-nam", "element": "AMP1", "reference": "tweed/deluxe",
          "row": "NAM.WaveNet.full", "cost": 0.5, "full_cost": 0.5, "measured": true,
          "slimmed": false },
        { "chain": "gtr", "node": "AMP2-nam", "element": "AMP2", "reference": "A2",
          "row": "NAM.WaveNet.lite", "cost": 0.15, "full_cost": 0.5, "measured": true,
          "slimmed": true } ] },
    "issues": [
      { "code": "model_slimmed", "severity": "info", "count": 1,
        "message": "node 'AMP2-nam' plays its Lite model to fit the cost table",
        "chain": "gtr", "node": "AMP2-nam", "element": "AMP2", "reference": "A2",
        "row": "NAM.WaveNet.lite" } ],
    "chains": [ { "id": "gtr", "name": "Guitar", "output_channel": 0,
                  "slimmed_models": [ { "node": "AMP2-nam", "element": "AMP2", "reference": "A2",
                                        "row": "NAM.WaveNet.lite", "cost": 0.15,
                                        "full_cost": 0.5 } ] } ],
    "an_unknown_field": 1 } }
"""

func testCostDecoding() {
    print("the cost table on the wire")

    guard let status = try? EngineCoding.decoder.decode(StatusResponse.self,
                                                       from: Data(statusJSON.utf8)).status else {
        check(false, "a status with a cost object decodes at all")
        return
    }

    check(status.cost?.verdict == "trimmed" && status.cost?.trimmed == true,
          "the verdict and the trimmed flag arrive")
    check(status.cost?.tableOk == true && status.cost?.tableRows == 13,
          "snake_case table fields arrive as table fields")
    check(status.cost?.nodes?.count == 2 && status.cost?.nodes?.last?.slimmed == true,
          "every node is charged, and one of them says it was trimmed")
    check(status.isPlayingTrimmed, "a rig with a Lite model in it is playing trimmed")
    check(status.cost?.over == false, "…and it is not over the headroom")
    check(status.slimmedModels.first?.element == "AMP2" && status.slimmedModels.first?.chain == "gtr",
          "the trimmed model is read from the chain it is on")

    // The two places the engine reports the same thing must not disagree, and a rig trimmed on
    // its second chain is the case that catching only one of them would miss.
    let onlyInCost = Data("""
    { "state": "running", "issues": [], "chains": [ { "id": "gtr" }, { "id": "voc" } ],
      "cost": { "cost": 0.9, "headroom": 0.8, "over": true, "verdict": "over", "trimmed": true,
                "nodes": [ { "chain": "voc", "node": "V-nam", "element": "V", "reference": "A2",
                             "row": "NAM.WaveNet.lite", "cost": 0.15, "full_cost": 0.5,
                             "measured": true, "slimmed": true } ] } }
    """.utf8)
    let over = try? EngineCoding.decoder.decode(EngineStatus.self, from: onlyInCost)
    check(over?.isPlayingTrimmed == true && over?.slimmedModels.first?.node == "V-nam",
          "a trimmed model reported only in the cost object is still found")
    check(over?.slimmedModels.first?.chain == "voc",
          "…and it keeps the chain it was reported under")
    check(over?.cost?.over == true && over?.cost?.verdict == "over",
          "a rig the cost table admitted anyway (the configured one) still says it is over")

    // An engine that predates the table reports none of this, which is not a broken engine.
    let plain = Data("""
    { "state": "running", "health": "ok", "chains": [ { "id": "gtr" } ] }
    """.utf8)
    let old = try? EngineCoding.decoder.decode(EngineStatus.self, from: plain)
    check(old?.cost == nil && old?.isPlayingTrimmed == false && old?.slimmedModels.isEmpty == true,
          "a status with no cost object says nothing rather than guessing")

    // The reply about a rig that is not playing: the same numbers, thrown away by the engine.
    let reply = Data("""
    { "ok": true, "id": "9",
      "cost": { "cost": 1.02, "full_cost": 1.02, "headroom": 0.8, "over": true, "verdict": "over",
                "trimmed": false, "table": "/etc/namchain/cost.json", "table_ok": true,
                "nodes": [] },
      "slimmed_models": [],
      "missing_assets": [ { "chain": "gtr", "node": "CAB-ir", "element": "CAB", "param": "ir",
                            "kind": "ir", "reference": "cabs/none", "message": "no such IR" } ] }
    """.utf8)
    guard let answer = try? EngineCoding.decoder.decode(CostResponse.self, from: reply),
          let cost = answer.cost else {
        check(false, "a rig.cost reply decodes at all")
        return
    }
    let report = RigCostReport(cost: cost, slimmedModels: answer.slimmedModels ?? [])
    check(report.isOver && !report.isTrimmed, "a rig that does not fit even on Lite is unusable")
    check(report.refusalReason == "Its blocks cost 1.02 of a core, and a rig may have 0.80.",
          "the reason is the total against the headroom (got \"\(report.refusalReason)\")")

    let trimmed = RigCostReport(cost: status.cost!, slimmedModels: status.slimmedModels)
    check(trimmed.refusalReason.contains("on Lite"),
          "…and says so when even that total is after trimming")
}

func testCostRequestEncoding() {
    print("asking what a rig would cost")

    // A Gain, because a rig with an amp in it and no model chosen does not encode at all —
    // which is its own answer: `cost(of:)` returns no verdict and the rig goes as it always did.
    let rig = Rig(name: "Two Amp",
                  chains: [SignalChain(name: "Guitar", source: .guitar,
                                       elements: [.block(Block(componentID: "util.gain"))])],
                  createdAt: Date(timeIntervalSince1970: 0),
                  modifiedAt: Date(timeIntervalSince1970: 0))
    guard let document = DocumentEncoder.encode(rig).document else {
        check(false, "the test rig encodes")
        return
    }

    var ask = CostRequest(document: document)
    ask.id = "5"
    let text = String(decoding: (try? EngineCoding.encoder.encode(ask)) ?? Data(), as: UTF8.self)
    check(text.contains("\"method\":\"rig.cost\""), "the request names the method")
    check(text.contains("\"document\""), "…and carries the whole document, which is the form this app uses")
    check(!text.contains("\"rig\""),
          "…and not a device-side rig name, which this app has no way to make")

    // The protocol's other form, kept working because it is the protocol's.
    var named = CostRequest(rig: "guitar-chain.json")
    named.id = "6"
    let namedText = String(decoding: (try? EngineCoding.encoder.encode(named)) ?? Data(), as: UTF8.self)
    check(namedText.contains("\"rig\":\"guitar-chain.json\"") && !namedText.contains("\"document\""),
          "a rig named as rig.load takes it goes on the wire as one")
}

func testCostNamingTheTrimmedBlocks() {
    print("naming what was trimmed")

    let amp = Block(componentID: "amp.brit800")
    let cab = Block(componentID: "cab.ir")
    let rig = Rig(name: "Two Amp",
                  chains: [SignalChain(name: "Guitar", source: .guitar,
                                       elements: [.block(amp), .block(cab)])],
                  createdAt: Date(timeIntervalSince1970: 0),
                  modifiedAt: Date(timeIntervalSince1970: 0))

    let json = """
    { "state": "running",
      "chains": [ { "id": "gtr", "slimmed_models": [
        { "node": "\(amp.id.uuidString)-nam", "element": "\(amp.id.uuidString)", "reference": "A2",
          "row": "NAM.WaveNet.lite", "cost": 0.15, "full_cost": 0.5 },
        { "node": "cab:ir", "element": "\(cab.id.uuidString)", "reference": "cabs/none",
          "row": "IR.8192", "cost": 0.4, "full_cost": 0.4 },
        { "node": "other-nam", "element": "\(UUID().uuidString)", "reference": "tweed/deluxe",
          "row": "NAM.WaveNet.lite", "cost": 0.15, "full_cost": 0.5 } ] } ] }
    """
    guard let status = try? EngineCoding.decoder.decode(EngineStatus.self, from: Data(json.utf8)),
          let trimmed = status.trimmedRig(in: rig) else {
        check(false, "a status naming trimmed blocks decodes")
        return
    }

    check(trimmed.blocks.count == 3, "every trimmed model is named, not just the first")
    check(trimmed.blocks[0].name == "Brit 800",
          "a block the app knows is named the way the canvas names it (got \(trimmed.blocks[0].name))")
    check(trimmed.blocks[1].name == "IR Loader", "…and so is the block after it")
    check(trimmed.blocks[2].name == "tweed/deluxe",
          "a block the app does not know falls back to the model reference")
    check(trimmed.label == "Lite: Brit 800, IR Loader +1",
          "the label names two blocks and counts the rest (got \"\(trimmed.label)\")")
    check(trimmed.detail.contains("Brit 800 (0.15 of a core instead of 0.50)"),
          "the detail says what each block saves")
    check(trimmed.detail.contains("does not sound like the rig as written"),
          "…and why it matters: a Lite model is a different network (D6)")

    // Nothing trimmed is nil, which is what keeps the toolbar quiet.
    let quiet = try? EngineCoding.decoder.decode(EngineStatus.self, from: Data("""
    { "state": "running", "cost": { "cost": 0.2, "headroom": 0.8, "verdict": "fits", "trimmed": false } }
    """.utf8))
    check(quiet?.trimmedRig(in: rig) == nil, "a rig playing what it names has nothing to show")
}

func testCostVerdictsGoStale() {
    print("when a verdict is stale")

    let rig = Rig(name: "Two Amp",
                  chains: [SignalChain(name: "Guitar", source: .guitar,
                                       elements: [.block(Block(componentID: "util.gain"))])],
                  createdAt: Date(timeIntervalSince1970: 0),
                  modifiedAt: Date(timeIntervalSince1970: 0))
    let id = rig.id
    guard let document = DocumentEncoder.encode(rig).document else {
        check(false, "the test rig encodes")
        return
    }
    var edited = rig
    edited.chains[0].elements.append(.block(Block(componentID: "util.gain")))
    guard let editedDocument = DocumentEncoder.encode(edited).document else {
        check(false, "the edited rig encodes")
        return
    }

    let table = CostTableKey(status: EngineCost(table: "/etc/namchain/cost.json", tableOk: true,
                                                tableRows: 13, tableMeasured: "2026-10-07T15:00:00Z"))
    check(table.isKnown, "a table the device has described can be compared")

    let report = RigCostReport(cost: EngineCost(cost: 1.02, headroom: 0.8, over: true,
                                                verdict: "over", table: "/etc/namchain/cost.json",
                                                tableOk: true))
    var verdicts = CostVerdicts()
    verdicts.store(report, for: id, document: document, table: table)

    check(verdicts.report(for: id, document: document, table: table)?.isOver == true,
          "the same rig against the same table is answered from the cache")
    check(verdicts.known(id)?.isOver == true, "…and the list can read it without the document")

    check(verdicts.report(for: id, document: editedDocument, table: table) == nil,
          "an edited rig is a different question")
    check(verdicts.report(for: id, document: document,
                          table: CostTableKey(status: EngineCost(table: "/etc/namchain/cost.json",
                                                                 tableOk: true, tableRows: 14,
                                                                 tableMeasured: "2026-10-08T09:00:00Z"))) == nil,
          "so is the same rig against a table that has been re-measured")
    check(verdicts.report(for: id, document: document,
                          table: CostTableKey(status: EngineCost(table: "/etc/other.json",
                                                                 tableOk: true, tableRows: 13))) == nil,
          "…or a different table entirely")

    // A device nobody has measured reports no table, and nothing can be keyed on nothing.
    let nowhere = CostTableKey(status: nil)
    check(!nowhere.isKnown, "a table nobody has described cannot be compared")
    check(verdicts.report(for: id, document: document, table: nowhere) == nil,
          "so no verdict is answered from the cache for it")
    var fresh = CostVerdicts()
    fresh.store(report, for: id, document: document, table: nowhere)
    check(fresh.known(id) == nil, "…and one is not kept against it either")

    verdicts.forget(id)
    check(verdicts.known(id) == nil, "an edit forgets the verdict it invalidates")
    verdicts.store(report, for: id, document: document, table: table)
    verdicts.removeAll()
    check(verdicts.known(id) == nil, "and a different device forgets all of them")
}
