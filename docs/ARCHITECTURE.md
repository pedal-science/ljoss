# Architecture

How the app is put together, and why. Where a decision could reasonably have
gone another way, the alternative and the reason it lost are recorded — those
are the parts most likely to be "simplified" back into bugs.

See [DRAG-ENGINE.md](DRAG-ENGINE.md) for the drag pipeline, which is the most
intricate part and has its own document, and [ENGINE.md](ENGINE.md) for how a rig
reaches a namchain device.

## Layers

```
App/          Scene, and the split-view / stack shell
Views/        Canvas, node tiles, palette tray, inspector, library, design tokens
DragEngine/   Drag state, frame registry, hit testing, slot mapping, the gesture
Engine/       The namchain client: block mapping, the encoder, framing, the session
Model/        The rig tree, addressing, and the edit algorithms
Store/        Persistence and starter content
Catalogue/    The 102 effect blocks and their parameters
```

Dependencies point downward. `Model/` knows nothing about SwiftUI and compiles
standalone — which is what lets `Tests/` exercise it with a plain `swiftc`
invocation and no test host. `Catalogue/` and the lower half of `Engine/` hold the
same line for the same reason: the encoder is where a silent mistake is most
expensive, so it has to be cheap to assert.

`Engine/` sits above `Model/` and `Catalogue/` and below `Views/`. It reads a rig
and never writes one — see [ENGINE.md](ENGINE.md).

## The routing model

A rig holds one or two chains. A chain is `Input -> [ChainElement] -> Output`.
A `ChainElement` is either a single block or a parallel section of lanes, and a
lane is itself a list of elements:

```
Input ─ Comp ─ Amp ─ Cab ─┬─ Shimmer ── Delay ─┬─ EQ ─ Output
                          └─ (dry)             ┘
                          ╰── ParallelSection ─╯
```

```swift
enum ChainElement { case block(Block); case parallel(ParallelSection) }
struct ParallelSection { var lanes: [Lane]; var splitMode: SplitMode; ... }
struct Lane { var elements: [ChainElement]; var level, pan: Double; ... }
```

### Why a series/parallel tree and not a general DAG

A DAG is the more general model and the wrong one here:

- It is what the hardware actually exposes. Helix, Quad Cortex and HeadRush all
  present series paths with parallel branches, not arbitrary graphs.
- It always renders as a left-to-right flow with vertical branching. A general
  DAG needs layout heuristics and can produce diagrams that cross over
  themselves.
- **Every insertion point is addressable as `(container, index)`.** This is the
  decisive one: dragging into a DAG means choosing an *edge* to splice, which is
  ambiguous when edges overlap on screen. Here a drop is "which list, which
  gap" — a question the geometry can answer unambiguously.

The cost is that genuinely exotic routing cannot be expressed. That is an
acceptable trade for a design tool aimed at guitarists.

### Why `ChainElement` is not `indirect`

The recursion runs through `Array` (in `Lane.elements`), which is a fixed-size
struct holding a heap buffer. The enum is therefore already finite-sized, and
`indirect` would only add a redundant box per element.

### Why lane steps address parallels by UUID

```swift
struct LaneStep { var parallelID: UUID; var laneIndex: Int }
```

A path into a lane names the parallel by identity, not by its index in the
parent list. That single choice removes an entire bug class: removing an
element earlier in an ancestor container **cannot** invalidate a path pointing
into a later sibling. Only the final index within one container can shift, and
that shift is handled in exactly one place (`move(from:to:)`).

If this were `parallelIndex: Int`, every mutation would have to rewrite every
outstanding path.

### Why Input and Output are properties, not cases

`SignalChain` has `input` and `output` as stored properties rather than
`ChainElement` cases. "The endpoints can never be deleted or reordered" then
becomes unrepresentable rather than a rule enforced at runtime.

## Edits and invariants

All mutations live in `Model/ChainEdits.swift`. Three things matter.

**`move` removes without normalising.** Normalisation can collapse a parallel
whose lanes just emptied — potentially the very container the element is about
to be inserted into. So `move` removes with `normalizing: false`, inserts, and
normalises once at the end. A failed insert puts the element back, so a failed
move is never destructive.

**Index adjustment happens in one place.** Within a single container, every slot
after the removed index slides down one:

```swift
if target.container == address.container && target.index > address.index {
    target.index -= 1
}
```

