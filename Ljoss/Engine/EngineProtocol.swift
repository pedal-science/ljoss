import Foundation

// The control protocol's requests and responses.
//
// Only the fields this app uses are declared. The daemon's own rule is that
// "responses are supersets; a client that ignores unknown fields keeps working"
// (docs/ui-integration-plan.md §5), so every response type here is deliberately
// partial, and every field is optional: a daemon one slice older than this build
// should degrade rather than fail to decode.
//
// Foundation only — no Network and no SwiftUI, so this compiles under the test
// runner alongside the encoder.

// MARK: - Failures

/// A refusal from the daemon. Normal, not exceptional: the connection stays open and
/// the running plan is untouched.
///
/// `code` is stable and machine-readable and is what the UI reacts to; `message` is
/// the engine's own prose, which names the node and lists the valid alternatives, and
/// is shown verbatim rather than parsed.
struct EngineFailure: Error, Decodable, Sendable, Hashable {
    var code: String
    var message: String
}

enum EngineTransportError: Error, Sendable, Hashable {
    case notConnected
    case unreachable(String)
    case closed
    case timedOut
    case frameTooLarge(Int)
    case malformed(String)

    var message: String {
        switch self {
        case .notConnected: "Not connected to a device."
        case .unreachable(let why): why
        case .closed: "The device closed the connection."
        case .timedOut: "The device did not answer."
        case .frameTooLarge(let bytes): "A message of \(bytes) bytes is larger than the device accepts."
        case .malformed(let why): "The device sent something unreadable: \(why)."
        }
    }
}

// MARK: - Requests

/// Every request carries a method and an id the daemon echoes, which is how a reply
/// is matched to the call that asked for it.
///
/// `method` is a **stored** property on every conformer, not a computed one:
/// synthesised `Encodable` only writes stored properties, so a computed `method`
/// would be silently left off the wire and every call answered `bad_request`.
protocol EngineRequest: Encodable, Sendable {
    var id: String { get set }
    var method: String { get }
}

struct HelloRequest: EngineRequest {
    var id: String = ""
    let method = "engine.hello"
    /// Anything from 1 to the server's version is accepted.
    var `protocol`: Int = 2
    /// Required on TCP, and checked **before** the version, so a peer without it
    /// learns nothing else about the daemon.
    var token: String?
}

/// A method that takes nothing but its name — `engine.status`, `engine.schema`,
/// `rig.get`, `engine.panic`.
struct PlainRequest: EngineRequest {
    var id: String = ""
    let method: String

    init(_ method: String) { self.method = method }
}

struct AssetsRequest: EngineRequest {
    var id: String = ""
    let method = "engine.assets"
    /// The only way to see a file copied onto the device since it started.
    var refresh: Bool
}

struct ApplyRequest: EngineRequest {
    var id: String = ""
    let method = "rig.apply"
    var document: EngineDocument
}

struct MuteRequest: EngineRequest {
    var id: String = ""
    let method = "engine.mute"
    var mute: Bool
    /// Optional for a one-chain document and **required** when there are several.
    var chain: String?
}

/// `set_param` ops for one chain, applied all-or-nothing. This app sends nothing else
/// in a patch: a parameter the engine ramps, streamed while its control moves
/// (`EngineEdits`). Every other edit goes as a whole document.
struct PatchRequest: EngineRequest {
    var id: String = ""
    let method = "rig.patch"
    /// Always named. It may be left out for a one-chain document, but this app sends
    /// every chain, hidden ones included, so which one a patch is for is never a guess.
    var chain: String
    var ops: [PatchOp]
}

/// How a `set_param` names what it sets.
enum ParamTarget: Hashable, Sendable {
    /// A primitive node, by the id this app gave it.
    case node(String)
    /// A macro's own parameter, by the element the macro came from. The engine expands
    /// a macro when it compiles the chain, so the macro's node id is not in the running
    /// plan; named by id, the same op would rebuild the chain rather than ramp.
    case element(String)
}

struct PatchOp: Encodable, Sendable, Hashable {
    var target: ParamTarget
    var param: String
    var value: Double

    private enum CodingKeys: String, CodingKey { case op, node, element, param, value }

    /// Exactly one of `node` and `element`: the engine refuses an op that gives both.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("set_param", forKey: .op)
        switch target {
        case .node(let id): try container.encode(id, forKey: .node)
        case .element(let element): try container.encode(element, forKey: .element)
        }
        try container.encode(param, forKey: .param)
        try container.encode(value, forKey: .value)
    }
}

// MARK: - Responses

struct EngineHello: Decodable, Sendable, Hashable {
    var role: String?
    var version: String?
    var `protocol`: Int?
    /// What the client may rely on. Absence is how it degrades rather than guesses.
    var features: [String]?
    var transport: String?
    var authenticated: Bool?

    func has(_ feature: String) -> Bool { features?.contains(feature) ?? false }
}

