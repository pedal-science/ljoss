# ljoss (Rig Designer)

A SwiftUI signal-chain designer for guitar, bass and vocal rigs (macOS 27+ and iOS 27+, one
multiplatform target). It is also the front end for namchain: pointed at a device, it sends the
rig being edited over TCP as it is edited. For the pedal it talks to `namchaind` on `tib`
directly over WiFi.

## Build and test

The Xcode project is generated from `project.yml` and not committed.

```sh
xcodegen generate
xcodebuild -project RigDesigner.xcodeproj -scheme RigDesigner -destination 'platform=macOS' build
./Tests/run-model-tests.sh        # model, geometry, encoder and wire assertions; plain swiftc
```

Checks that need a real daemon are tools, not tests: `Tools/dump-engine-document.sh` and
`Tools/check-device.sh` (see `docs/ENGINE.md`).

## Constraints

- `Model/`, `Catalogue/`, and the wire, encoder and protocol files in `Engine/` have no
  SwiftUI (and the engine files no Network), so they compile into the test runner. Keep it so.
- `docs/ARCHITECTURE.md`, `docs/DRAG-ENGINE.md`, `docs/ENGINE.md` and `docs/ASSETS.md`
  record decisions that could have gone the other way. Read the relevant one before
  "simplifying" something.
- LocalEngine and model-finder work is on the `local-engine` branch, not `main`.
- The checkout is `~/code.local/ljoss`; the app is still called Rig Designer.

System context (the pedal, how the repos fit together, the plan): `~/code.local/pedal.project`, starting at its `CLAUDE.md` and `docs/working-across-repos.md`.
