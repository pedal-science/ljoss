import Foundation

extension Rig {

    /// How deeply parallel sections may nest.
    ///
    /// 1 means a parallel may sit at a chain's top level but not inside another
    /// parallel's lane; 2 would permit one level of nesting. It is held at 1
    /// deliberately: a column is then always either a single block or a stack of
    /// lanes of blocks, which keeps the canvas readable and hit testing
    /// unambiguous. Multiple independent splits along one chain are still fine,
    /// which is what "split and join at different places" actually asks for.
    /// Every code path honours this constant, so raising it is a one-line change.
    static let maxParallelDepth = 1

    // MARK: - Insert

    /// Insert an element at a slot. Returns false if the slot does not resolve
    /// or the insertion would violate the nesting cap.
    @discardableResult
    mutating func insert(_ element: ChainElement, at slot: InsertionSlot, normalizing: Bool = true) -> Bool {
        if case .parallel = element, slot.container.depth >= Self.maxParallelDepth {
            return false
        }
        let ok = mutateContainer(slot.container) { elements -> Bool in
            let clamped = min(max(slot.index, 0), elements.count)
            elements.insert(element, at: clamped)
            return true
        } ?? false
        if ok && normalizing { normalize() }
        return ok
    }

    // MARK: - Remove

    /// Remove and return the element at `address`.
    ///
    /// `normalizing` is deliberately opt-out: a move must remove without
    /// normalizing, because collapsing an emptied parallel mid-move can destroy
    /// the very container the element is about to be dropped into.
    @discardableResult
    mutating func remove(at address: ElementAddress, normalizing: Bool = true) -> ChainElement? {
        let removed = mutateContainer(address.container) { elements -> ChainElement? in
            guard elements.indices.contains(address.index) else { return nil }
            return elements.remove(at: address.index)
        } ?? nil
        if removed != nil && normalizing { normalize() }
        return removed
    }

    @discardableResult
    mutating func removeElement(id: UUID, normalizing: Bool = true) -> ChainElement? {
        guard let address = address(ofElement: id) else { return nil }
        return remove(at: address, normalizing: normalizing)
    }

    // MARK: - Move

    /// Whether moving the element at `address` into `slot` is legal.
    ///
    /// The one genuinely dangerous case is dropping a parallel section into one
    /// of its own lanes, which would detach the subtree from the tree entirely.
    func canMove(from address: ElementAddress, to slot: InsertionSlot) -> Bool {
        guard let element = element(at: address) else { return false }
        if case .parallel = element {
            // Reject if the destination lies inside the moved subtree…
            let movedIDs = element.subtreeIDs
            if slot.container.steps.contains(where: { movedIDs.contains($0.parallelID) }) {
                return false
            }
            // …or if landing there would exceed the nesting cap.
            if slot.container.depth >= Self.maxParallelDepth { return false }
        }
        return elements(at: slot.container) != nil
    }

    /// Move an element to a new slot, adjusting for the hole the removal leaves.
    @discardableResult
    mutating func move(from address: ElementAddress, to slot: InsertionSlot) -> Bool {
        guard canMove(from: address, to: slot) else { return false }

        // Remove first, without normalizing — see `remove(at:normalizing:)`.
        guard let element = remove(at: address, normalizing: false) else { return false }

        // Index adjustment. Only the *final* index can shift: lane steps address
        // parallels by UUID, so removing an element never renumbers a path.
        // Within one container, every slot after the removed index slides down one.
        var target = slot
        if target.container == address.container && target.index > address.index {
            target.index -= 1
        }

        if insert(element, at: target, normalizing: false) {
            normalize()
            return true
        }

        // Destination vanished between validation and insertion: put it back so
        // a failed move is never a destructive one.
        insert(element, at: InsertionSlot(container: address.container, index: address.index), normalizing: false)
        normalize()
        return false
    }

    // MARK: - Splitting and joining

