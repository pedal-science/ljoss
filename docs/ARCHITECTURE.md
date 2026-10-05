# Architecture

How the app is put together, and why. Where a decision could reasonably have
gone another way, the alternative and the reason it lost are recorded — those
are the parts most likely to be "simplified" back into bugs.

See [DRAG-ENGINE.md](DRAG-ENGINE.md) for the drag pipeline, which is the most
intricate part and has its own document, and [ENGINE.md](ENGINE.md) for how a rig
reaches a namchain device.

## Layers

```
App/          Scene, the split-view / stack shell, and the File menu's export
Views/        Canvas, node tiles, palette tray, inspector, library, settings, design tokens
DragEngine/   Drag state, frame registry, hit testing, slot mapping, the gesture
Engine/       The namchain client: block mapping, the encoder, framing, the session,
              and the local engine this app can run itself
Assets/       The local model and IR library: folders, scanning, sniffing, ordering
Model/        The rig tree, addressing, and the edit algorithms
Store/        Persistence, starter content, and the export's two documents and zip
Catalogue/    The 102 effect blocks and their parameters
```

Dependencies point downward. `Model/` knows nothing about SwiftUI and compiles
standalone — which is what lets `Tests/` exercise it with a plain `swiftc`
invocation and no test host. `Catalogue/` and the lower half of `Engine/` hold the
same line for the same reason: the encoder is where a silent mistake is most
expensive, so it has to be cheap to assert.

`Engine/` sits above `Model/` and `Catalogue/` and below `Views/`. It reads a rig
and never writes one — see [ENGINE.md](ENGINE.md).

