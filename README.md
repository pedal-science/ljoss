# Rig Designer

A signal-chain designer for guitar, bass and vocal rigs — the kind of routing
you'd build on a HeadRush Core, Quad Cortex or Helix Stadium. SwiftUI, one
multiplatform target, iOS 27+ (iPhone and iPad) and macOS 27+.

## Build

The Xcode project is generated and therefore not committed:

```bash
xcodegen generate
open RigDesigner.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project RigDesigner.xcodeproj -scheme RigDesigner -destination 'platform=macOS' build
xcodebuild -project RigDesigner.xcodeproj -scheme RigDesigner -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Layout

| Path | What lives there |
| --- | --- |
| `Model/` | The rig tree: a chain is a series of elements, an element is a block or a parallel section of lanes. Addressing and the insert/move/remove/normalise algorithms. |
| `DragEngine/` | Drag state, the frame registry and hit testing, the render-slot ↔ model-slot mapping, and the gesture that hosts a drag. |
| `Views/` | Canvas, node tiles, palette tray, inspector, rig library, and the sizing/colour tokens. |
| `Store/` | Rig persistence (one JSON file per rig) and the starter rigs. |
| `Catalogue/` | 102 effect blocks with parameters, plus the input/output and split/merge specs. |

## Notes

Parallel sections are capped to a chain's top level (`Rig.maxParallelDepth`);
every code path honours the constant, so allowing nested splits is a one-line
change.

Rigs are stored as JSON under
`~/Library/Application Support/RigDesigner/Rigs/`, one file per rig.