/// Something that is true right now, not a log entry: an issue disappears when it
/// stops being the case, which is what makes a status light worth showing.
struct EngineIssue: Decodable, Sendable, Hashable, Identifiable {
    var code: String
    var severity: String?
    var message: String?
    var count: Int?
    var chain: String?
    var node: String?
    /// The client's own id for the block the issue is about — a block's UUID, as the
    /// encoder sends it. Set on `asset_missing`, which is per block.
    var element: String?
    /// `asset_missing`: the parameter that named the file (`model`, `ir`), which kind
    /// of file it is (`model`, `ir`) and the reference as the rig wrote it.
    var param: String?
    var kind: String?
    var reference: String?

    var id: String { "\(code)|\(chain ?? "")|\(node ?? "")" }
}

struct EngineChainStatus: Decodable, Sendable, Hashable {
    var id: String
    var name: String?
    var inputChannel: Int?
    var outputChannel: Int?
    var generation: Int?
    var audibleGeneration: Int?
    var transitionActive: Bool?
    var muted: Bool?
    var failedNodes: Int?
    var guardTrips: Int?
}

struct EngineControl: Decodable, Sendable, Hashable {
    var tcpListening: Bool?
    var tcpAddress: String?
    var tcpPort: Int?
    var tcpConnections: Int?
    var tcpTokenRequired: Bool?
}

struct EngineStatus: Decodable, Sendable, Hashable {
    /// `closed`, `running` or `lost`.
    var state: String?
    var backend: String?
    var device: String?
    var sampleRate: Int?
    var periodSize: Int?
    /// What the device is actually configured for. A chain naming a channel beyond
    /// these is refused at load, so the app checks before it sends.
    var captureChannels: Int?
    var playbackChannels: Int?
    var rigName: String?
    var generation: Int?
    /// The generation the device is *hearing* — the previous one while a chain is
    /// still crossfading. A response is an acknowledgement; this is the completion.
    var audibleGeneration: Int?
    var transitionActive: Bool?
    var mute: Bool?
    var xruns: Int?
    var maxChains: Int?
    var failedNodes: Int?
    var guardTrips: Int?
    /// `ok`, `warn` or `error`, derived from `issues` so the two cannot disagree.
    var health: String?
    var issues: [EngineIssue]?
    var chains: [EngineChainStatus]?
    var control: EngineControl?

    var isAdopted: Bool {
        guard let generation, let audibleGeneration else { return false }
        return generation == audibleGeneration && transitionActive != true
    }

    /// The block's `asset_missing` issue, if its model or IR isn't in the device's
    /// library. The engine plays such a block as if bypassed rather than refusing the
    /// rig, so this is how the canvas knows to show it as not configured.
    func missingAsset(element: UUID) -> EngineIssue? {
        let key = element.uuidString
        return issues?.first { $0.code == "asset_missing" && $0.element == key }
    }
}

/// The envelope `engine.status` arrives in.
struct StatusResponse: Decodable, Sendable { var status: EngineStatus? }

// MARK: - Levels

/// One place in the signal path, measured: a peak and an RMS in dBFS, and how many samples
/// the window held.
///
/// `frames` matters as much as the numbers. The engine's probes are read-and-reset, so a
/// window can legitimately be empty — a read that lands between two blocks — and a level
/// with `frames == 0` is not a level at all. A meter must hold what it was showing rather
/// than jumping to the floor, which is why this is a `Decodable` field and not a default.
struct EngineLevel: Decodable, Sendable, Hashable {
    var node: String?
    /// The client's block identity — a block's UUID as the encoder sent it. A macro is
    /// lowered into primitives that keep this, so several nodes can share one element.
    var element: String?
    /// Which primitive of that macro this node is (`level`, `low`, `ir`, …).
    var role: String?
    var peak: Double?
    var rms: Double?
    var frames: UInt64?

    var hasSignal: Bool { (frames ?? 0) > 0 }
}

/// One chain's levels: its own output, and every node in the plan it is playing.
struct EngineChainLevels: Decodable, Sendable, Hashable, Identifiable {
    var id: String?
    var name: String?
    var outputChannel: Int?
    var muted: Bool?
    var out: EngineLevel?
    var nodes: [EngineLevel]?

    /// The loudest node for this element, which is the level of the *block*: a macro's
    /// primitives are in series, so the loudest is where the signal has got to by the end
    /// of the part that matters. An element with no nodes (a block the engine lowered
    /// away, or one the guard has failed) has no level, and `nil` is the honest answer.
    func level(forElement element: UUID) -> EngineLevel? {
        let key = element.uuidString
        let matching = (nodes ?? []).filter { $0.element == key && $0.hasSignal }
        return matching.max { ($0.peak ?? -200) < ($1.peak ?? -200) }
    }
}

