import Foundation

// Assertions for the two halves of the client contract that can be checked without
// a device: the framing, and what comes back off the wire.
//
// The daemon's own tests cover the same framing cases from the socket side
// (`tests/test_tcp.cpp`). These are here because "one recv is not one message" is
// the mistake that works on loopback and fails on a network.

private func body(_ text: String) -> Data { Data(text.utf8) }

func testFraming() {
    print("the length prefix")

    let one = body("{\"id\":\"1\"}")
    let framed = EngineFraming.frame(one)
    check(framed.count == 4 + one.count, "a frame is four bytes of length and the body")
    check([UInt8](framed.prefix(4)) == [UInt8(one.count), 0, 0, 0],
          "the length is little-endian, whatever this machine is")

    var buffer = framed
    check((try? EngineFraming.cut(from: &buffer)) == [one], "a whole frame comes straight back")
    check(buffer.isEmpty, "…and nothing is left over")

    // One recv is not one message: the far end may hand over any number of bytes.
    var dribble = Data()
    var recovered: [Data] = []
    for byte in framed {
        dribble.append(byte)
        recovered += (try? EngineFraming.cut(from: &dribble)) ?? []
    }
    check(recovered == [one], "a message delivered one byte at a time reassembles")

    // …and several may arrive together.
    let two = body("{\"id\":\"2\",\"ok\":true}")
    var together = EngineFraming.frame(one) + EngineFraming.frame(two)
    check((try? EngineFraming.cut(from: &together)) == [one, two],
          "two messages in one read come back as two, in order")
    check(together.isEmpty, "…consuming both")

    // A partial tail is kept, not guessed at.
    var partial = EngineFraming.frame(one) + EngineFraming.frame(two).prefix(6)
    check((try? EngineFraming.cut(from: &partial)) == [one], "a partial tail waits for the rest")
    check(partial.count == 6, "…and stays in the buffer")

    // Refused from the header alone, before a byte of the body is waited for.
    var absurd = Data([0xff, 0xff, 0xff, 0xff])
    var refused = false
    do { _ = try EngineFraming.cut(from: &absurd, maxMessageBytes: 1024) }
    catch { refused = true }
    check(refused, "a length past the cap is refused from the header, not read")

    check(EngineFraming.frame(Data()).count == 4, "an empty body is still a legal frame")

    // A reply lists the device's library, so it may be far past the request limit: a real one's
    // `engine.assets` is about a megabyte on its own.
    let library = Data(repeating: UInt8(ascii: " "), count: 2 * EngineFraming.defaultMaxMessageBytes)
    var large = EngineFraming.frame(library)
    check((try? EngineFraming.cut(from: &large, maxMessageBytes: EngineFraming.maxReplyBytes)) == [library],
          "a reply twice the request limit is read whole under the reply limit")
    var asRequest = EngineFraming.frame(library)
    var tooLarge = false
    do { _ = try EngineFraming.cut(from: &asRequest) } catch { tooLarge = true }
    check(tooLarge, "…and would be refused under the request limit, which is why replies have their own")
}

