# Rig Designer

A signal-chain designer for guitar, bass and vocal rigs — the kind of routing
you'd build on a HeadRush Core, Quad Cortex or Helix Stadium. SwiftUI, one
multiplatform target, iOS 27+ (iPhone and iPad) and macOS 27+.

It is also the front end for [namchain](https://github.com/rikkus/namchain), the
real-time engine that runs on the pedal: point it at a device and the rig you are
editing is sent over TCP as you edit it.

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

Assertions for the tree edits, the drag slot mapping, wrapped-row layout and hit
testing, and the engine encoder and wire format — the places where a mistake is
silent rather than a crash. None of it depends on SwiftUI, so this compiles with
plain `swiftc`: no test host, no scheme, a few seconds.

Two things cannot be asserted against a fixture, because they are claims about
another process:

```bash
./Tools/dump-engine-document.sh gain0 --bare    # what the encoder would send
./Tools/check-device.sh 127.0.0.1 47810 /tmp/nc/token
```

The first prints a named rig as this app would put it on the wire; point
namchain's `tools/macos/null-test.sh` at a directory of them and the null test is
about *these* bytes rather than JSON written to resemble them. The second
connects, applies, and waits for `audible_generation` — the field that separates
a rig the engine acknowledged from one it is actually playing. Both need a daemon,
which is why they are tools and not tests. See
[docs/ENGINE.md](docs/ENGINE.md#verified-and-not).

## Documentation

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — the routing model and why
  it is a series/parallel tree rather than a DAG, the edit invariants,
  persistence, and the platform differences.
- **[docs/DRAG-ENGINE.md](docs/DRAG-ENGINE.md)** — the drag pipeline, the three
  properties that hold it together, and the traps that are easy to reintroduce.
- **[docs/ENGINE.md](docs/ENGINE.md)** — talking to a namchain device: who flattens
  what, which blocks the engine can actually play and how the rest are kept honest,
  and the transport.

Each records the reasoning behind decisions that could plausibly have gone the
other way, because those are the ones most likely to be "simplified" back into
bugs.

## Layout

| Path | What lives there |
| --- | --- |
| `RigDesigner/Model/` | The rig tree, addressing, and the insert/move/remove/normalise algorithms. No SwiftUI. |
| `RigDesigner/DragEngine/` | Drag state, the frame registry and hit testing, the render-slot mapping, wrapped-row geometry, auto-scroll, and the gesture. |
| `RigDesigner/Views/` | Canvas, node tiles, palette tray, inspector, rig library, and the sizing and colour tokens. |
| `RigDesigner/Store/` | Rig persistence (one JSON file per rig) and the starter rigs. |
| `RigDesigner/Catalogue/` | 102 effect blocks with parameters, plus the input/output and split/merge specs. No SwiftUI. |
| `RigDesigner/Engine/` | The namchain client. The wire types, the block mapping, the tree-to-graph encoder, the protocol types and the framing have no SwiftUI and no Network, so they compile into the test runner; the client, settings and session sit above them. |
| `Tests/` | Model-layer, flow-geometry, encoder and wire assertions, and their runner. |
| `Tools/` | Two things that need a real engine rather than a fixture: a dump of what the encoder would send, and a handshake-and-apply against a running daemon. |

Rigs are stored as JSON under
`~/Library/Application Support/RigDesigner/Rigs/`, one file per rig.

## Status

The macOS build is exercised: reordering, palette-to-chain insertion,
drag-to-remove, dragging into and out of a parallel lane, the inspector, autosave,
and the device controls — the status popover and its refusal list, the connection
sheet, and the out-of-band labelling.

**The iOS touch path is unverified.** It compiles and the shell adapts, but the
long-press-to-lift gesture has not been run on a device or simulator.

**Nothing has talked to a real namchain daemon yet.** The encoder, the framing and
the protocol types are all asserted against the published contract, but `namchaind`
is a Linux-only target, so end to end needs a Linux host or the board. See
[docs/ENGINE.md](docs/ENGINE.md#verified-and-not).
