import SwiftUI

/// Scroll metrics along one axis, in raw content-offset terms.
private struct AxisScrollMetrics: Equatable {
    var offset: CGFloat
    var minOffset: CGFloat
    var maxOffset: CGFloat
    /// Insets at the start and end of the axis — content under a toolbar, say —
    /// which the edge zones must measure from, not the scroll view's frame.
    var leadingInset: CGFloat
    var trailingInset: CGFloat
}

/// Live auto-scroll state, kept off SwiftUI state so ticks are free.
@MainActor
private final class AutoScrollState {
    var offset: CGFloat = 0
    var minOffset: CGFloat = 0
    var maxOffset: CGFloat = 0
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    var viewport: CGRect = .zero
    var isAutoScrolling = false
    var isArmed = false
}

/// Slides a scroll view by itself while a drag rests near one of its edges.
///
/// Applied to each chain row (horizontally, for a chain on one line) and to the
/// canvas (vertically, for chains wrapped onto more rows than fit).
struct DragAutoScroll: ViewModifier {
    let axis: Axis
    /// Keep scrolling while the pointer is past the trailing edge, not just near
    /// it. Right for a chain row, whose edges are the window's; wrong for the
    /// canvas, whose bottom edge borders the palette tray.
    let scrollsPastTrailingEdge: Bool

    @Environment(RigEditor.self) private var editor
    @State private var position = ScrollPosition(idType: Never.self)
    @State private var state = AutoScrollState()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: AxisScrollMetrics.self) { [axis] geo in
                switch axis {
                case .horizontal:
                    AxisScrollMetrics(
                        offset: geo.contentOffset.x,
                        minOffset: -geo.contentInsets.leading,
                        maxOffset: geo.contentSize.width + geo.contentInsets.trailing - geo.containerSize.width,
                        leadingInset: geo.contentInsets.leading,
                        trailingInset: geo.contentInsets.trailing
                    )
                case .vertical:
                    AxisScrollMetrics(
                        offset: geo.contentOffset.y,
                        minOffset: -geo.contentInsets.top,
                        maxOffset: geo.contentSize.height + geo.contentInsets.bottom - geo.containerSize.height,
                        leadingInset: geo.contentInsets.top,
                        trailingInset: geo.contentInsets.bottom
                    )
                }
            } action: { _, new in
                state.minOffset = new.minOffset
                state.maxOffset = max(new.minOffset, new.maxOffset)
                state.leadingInset = new.leadingInset
                state.trailingInset = new.trailingInset
                // Accept the echo only when the user is driving. During
                // auto-scroll the reported offset lags our own writes by a
                // frame, and feeding it back makes the content judder.
                if !state.isAutoScrolling { state.offset = new.offset }
            }
            .reportGlobalFrame { state.viewport = $0 }
            .task(id: editor.drag.isActive) {
                await run()
            }
    }

    /// There is no scroll-by-offset API, and `ScrollPosition` is not a live
    /// readout of where the user scrolled to, so this keeps its own accumulator
    /// seeded from `onScrollGeometryChange` and writes absolute positions.
    private func run() async {
        state.isAutoScrolling = false
        guard editor.drag.isActive else { return }

        // A drag that starts inside this view may scroll it straight away. One
        // that arrives from elsewhere — a palette tile carried up into the
        // canvas — must first reach the interior, or merely crossing an edge
        // zone on the way in would scroll the content out from under the user.
        state.isArmed = visibleViewport.contains(editor.drag.pointerGlobal)

        let dt = 1.0 / 60.0
        while !Task.isCancelled && editor.drag.isActive {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { break }

            let velocity = velocity(at: editor.drag.pointerGlobal)
            let proposed = (state.offset + velocity * dt).clamped(to: state.minOffset...state.maxOffset)
            guard velocity != 0, abs(proposed - state.offset) > 0.01 else {
                state.isAutoScrolling = false
                continue
            }

            state.isAutoScrolling = true
            state.offset = proposed
            switch axis {
            case .horizontal: position.scrollTo(x: proposed)
            case .vertical: position.scrollTo(y: proposed)
            }

            // The finger is stationary while the content slides, so the gesture
            // has stopped firing. Without this the gap would stay pinned to the
            // slot the pointer was over when it stopped moving.
            editor.recomputeTarget()
        }
        state.isAutoScrolling = false
    }

    /// The part of the viewport content is actually visible in.
    private var visibleViewport: CGRect {
        var rect = state.viewport
        switch axis {
        case .horizontal:
            rect.origin.x += state.leadingInset
            rect.size.width -= state.leadingInset + state.trailingInset
        case .vertical:
            rect.origin.y += state.leadingInset
            rect.size.height -= state.leadingInset + state.trailingInset
        }
        return rect
    }

    private func velocity(at point: CGPoint) -> CGFloat {
        let viewport = visibleViewport
        guard viewport.width > 0, viewport.height > 0 else { return 0 }

        let (position, lower, upper, cross, crossLower, crossUpper) = switch axis {
        case .horizontal: (point.x, viewport.minX, viewport.maxX, point.y, viewport.minY, viewport.maxY)
        case .vertical: (point.y, viewport.minY, viewport.maxY, point.x, viewport.minX, viewport.maxX)
        }

        // Only the scroll view the pointer is actually over should move.
        let crossSlack: CGFloat = 40
        guard cross >= crossLower - crossSlack, cross <= crossUpper + crossSlack else { return 0 }
        // Hovering the remove target is a request to delete, not to scroll.
        guard !editor.registry.trashRect.contains(point) else { return 0 }
        if !scrollsPastTrailingEdge, position > upper { return 0 }

        // A short viewport keeps an interior to rest in.
        let zone = min(Metrics.autoScrollZone, (upper - lower) / 4)
        let leadingDepth = zone - (position - lower)
        let trailingDepth = zone - (upper - position)

        if !state.isArmed {
            if leadingDepth <= 0, trailingDepth <= 0, cross >= crossLower, cross <= crossUpper {
                state.isArmed = true
            }
            return 0
        }
        if leadingDepth > 0 { return -Metrics.autoScrollMaxSpeed * ramp(leadingDepth / zone) }
        if trailingDepth > 0 { return Metrics.autoScrollMaxSpeed * ramp(trailingDepth / zone) }
        return 0
    }

    /// Ease in so the edge of the zone nudges gently and the very edge races.
    private func ramp(_ t: CGFloat) -> CGFloat {
        let c = t.clamped(to: 0...1)
        return c * c
    }
}

extension View {
    /// Scroll this scroll view along `axis` while a drag rests near its edges.
    func dragAutoScroll(_ axis: Axis, scrollsPastTrailingEdge: Bool = true) -> some View {
        modifier(DragAutoScroll(axis: axis, scrollsPastTrailingEdge: scrollsPastTrailingEdge))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