func testResponseDecoding() {
    print("what comes back off the wire")

    // A realistic status, trimmed. Every key is snake_case on the wire and camelCase
    // here, which is the conversion most likely to be silently wrong.
    let json = """
    { "ok": true, "id": "7", "status": {
        "state": "running", "backend": "alsa_raw", "sample_rate": 48000, "period_size": 64,
        "capture_channels": 2, "playback_channels": 2,
        "rig_name": "Guitar + Vocal", "generation": 4, "audible_generation": 3,
        "transition_active": true, "mute": false, "xruns": 0, "max_chains": 8,
        "health": "warn",
        "issues": [ { "code": "xruns", "severity": "warn", "count": 3,
                      "message": "the device has missed deadlines recently" } ],
        "chains": [ { "id": "voc", "name": "Vocal", "input_channel": 1, "output_channel": 1,
                      "generation": 3, "audible_generation": 3, "muted": true } ],
        "control": { "tcp_listening": true, "tcp_port": 47810, "tcp_token_required": true },
        "an_unknown_field": 12 } }
    """

    let data = Data(json.utf8)
    guard let envelope = try? EngineCoding.decoder.decode(EngineEnvelope.self, from: data),
          let status = try? EngineCoding.decoder.decode(StatusResponse.self, from: data).status else {
        check(false, "a status response decodes at all")
        return
    }

    check(envelope.ok && envelope.id == "7", "the envelope carries ok and the echoed id")
    check(status.captureChannels == 2 && status.playbackChannels == 2,
          "snake_case channel counts arrive as channel counts")
    check(status.health == "warn" && status.issues?.first?.code == "xruns",
          "health and its issues come through")
    check(status.chains?.first?.inputChannel == 1 && status.chains?.first?.muted == true,
          "the per-chain array does too")
    check(status.control?.tcpPort == 47810, "…and the control block")
    check(!status.isAdopted, "a generation ahead of what is audible is not yet adopted")

    // Responses are supersets: a field this build does not know must not break it.
    check(status.state == "running", "an unknown field alongside is ignored")

    let refused = Data("""
    { "ok": false, "id": "9",
      "error": { "code": "asset_missing", "message": "no model 'tweed/delux'; did you mean 'tweed/deluxe'" } }
    """.utf8)
    let failure = try? EngineCoding.decoder.decode(EngineEnvelope.self, from: refused)
    check(failure?.ok == false && failure?.error?.code == "asset_missing",
          "a refusal decodes to a stable code")
    check(failure?.error?.message.contains("did you mean") == true,
          "…keeping the engine's own words, which name the near miss")

    // A block whose file isn't in the library plays as bypassed, and the issue says which
    // block by the UUID the encoder sent as its element.
    let block = UUID()
    let stoodIn = Data("""
    { "state": "running", "health": "warn",
      "issues": [ { "code": "asset_missing", "severity": "warn", "count": 1,
                    "message": "node 'x-amp' plays as if bypassed: no model 'tweed/delux'",
                    "chain": "c", "node": "x-amp", "element": "\(block.uuidString)",
                    "param": "model", "kind": "model", "reference": "tweed/delux" } ] }
    """.utf8)
    let bypassed = try? EngineCoding.decoder.decode(EngineStatus.self, from: stoodIn)
    check(bypassed?.missingAsset(element: block)?.reference == "tweed/delux",
          "a missing asset is found by the block's UUID")
    check(bypassed?.missingAsset(element: block)?.kind == "model", "…and says what kind of file")
    check(bypassed?.missingAsset(element: UUID()) == nil, "another block isn't missing anything")

    let assets = Data("""
    { "ok": true, "models": [ { "id": "tweed/deluxe", "name": "deluxe", "group": "tweed",
                                "sample_rate": 48000.0, "architecture": "WaveNet" } ],
      "irs": [ { "id": "cab-b", "name": "cab-b" } ] }
    """.utf8)
    let library = try? EngineCoding.decoder.decode(AssetsResponse.self, from: assets)
    check(library?.list(for: .model).first?.id == "tweed/deluxe", "a model is listed by its id")
    check(library?.list(for: .model).first?.group == "tweed", "…with the folder it is filed under")
    check(library?.list(for: .ir).count == 1, "and impulse responses come back too")

    // Missing lists are an empty library, not a failure.
    let empty = try? EngineCoding.decoder.decode(AssetsResponse.self, from: Data("{\"ok\":true}".utf8))
    check(empty?.list(for: .model).isEmpty == true, "an empty library is empty, not nil")
}