This composes with the render-slot mapping described in
[DRAG-ENGINE.md](DRAG-ENGINE.md#rendered-indices-versus-model-indices).
Applying only one of the two is the classic reordering off-by-one.

**`normalize()` restores invariants after every mutation.** It is cheap and
idempotent, so the rest of the app can assume a well-formed tree:

| Rule | Reason |
| --- | --- |
| A parallel with fewer than 2 lanes is spliced back into series | A one-lane split is just series routing |
| A parallel whose lanes are **all** empty is removed | Dragging the last block out of a split should close the space up |
| An **individually** empty lane is preserved | A dry parallel path is legitimate and common — this is the wet/dry split |

That third row is deliberate and worth defending: auto-collapsing a section the
moment one lane empties would destroy the user's routing every time they picked
up their only reverb to reposition it.

### Nesting depth

`Rig.maxParallelDepth = 1` — parallels sit at a chain's top level, not inside
another parallel's lane. A column is then always either a single block or a
stack of lanes of blocks, which keeps the canvas readable and hit testing
unambiguous. Multiple independent splits along one chain are still allowed,
which is what "split and join at different places" actually asks for.

Every code path honours the constant, so raising it is a one-line change.

### Moving a parallel into its own lane

`canMove` rejects it before anything is removed, by checking whether the
destination path descends through any id in the moved subtree. Without the
check, a naive remove-then-insert either loses the subtree or builds a cycle.

## Persistence

One JSON file per rig under
`~/Library/Application Support/RigDesigner/Rigs/`, written atomically, with
edits coalesced behind a 400 ms debounce and flushed when the scene leaves
`.active`.

**One file per rig, not one library file:** a rig that fails to decode then
costs the user that rig rather than their whole library, and duplicate and
delete become single file operations.

**`Block.componentID` is a `String`, not an enum.** An unrecognised enum raw
value throws and takes the entire rig down with it. As a string, a rig saved by
a future build still opens and shows an "Unknown Block" placeholder for the one
component this build does not know
(`Catalogue.resolve(_:)` falls back to `placeholder(for:)`).

Likewise, parameter values absent from `Block.values` fall back to the
catalogue's default, so adding a parameter to a component does not invalidate
saved rigs.

**Codable is synthesised.** Swift derives it for the recursive enum, and the
round trip is asserted in the tests.

## Layout switching is grow-only

`Rig.chains` may hold more chains than the current layout displays;
`Rig.activeChains` is what the UI renders. Switching from a dual to a single
layout **hides** the second chain rather than deleting it, and switching back
reveals it intact.

The first implementation truncated the array. A stray tap on the layout menu
then silently destroyed a fully built vocal chain, with no undo. Hiding is
reversible; deleting is not.

## Views

`RigEditorView` owns a `RigEditor` (`@Observable`) and injects it into the
environment. `ContentView` keys the editor on the rig id (`.id(id)`) so
switching rigs builds a fresh editor rather than carrying the previous rig's
drag and selection state across.

The palette tray deliberately lives in the **same pane** as the canvas. The
drag is a custom gesture tracked in the global coordinate space, so tray and
canvas being under one root is what makes dragging between them the same code
path as reordering within a chain.

**Wrap is a viewing preference, not rig data.** It is stored with
`@AppStorage`, shared by every rig and never written into one, so toggling it
cannot mark a rig modified or change its file. How the wrapped layout and its
drag targeting work is in [DRAG-ENGINE.md](DRAG-ENGINE.md#wrapping).

### Sizing

`Metrics` holds the numbers. The brief was that nothing may be too small to hit
accurately with a fingertip; Apple's floor is 44pt and everything here clears
it, with the things you touch during a drag much larger:

| | |
| --- | --- |
| Node tile | 148 × 104 |
| Palette tile | 132 × 86 |
| Any control | ≥ 48pt (`minTouchTarget`) |

Category colour is one vivid accent per category, used at ~0.16 opacity for
fills and full strength for icons and strokes. One value works in both
appearances, so there is no dynamic colour provider and no asset catalogue to
keep in sync.

## Platform differences

| | macOS | iOS |
| --- | --- | --- |
| Start a drag | 8pt of pointer movement | 0.18 s long press |
| Shell | `NavigationSplitView` | Split view on iPad, `NavigationStack` on iPhone |
| Haptics | `sensoryFeedback` is a no-op | Selection tick as the gap moves |

The drag activation split is not cosmetic. On iOS a finger pan *is* how you
scroll, so a drag must be gated behind a hold or the scroll view wins every
touch. On macOS scrolling is a trackpad gesture that competes with nothing, so
requiring a hold before a mouse drag would feel broken.

`sensoryFeedback` works on both platforms and needs no UIKit import, so there is
no conditional compilation for haptics.

## Tests

`Tests/` holds assertions for the model layer — the tree edits and the
render-slot mapping — for the wrapped-row geometry and hit testing, and for the
engine encoder and the wire format. That is where correctness is subtle and where a
regression is silent rather than a crash:

```bash
./Tests/run-model-tests.sh
```

It compiles `Model/`, `Catalogue/`, the slot mapping, the flow geometry and the
SwiftUI-free half of `Engine/` with `swiftc` and runs the assertions. No test host,
no scheme, about five seconds. None of those sources depend on SwiftUI, so this
needs nothing from Xcode beyond a toolchain.

It is not a substitute for a build, though. Swift's region-based isolation
diagnostics run in a later pass than `swiftc -typecheck`, so a file can typecheck
cleanly and still fail `xcodebuild` with a data race — which is how
`EngineClient`'s continuation wrapper was caught.

## Verified, and not

Driven against the running macOS app: reorder within a chain; palette → chain
insert; drag-to-remove; drag a block into a parallel lane and back out again
leaving a preserved dry lane; tap-to-select opening the inspector; autosave
round-tripping. With wrap on: rows breaking at the window width, the wire
returning beneath each row into the next, toggling wrap off and back on, both
toolbar icons, and a reorder between wrapped rows landing in the slot aimed at.

Not yet seen live: **hover feedback across wrapped rows** — the gap opening at
the start of the next row, and the canvas scrolling vertically. The automation
used so far delivers no pointer movement between press and release, so it can
check where a drop lands but not what happens on the way. The rules behind both
are asserted in `Tests/FlowTests.swift`.

Not yet exercised: **the iOS touch path**. It compiles and the shell adapts,
but the long-press-to-lift gesture has never run on a device or simulator.
That is the first thing to test on hardware.

Also not yet exercised: **a real namchain daemon**. The device controls have been
driven by hand against no device, which is the honest offline case and the one that
shows the refusal list; but `namchaind` is a Linux-only target, so nothing here has
completed a handshake or applied a document. See
[ENGINE.md](ENGINE.md#verified-and-not).
