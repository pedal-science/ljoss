import Foundation

// MARK: - Placed blocks

/// One effect instance placed in a chain. Parameter values not present in
/// `values` fall back to the catalogue spec's default, so adding a parameter to
/// a component in a later version does not invalidate saved rigs.
struct Block: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Catalogue identifier, e.g. "drive.green". Kept as a String (not an enum)
    /// so a rig saved with a component this build does not know about still
    /// decodes; it renders as an "unknown block" placeholder instead.
    var componentID: String
    var isEnabled: Bool = true
    var values: [String: ParamValue] = [:]

    init(componentID: String, isEnabled: Bool = true, values: [String: ParamValue] = [:]) {
        self.componentID = componentID
        self.isEnabled = isEnabled
        self.values = values
    }
}

// MARK: - Parallel routing

enum SplitMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case yCable, aB, crossover, dynamic
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .yCable: "Y Split"
        case .aB: "A / B"
        case .crossover: "Crossover"
        case .dynamic: "Dynamic"
        }
    }
}

/// One parallel branch. Holds its own mixer settings for the merge point.
struct Lane: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var elements: [ChainElement] = []
    /// Merge level in dB.
    var level: Double = 0
    /// -1 (hard left) ... 1 (hard right).
    var pan: Double = 0
    var isMuted: Bool = false
    var invertPhase: Bool = false

    init(elements: [ChainElement] = []) {
        self.elements = elements
    }
}

/// A split-and-rejoin section: the signal fans out across `lanes` and is mixed
/// back together at the end.
struct ParallelSection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var splitMode: SplitMode = .yCable
    /// Crossover frequency, used when `splitMode == .crossover`.
    var crossoverHz: Double = 800
    /// Routing balance for A/B and dynamic splits, -1 ... 1.
    var balance: Double = 0
    var lanes: [Lane]

    init(lanes: [Lane] = [Lane(), Lane()], splitMode: SplitMode = .yCable) {
        self.lanes = lanes
        self.splitMode = splitMode
    }
}

// MARK: - The recursive chain element

/// A chain is a series of elements; an element is either a single block or a
/// parallel section whose lanes are themselves series of elements.
///
/// This series/parallel tree is deliberately *not* a general DAG: it is exactly
/// what hardware processors expose, it always renders as a left-to-right flow
/// with vertical branching, and every insertion point is addressable as
/// (container, index) — which is what makes drag insertion tractable.
/// Note: no `indirect` needed. The recursion runs through `Array` (in
/// `Lane.elements`), which is itself a fixed-size struct holding a heap buffer,
/// so the enum is already finite-sized — `indirect` would only add a redundant
/// box per element.
enum ChainElement: Identifiable, Codable, Hashable, Sendable {
    case block(Block)
    case parallel(ParallelSection)

    var id: UUID {
        switch self {
        case .block(let b): b.id
        case .parallel(let p): p.id
        }
    }

    var asBlock: Block? { if case .block(let b) = self { b } else { nil } }
    var asParallel: ParallelSection? { if case .parallel(let p) = self { p } else { nil } }

    /// Every element id in this subtree, including its own.
    var subtreeIDs: Set<UUID> {
        switch self {
        case .block(let b):
            return [b.id]
        case .parallel(let p):
            var ids: Set<UUID> = [p.id]
            for lane in p.lanes {
                ids.insert(lane.id)
                for e in lane.elements { ids.formUnion(e.subtreeIDs) }
            }
            return ids
        }
    }
}

// MARK: - Input and output

/// The fixed endpoints of every chain. They are never removable and never
/// reorderable, but they do carry parameters.
struct IONode: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var values: [String: ParamValue] = [:]
}

// MARK: - Chain

struct SignalChain: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var source: SourceKind
    var input: IONode = IONode()
    var elements: [ChainElement] = []
    var output: IONode = IONode()

    init(name: String, source: SourceKind, elements: [ChainElement] = []) {
        self.name = name
        self.source = source
        self.elements = elements
    }
}

// MARK: - Rig

/// How many chains a rig runs and how they are presented.
enum RigLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    /// One chain, e.g. guitar only.
    case single
    /// Two fully independent chains, e.g. guitar and vocal.
    case dual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: "Single Chain"
        case .dual: "Dual Chain"
        }
    }

    var chainCount: Int {
        switch self {
        case .single: 1
        case .dual: 2
        }
    }
}

struct Rig: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var layout: RigLayout
    var chains: [SignalChain]
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        layout: RigLayout = .single,
        chains: [SignalChain],
        createdAt: Date,
        modifiedAt: Date
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.chains = chains
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
