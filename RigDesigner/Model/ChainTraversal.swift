import Foundation

extension Rig {

    /// Locate an element anywhere in the rig by id.
    func address(ofElement elementID: UUID) -> ElementAddress? {
        for chain in chains {
            if let a = Self.find(elementID, in: chain.elements, container: .top(chain.id)) {
                return a
            }
        }
        return nil
    }

    private static func find(
        _ elementID: UUID,
        in elements: [ChainElement],
        container: ContainerPath
    ) -> ElementAddress? {
        for (i, element) in elements.enumerated() {
            if element.id == elementID {
                return ElementAddress(container: container, index: i)
            }
            if case .parallel(let p) = element {
                for (li, lane) in p.lanes.enumerated() {
                    let sub = container.appending(LaneStep(parallelID: p.id, laneIndex: li))
                    if let a = find(elementID, in: lane.elements, container: sub) { return a }
                }
            }
        }
        return nil
    }

    /// The container that holds a given parallel section, needed by the lane and
    /// section mutators.
    func container(holdingParallel parallelID: UUID) -> ContainerPath? {
        address(ofElement: parallelID)?.container
    }

    /// Every block placed in the rig, in signal order.
    var allBlocks: [Block] {
        chains.flatMap { Self.blocks(in: $0.elements) }
    }

    private static func blocks(in elements: [ChainElement]) -> [Block] {
        elements.flatMap { element -> [Block] in
            switch element {
            case .block(let b): [b]
            case .parallel(let p): p.lanes.flatMap { blocks(in: $0.elements) }
            }
        }
    }

    /// The chains the current layout actually shows.
    ///
    /// `chains` may hold more than the layout displays: switching from a dual
    /// to a single layout hides the second chain rather than deleting it, so a
    /// stray tap on the layout menu can never destroy work the user has done.
    /// Switching back reveals it again, intact.
    var activeChains: [SignalChain] {
        Array(chains.prefix(layout.chainCount))
    }

    /// Total placed-block count across the visible chains.
    var blockCount: Int {
        activeChains.reduce(0) { $0 + $1.blockCount }
    }
}

extension SignalChain {
    /// Number of blocks in this chain.
    var blockCount: Int {
        Self.count(in: elements)
    }

    private static func count(in elements: [ChainElement]) -> Int {
        elements.reduce(0) { total, element in
            switch element {
            case .block: total + 1
            case .parallel(let p): total + p.lanes.reduce(0) { $0 + count(in: $1.elements) }
            }
        }
    }
}
