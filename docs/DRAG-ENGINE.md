# The drag engine

Dragging is the feature this app is judged on, so it is built by hand rather
than on SwiftUI's drag-and-drop. This document explains the pipeline and, more
importantly, the three properties that hold it together — each of which was
learned by breaking it.

## Why not SwiftUI drag-and-drop

The requirement is that the chain **opens a gap under the dragged item** and
closes it again when the item moves away. That needs a continuous stream of
pointer positions while the drag is in flight.

In the iOS 27 SDK, the modern drop-hover callback is macOS-only:

```swift
// SwiftUI.swiftinterface — inside an
// @available(macOS 26.0, *) @available(iOS, unavailable) extension
nonisolated public func onDropSessionUpdated(_ onUpdate: @escaping (DropSession) -> Void) -> some View
```

So on iPhone and iPad the native path gives no continuous hover feed at all,
and the gap animation is impossible to drive from it. A custom
`DragGesture(coordinateSpace: .global)` gives one code path on both platforms
with full control over timing and animation.

The trade is no cross-application dragging, which this app does not need.

## Pipeline

```
press ─▶ DragSurfaceGesture ─▶ FrameRegistry.element(at:) ─▶ DragController.begin
                                                                    │
 pointer moves ────────────────────────────────────────────────────┘
        │
        ▼
FrameRegistry.dropTarget(at:) ─▶ DropTarget (.slot(RenderSlot) | .trash)
        │                                   │
        │                                   └─▶ canvas animates the gap open
        ▼
release ─▶ Rig.modelSlot(for:hiding:) ─▶ Rig.move(from:to:) ─▶ normalize()
```

- `DragController` (`@Observable`) holds live drag state — payload, pointer,
  grab offset, current target. Views observe it.
- `FrameRegistry` holds where everything is on screen. Views *write* to it;
  only gesture and tick callbacks *read* it.
- `RigEditor` owns both, plus the rig, and commits the drop.

## The three load-bearing properties

### 1. The gesture is hosted on the canvas, never on a tile

`.dragSurface(.canvas)` is applied to the scroll content; `.dragSurface(.palette)`
to the tray row. Neither is applied to an individual tile. What was grabbed is
resolved by hit-testing the registry at the press point.

This is not a style preference. The dragged element is **removed from the
canvas** while it is in flight, so the space it occupied closes up. If the
gesture lived on that tile, removing the tile would tear down the gesture
mid-drag: `onEnded` never fires, and the drag stays stuck forever with a ghost
frozen on screen and the trash zone showing.

That is exactly what happened in the first implementation, and it was visible in
the very first screenshot of the running app. The container outlives every tile,
so the gesture always completes.

**Do not move the gesture back onto the tiles.**

### 2. The tree is never mutated during hover

The gap is a view (`DropGap`) that animates its own width between zero and one
node. Nothing is inserted into the model to open it. The model changes exactly
once, on drop.

Inserting a real placeholder would shift every slot index past it, invalidate
the frame-registry keys mid-drag, and leave a mutation to undo if the user
released outside the canvas.

### 3. `FrameRegistry` is deliberately not `@Observable`

Geometry is written to it on every layout pass — dozens of writes per frame
while auto-scrolling. If a view observed it, each write would invalidate that
view, which re-runs layout, which writes again. Best case a storm of
invalidations; worst case *"Modifying state during view update"* and a loop.

Nothing reads the registry during `body`. It is read only from gesture and
tick callbacks, which run outside the view update. The derived `DropTarget` —
which *is* observed — changes a handful of times per drag, not per frame.

Related: the `of:` transform passed to `onGeometryChange` is `@Sendable` and
must stay pure. The write belongs in `action:`. Because the API is
`@preconcurrency`, doing it the wrong way is only a warning under Swift 6 — so
it is easy to ship an actual data race here.

## Hit testing

`FrameRegistry` records, all in the **global** coordinate space:

| | |
| --- | --- |
| `elements` | every block and parallel section, by id |
| `containers` | every element list — a chain's top level, and each lane — with its depth and the ids currently rendered in it |
| `chainViewports` | each chain's scroll viewport, for auto-scroll edge zones |
| `paletteItems` | palette tiles, by component id |
| `trashRect` | the remove target, non-empty only while an existing node is in flight |