func testLevelDecoding() {
    // A real reply, from the pedal with a guitar plugged in and nothing played: about -60 dBFS
    // on the input, one output channel silent because nothing is routed to it, and four nodes
    // of which two share an element (a macro lowered into primitives).
    let block = UUID()
    let json = """
    { "ok": true, "levels": {
        "state": "running", "blocks": 2039, "sample_rate": 48000, "period_size": 64,
        "truncated": false,
        "input":  { "peak": [-61.5, -75.3], "rms": [-72.0, -84.0], "clipped": [0, 0] },
        "output": { "peak": [-49.5, -200.0], "rms": [-60.0, -200.0], "clipped": [0, 0] },
        "chains": [ { "id": "c1", "name": "Guitar", "output_channel": 0, "muted": false,
                      "out": { "peak": -49.5, "rms": -60.0, "frames": 4224, "clipped": 0 },
                      "nodes": [
                        { "node": "in", "element": "\(block.uuidString)", "role": "",
                          "peak": -61.5, "rms": -72.0, "frames": 4224 },
                        { "node": "cab:low", "element": "\(block.uuidString)", "role": "low",
                          "peak": -70.0, "rms": -80.0, "frames": 4224 },
                        { "node": "cab:level", "element": "\(block.uuidString)", "role": "level",
                          "peak": -55.0, "rms": -68.0, "frames": 4224 },
                        { "node": "orphan", "element": "not-a-uuid", "role": "",
                          "peak": -200.0, "rms": -200.0, "frames": 0 } ] } ],
        "an_unknown_field": 12 } }
    """
    guard let levels = try? EngineCoding.decoder.decode(LevelsResponse.self, from: body(json)).levels else {
        check(false, "a levels response decodes at all")
        return
    }
    check(levels.state == "running" && levels.blocks == 2039, "the levels reply carries its state")
    check(levels.sampleRate == 48000 && levels.periodSize == 64, "…and the device's clock")
    check(levels.input?.maxPeak == -61.5, "the input's loudest channel is the loudest channel")
    check(levels.input?.rms?.count == 2 && levels.output?.clipped?.count == 2,
          "every direction reports per channel")
    check(levels.hasSignal, "signal on the input is signal")
    check(levels.truncated == false, "an unknown field alongside is ignored")

    // The block's level is its loudest node: a macro's primitives are in series, so the end of
    // the part that matters is the one to show.
    let chain = levels.chains?.first
    check(chain?.name == "Guitar" && chain?.id == "c1", "the chain carries its document identity")
    check(chain?.level(forElement: block)?.peak == -55.0,
          "a block's level is the loudest node that shares its element")
    check(chain?.level(forElement: block)?.hasSignal == true, "…and it has samples behind it")
    check(chain?.level(forElement: UUID()) == nil, "a block the device is not running has no level")

    // A window that measured nothing is not silence, and the two must not be confused: this is
    // the bug that had the diagnostic tool reporting a quiet guitar as a dead input.
    let empty = """
    { "state": "running", "blocks": 2040,
      "input":  { "peak": [-200.0], "rms": [-200.0], "clipped": [0] },
      "output": { "peak": [-200.0], "rms": [-200.0], "clipped": [0] },
      "chains": [ { "id": "c1", "out": { "peak": -200.0, "frames": 0 },
                    "nodes": [ { "node": "in", "element": "e", "peak": -200.0, "frames": 0 } ] } ] }
    """
    let blankData = body("{\"levels\": \(empty)}")
    guard let blank = try? EngineCoding.decoder.decode(LevelsResponse.self, from: blankData).levels else {
        let why: String
        do { _ = try EngineCoding.decoder.decode(LevelsResponse.self, from: blankData); why = "decoded but levels was nil" }
        catch { why = "\(error)" }
        check(false, "an empty window decodes too: \(why)")
        return
    }
    check(!blank.hasSignal, "an empty window is not signal")
    check(!(blank.chains?.first?.level(forElement: block)?.hasSignal ?? false),
          "…and a node with no frames has no level to show")

    // The read-and-reset rule: an empty window inherits the last one that was not, while the
    // counters and the state stay fresh. Without this a meter would flicker to the floor every
    // time anything else asked the engine a question.
    let merged = EngineLevels.combining(previous: levels, fresh: blank)
    check(merged.blocks == 2040, "a merged window keeps the fresh counters")
    check(merged.hasSignal, "…and does not lose the signal it is holding")
    check(merged.chains?.first?.out?.frames == 4224, "the held chain output is the last good one")
    check(merged.chains?.first?.nodes?.first?.frames == 4224, "…and so are its nodes")

    // And a fresh window always wins over a held one.
    check(EngineLevels.combining(previous: blank, fresh: levels).blocks == 2039,
          "a window with samples replaces what was held")
}

