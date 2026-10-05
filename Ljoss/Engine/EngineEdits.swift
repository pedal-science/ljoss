import Foundation

// Which edits reach the engine as ramps, and which need the whole document.
//
// namchain has two paths for an edit (its docs/transitions.md). A `rig.patch` whose ops
// are all `set_param` on parameters the engine ramps is the **smooth** class: the
// render thread ramps the value inside the node, with no compile and no crossfade.
// Anything else rebuilds the chain: a new plan compiled and prewarmed, every model in
// it reloaded and restarted from silence, and both plans rendered together for the
// fade. So a control is streamed only when the engine says its parameter ramps
// (`engine.schema`'s `rampable`), and every other edit goes as the whole document,
// which keeps the flattening of the tree into a graph in `DocumentEncoder` alone.
//
// The comparison is between two encoded documents rather than two rigs, because the
// document is exactly what the engine holds: a lane at 0 dB has no gain node, an amp's
// tone knob reaches the tone stack through a transform, and a block's bypass is on
// every node it lowers to. Whatever this cannot show to be a ramp is structural.
//
// A bypass goes as the whole document too, and still doesn't rebuild: an engine with
// `bypass_ramp` compares the document node by node, sees that only the flag moved, and
// crossfades the block in the plan it is playing. Sending it as a patch op instead would
// save bytes, not work.
//
// No SwiftUI and no Network here: this file is in the source list of
// `Tests/run-model-tests.sh`.

// MARK: - What the engine ramps

/// The part of `engine.schema` that decides how an edit is sent.
struct EngineCatalogue: Sendable, Equatable {

    /// Node type id → the parameters of that type the engine ramps.
    private var rampable: [String: Set<String>]

    /// Macro type ids. Their parameters are addressed by element (`ParamTarget`).
    private var macros: Set<String>

    init(rampable: [String: Set<String>], macros: Set<String>) {
        self.rampable = rampable
        self.macros = macros
    }

    init(schema: SchemaResponse) {
        var rampable: [String: Set<String>] = [:]
        var macros: Set<String> = []
        for node in schema.nodes ?? [] {
            if node.kind == "macro" { macros.insert(node.id) }
            rampable[node.id] = Set((node.params ?? []).filter { $0.rampable == true }.map(\.id))
        }
        self.init(rampable: rampable, macros: macros)
    }

    /// False for a type or parameter the schema does not list: an unknown is sent as a
    /// whole document, which is slower to hear but never wrong.
    func ramps(_ type: String, _ param: String) -> Bool {
        rampable[type]?.contains(param) ?? false
    }

    func isMacro(_ type: String) -> Bool { macros.contains(type) }

    /// For a parameter the engine rebuilt for when this said it would ramp. Streaming it
    /// would be a rebuild per step of a drag, so it goes back to whole documents.
    mutating func stopRamping(_ type: String, _ param: String) {
        rampable[type]?.remove(param)
    }
}

// MARK: - One parameter moving

struct ParamEdit: Hashable, Sendable {
    var chain: String
    var target: ParamTarget
    var param: String
    var value: Double
    /// The engine node type, so that a reply saying the engine rebuilt can stop the
    /// stream for this parameter.
    var type: String

    /// Two edits with the same key are the same control moving.
    struct Key: Hashable, Sendable {
        var chain: String
        var target: ParamTarget
        var param: String
    }

    var key: Key { Key(chain: chain, target: target, param: param) }

    var op: PatchOp { PatchOp(target: target, param: param, value: value) }
}

// MARK: - Comparing two documents

enum DocumentChange: Hashable, Sendable {
    /// Nothing the engine holds differs.
    case none
    /// Only parameters the engine ramps differ.
    case ramps([ParamEdit])
    /// Anything else. The whole document goes.
    case structural
}

enum EngineEdits {

