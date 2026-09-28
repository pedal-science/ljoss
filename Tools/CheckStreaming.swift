import Foundation

// Turn knobs on a real namchaind through the app's own `EngineSession`, the way the
// inspector does, and say whether the engine ramped them or rebuilt.
//
// The unit tests show which edits `EngineEdits` calls ramps and what a patch looks like.
// Whether the engine agrees — that a macro's knob named by element really is ramped, and
// that a drag costs no rebuild — is a claim about two processes, so like `check-device`
// it is a tool. A second connection reads the engine's own counters, because the app's
// status type does not carry them:
//
//   `params_applied`       ramps the render thread applied
//   `transitions_started`  rebuilds, each one two plans rendered for the fade
//
// usage: check-streaming HOST PORT TOKEN-FILE

@main
enum CheckStreaming {

    private static func say(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private struct Counters: Decodable {
        var paramsApplied: Int?
        var paramsStale: Int?
        var transitionsStarted: Int?
        var generation: Int?
        var audibleGeneration: Int?
        var transitionActive: Bool?
        var rigName: String?
    }

    private struct CountersResponse: Decodable { var status: Counters? }

    private static func counters(_ probe: EngineClient) async throws -> Counters {
        try await probe.call(PlainRequest("engine.status"), expecting: CountersResponse.self).status
            ?? Counters()
    }

    /// The same rig with one value of the block at `index` changed.
    private static func setting(_ rig: Rig, block index: Int, _ key: String, _ value: ParamValue) -> Rig {
        var copy = rig
        guard case .block(var block) = copy.chains[0].elements[index] else { return copy }
        block.values[key] = value
        copy.chains[0].elements[index] = .block(block)
        return copy
    }

    /// The engine's parse of the document it is running. `rig.get` writes every parameter
    /// inline on its node, beside `id`, `type` and `element`, and each of those is a
    /// number, a string or a flag, so a node decodes as a map of `EngineValue`s.
    private struct GetResponse: Decodable {
        struct Document: Decodable { var chains: [Chain]? }
        struct Chain: Decodable { var nodes: [[String: EngineValue]]? }
        var document: Document?
    }

    private static func engineValue(_ probe: EngineClient, node: String, param: String) async throws -> Double? {
        let got = try await probe.call(PlainRequest("rig.get"), expecting: GetResponse.self)
        let found = got.document?.chains?.first?.nodes?.first { $0["id"] == .string(node) }
        guard case .number(let value)? = found?[param] else { return nil }
        return value
    }

    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3, let port = UInt16(arguments[1]),
              let token = try? String(contentsOfFile: arguments[2], encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines) else {
            FileHandle.standardError.write(Data("usage: check-streaming HOST PORT TOKEN-FILE\n".utf8))
            exit(2)
        }
        let host = arguments[0]

        let session = EngineSession(settings: EngineSettings(host: host, port: port, token: token))
        await session.connect()
        guard session.connection.isOnline else {
            say("FAILED: the session did not come online: \(session.connection)")
            exit(1)
        }
        let probe = EngineClient(host: host, port: port, token: token)

        do {
            _ = try await probe.connect()

            // The rig goes as a whole document once it has been still for the debounce.
            var rig = TestRigs.streaming()
            session.rigDidChange(rig)
            var settled = false
            for _ in 1...100 {
                try await Task.sleep(for: .milliseconds(50))
                let now = try await counters(probe)
                if now.rigName == rig.name, now.audibleGeneration == now.generation,
                   now.transitionActive != true {
                    settled = true
                    break
                }
            }
            guard settled else {
                say("FAILED: the rig never became audible: \(session.lastFailure?.message ?? "no refusal")")
                exit(1)
            }
            let before = try await counters(probe)
            say("applied    '\(rig.name)', generation \(before.generation ?? -1), "
                + "\(before.transitionsStarted ?? 0) rebuild(s) so far")

            // A drag of two seconds, one step every 10 ms, turning three knobs at once: a
            // primitive and two macros.
            let steps = 200
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                rig = setting(rig, block: 0, "gain", .number(-12 + 12 * t))
                rig = setting(rig, block: 1, "lowgain", .number(-6 + 12 * t))
                rig = setting(rig, block: 2, "mix", .number(10 + 50 * t))
                session.rigDidChange(rig)
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(300))
            let after = try await counters(probe)
            let ramps = (after.paramsApplied ?? 0) - (before.paramsApplied ?? 0)
            let rebuilds = (after.transitionsStarted ?? 0) - (before.transitionsStarted ?? 0)
            let stale = (after.paramsStale ?? 0) - (before.paramsStale ?? 0)
            say("drag       \(steps + 1) steps of three knobs: \(ramps) ramps applied, "
                + "\(rebuilds) rebuild(s), \(stale) stale")

            // The engine's document has followed the ramps to the final values, which is
            // what a later structural edit is built from.
            let ids = rig.chains[0].elements.map { $0.id.uuidString }
            let gain = try await engineValue(probe, node: "\(ids[0])-gain", param: "gain_db")
            let band = try await engineValue(probe, node: "\(ids[1])-eq", param: "gain1")
            let mix = try await engineValue(probe, node: "\(ids[2])-delay", param: "mix")
            say("engine     gain_db \(gain.map { "\($0)" } ?? "?"), gain1 \(band.map { "\($0)" } ?? "?"), "
                + "mix \(mix.map { "\($0)" } ?? "?")")
            let landed = gain.map { abs($0 - 0) < 1e-9 } == true
                && band.map { abs($0 - 6) < 1e-9 } == true
                && mix.map { abs($0 - 0.6) < 1e-9 } == true

            // A bypass is still structural, so it still rebuilds: once.
            if case .block(var block) = rig.chains[0].elements[0] {
                block.isEnabled = false
                rig.chains[0].elements[0] = .block(block)
            }
            session.rigDidChange(rig)
            try await Task.sleep(for: .milliseconds(700))
            let bypassed = try await counters(probe)
            let bypassRebuilds = (bypassed.transitionsStarted ?? 0) - (after.transitionsStarted ?? 0)
            say("bypass     \(bypassRebuilds) rebuild(s)")

            var failures: [String] = []
            if rebuilds != 0 { failures.append("the drag rebuilt \(rebuilds) time(s)") }
            if ramps < steps / 2 { failures.append("only \(ramps) ramps reached the engine") }
            if !landed { failures.append("the engine's document did not end at the final values") }
            if bypassRebuilds != 1 { failures.append("the bypass rebuilt \(bypassRebuilds) time(s), not once") }
            if let failure = session.lastFailure { failures.append("the engine refused: \(failure.message)") }
            if failures.isEmpty {
                say("OK")
                exit(0)
            }
            say("FAILED: " + failures.joined(separator: "; "))
            exit(1)
        } catch {
            say("FAILED: \(error)")
            exit(1)
        }
    }
}
