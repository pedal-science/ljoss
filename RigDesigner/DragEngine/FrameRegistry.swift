import SwiftUI

/// Where everything is on screen, in the global coordinate space.
///
/// Deliberately **not** `@Observable`. Geometry is written here on every layout
/// pass — dozens of writes per frame while auto-scrolling. If a view observed
/// this, each write would invalidate it, which re-runs layout, which writes
/// again: at best a storm of invalidations, at worst "Modifying state during
/// view update". Nothing reads this during `body`; it is read only from gesture
/// and tick callbacks, which run outside the view update.
@MainActor
final class FrameRegistry {

    struct ContainerInfo {
        var rect: CGRect
        /// 0 for a chain's top-level row, 1 for a lane inside a parallel.
        /// The deepest container containing the point wins the hit test.
        var depth: Int
        /// The element ids actually on screen, in order. The element being
        /// dragged is absent, which is what keeps rendered indices honest.
        var renderedIDs: [UUID]
    }

    private(set) var containers: [ContainerPath: ContainerInfo] = [:]
    private(set) var elements: [UUID: CGRect] = [:]
    /// Viewport of each chain's scrolling row, for the auto-scroll edge zones.
    private(set) var chainViewports: [UUID: CGRect] = [:]
    /// Palette tiles, keyed by component id, so a press in the tray can be
    /// resolved to the component under it.
    private(set) var paletteItems: [String: CGRect] = [:]
    var trashRect: CGRect = .zero

    // MARK: - Registration

    func setContainer(_ path: ContainerPath, rect: CGRect, depth: Int, renderedIDs: [UUID]) {
        containers[path] = ContainerInfo(rect: rect, depth: depth, renderedIDs: renderedIDs)
    }

    func removeContainer(_ path: ContainerPath) { containers[path] = nil }

    func setElement(_ id: UUID, rect: CGRect) { elements[id] = rect }
    func removeElement(_ id: UUID) { elements[id] = nil }

    func setChainViewport(_ id: UUID, rect: CGRect) { chainViewports[id] = rect }

    func setPaletteItem(_ componentID: String, rect: CGRect) { paletteItems[componentID] = rect }
    func removePaletteItem(_ componentID: String) { paletteItems[componentID] = nil }

    /// The placed element under a point, used to decide what a press picked up.
    ///
    /// Rects nest: a parallel section's rect encloses every block in its lanes.
    /// The *smallest* containing rect wins, so pressing a block inside a split
    /// picks up that block, while pressing the split's bracket or backing —
    /// which no block covers — picks up the whole section.
    func element(at point: CGPoint) -> (id: UUID, rect: CGRect)? {
        var best: (id: UUID, rect: CGRect)?
        for (id, rect) in elements where rect.contains(point) {
            if best == nil || rect.area < best!.rect.area { best = (id, rect) }
        }
        return best
    }

    /// The palette component under a point.
    func paletteItem(at point: CGPoint) -> (id: String, rect: CGRect)? {
        for (id, rect) in paletteItems where rect.contains(point) { return (id, rect) }
        return nil
    }

    func reset() {
        containers.removeAll()
        elements.removeAll()
        chainViewports.removeAll()
        paletteItems.removeAll()
        trashRect = .zero
    }

    // MARK: - Hit testing

    /// Resolve a pointer position to the place a drop would land.
    func dropTarget(at point: CGPoint, allowTrash: Bool = true) -> DropTarget? {
        if allowTrash, !trashRect.isEmpty, trashRect.contains(point) {
            return .trash
        }
        guard let (path, info) = container(at: point) else { return nil }
        return .slot(RenderSlot(container: path, renderedIndex: insertionIndex(in: info, at: point)))
    }

    /// The container the point is over: the deepest one containing it, or —
    /// when the point is in the dead space between lanes — the nearest.
    private func container(at point: CGPoint) -> (ContainerPath, ContainerInfo)? {
        var best: (ContainerPath, ContainerInfo)?
        for (path, info) in containers where info.rect.contains(point) {
            if best == nil || info.depth > best!.1.depth { best = (path, info) }
        }
        if let best { return best }

        // Nothing directly under the pointer. Fall back to the nearest container
        // so a slightly-off drop still does the obvious thing rather than nothing.
        var nearest: (ContainerPath, ContainerInfo)?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (path, info) in containers {
            let d = info.rect.distance(to: point)
            if d < nearestDistance {
                nearestDistance = d
                nearest = (path, info)
            }
        }
        // Only snap if it is plausibly the intended target.
        return nearestDistance <= Metrics.nodeHeight ? nearest : nil
    }

    /// Which gap in this container the pointer sits in, comparing against the
    /// horizontal midpoint of each rendered element.
    private func insertionIndex(in info: ContainerInfo, at point: CGPoint) -> Int {
        for (i, id) in info.renderedIDs.enumerated() {
            guard let rect = elements[id] else { continue }
            if point.x < rect.midX { return i }
        }
        return info.renderedIDs.count
    }

    /// Which chain's viewport the pointer is over, for auto-scrolling.
    func chain(at point: CGPoint) -> UUID? {
        chainViewports.first { $0.value.contains(point) }?.key
    }
}

extension CGRect {
    var area: CGFloat { width * height }

    /// Shortest distance from the rect to a point; zero when it contains it.
    func distance(to p: CGPoint) -> CGFloat {
        let dx = max(minX - p.x, 0, p.x - maxX)
        let dy = max(minY - p.y, 0, p.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
