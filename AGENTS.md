# ljoss

A SwiftUI signal-chain designer for guitar, bass and vocal rigs (macOS 27+ and iOS 27+, one
multiplatform target). It is also the front end for namchain: pointed at a device, it sends the
rig being edited over TCP as it is edited. For the pedal it talks to `namchaind` on the Core
host directly over WiFi.

## Build and test

The Xcode project is generated from `project.yml` and not committed.

```sh
xcodegen generate
xcodebuild -project Ljoss.xcodeproj -scheme Ljoss -destination 'platform=macOS' build
./Tests/run-model-tests.sh        # model, geometry, encoder and wire assertions; plain swiftc
```

Checks that need a real daemon are tools, not tests: `Tools/dump-engine-document.sh`,
`Tools/check-device.sh` and `Tools/check-streaming.sh` (see `docs/ENGINE.md`).

`LJOSS_DEMO=<dir>` (macOS) runs `Ljoss/App/DemoMode.swift`: a scripted, hands-off run that builds the
rig in `<dir>/demo.json`, makes its edits and saves the window after each, touching nothing of the
user's. pedal.science's teaser takes its screenshots this way (`comms/video/README.md`).

## Constraints

- `Model/`, `Catalogue/`, and the wire, encoder and protocol files in `Engine/` have no
  SwiftUI (and the engine files no Network), so they compile into the test runner. Keep it so.
- `docs/ARCHITECTURE.md`, `docs/DRAG-ENGINE.md`, `docs/ENGINE.md` and `docs/ASSETS.md`
  record decisions that could have gone the other way. Read the relevant one before
  "simplifying" something.
- LocalEngine and model-finder work is on the `local-engine` branch, not `main`.
- The checkout is `~/code.local/pedal/ljoss`, and the app, the project and the Xcode target are all called Ljoss.

System context (the pedal, how the repos fit together, the plan): `~/code.local/pedal/pedal.project`, starting at its `CLAUDE.md` and `docs/working-across-repos.md`.