func testMeterBallistics() {
    // What a bar is drawn from. The claim these pin is that a meter shows what a player can read:
    // a peak that jumps instantly, falls slowly, and does not flicker to silence because a window
    // happened to be empty.
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    var meter = MeterBallistics()
    check(!meter.isAudible, "a meter that has been given nothing shows nothing")

    meter.update(-12.0, now: t0)
    check(meter.peak == -12.0 && meter.isAudible, "the first reading is the level")

    // A louder peak takes over at once: an instant attack is what makes a transient visible.
    meter.update(-3.0, now: t0.addingTimeInterval(0.05))
    check(meter.peak == -3.0, "a louder peak shows at once")

    // A quieter reading does not drag the bar down with it; the bar keeps releasing at its own
    // rate. A tenth of a second at 24 dB/s is 2.4 dB, so the answer is -5.4, not the -30 that just
    // arrived.
    meter.update(-30.0, now: t0.addingTimeInterval(0.15))
    check(abs(meter.peak - (-5.4)) < 0.001,
          "a quieter reading leaves the bar to release (got \(meter.peak))")

    // And the release is a rate over real time, so a longer gap falls further — which is what keeps
    // the meter's motion the same whatever the poll rate is.
    meter.update(-30.0, now: t0.addingTimeInterval(0.65))
    check(abs(meter.peak - (-17.4)) < 0.01,
          "the bar falls at the release rate (got \(meter.peak))")

    // An empty window — the engine's probes are read and reset, so this is what arrives whenever
    // anything else asks the engine a question — releases rather than resetting.
    let held = meter.peak
    meter.update(nil, now: t0.addingTimeInterval(0.75))
    check(meter.peak < held, "an empty window falls, it does not jump")
    check(meter.peak > held - 10, "…and it falls by the release, not to the floor")

    // Left alone it reaches the floor and stops there, and a meter at the floor has nothing to
    // show: a bar drawn for it would claim a signal that is not there.
    meter.update(nil, now: t0.addingTimeInterval(30))
    check(meter.peak == MeterScale.floor, "a meter left alone reaches the floor")
    check(!meter.isAudible, "…and says it has nothing to show")

    // The engine's own floor is silence, not a very quiet signal: a channel nothing is routed to
    // arrives as -200 and must not draw a bar.
    var silent = MeterBallistics()
    silent.update(-200.0, now: t0)
    check(!silent.isAudible && silent.peak == MeterScale.floor,
          "the engine's floor is silence, not a level")

    // The scale: the floor at the left, full scale at the right, -18 dBFS where a digital meter's
    // nominal sits.
    check(MeterScale.fraction(nil) == 0, "no reading is no bar")
    check(MeterScale.fraction(MeterScale.floor) == 0, "the floor is the left-hand end")
    check(MeterScale.fraction(0) == 1, "full scale is the right-hand end")
    check(MeterScale.fraction(-200) == 0, "below the floor is still the left-hand end")
    check(MeterScale.fraction(6) == 1, "past full scale cannot overflow the bar")
    check(abs(MeterScale.fraction(-35) - 0.5) < 0.001, "halfway in dB is halfway along the bar")

    // The thresholds, which are the colours a player actually reads.
    check(!MeterScale.isHot(-18.1) && MeterScale.isHot(-6) && MeterScale.isHot(0),
          "hot starts at -6 dBFS")
    check(MeterScale.isClipping(-0.05) && !MeterScale.isClipping(-1),
          "clipping is at the encode's own clamp, not near it")
    check(MeterScale.colour(-40) == .green, "a healthy level is green")
    check(MeterScale.colour(-10) == .yellow, "above nominal is yellow")
    check(MeterScale.colour(-3) == .orange, "into the headroom it is orange")
    check(MeterScale.colour(0) == .red, "at full scale it is red")
}

/// `MeterReader` is `@MainActor` because the views that read it are. `main.swift` is top-level
/// code, which is already on the main actor, so the annotation here is the whole difference.
@MainActor
func testMeterReader() {
    // The reader folds the engine's reply into per-channel bars and per-block bars, and it is
    // where the "loudest node of an element" rule lives.
    let t0 = Date(timeIntervalSinceReferenceDate: 2000)
    let reader = MeterReader()
    let block = UUID()

    let json = """
    { "ok": true, "levels": {
        "state": "running", "blocks": 10,
        "input":  { "peak": [-61.5, -75.3], "rms": [-72.0, -84.0], "clipped": [0, 0] },
        "output": { "peak": [-49.5, -200.0], "rms": [-60.0, -200.0], "clipped": [0, 1] },
        "chains": [ { "id": "c1", "out": { "peak": -49.5, "frames": 64 },
                      "nodes": [
                        { "node": "cab:low", "element": "\(block.uuidString)", "role": "low",
                          "peak": -70.0, "frames": 64 },
                        { "node": "cab:level", "element": "\(block.uuidString)", "role": "level",
                          "peak": -55.0, "frames": 64 },
                        { "node": "quiet", "element": "\(UUID().uuidString)", "role": "",
                          "peak": -200.0, "frames": 0 } ] } ] } }
    """
    let readerLevels: EngineLevels
    do {
        guard let decoded = try EngineCoding.decoder.decode(LevelsResponse.self, from: body(json)).levels else {
            check(false, "the reader's fixture decodes (levels was nil)")
            return
        }
        readerLevels = decoded
    } catch {
        check(false, "the reader's fixture decodes: \(error)")
        return
    }
    let levels = readerLevels

    reader.tick(levels, now: t0)
    check(reader.channels(for: .input).count == 2 && reader.channels(for: .output).count == 2,
          "a bar per device channel, both directions")
    check(reader.channels(for: .input).first! == -61.5,
          "the input bar is the ADC's level (got \(String(describing: reader.channels(for: .input))))")
    check(reader.block(block) == -55.0, "a block's bar is its loudest node, not its last")
    check(reader.chain("c1") == -49.5, "a chain's bar is the chain's own output")
    check(reader.block(UUID()) == nil, "a block the device is not running has no bar")

    // A channel at the engine's floor has no bar at all, because "no level to show" is a different
    // statement from "-60 dB": the engine quotes digital silence as -200, and a bar drawn for it
    // would claim a signal that is not there.
    let silentBar: Double? = reader.channels(for: .output).last ?? nil
    check(silentBar == nil, "a channel nothing is routed to shows no bar")
    check(MeterScale.fraction(silentBar) == 0, "…so its width is zero")
    check(reader.clipped, "the encode's own clamp latches")
    check(reader.clippingChannels.contains(1), "…and says which channel clipped")
    reader.clearClip()
    check(!reader.clipped && reader.clippingChannels.isEmpty, "the player can clear it")

    // A window that measured nothing holds what was shown: the engine reads and resets, so an
    // empty reply is a reading of nothing rather than silence.
    let empty = """
    { "ok": true, "levels": {
        "state": "running", "blocks": 11,
        "input":  { "peak": [-200.0, -200.0], "rms": [-200.0, -200.0], "clipped": [0, 0] },
        "output": { "peak": [-200.0, -200.0], "rms": [-200.0, -200.0], "clipped": [0, 0] },
        "chains": [] } }
    """
    guard let blank = try? EngineCoding.decoder.decode(LevelsResponse.self, from: body(empty)).levels else {
        check(false, "an empty window decodes")
        return
    }
    // Half a second later, as the poller's own clock would be: the release is a rate over real
    // time, so the gap is the whole of the answer.
    let before = reader.block(block)
    reader.tick(blank, now: t0.addingTimeInterval(0.5))
    let fell = (before ?? MeterScale.floor) - (reader.block(block) ?? MeterScale.floor)
    check(fell > 0, "an empty window releases the block's bar")
    check(abs(fell - MeterScale.releaseDbPerSecond * 0.5) < 1.0,
          "…by the release rate over the time that passed (fell \(fell) dB)")
}

