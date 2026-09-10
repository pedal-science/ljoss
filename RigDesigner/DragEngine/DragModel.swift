import SwiftUI

/// What is being dragged.
enum DragPayload: Equatable {
    /// A brand-new component lifted out of the palette tray.
    case newComponent(componentID: String)
    /// An element already placed in a chain, lifted from its slot.
    case existing(id: UUID, from: ElementAddress)

    var existingID: UUID? {
        if case .existing(let id, _) = self { return id }
        return nil
    }
}

/// An insertion point expressed in terms of what is currently *on screen*.
///
/// During a drag the element being moved is not rendered, so rendered indices
/// and model indices diverge. Tracking the target in rendered terms means the
/// gap is drawn exactly where the eye expects; the conversion to a model slot
/// happens once, at drop.
struct RenderSlot: Hashable {
    var container: ContainerPath
    var renderedIndex: Int
}

/// Where a drop would land, or that it would delete.
enum DropTarget: Equatable {
    case slot(RenderSlot)
    case trash
}

@MainActor
@Observable
final class DragController {

    // MARK: - Live drag state

    private(set) var payload: DragPayload?
    /// Current finger/cursor position in the global coordinate space.
    var pointerGlobal: CGPoint = .zero
    /// Where in the tile the finger grabbed it, so the ghost does not jump.
    private(set) var grabOffset: CGSize = .zero
    /// Size the ghost draws at, and the width the gap opens to.
    private(set) var ghostSize: CGSize = .init(width: Metrics.nodeWidth, height: Metrics.nodeHeight)

    var target: DropTarget?
    /// Bumped on every meaningful target change to drive haptics.
    private(set) var targetChangeCount: Int = 0

    var isActive: Bool { payload != nil }

    /// The element hidden from the canvas while it is in flight, so the space it
    /// occupied closes up.
    var hiddenElementID: UUID? { payload?.existingID }

    var isOverTrash: Bool { target == .trash }

    // MARK: - Lifecycle

    func begin(_ payload: DragPayload, pointerGlobal: CGPoint, grabOffset: CGSize, ghostSize: CGSize) {
        self.payload = payload
        self.pointerGlobal = pointerGlobal
        self.grabOffset = grabOffset
        self.ghostSize = ghostSize
        self.target = nil
        self.targetChangeCount = 0
    }

    func updateTarget(_ newTarget: DropTarget?) {
        guard newTarget != target else { return }
        target = newTarget
        targetChangeCount &+= 1
    }

    func end() {
        payload = nil
        target = nil
    }

    /// Top-left of the ghost, derived from the pointer and the original grab point.
    var ghostOrigin: CGPoint {
        CGPoint(
            x: pointerGlobal.x - grabOffset.width,
            y: pointerGlobal.y - grabOffset.height
        )
    }
}