    /// Wrap the element at `address` in a new parallel section, placing it in
    /// the first lane and leaving the second lane empty (a dry path).
    @discardableResult
    mutating func wrapInParallel(at address: ElementAddress, lanes laneCount: Int = 2) -> UUID? {
        guard address.container.depth < Self.maxParallelDepth,
              let element = element(at: address) else { return nil }
        // A parallel cannot be wrapped in another parallel beyond the cap.
        if case .parallel = element, address.container.depth + 1 >= Self.maxParallelDepth { return nil }

        var lanes = [Lane(elements: [element])]
        lanes.append(contentsOf: (1..<max(2, laneCount)).map { _ in Lane() })
        let section = ParallelSection(lanes: lanes)

        let ok = mutateContainer(address.container) { elements -> Bool in
            guard elements.indices.contains(address.index) else { return false }
            elements[address.index] = .parallel(section)
            return true
        } ?? false
        guard ok else { return nil }
        normalize()
        return section.id
    }

    /// Insert a fresh empty split at a slot, seeded with one lane holding
    /// `seed` so it is never a content-free section (which `normalize` prunes).
    @discardableResult
    mutating func insertSplit(seededWith seed: ChainElement, at slot: InsertionSlot) -> UUID? {
        guard slot.container.depth < Self.maxParallelDepth else { return nil }
        let section = ParallelSection(lanes: [Lane(elements: [seed]), Lane()])
        guard insert(.parallel(section), at: slot) else { return nil }
        return section.id
    }

    /// Add another lane to a parallel section.
    @discardableResult
    mutating func addLane(to parallelID: UUID, in path: ContainerPath, limit: Int = 4) -> Bool {
        mutateParallel(in: path, parallelID: parallelID) { p in
            guard p.lanes.count < limit else { return false }
            p.lanes.append(Lane())
            return true
        } ?? false
    }

    /// Remove a lane. Dropping below two lanes collapses the section back into
    /// series via `normalize()`.
    @discardableResult
    mutating func removeLane(at laneIndex: Int, from parallelID: UUID, in path: ContainerPath) -> Bool {
        let ok = mutateParallel(in: path, parallelID: parallelID) { p -> Bool in
            guard p.lanes.indices.contains(laneIndex) else { return false }
            p.lanes.remove(at: laneIndex)
            return true
        } ?? false
        if ok { normalize() }
        return ok
    }

    /// Explicitly join a parallel back into series, splicing every lane's
    /// contents inline in lane order.
    @discardableResult
    mutating func joinParallel(_ parallelID: UUID, in path: ContainerPath) -> Bool {
        let ok = mutateContainer(path) { elements -> Bool in
            guard let idx = elements.firstIndex(where: { $0.id == parallelID }),
                  case .parallel(let p) = elements[idx] else { return false }
            let spliced = p.lanes.flatMap(\.elements)
            elements.replaceSubrange(idx...idx, with: spliced)
            return true
        } ?? false
        if ok { normalize() }
        return ok
    }

    // MARK: - Normalisation

    /// Restore structural invariants. Cheap, idempotent, and run after every
    /// mutation so the rest of the app can assume a well-formed tree.
    ///
    /// Invariants:
    ///  * a parallel section has at least two lanes, otherwise it is spliced
    ///    back into series;
    ///  * a parallel section whose lanes are *all* empty is removed entirely —
    ///    this is what makes the space close up when the last block is dragged
    ///    out of a split;
    ///  * an individually empty lane is preserved, because a dry parallel path
    ///    is a legitimate and common routing choice.
    mutating func normalize() {
        for ci in chains.indices {
            Self.normalize(&chains[ci].elements)
        }
    }

    private static func normalize(_ elements: inout [ChainElement]) {
        var result: [ChainElement] = []
        result.reserveCapacity(elements.count)

        for element in elements {
            guard case .parallel(var p) = element else {
                result.append(element)
                continue
            }

            for li in p.lanes.indices {
                var laneElements = p.lanes[li].elements
                normalize(&laneElements)
                p.lanes[li].elements = laneElements
            }

            if p.lanes.allSatisfy({ $0.elements.isEmpty }) {
                continue                                   // prune a spent split
            }
            if p.lanes.count < 2 {
                result.append(contentsOf: p.lanes.flatMap(\.elements))   // back to series
                continue
            }
            result.append(.parallel(p))
        }

        elements = result
    }
}
