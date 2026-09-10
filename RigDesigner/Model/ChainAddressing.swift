import Foundation

// MARK: - Addressing

/// One step down into a parallel section's lane.
///
/// The parallel is identified by its **UUID**, not by its index. That single
/// choice is what makes moves safe: removing an element earlier in an ancestor
/// container cannot invalidate a path that points into a later sibling.
struct LaneStep: Codable, Hashable, Sendable {
    var parallelID: UUID
    var laneIndex: Int
}

/// Addresses a list of `ChainElement` — either a chain's top level (`steps`
/// empty) or the element list of a lane nested somewhere inside it.
struct ContainerPath: Codable, Hashable, Sendable {
    var chainID: UUID
    var steps: [LaneStep] = []

    static func top(_ chainID: UUID) -> ContainerPath { ContainerPath(chainID: chainID) }

    /// Nesting depth: 0 for a chain's top level, 1 inside a parallel, etc.
    var depth: Int { steps.count }

    func appending(_ step: LaneStep) -> ContainerPath {
        ContainerPath(chainID: chainID, steps: steps + [step])
    }

    /// True when `self` is `other` or lies inside it.
    func isInside(_ other: ContainerPath) -> Bool {
        guard chainID == other.chainID, steps.count >= other.steps.count else { return false }
        return Array(steps.prefix(other.steps.count)) == other.steps
    }
}

/// Addresses an element that exists: `index` is a valid subscript.
struct ElementAddress: Codable, Hashable, Sendable {
    var container: ContainerPath
    var index: Int
}

/// Addresses a gap between elements: `index` may be `0...count`.
struct InsertionSlot: Codable, Hashable, Sendable {
    var container: ContainerPath
    var index: Int
}

// MARK: - Tree access

extension Rig {

    func chainIndex(of chainID: UUID) -> Int? {
        chains.firstIndex { $0.id == chainID }
    }

    /// Read the element list at `path`, or nil if the path no longer resolves.
    func elements(at path: ContainerPath) -> [ChainElement]? {
        guard let ci = chainIndex(of: path.chainID) else { return nil }
        return Self.resolve(chains[ci].elements, steps: path.steps[...])
    }

    private static func resolve(_ elements: [ChainElement], steps: ArraySlice<LaneStep>) -> [ChainElement]? {
        guard let step = steps.first else { return elements }
        guard let idx = elements.firstIndex(where: { $0.id == step.parallelID }),
              case .parallel(let p) = elements[idx],
              p.lanes.indices.contains(step.laneIndex)
        else { return nil }
        return resolve(p.lanes[step.laneIndex].elements, steps: steps.dropFirst())
    }

    func element(at address: ElementAddress) -> ChainElement? {
        guard let list = elements(at: address.container),
              list.indices.contains(address.index) else { return nil }
        return list[address.index]
    }

    /// Mutate the element list at `path` in place. Returns nil if the path does
    /// not resolve, in which case nothing was changed.
    @discardableResult
    mutating func mutateContainer<R>(
        _ path: ContainerPath,
        _ body: (inout [ChainElement]) -> R
    ) -> R? {
        guard let ci = chainIndex(of: path.chainID) else { return nil }
        return Self.mutate(&chains[ci].elements, steps: path.steps[...], body)
    }

    private static func mutate<R>(
        _ elements: inout [ChainElement],
        steps: ArraySlice<LaneStep>,
        _ body: (inout [ChainElement]) -> R
    ) -> R? {
        guard let step = steps.first else { return body(&elements) }
        guard let idx = elements.firstIndex(where: { $0.id == step.parallelID }),
              case .parallel(var parallel) = elements[idx],
              parallel.lanes.indices.contains(step.laneIndex)
        else { return nil }

        // Take the lane's elements out, recurse, and write back unconditionally:
        // if the recursion bailed it left the array untouched, so the write-back
        // is a no-op rather than a corruption.
        var laneElements = parallel.lanes[step.laneIndex].elements
        let result = mutate(&laneElements, steps: steps.dropFirst(), body)
        parallel.lanes[step.laneIndex].elements = laneElements
        elements[idx] = .parallel(parallel)
        return result
    }

    /// Mutate a lane's non-element properties (level, pan, mute, phase).
    @discardableResult
    mutating func mutateLane<R>(
        containerOfParallel path: ContainerPath,
        parallelID: UUID,
        laneIndex: Int,
        _ body: (inout Lane) -> R
    ) -> R? {
        mutateContainer(path) { elements -> R? in
            guard let idx = elements.firstIndex(where: { $0.id == parallelID }),
                  case .parallel(var p) = elements[idx],
                  p.lanes.indices.contains(laneIndex) else { return nil }
            let r = body(&p.lanes[laneIndex])
            elements[idx] = .parallel(p)
            return r
        } ?? nil
    }

    /// Mutate a parallel section's own properties (split mode, crossover…).
    @discardableResult
    mutating func mutateParallel<R>(
        in path: ContainerPath,
        parallelID: UUID,
        _ body: (inout ParallelSection) -> R
    ) -> R? {
        mutateContainer(path) { elements -> R? in
            guard let idx = elements.firstIndex(where: { $0.id == parallelID }),
                  case .parallel(var p) = elements[idx] else { return nil }
            let r = body(&p)
            elements[idx] = .parallel(p)
            return r
        } ?? nil
    }

    /// Mutate a placed block anywhere in the rig, found by id.
    @discardableResult
    mutating func mutateBlock<R>(id blockID: UUID, _ body: (inout Block) -> R) -> R? {
        for ci in chains.indices {
            if let r = Self.mutateBlock(&chains[ci].elements, id: blockID, body) { return r }
        }
        return nil
    }

    private static func mutateBlock<R>(
        _ elements: inout [ChainElement],
        id blockID: UUID,
        _ body: (inout Block) -> R
    ) -> R? {
        for i in elements.indices {
            switch elements[i] {
            case .block(var b) where b.id == blockID:
                let r = body(&b)
                elements[i] = .block(b)
                return r
            case .parallel(var p):
                for li in p.lanes.indices {
                    var laneElements = p.lanes[li].elements
                    let r = mutateBlock(&laneElements, id: blockID, body)
                    p.lanes[li].elements = laneElements
                    if r != nil {
                        elements[i] = .parallel(p)
                        return r
                    }
                }
            default:
                continue
            }
        }
        return nil
    }
}
