import SwiftUI

/// Owns the rig being edited and everything the drag needs.
@MainActor
@Observable
final class RigEditor {

    var rig: Rig {
        didSet {
            guard rig != oldValue else { return }
            library?.update(rig)
            // The device is told separately and decides for itself when: a drag is
            // local, a drop is one commit, and the session's own debounce coalesces
            // the burst an edit produces into one `rig.apply`.
            engine?.rigDidChange(rig)
        }
    }

    /// What the inspector is showing.
    var selection: Selection?

    enum Selection: Hashable {
        case block(UUID)
        case input(UUID)      // chain id
        case output(UUID)     // chain id
        case parallel(UUID)   // parallel id
    }

    let drag = DragController()

    /// Plain, unobserved on purpose — see `FrameRegistry`.
    @ObservationIgnored let registry = FrameRegistry()

    @ObservationIgnored private weak var library: RigLibrary?
    @ObservationIgnored private weak var engine: EngineSession?

    init(rig: Rig, library: RigLibrary?, engine: EngineSession? = nil) {
        self.rig = rig
        self.library = library
        self.engine = engine
    }

    /// Called when the editor appears, not from `init`: SwiftUI runs `RigEditorView.init`,
    /// and so this class's, on every render of its parent, and `@State` keeps only the first.
    /// So the canvas can badge what this device cannot play before anything is dragged, and
    /// so a freshly opened rig reaches a connected device.
    func didAppear() {
        engine?.rigDidChange(rig)
        remeasure()
    }

    // MARK: - Measurement

    /// Bumped to make every view that measures itself measure again — see
    /// `remeasure()`. Views read it where they are built, so a bump re-renders
    /// them and their `onGeometryChange` value differs even when the numbers are
    /// the same as last time.
    private(set) var layoutGeneration = 0