func testRequestEncoding() {
    print("what goes out on the wire")

    var hello = HelloRequest(token: "0123456789abcdef")
    hello.id = "1"
    let helloJSON = String(decoding: (try? EngineCoding.encoder.encode(hello)) ?? Data(), as: UTF8.self)
    check(helloJSON.contains("\"protocol\":2"), "hello declares the protocol version")
    check(helloJSON.contains("\"method\":\"engine.hello\""), "…and names its method")
    check(helloJSON.contains("0123456789abcdef"), "…and carries the token")

    var mute = MuteRequest(mute: true, chain: "voc")
    mute.id = "2"
    let muteJSON = String(decoding: (try? EngineCoding.encoder.encode(mute)) ?? Data(), as: UTF8.self)
    check(muteJSON.contains("\"chain\":\"voc\""),
          "a mute names its chain, which is required when there are several")

    // The one thing a network client may never do.
    let rig = Rig(name: "T", chains: [SignalChain(name: "Guitar", source: .guitar,
                                                  elements: [.block(Block(componentID: "util.gain"))])],
                  createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0))
    guard let document = DocumentEncoder.encode(rig).document else {
        check(false, "the test rig encodes")
        return
    }
    var apply = ApplyRequest(document: document)
    apply.id = "3"
    let applyJSON = String(decoding: (try? EngineCoding.encoder.encode(apply)) ?? Data(), as: UTF8.self)
    check(applyJSON.contains("\"method\":\"rig.apply\"") && applyJSON.contains("\"document\""),
          "an apply carries the whole document")
    check(!applyJSON.contains("/Users/") && !applyJSON.contains("\"path\""),
          "…and never an absolute path, which a network client may not send")

    // The generalisation of a bug this caught: `method` has to be a *stored*
    // property, because synthesised Encodable does not write computed ones, and a
    // request with no method is answered `bad_request` by a daemon that cannot say
    // anything more useful.
    let every: [any EngineRequest] = [
        HelloRequest(token: "x"), PlainRequest("engine.status"), PlainRequest("rig.get"),
        AssetsRequest(refresh: true), ApplyRequest(document: document),
        MuteRequest(mute: false, chain: nil), PlainRequest("engine.schema"),
        PatchRequest(chain: "c", ops: [PatchOp(target: .node("g"), param: "gain_db", value: 0)]),
    ]
    var missing: [String] = []
    for var request in every {
        request.id = "1"
        let text = String(decoding: (try? EngineCoding.encoder.encode(request)) ?? Data(), as: UTF8.self)
        if !text.contains("\"method\":\"\(request.method)\"") { missing.append(request.method) }
        if !text.contains("\"id\":\"1\"") { missing.append("\(request.method) (no id)") }
    }
    check(missing.isEmpty,
          "every request puts its method and id on the wire\(missing.isEmpty ? "" : ": \(missing)")")
}
