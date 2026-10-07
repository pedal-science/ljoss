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

/// `rig.cost`: what a rig would cost on this device *before* anyone plays it, and whether
/// the device would publish it at all.
///
/// Nothing is published, compiled or loaded (`docs/daemon.md`, "Cost and admission"), so it
/// is safe to ask about a rig the player has merely picked. The engine owns the table and the
/// verdict (D9); this asks rather than summing costs here, which would be the second cost
/// model D9 rules out.
struct CostRequest: EngineRequest {
    var id: String = ""
    let method = "rig.cost"

    /// The form this app uses: the rigs a player can reach are this app's own library, not
    /// files on the device, and there is no way to put one there.
    var document: EngineDocument?
    /// The other form, which names a file under the device's `rigs_root` as `rig.load` does.
    /// Declared because it is the protocol's, not because this app sends it.
    var rig: String?

    init(document: EngineDocument) { self.document = document }
    init(rig: String) { self.rig = rig }
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

/// One model the cost table trimmed Full → Lite, named so a client can mark the block.
///
/// Lite and Full are separately trained networks and a trimmed rig is a *different-sounding*
/// rig (D6), so this is the thing the player has to be able to see. `element` is this app's own
/// block identity, which is what turns it back into a block on the canvas or a row in the list.
struct EngineSlimmedModel: Decodable, Sendable, Hashable {
    var chain: String?
    var node: String?
    var element: String?
    /// The model as the rig wrote it — a library id, never a path (`tweed/deluxe`).
    var reference: String?
    /// The table row it plays instead: `NAM.WaveNet.lite`.
    var row: String?
    /// What it costs now, and what it cost as written, as fractions of one core.
    var cost: Double?
    var fullCost: Double?
}

/// One node's share of a rig's cost, as `engine.status.cost` and `rig.cost` report it.
struct EngineCostNode: Decodable, Sendable, Hashable {
    var chain: String?
    var node: String?
    var element: String?
    var reference: String?
    var row: String?
    var cost: Double?
    var fullCost: Double?
    /// Whether the table has a measured row for this unit. An unmeasured one is charged the
    /// dearest measured value (D8), so this is also "admission is guessing here".
    var measured: Bool?
    /// This is the node trimming changed: it plays its Lite submodel (D6).
    var slimmed: Bool?
}

/// What a rig costs on this device, and how it was admitted.
///
/// The rig is the unit (D1): it renders on one core, all of its chains, against the table's
/// `headroom` and no more (D3). Costs are fractions of one core.
struct EngineCost: Decodable, Sendable, Hashable {
    /// As it stands — after trimming.
    var cost: Double?
    /// As the rig is written: what it would cost with no model on Lite.
    var fullCost: Double?
    var headroom: Double?
    /// Over the headroom *after* trimming, so a client's publish is refused. The rig is
    /// unusable: there is nothing left to give.
    var over: Bool?
    /// `fits`, `trimmed` or `over` — the same answer as the two flags, in the engine's words.
    var verdict: String?
    /// At least one model plays its Lite submodel: this rig does not sound like the rig it
    /// names (D6).
    var trimmed: Bool?
    /// Which table the numbers came from, whether it could be read, how many rows it has and
    /// when it was measured. The rows are the *device's* (D9), so a table that has been
    /// re-measured changes every one of these answers.
    var table: String?
    var tableOk: Bool?
    var tableRows: Int?
    var tableMeasured: String?
    var nodes: [EngineCostNode]?
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
    /// This chain's trimmed models, which is where `engine.status` puts them.
    var slimmedModels: [EngineSlimmedModel]?
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
    /// What the running rig costs on this device, and whether any of it was trimmed (D6).
    /// Absent from an engine that does not report it, and an older engine is not a broken one.
    var cost: EngineCost?

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

    /// The running rig's trimmed models, wherever the engine put them.
    ///
    /// It reports them twice — per chain, and as the slimmed nodes of the cost object — and a
    /// rig with one trimmed amp on its second chain is missed by reading only one of the two.
    /// The per-chain array wins when there is one, because its entries carry the chain they
    /// belong to.
    var slimmedModels: [EngineSlimmedModel] {
        let perChain = (chains ?? []).flatMap { chain in
            (chain.slimmedModels ?? []).map { model -> EngineSlimmedModel in
                var named = model
                named.chain = named.chain ?? chain.id
                return named
            }
        }
        guard perChain.isEmpty else { return perChain }
        return (cost?.nodes ?? []).filter { $0.slimmed == true }.map(EngineSlimmedModel.init(node:))
    }

    /// Whether what is being heard is not the rig it names (D6): the toolbar says so while the
    /// player is playing, which is the whole point of reporting it.
    var isPlayingTrimmed: Bool { cost?.trimmed == true || !slimmedModels.isEmpty }
}

extension EngineSlimmedModel {
    /// The same entry as it appears in the cost object's node list.
    init(node: EngineCostNode) {
        self.init(chain: node.chain, node: node.node, element: node.element,
                  reference: node.reference, row: node.row, cost: node.cost, fullCost: node.fullCost)
    }
}

/// The envelope `engine.status` arrives in.
struct StatusResponse: Decodable, Sendable { var status: EngineStatus? }

/// The envelope `rig.cost` arrives in.
///
/// Partial, like every response here: what a rig costs and what would be trimmed to make it
/// fit. `missing_assets` arrives beside them and is not declared, because the issues in
/// `engine.status` already say which blocks play as bypassed and this app has nothing of its
/// own to do with the list.
struct CostResponse: Decodable, Sendable {
    var cost: EngineCost?
    /// The models that would be trimmed to make it fit — or were, in a publish's reply. A rig
    /// over the headroom *even so* is what `cost.over` reports.
    var slimmedModels: [EngineSlimmedModel]?
}

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
