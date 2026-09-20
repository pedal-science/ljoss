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
}

/// The envelope `engine.status` arrives in.
struct StatusResponse: Decodable, Sendable { var status: EngineStatus? }

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
