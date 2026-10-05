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
            .onEnded { value in
                guard isLifted else { return }
                isLifted = false
                // Drop where the button came up. The release can arrive at a
                // point no movement was reported for, and the target would
                // otherwise be the one from the last reported move.
                editor.updateDrag(pointerGlobal: value.location)
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
            .onEnded { value in
                guard isLifted else { return }
                isLifted = false
                // Drop where the finger lifted; see the macOS branch.
                if case .second(true, let drag?) = value {
                    editor.updateDrag(pointerGlobal: drag.location)
                }
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

/// One measured frame, tagged with the layout generation it was measured in.
///
/// `onGeometryChange` fires when the value its transform produces *changes*, and
/// a view that is re-inserted — a canvas coming back from settings — can be
/// measured once while it is still moving into place and then never again, which
/// leaves the registry describing a canvas that is no longer on screen. Carrying
/// the generation makes the value differ when the editor asks for a fresh
/// measurement, so the action runs again and reports where things really are.
/// See `RigEditor.layoutGeneration`.
struct MeasuredFrame: Equatable {
    var rect: CGRect
    var generation: Int
}

/// A container's frame, its rendered contents, and the generation it was
/// measured in. Bundling the rendered ids with the rect means the registry is
/// refreshed when the *contents* change, not only when the frame moves.
struct FrameSnapshot: Equatable {
    var rect: CGRect
    var ids: [UUID]
    var generation: Int
}

extension View {
    /// Host the drag gesture for a surface. Apply to a container that outlives
    /// the tiles inside it.
    func dragSurface(_ surface: DragSurface) -> some View {
        modifier(DragSurfaceGesture(surface: surface))
    }

    /// Publish this view's global frame to a closure, without touching view state.
    ///
    /// `generation` is the caller's reading of `RigEditor.layoutGeneration`: it
    /// must be read where the view is built, because that is what makes the view
    /// re-render — and so re-measure — when the editor moves it on.
    func reportGlobalFrame(generation: Int, _ action: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: MeasuredFrame.self) { proxy in
            MeasuredFrame(rect: proxy.frame(in: .global), generation: generation)
        } action: { action($0.rect) }
    }
}