Everything in one space means no coordinate conversion during the drag.

**What was grabbed** (`element(at:)`) is the **smallest** rect containing the
point. Rects nest — a parallel section encloses every block in its lanes — so
smallest-wins means pressing a block inside a split picks up that block, while
pressing the split's bracket or backing, which no block covers, picks up the
whole section.

**Where it would land** (`dropTarget(at:)`) is the **deepest** container
containing the point, so a lane beats the chain top level it sits inside. If no
container contains the point, the nearest within one node-height wins, so a
slightly-off drop still does the obvious thing. Within the chosen container the
insertion index comes from comparing the pointer against each rendered
element's horizontal midpoint.

Containers and elements **unregister on disappear**. A pruned split that left
its rect behind would win a later hit test and silently swallow drops.

## Rendered indices versus model indices

While a drag is in flight the dragged element is not rendered, so in its own
container the rendered indices run one short of the model indices past its
position. The target is tracked in **rendered** terms — so the gap is drawn
where the eye expects — and converted once, at drop:

```swift
// Rig.modelSlot(for:hiding:)
let modelIndex = rendered <= hiddenIndex ? rendered : rendered + 1
```

This **composes** with the adjustment inside `move(from:to:)`. The mapping
produces a slot in the current model, which still contains the dragged element;
`move` then accounts for the hole its own removal leaves. Worked example —
model `[a, b, c, d]`, dragging `a`, so the user sees `[b, c, d]`:

| Gap the user aims at | Rendered index | → model slot | `move` adjusts to | Result |
| --- | --- | --- | --- | --- |
| before `b` | 0 | 0 | 0 | `a b c d` |
| `b` \| `c` | 1 | 2 | 1 | `b a c d` |
| `c` \| `d` | 2 | 3 | 2 | `b c a d` |
| after `d` | 3 | 4 | 3 | `b c d a` |

Applying only one of the two adjustments turns "drop just to my right" into a
one-position shuffle — the most visible and most infuriating reordering bug.
Every row above is asserted in `Tests/`, for a leading element and a middle one.

## Auto-scroll

While the pointer rests near the leading or trailing edge of a chain, the canvas
scrolls itself, ramped quadratically so the edge of the zone nudges and the very
edge races.

Two non-obvious constraints:

**There is no scroll-by-offset API, and `ScrollPosition.x` is not a live
readout** — it returns a value only when the position was last set by point. So
the row keeps its own offset accumulator, seeded from
`onScrollGeometryChange`, and writes absolute positions via `scrollTo(point:)`.
The echo from that callback is accepted only while the user is driving; during
auto-scroll it lags our own writes by a frame, and feeding it back makes the
canvas judder.

**The tick must recompute the drop target.** The finger is stationary in the
edge zone, so the gesture has stopped firing while the content slides
underneath. Without `editor.recomputeTarget()` on each tick, the gap stays
pinned to whichever slot the pointer was over when it stopped moving.

Scrolling is disabled outright (`scrollDisabled(editor.drag.isActive)`) while a
drag is live, so nothing competes for the gesture.

## Other traps worth keeping

**Eager `HStack`, not `LazyHStack`, for a chain.** Off-screen blocks in a lazy
stack never register a frame, so the insertion index is wrong as soon as
auto-scroll moves past the materialised window. It fails only for long chains —
that is, in use rather than in a quick test. At this element count eager layout
costs nothing. (The palette tray *is* lazy, which is fine: you can only grab a
tile you can see, and tiles unregister on disappear.)

**Re-resolve the source address at drop.** `commitDrop` looks the element up by
id rather than trusting the `ElementAddress` captured at lift, because
normalisation may have reshaped the tree in between.

**Deep-regenerate ids when duplicating.** Two `ForEach` children sharing an id
makes SwiftUI's diffing undefined, and the symptom is precisely the glitchy
insert/remove animation the whole design is trying to avoid.
`RigLibrary.duplicate` and `RigEditor.duplicateElement` both regenerate every
id in the subtree, lane ids included.

## Known gap

The iOS branch — `LongPressGesture(minimumDuration:).sequenced(before:)` —
compiles but has not been run on a device or simulator. The macOS branch is
verified. Everything downstream of the gesture is shared between them.