    /// Ask the canvas to measure itself again, now and for the next moment.
    ///
    /// `onGeometryChange` fires when the value it computes *changes*, and that is
    /// not enough on its own. Coming back from settings the canvas is built again
    /// and can be measured while it is still moving into place — before the split
    /// view's columns have settled, or before a scroll position is restored —
    /// after which nothing reports again. The registry is then left holding rects
    /// for a canvas that is no longer on screen, so a press resolves to nothing
    /// and no node can be picked up, while the nodes themselves look perfectly
    /// normal. The rig id keys the editor, so switching rigs builds a new one and
    /// measures from scratch — which is why that is the way out of it.
    ///
    /// Measuring a few times over the first second and a half is what makes the
    /// difference: the later measurements see the settled layout. It is bounded,
    /// it happens only on appearance, and each pass is one render of the canvas.
    private func remeasure() {
        for delay in Self.remeasureDelays {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                layoutGeneration &+= 1
            }
        }
    }

    /// Seconds after appearing at which to measure again: at once, and then as
    /// the columns and any restored scroll position finish moving. Measured
    /// against the app rather than guessed: coming back from settings the canvas
    /// reports itself at x = 9.5, then 265, and only settles at 438, with the
    /// last of those arriving well after the first.
    private static let remeasureDelays: [Double] = [0, 0.1, 0.25, 0.5, 0.9, 1.5]

    // MARK: - Drag lifecycle

    func beginDrag(
        _ payload: DragPayload,
        pointerGlobal: CGPoint,
        grabOffset: CGSize,
        ghostSize: CGSize = CGSize(width: Metrics.nodeWidth, height: Metrics.nodeHeight)
    ) {
        withAnimation(Anim.lift) {
            drag.begin(payload, pointerGlobal: pointerGlobal, grabOffset: grabOffset, ghostSize: ghostSize)
        }
        recomputeTarget()
    }

    /// Re-resolve the drop target from the current pointer position.
    ///
    /// Called from the gesture *and* from every auto-scroll tick: while the
    /// canvas slides under a stationary finger the gesture stops firing, and
    /// without this the gap would stay glued to the wrong slot.
    func recomputeTarget() {
        guard drag.isActive else { return }
        let allowTrash = drag.payload?.existingID != nil
        let newTarget = registry.dropTarget(at: drag.pointerGlobal, allowTrash: allowTrash)
        guard newTarget != drag.target else { return }
        withAnimation(Anim.reflow) {
            drag.updateTarget(newTarget)
        }
    }

    func updateDrag(pointerGlobal: CGPoint) {
        guard drag.isActive else { return }
        drag.pointerGlobal = pointerGlobal
        recomputeTarget()
    }

    func cancelDrag() {
        withAnimation(Anim.settle) { drag.end() }
    }

    /// Apply the drop. Returns true if the rig changed.
    @discardableResult
    func commitDrop() -> Bool {
        guard let payload = drag.payload else { return false }
        let target = drag.target
        var changed = false

        withAnimation(Anim.settle) {
            switch target {
            case .trash:
                if case .existing(let id, _) = payload {
                    rig.removeElement(id: id)
                    if selection == .block(id) { selection = nil }
                    changed = true
                }

            case .slot(let renderSlot):
                guard let slot = rig.modelSlot(for: renderSlot, hiding: drag.hiddenElementID) else { break }
                switch payload {
                case .newComponent(let componentID):
                    let block = Block(componentID: componentID)
                    changed = rig.insert(.block(block), at: slot)

                case .existing(let id, _):
                    // Re-resolve by id rather than trusting the address captured
                    // at lift: normalisation may have reshaped the tree since.
                    guard let address = rig.address(ofElement: id) else { break }
                    changed = rig.move(from: address, to: slot)
                }

            case nil:
                break   // dropped on nothing — snap back, change nothing
            }
            drag.end()
        }
        return changed
    }

    // MARK: - Structural edits

    func removeElement(id: UUID) {
        withAnimation(Anim.reflow) {
            rig.removeElement(id: id)
            if selection == .block(id) { selection = nil }
        }
    }

    func duplicateElement(id: UUID) {
        guard let address = rig.address(ofElement: id),
              let element = rig.element(at: address) else { return }
        let copy = Self.regenerateIDs(element)
        withAnimation(Anim.reflow) {
            _ = rig.insert(copy, at: InsertionSlot(container: address.container, index: address.index + 1))
        }
    }

    func toggleEnabled(blockID: UUID) {
        rig.mutateBlock(id: blockID) { $0.isEnabled.toggle() }
    }

    func splitAtElement(id: UUID) {
        guard let address = rig.address(ofElement: id) else { return }
        withAnimation(Anim.reflow) {
            _ = rig.wrapInParallel(at: address)
        }
    }

    func joinParallel(id: UUID) {
        guard let path = rig.container(holdingParallel: id) else { return }
        withAnimation(Anim.reflow) {
            _ = rig.joinParallel(id, in: path)
        }
    }

    func addLane(toParallel id: UUID) {
        guard let path = rig.container(holdingParallel: id) else { return }
        withAnimation(Anim.reflow) {
            _ = rig.addLane(to: id, in: path)
        }
    }

    func removeLane(_ laneIndex: Int, fromParallel id: UUID) {
        guard let path = rig.container(holdingParallel: id) else { return }
        withAnimation(Anim.reflow) {
            _ = rig.removeLane(at: laneIndex, from: id, in: path)
        }
    }

    /// Append to the end of a chain, used by tapping a palette item.
    func append(componentID: String, toChain chainID: UUID) {
        let count = rig.elements(at: .top(chainID))?.count ?? 0
        withAnimation(Anim.reflow) {
            _ = rig.insert(
                .block(Block(componentID: componentID)),
                at: InsertionSlot(container: .top(chainID), index: count)
            )
        }
    }

    func setLayout(_ layout: RigLayout) {
        withAnimation(Anim.reflow) {
            rig.layout = layout
            // Grow to fit the new layout, but never truncate: hiding a chain is
            // reversible, deleting one is not.
            rig.chains = RigFactory.chains(growing: rig.chains, toAtLeast: layout.chainCount)
        }
    }

    private static func regenerateIDs(_ element: ChainElement) -> ChainElement {
        switch element {
        case .block(var b):
            b.id = UUID()
            return .block(b)
        case .parallel(var p):
            p.id = UUID()
            p.lanes = p.lanes.map { lane in
                var l = lane
                l.id = UUID()
                l.elements = lane.elements.map(regenerateIDs)
                return l
            }
            return .parallel(p)
        }
    }
}