    /// What it takes to bring the engine from `old` to `new`.
    ///
    /// Ramps only when every chain, node, connection, bypass and parameter key is
    /// unchanged, and every value that differs is a number the engine ramps. The order
    /// of chains and nodes counts as structure: the encoder is deterministic, so the
    /// same rig always encodes in the same order.
    static func change(from old: EngineDocument, to new: EngineDocument,
                       catalogue: EngineCatalogue) -> DocumentChange {
        guard old.name == new.name, old.chains.count == new.chains.count else { return .structural }

        var edits: [ParamEdit] = []
        for (was, now) in zip(old.chains, new.chains) {
            guard was.id == now.id, was.name == now.name,
                  was.inputChannel == now.inputChannel, was.outputChannel == now.outputChannel,
                  was.connections == now.connections,
                  was.nodes.count == now.nodes.count else { return .structural }

            for (before, after) in zip(was.nodes, now.nodes) {
                guard before.id == after.id, before.type == after.type,
                      before.element == after.element, before.bypass == after.bypass,
                      Set(before.params.keys) == Set(after.params.keys) else { return .structural }

                for param in after.params.keys.sorted() where before.params[param] != after.params[param] {
                    guard case .number(let value)? = after.params[param],
                          catalogue.ramps(after.type, param),
                          let target = target(for: after, in: now, catalogue: catalogue) else {
                        return .structural
                    }
                    edits.append(ParamEdit(chain: now.id, target: target, param: param,
                                           value: value, type: after.type))
                }
            }
        }
        return edits.isEmpty ? .none : .ramps(edits)
    }

    /// How a `set_param` has to name a node for the engine to ramp it.
    ///
    /// A primitive is in the running plan under the id this app gave it, so it is named
    /// by `node`. A macro is not: the engine expands it into primitives when it compiles
    /// the chain, and the one address that reaches a macro's own parameter as a ramp is
    /// its `element`, alone (namchain's `resolve_smooth_edit`). The engine then takes
    /// the first macro carrying that element, so an element with two gets no address,
    /// and the edit goes as a document.
    static func target(for node: EngineNode, in chain: EngineChain,
                       catalogue: EngineCatalogue) -> ParamTarget? {
        guard catalogue.isMacro(node.type) else { return .node(node.id) }
        let macros = chain.nodes.filter { $0.element == node.element && catalogue.isMacro($0.type) }
        return macros.count == 1 ? .element(node.element) : nil
    }
}

// MARK: - Waiting to be sent

/// Ramps not yet sent, one per control: a later value replaces an earlier one, and the
/// order in which controls first moved is kept.
struct PendingEdits: Sendable {

    private var order: [ParamEdit.Key] = []
    private var latest: [ParamEdit.Key: ParamEdit] = [:]

    var isEmpty: Bool { order.isEmpty }

    mutating func add(_ edits: [ParamEdit]) {
        for edit in edits {
            if latest.updateValue(edit, forKey: edit.key) == nil { order.append(edit.key) }
        }
    }

    mutating func removeAll() {
        order.removeAll()
        latest.removeAll()
    }

    /// Everything waiting, as one batch per chain in the order the chains first appear,
    /// leaving nothing behind.
    mutating func take() -> [PatchBatch] {
        var batches: [PatchBatch] = []
        for key in order {
            guard let edit = latest[key] else { continue }
            if let index = batches.firstIndex(where: { $0.chain == edit.chain }) {
                batches[index].edits.append(edit)
            } else {
                batches.append(PatchBatch(chain: edit.chain, edits: [edit]))
            }
        }
        removeAll()
        return batches
    }
}

/// One `rig.patch`: a patch names one chain, and is all-or-nothing within it.
struct PatchBatch: Hashable, Sendable {
    var chain: String
    var edits: [ParamEdit]

    var request: PatchRequest { PatchRequest(chain: chain, ops: edits.map(\.op)) }
}

// MARK: - How often

/// When the next patch may go: at least `interval` after the one before it. The caller
/// keeps one patch in flight at a time, so a slow link sends less often, not more.
struct StreamGate: Sendable {
    var interval: Duration
    private(set) var lastSent: ContinuousClock.Instant?

    init(interval: Duration) { self.interval = interval }

    /// How long to wait, from `now`, before sending.
    func wait(at now: ContinuousClock.Instant) -> Duration {
        guard let lastSent else { return .zero }
        let due = lastSent + interval
        return due > now ? due - now : .zero
    }

    mutating func sent(at now: ContinuousClock.Instant) { lastSent = now }
}
