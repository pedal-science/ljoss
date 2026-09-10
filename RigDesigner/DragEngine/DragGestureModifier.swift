import SwiftUI

/// What a press at a given point picked up, if anything.
enum DragSurface: Equatable {
    /// The chain canvas: a press resolves to whichever placed element is under it.
    case canvas
    /// The palette tray: a press resolves to a component tile.
    case palette
}

/// Hosts the lift-and-drag gesture for a whole surface.
///
/// The gesture lives on the *container*, never on the individual tile, and that
/// is load-bearing. The dragged element is removed from the canvas while it is
/// in flight so the space it left closes up — and if the gesture were attached
/// to the tile, removing the tile would tear down the gesture mid-drag, so
/// `onEnded` would never fire and the drag would stay stuck forever. The
/// container outlives every tile, so the gesture always completes.
///
/// Gesture shape: a bare `DragGesture` inside a `ScrollView` loses the touch to
/// the scroll pan, so the drag is gated behind a short long press. Holding still
/// means "pick this up"; an immediate swipe fails the press and scrolls normally.
/// Once lifted, the surfaces set `scrollDisabled` and auto-scroll takes over.
struct DragSurfaceGesture: ViewModifier {
    let surface: DragSurface

    @Environment(RigEditor.self) private var editor
    @State private var isLifted = false

    func body(content: Content) -> some View {
        content.gesture(gesture)
    }

    #if os(macOS)
    /// On macOS a drag is distinguished by *movement*, not by a hold. Scrolling
    /// is a trackpad/wheel gesture here, so click-drag competes with nothing,
    /// and requiring a hold before a mouse drag would feel broken. A click that never
    /// travels `Metrics.pointerDragThreshold` stays a click, so tap-to-select
    /// still works.
    private var gesture: some Gesture {
        DragGesture(minimumDistance: Metrics.pointerDragThreshold, coordinateSpace: .global)
            .onChanged { value in
                if isLifted {
                    editor.updateDrag(pointerGlobal: value.location)
                } else {
                    begin(at: value.startLocation, current: value.location)
                }
            }
            .onEnded { _ in
                guard isLifted else { return }
                isLifted = false
                editor.commitDrop()
            }
    }
    #else
    /// On iOS a finger pan *is* how you scroll, so the drag has to be gated
    /// behind a short hold — otherwise the scroll view wins every touch.
    private var gesture: some Gesture {
        LongPressGesture(minimumDuration: Metrics.liftDuration, maximumDistance: 14)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if isLifted {
                    editor.updateDrag(pointerGlobal: drag.location)
                } else {
                    begin(at: drag.startLocation, current: drag.location)
                }
            }
            .onEnded { _ in
                guard isLifted else { return }
                isLifted = false
                editor.commitDrop()
            }
    }
    #endif

    private func begin(at start: CGPoint, current: CGPoint) {
        guard let (payload, rect) = resolve(at: start) else { return }
        isLifted = true
        // Grab offset keeps the ghost under the finger exactly where it was
        // picked up, rather than snapping its centre to the touch point.
        let grab = CGSize(width: start.x - rect.minX, height: start.y - rect.minY)
        editor.beginDrag(payload, pointerGlobal: current, grabOffset: grab, ghostSize: rect.size)
    }

    private func resolve(at point: CGPoint) -> (DragPayload, CGRect)? {
        switch surface {
        case .canvas:
            guard let hit = editor.registry.element(at: point) else { return nil }
            let address = editor.rig.address(ofElement: hit.id)
                ?? ElementAddress(container: .top(editor.rig.chains.first?.id ?? UUID()), index: 0)
            return (.existing(id: hit.id, from: address), hit.rect)
        case .palette:
            guard let hit = editor.registry.paletteItem(at: point) else { return nil }
            // A new component's ghost is drawn at canvas node size, not the
            // smaller tray size, so the gap it opens matches what will land.
            let rect = CGRect(
                x: hit.rect.midX - Metrics.nodeWidth / 2,
                y: hit.rect.midY - Metrics.nodeHeight / 2,
                width: Metrics.nodeWidth,
                height: Metrics.nodeHeight
            )
            return (.newComponent(componentID: hit.id), rect)
        }
    }
}

extension View {
    /// Host the drag gesture for a surface. Apply to a container that outlives
    /// the tiles inside it.
    func dragSurface(_ surface: DragSurface) -> some View {
        modifier(DragSurfaceGesture(surface: surface))
    }

    /// Publish this view's global frame to a closure, without touching view state.
    func reportGlobalFrame(_ action: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { action($0) }
    }
}


