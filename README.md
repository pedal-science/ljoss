# Rig Designer

A signal-chain designer for guitar, bass and vocal rigs — the kind of routing
you'd build on a HeadRush Core, Quad Cortex or Helix Stadium. SwiftUI, one
multiplatform target, iOS 27+ (iPhone and iPad) and macOS 27+.

A rig holds one or two chains. Each runs `Input -> your blocks -> Output` and
can split into parallel lanes and rejoin at any point. Blocks are dragged in
from a palette, reordered by dragging, and removed by dragging them out; the
chain opens a gap to receive an item and closes up behind one that leaves.

## Build

The Xcode project is generated from `project.yml` and is not committed:

```bash
xcodegen generate
open RigDesigner.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project RigDesigner.xcodeproj -scheme RigDesigner -destination 'platform=macOS' build
xcodebuild -project RigDesigner.xcodeproj -scheme RigDesigner -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Test

```bash
./Tests/run-model-tests.sh
```

Assertions for the tree edits, the drag slot mapping, and wrapped-row layout
and hit testing — the places where a mistake is silent rather than a crash.
None of it depends on SwiftUI, so this compiles with plain `swiftc`: no test
host, no scheme, a few seconds.

## Documentation

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — the routing model and why
  it is a series/parallel tree rather than a DAG, the edit invariants,
  persistence, and the platform differences.
- **[docs/DRAG-ENGINE.md](docs/DRAG-ENGINE.md)** — the drag pipeline, the three
  properties that hold it together, and the traps that are easy to reintroduce.

Both record the reasoning behind decisions that could plausibly have gone the
other way, because those are the ones most likely to be "simplified" back into
bugs.

## Layout

| Path | What lives there |
| --- | --- |
| `RigDesigner/Model/` | The rig tree, addressing, and the insert/move/remove/normalise algorithms. No SwiftUI. |
| `RigDesigner/DragEngine/` | Drag state, the frame registry and hit testing, the render-slot mapping, wrapped-row geometry, auto-scroll, and the gesture. |
| `RigDesigner/Views/` | Canvas, node tiles, palette tray, inspector, rig library, and the sizing and colour tokens. |
| `RigDesigner/Store/` | Rig persistence (one JSON file per rig) and the starter rigs. |
| `RigDesigner/Catalogue/` | 102 effect blocks with parameters, plus the input/output and split/merge specs. |
| `Tests/` | Model-layer assertions and their runner. |

Rigs are stored as JSON under
`~/Library/Application Support/RigDesigner/Rigs/`, one file per rig.

## Status

The macOS build is exercised: reordering, palette-to-chain insertion,
drag-to-remove, dragging into and out of a parallel lane, the inspector, and
autosave.

**The iOS touch path is unverified.** It compiles and the shell adapts, but the
long-press-to-lift gesture has not been run on a device or simulator.