/// `engine.levels`: the audio levels and nothing else.
///
/// A method of its own rather than the levels inside `engine.status`, because a meter polls
/// this several times a second and `engine.status` is a document's worth of JSON — chains,
/// issues, model budget, transitions — that has to be built on the engine's control thread
/// every time it is asked.
struct EngineLevels: Decodable, Sendable, Hashable {
    /// `closed`, `running` or `lost`, so a meter can say why it has nothing to show.
    var state: String?
    var blocks: UInt64?
    var sampleRate: Int?
    var periodSize: Int?
    /// Per device channel. The input is the ADC's own level, before any chain routing —
    /// which is what makes "the input is dead" different from "the input is not routed".
    var input: EngineSideLevels?
    /// Per device channel, summed over the chains writing that channel.
    var output: EngineSideLevels?
    var chains: [EngineChainLevels]?
    var truncated: Bool?

    /// Whether anything at all was measured, which is the difference between "silence" and
    /// "the window was empty".
    var hasSignal: Bool {
        if (input?.maxPeak ?? -200) > -199 { return true }
        if (output?.maxPeak ?? -200) > -199 { return true }
        return (chains ?? []).contains { chain in
            (chain.out?.frames ?? 0) > 0 || (chain.nodes ?? []).contains { $0.hasSignal }
        }
    }
}

/// One direction's levels: an entry per device channel.
struct EngineSideLevels: Decodable, Sendable, Hashable {
    var peak: [Double]?
    var rms: [Double]?
    var clipped: [UInt64]?

    /// The loudest channel, for a single-number readout.
    var maxPeak: Double? { peak?.max() }
}

/// The envelope `engine.levels` arrives in.
struct LevelsResponse: Decodable, Sendable { var levels: EngineLevels? }

extension EngineLevels {
    /// rief `fresh`, with any window it did not measure taken from `previous`.
    ///
    /// The engine reads and resets, so a poll can arrive with `frames: 0` everywhere — the
    /// window it took was empty because something else (a status call, another client) read
    /// the probes a moment before. That is a reading of nothing, not silence, and a meter that
    /// drew it would flicker to the floor whenever anything else asked the engine a question.
    /// So an empty window inherits the last one that was not, and the `state` and counters
    /// stay the fresh ones, because those really are new.
    static func combining(previous: EngineLevels?, fresh: EngineLevels) -> EngineLevels {
        guard let previous, !fresh.hasSignal else { return fresh }
        var merged = fresh
        merged.input = fresh.input?.framesPresent ?? previous.input
        merged.output = fresh.output?.framesPresent ?? previous.output
        if let freshChains = fresh.chains {
            merged.chains = freshChains.map { chain in
                guard let old = previous.chains?.first(where: { $0.id == chain.id }) else { return chain }
                var carried = chain
                if !(chain.out?.hasSignal ?? false) { carried.out = old.out }
                if !(chain.nodes ?? []).contains(where: { $0.hasSignal }) { carried.nodes = old.nodes }
                return carried
            }
        }
        return merged
    }
}

extension EngineSideLevels {
    /// Whether this direction measured anything. The envelope has no frame count of its own —
    /// a peak above the floor is what "measured something" means here — so `-199` is the test,
    /// which is well inside the engine's `-200` floor and far below any real signal.
    var framesPresent: EngineSideLevels? {
        (maxPeak ?? -200) > -199 ? self : nil
    }
}

struct EngineAsset: Decodable, Sendable, Hashable, Identifiable {
    /// The path under the root with the extension removed — `tweed/deluxe`. **This**
    /// is what a document names; a path is refused outright from a network client.
    var id: String
    var name: String?
    /// The folder under the root, for a palette that groups.
    var group: String?
    var sampleRate: Double?
    var architecture: String?
    var size: Int?
}

struct AssetsResponse: Decodable, Sendable {
    var models: [EngineAsset]?
    var irs: [EngineAsset]?

    func list(for kind: AssetKind) -> [EngineAsset] {
        switch kind {
        case .model: models ?? []
        case .ir: irs ?? []
        }
    }
}

struct ApplyResponse: Decodable, Sendable {
    var name: String?
    var generation: Int?
}

/// `rig.patch` says which path it took: `smooth` was ramped inside the node, and
/// `structural` rebuilt and crossfaded the plan.
struct PatchResponse: Decodable, Sendable {
    var kind: String?
    var applied: Int?
    var chain: String?
    var generation: Int?
}

/// `engine.schema`, reduced to what deciding how to send an edit needs: which types
/// are macros, and which parameters ramp. The palette and inspector fields, and the
/// library-backed `options`, are left undecoded.
struct SchemaResponse: Decodable, Sendable {
    var nodes: [SchemaNode]?
}

struct SchemaNode: Decodable, Sendable {
    var id: String
    /// `primitive` or `macro`.
    var kind: String?
    var params: [SchemaParam]?
}

struct SchemaParam: Decodable, Sendable {
    var id: String
    var rampable: Bool?
}

/// Nothing to read, but the envelope still has to be checked.
struct EmptyResponse: Decodable, Sendable {}

// MARK: - The envelope

/// Every reply is `{"ok": true, …}` or `{"ok": false, "error": {code, message}}`.
struct EngineEnvelope: Decodable, Sendable {
    var ok: Bool
    var error: EngineFailure?
    var id: String?
}

enum EngineCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
}
