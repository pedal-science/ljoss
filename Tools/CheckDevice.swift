import Foundation

// Talk to a real namchaind with the app's own client, and say what happened.
//
// This is the one link the unit tests cannot cover: `EngineFraming` is asserted against
// bytes and `DocumentEncoder` against documents, but whether `EngineClient` completes a
// handshake with a daemon and gets a rig adopted is a claim about two processes. It needs
// a daemon, so it is a tool rather than a test — the same shape as namchainctl, and for
// the same reason.
//
// usage: check-device HOST PORT TOKEN [RIG]

@main
enum CheckDevice {

    private static func say(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 3, let port = UInt16(arguments[1]) else {
            FileHandle.standardError.write(Data(
                "usage: check-device HOST PORT TOKEN [empty|gain0|gain6]\n".utf8))
            exit(2)
        }
        let rigName = arguments.count > 3 ? arguments[3] : "gain0"

        let client = EngineClient(host: arguments[0], port: port, token: arguments[2])
        do {
            let hello = try await client.connect()
            say("hello      protocol \(hello.protocol ?? -1), \(hello.role ?? "?") \(hello.version ?? "?"), \(hello.transport ?? "?"), authenticated \(hello.authenticated ?? false)")
            say("features   \((hello.features ?? []).joined(separator: ", "))")

            let before = try await client.call(PlainRequest("engine.status"), expecting: StatusResponse.self)
            let status = before.status
            say("device     \(status?.state ?? "?") on \(status?.backend ?? "?"), "
                + "\(status?.captureChannels ?? 0) in / \(status?.playbackChannels ?? 0) out "
                + "at \(status?.sampleRate ?? 0) Hz, period \(status?.periodSize ?? 0)")
            say("health     \(status?.health ?? "?"), issues "
                + "\((status?.issues ?? []).map { $0.code })")

            var rig = RigFactory.emptyRig(name: "Check", layout: .single)
            if rigName != "empty" {
                var block = Block(componentID: "util.gain")
                if rigName == "gain6" { block.values["gain"] = .number(6.0) }
                rig.chains[0].elements = [.block(block)]
            }

            let encoded = DocumentEncoder.encode(rig)
            for refusal in encoded.refusals { say("refused    \(refusal.chain): \(refusal.message)") }
            guard let document = encoded.document else { exit(1) }

            say("applying   '\(rigName)' — \(document.chains[0].nodes.count) nodes, "
                + "\(document.chains[0].connections.count) connections")
            let applied = try await client.call(ApplyRequest(document: document),
                                                expecting: ApplyResponse.self)
            say("applied    generation \(applied.generation ?? -1)")

            // A response is an acknowledgement, not a fact about what is being heard. The engine
            // adopts asynchronously, so the question is answered by `audible_generation` catching
            // up — which is the whole reason that field exists (docs/daemon.md).
            for attempt in 1...40 {
                let status = try await client.call(PlainRequest("engine.status"),
                                                   expecting: StatusResponse.self)
                let audible = status.status?.audibleGeneration ?? -1
                if audible >= (applied.generation ?? 0) {
                    say("audible    generation \(audible) after \(attempt) poll(s)")
                    say("xruns      \(status.status?.xruns ?? 0), failed nodes \(status.status?.failedNodes ?? 0)")
                    say("OK")
                    exit(0)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            say("FAILED: the engine acknowledged the rig but never made it audible")
            exit(1)
        } catch {
            say("FAILED: \(error)")
            exit(1)
        }
    }
}
