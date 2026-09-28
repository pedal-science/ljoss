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