The local engine's decisions are split along that same line deliberately:
`Engine/LocalEnginePlan.swift` resolves paths and builds the daemon's command line and is in
the fast test set, while `Engine/LocalEngine.swift` does nothing but spawn a process and watch
it. See [ENGINE.md](ENGINE.md#the-local-engine).

`Assets/` is the odd one: it uses `AssetKind` from `Engine/BlockMapping.swift`, because
a model and an impulse response are one idea and two enums for it would drift. The five
files that do the work — the entries, the sniff, the make table, the scan and the
ordering — are SwiftUI-free and in the fast test set; `AssetLibrary.swift` is the
observable store above them, beside `RigLibrary`. See [ASSETS.md](ASSETS.md).

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
`~/Library/Application Support/Ljoss/Rigs/`, written atomically, with
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

**How a rig is spelled as JSON is one thing, in one place**
(`Store/RigJSON.swift`). The library's own save and the export both write a rig
file, and the export's `ljoss.json` has to be byte for byte what the library
would write — two encoders configured alike would drift the first time one of
them gained a setting, and a file that still loaded but was not the same file
would not say so. The export's layout and its rules are in
[EXPORT.md](EXPORT.md).

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

## Settings is a mode, not a sheet

The gear button at the top right swaps the window's two columns: the rig library's
place is taken by the list of settings areas, and the rig editor's pane by the area
that is selected. It is one window doing two jobs rather than a second scene,
because the alternative — a Settings *scene* on macOS and a modal sheet on iOS —
is two implementations and two ways for the app to be in two states at once.

Three consequences worth stating, because each was a choice:

- **`ContentView` owns the mode, `Views/SettingsShell.swift` owns the contents.**
  The areas are an enum with a title, a symbol and a subtitle, and the first case is
  what settings opens on. The button that opens them is attached to the content
  *inside* each navigation container rather than to the shell: a toolbar item is
  collected from the content up, and a modifier on a view that merely *contains* the
  stack writes a preference nobody reads.
- **The rig `selection` is untouched across the swap.** The editor is keyed on the rig
  id, so returning rebuilds it the way switching rigs already rebuilds it, and
  `RigEditor.rig.didSet` writes every edit through `RigLibrary` immediately, so
  nothing is lost with the view.
- **Entering settings forces the sidebar visible and leaving restores it.** The areas
  list *is* the sidebar in that mode, so a collapsed one would leave the user in a page
  with no way out.

The device control is the same story in miniature. It used to open a popover holding
the connection, the refusals, the issues, the audio details and a "Settings…" button
that opened a sheet; now the button is a shortcut to Settings → Hardware and the popover
is gone, so every one of those lives in one place. The health dot stays on the button,
because the whole point of the dot is that it can be read without opening anything.
`wrap` and the layout menu stay in the editor's toolbar, where the rig they affect is.

### The scan indicator

Settings → Models & IRs disables the results list while a scan is running and dims it —
the list can change under the pointer the moment the scan publishes, and the rows being
read-only today means the dimming is what the user sees, with the disabled state there
for any control a row gains later. Above it is a status row that is **always present at a
fixed height**, with only its contents fading: a row that came and went would move the
list exactly when the user is reading it. The rest of the page (the folders, the grouping
choices) stays live: those are what starts the next scan, and changing one mid-scan
supersedes it. How the library itself works is in [ASSETS.md](ASSETS.md).

## Platform differences

| | macOS | iOS |
| --- | --- | --- |
| Start a drag | 8pt of pointer movement | 0.18 s long press |
| Shell | `NavigationSplitView` | Split view on iPad, `NavigationStack` on iPhone |
| Settings | Areas column, selected area in the detail pane | Areas are the stack's root, a row pushes its page |
| Haptics | `sensoryFeedback` is a no-op | Selection tick as the gap moves |

The drag activation split is not cosmetic. On iOS a finger pan *is* how you
scroll, so a drag must be gated behind a hold or the scroll view wins every
touch. On macOS scrolling is a trackpad gesture that competes with nothing, so
requiring a hold before a mouse drag would feel broken.

Settings follows the same shape: on an iPhone there is no column to replace — which is
what "the sidebar becomes the list of settings areas" asks for — so the list is the
stack's root and a row pushes its page, while the gear button sits on that root screen
rather than on every page it leads to.

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

It compiles `Model/`, `Catalogue/`, the slot mapping, the flow geometry, the
SwiftUI-free half of `Engine/`, the SwiftUI-free half of `Assets/`, and the export — the
zip format, the two documents, the selection and the controller that asks for a place to
put them — with `swiftc` and runs the assertions. No test host, no scheme, about five
seconds. None of those sources depend on SwiftUI, so this needs nothing from Xcode beyond
a toolchain.

**`-plugin-path` is spelled out in the script.** The macro behind `@Observable` is an
external macro, and a frontend not told where its plugin lives shells out to
`swift-plugin-server`; where that server cannot run, the compiler reports "could not be
found for macro 'Observable()'", which reads like a bad source file and is not. The path
is resolved from the active toolchain, so a different Xcode needs no edit.

The asset assertions are the newest and the most load-bearing of the cheap ones. A scan
that re-reads the whole library every time still works, and an ordering that reshuffles
between two draws of the same data still looks sorted, so `Tests/AssetTests.swift`
asserts the parse count of a repeated scan, that a file that changed is the only one read
again, that a file that is gone is pruned, that the day a file was first seen survives
all of it, and that every grouping and sort combination lands in one order.

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

Now exercised: **a real namchain daemon**. `namchaind` builds on macOS on
namchain's `main`, so the engine layer has completed a handshake, applied a
document, and watched `audible_generation` catch up — an empty chain and a unity
gain have both been shown transparent to the sample, and an amp block has run a
NAM model named by library id. The device
controls had until then only been driven against no device, which is the honest
offline case and the one that shows the refusal list. What has still never run is
the board, an audio interface, and iOS. See
[ENGINE.md](ENGINE.md#verified-and-not).

Also exercised, in the running macOS app: **the settings view**. The gear swaps the
library column for the two areas and opens on Hardware; the Device control opens the same
page; the gear swaps back with the rig editor and its rig intact. Settings → Models & IRs
was driven against two folders of real captures — 83 entries — and showed the folders,
the four choices, the indicator going "Scanning folders…" → "Scan finished — 4 files ·
nothing changed" → gone five seconds later, brands read out of metadata (`Darkglass`) and
guessed from filenames (`ORNG-…` → Orange), 56 models before 27 impulse responses, and
`Unknown` last.

Two things could not be driven, and are worth saying rather than implying: this
environment's synthetic clicks do not select rows in a SwiftUI `List` (they do not in the
rig library either) and its keystrokes do not reach the app, so **the areas list being
clicked, and the Hardware form being typed into and saved, are the parts a person still
has to try.**
