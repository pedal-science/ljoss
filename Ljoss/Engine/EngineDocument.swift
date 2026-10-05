import Foundation

// The namchain rig document, as it goes on the wire.
//
// This is a *transport* type and nothing else: it is built from a `Rig` by
// `DocumentEncoder` and thrown away after the send. The app's own document stays
// the `Rig` tree — the engine is a sink, not a mirror, and nothing is ever
// rehydrated from what it hands back (docs/ui-integration-plan.md §1.1).
//
// No SwiftUI and no Network here, deliberately: this file is in the source list of
// `Tests/run-model-tests.sh`, which compiles with a plain `swiftc`.

// MARK: - Values

/// A value a node parameter may carry.
///
/// The engine's parser accepts a number, a string or a boolean, and nothing else
/// (`src/graph/rig.cpp`). Three cases is the entire vocabulary, which is why this is
/// an enum rather than an existential.
enum EngineValue: Hashable, Sendable {
    case number(Double)
    case string(String)
    case flag(Bool)
}

extension EngineValue: Codable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .flag(let b): try container.encode(b)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool first: `Double` would happily decode `true` on some paths, and a flag
        // that arrived back as 1.0 would compare unequal to the one that was sent.
        if let b = try? container.decode(Bool.self) { self = .flag(b) }
        else if let d = try? container.decode(Double.self) { self = .number(d) }
        else { self = .string(try container.decode(String.self)) }
    }
}

// MARK: - Nodes

/// One node in a chain's graph.
struct EngineNode: Hashable, Sendable {

    /// Reserved keys, from the parser's own list in `src/graph/rig.cpp`. Every other
    /// key in a node object is a parameter, so a parameter named like one of these
    /// would be silently swallowed — `DocumentEncoder` refuses to produce one.
    static let reservedKeys: Set<String> = [
        "id", "type", "element", "role", "params", "strings", "bypass",
    ]

    /// The id this app chose. Unique within the chain, and what a `rig.patch` names.
    var id: String

    /// The engine type: `nc.gain`, `fx.delay.feedback`, …
    var type: String

    /// This app's own identity for the document thing the node came from — a block's
    /// or a parallel section's UUID. Stored and returned verbatim, never parsed, and
    /// **not** required to be unique: an amp is two nodes sharing one element.
    var element: String

    /// `Block.isEnabled == false`. A bypassed node keeps running and passes its dry
    /// input through, so its state stays warm and un-bypassing does not click.
    var bypass: Bool = false

    /// Written inline beside the reserved keys, which is how the engine's own rig
    /// files spell them (`rigs/guitar-chain.json`).
    var params: [String: EngineValue] = [:]
}

/// A key whose name is only known at runtime, for the inline parameters.
private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension EngineNode: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(id, forKey: DynamicKey("id"))
        try container.encode(type, forKey: DynamicKey("type"))
        try container.encode(element, forKey: DynamicKey("element"))
        // Only when true: the engine defaults it to false, and an explicit `false` on
        // every node is noise in a document a human may have to read.
        if bypass { try container.encode(true, forKey: DynamicKey("bypass")) }
        // Sorted, so two encodings of the same rig are byte-identical and a diff
        // between two documents shows what actually changed.
        for key in params.keys.sorted() {
            try container.encode(params[key]!, forKey: DynamicKey(key))
        }
    }
}

// MARK: - Connections

struct EngineConnection: Hashable, Sendable, Encodable {
    var from: String
    var fromPort: Int = 0
    var to: String
    var toPort: Int = 0

    enum CodingKeys: String, CodingKey {
        case from
        case fromPort = "from_port"
        case to
        case toPort = "to_port"
    }

    init(from: String, fromPort: Int = 0, to: String, toPort: Int = 0) {
        self.from = from
        self.fromPort = fromPort
        self.to = to
        self.toPort = toPort
    }
}

// MARK: - Chains

/// One chain: a graph, and the device channels it reads and writes.
///
/// Channel binding lives here rather than on `nc.input`/`nc.output` because it is a
/// property of the chain, not of a node — which is exactly what this app models with
/// a guitar chain and a vocal chain.
struct EngineChain: Hashable, Sendable, Encodable {
    var id: String
    var name: String
    var inputChannel: Int
    var outputChannel: Int
    var nodes: [EngineNode] = []
    var connections: [EngineConnection] = []

    enum CodingKeys: String, CodingKey {
        case id, name
        case inputChannel = "input_channel"
        case outputChannel = "output_channel"
        case nodes, connections
    }
}

// MARK: - The document

struct EngineDocument: Hashable, Sendable, Encodable {
    var name: String
    var chains: [EngineChain]

    /// The document as the daemon wants it: one JSON object, no date strategy needed
    /// because a document carries no dates.
    func jsonData(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        // Sorted because a document is a thing people read and diff. Object key order
        // means nothing on the wire, but Swift's per-process string hashing would
        // otherwise shuffle a node's keys between runs and make two dumps of the same
        // rig look different. `RigLibrary` sorts its keys for the same reason.
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                          : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func jsonString(pretty: Bool = true) throws -> String {
        String(decoding: try jsonData(pretty: pretty), as: UTF8.self)
    }
}
