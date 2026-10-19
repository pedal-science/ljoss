# The engine

How a rig reaches a namchain device, and why the split of work is where it is.

[namchain](https://github.com/pedal-science/namchain) is the real-time engine the pedal
runs: a NAM inference core, a graph compiler, and `namchaind`, which holds a plan per
chain on a real-time thread and serves a JSON control protocol. This app is its front
end. The contract between them is **namchain's** `docs/ui-integration-plan.md` §1,
and the operational references are its `docs/daemon.md`, `docs/schema.md`,
`docs/macros.md` and `docs/assets.md`. Nothing here restates them; this records what
*this* side does and the decisions behind it.

## Who does what

| Job | Owner |
| --- | --- |
| The document — library, tree edits, drag invariants | **app** |
| Flattening the tree into a graph: parallel → `nc.split` + lanes + `nc.mix` | **app** |
| Lowering a block into primitives: EQ bands, feedback delay, tone stack | **engine** |
| The running plan, transitions, ramps, health | **engine** |
| Models and impulse responses | **engine**, listed by `engine.assets` |
| Presentation — subtitle, SF Symbol, source suitability | **app**, keyed by type id |

The app also keeps its **own** list of the user's model and IR files, under Settings →
Models & IRs. It is a listing for the user's benefit and nothing more: no rig names
anything from it, no document carries one, and there is no way to put a file on the
device — the device's library is the operator's, and a rig still names an id from
`engine.assets`. That is a deliberate boundary rather than a gap; see
[ASSETS.md](ASSETS.md).

### Why the app flattens but the engine lowers

The engine will not accept this app's tree, and that is deliberate on both sides.
Taking it would mean the engine owning an ordered chain/lane/parallel model that
exists purely for authoring, duplicating the edit algorithms and invariants of
[ChainEdits.swift](../Ljoss/Model/ChainEdits.swift) in C++, and doubling the
document forms the patch protocol has to support.

The other extreme — the app emitting raw primitive graphs — fails differently: every
client would re-implement the DSP vocabulary, the engine could no longer say what a
document *meant*, and `rig.get` could not return what the user wrote.

So topology is ours and vocabulary is theirs. Our half is one convention, small
enough to state in a sentence and assert in a test:

> a parallel section is one `nc.split` with `outputs = lane count`, one `nc.mix`
> with `inputs = lane count`, lane *i* on port *i*, and the parallel's element id on
> both nodes.

```
Input ─ Amp ─ Cab ─┬─ Delay ─┬─ High Cut ─ Output
                   └─ (dry) ─┘

in → …-nam → …-tone → …-cab → p1-split ─[0]→ …-delay →[0] p1-mix → …-cut → out
                                        └[1]───────────────────→[1]
```

**An empty lane is wired, not omitted.** It carries the dry signal — this app's
wet/dry split, the thing `normalize()` goes out of its way to preserve. Leaving the
mixer port unconnected would bind it to *silence*, which is a different thing and not
what the canvas is showing. That distinction is one line in the encoder and one
assertion in the tests, and it is the easiest thing here to get backwards.

## Identity

Three id spaces, none of them composed out of the others:

| | Owner | What it is |
| --- | --- | --- |
| `element` | **this app** | the block or parallel section a node came from — a UUID, stored and returned verbatim, never parsed, and *not* unique: an amp is two nodes sharing one element |
| `role` | the engine | which node of a lowered macro this is |
| `id` | either | the node's identity inside the graph |

**A primitive's parameter is addressed by `node`, a macro's by `element`.** We supply
explicit ids (`<uuid>-nam`, `<uuid>-tone`), so we can always name a node exactly. But
a macro's node is not in the running plan. The engine expands it into primitives when
it compiles the chain, so the only address that ramps a macro's parameter is its
`element`, alone. A `set_param` that names the macro by `node` is applied to the
document and rebuilds the chain; against a daemon, the same EQ op answered `smooth`
by element and `structural` by node. The engine takes the element's first macro, and
no block lowers to two macros, so an element never names more than one. If one ever
does, `EngineEdits` sends the whole document rather than guess.

`role` stays the engine's word to coin, and we never send one. `element` goes on every
node, because that is what makes a `rig.get` dump recognisable as our work.

## What maps, and what does not

The engine has 11 primitives and 7 macros. **27 of the 102 catalogue blocks** have an
honest target, using 8 of those 18 types:

| Catalogue | Engine |
| --- | --- |
| the 11 amps | `nc.nam` + `fx.amp.tonestack` |
| the 5 cabs | `fx.cab.ir` |
| `eq.parametric`, `eq.vocalair` | `fx.eq.bands` |
| `eq.tilt` | `fx.eq.tilt` |
| `eq.lowcut`, `eq.highcut` | `fx.filter.cut` |
| `delay.digital`, `.tape`, `.analog`, `.slapback` | `fx.delay.feedback` |
| `util.gain`, `util.volume` | `nc.gain` |

The other 75 — drives, dynamics, modulation, reverb, pitch, filters, vocal, tuner,
looper, FX loop — are real DSP nobody has written. They stay in the palette, badged,
and a rig holding one is refused by name rather than half-sent.

### The rule that keeps it honest

> A block is mappable only when **every** parameter it exposes either reaches the
> engine or is named in `outOfBand` with a reason.

44 parameters are currently named out-of-band. The rule is not a convention: a
parameter in neither place **fails the build**, asserted in
[EncoderTests.swift](../Tests/EncoderTests.swift) over every entry in the table. So
does the reverse — a mapping naming a parameter the block no longer has, which is how
a rename in the catalogue would otherwise become a silent no-op.

This exists because a knob that looks live and does nothing is the exact failure
namchain's own schema work was built to kill. Having closed it on their side, it
would be absurd to reopen it on ours.

Two things are out-of-band by decision rather than by omission:

- **Hardware.** Phantom power, a pad, input impedance, an output destination: these
  are the interface's, not the rig's. Remembered, shown, labelled, never sent.
- **Stereo.** The engine declares one channel per port and refuses more, so lane pan,
  output pan and `util.pan` have nowhere to go.

`SplitMode` is the same story told per value. Only `.yCable` is `nc.split`; `aB` is
two mixer gains, `crossover` is a Linkwitz-Riley, and `dynamic` reads a detector.
A rig using one is refused **by name** — quietly sending a Y split would look like it
had worked.

## Decisions

**A lane's level, mute and polarity become a `nc.gain` node.** A mixer's per-port
parameters are runtime state; a document cannot set them. So a lane whose settings
are non-default gets a gain at its tail carrying the combined *linear* value —
linear because polarity needs the sign, and the engine's `gain` reaches down to −8.
A lane at its defaults costs no node at all.

**`isEnabled` becomes bypass, which is not off.** A bypassed node keeps running and
substitutes its dry input, so its state stays warm and switching it back in does not
click. The tile reads dimmed but alive, and the inspector says so.

**`layout` stays a viewing preference.** Every chain in `rig.chains` is sent, not
just `activeChains`, and a hidden one is then explicitly muted and shown as muted.
This is the same argument `wrap` already makes, and it is what stops a stray tap on
the layout menu silently changing what is audible — the failure the grow-only layout
was designed to avoid.

**Channels bind by chain index.** A chain whose index exceeds the device's configured
channel count is caught before sending, naming both numbers. Clamping both chains
onto channel 0 was the alternative and is worse: it would feed the guitar's signal
into the vocal chain, visibly working and audibly wrong.

**A block whose file the device lacks plays as bypassed.** When a model or IR a block names
isn't in the device's library, namchain doesn't refuse the rig: it plays that block as if
bypassed and reports an `asset_missing` issue carrying the block's UUID as `element`
(namchain docs/assets.md). The canvas shows the block as not configured (a folder marker, an
orange dashed outline, "Model not on device" or "IR not on device") and faded like a bypassed
block, because that's what it sounds like. The rig itself is untouched: pick a model the device
has, or copy the file into its library, and the block plays. The lookup is
`EngineStatus.missingAsset(element:)`, so it's covered by the wire tests.

**Engine state is never rig data.** Connection, health, generation and the schema
live in `EngineSession`, beside `RigLibrary` and never inside a `Rig`. Writing a
generation into the document would mark every rig modified and thrash the 400 ms
autosave debounce.

**The engine is a sink, not a mirror.** This app owns the document; `rig.get` is a
diagnostic and nothing is ever rehydrated from it. When the two disagree, the
recovery is to re-send the whole document, which is a button.

## Sending an edit

namchain has two paths for an edit. This app picks between them by what the engine
will do with the edit, not by the kind of control (pedal.project's
`docs/rig-edits.md`, C4).

**A knob the engine ramps is streamed.**
- `EngineEdits` compares the document the engine holds with the one the rig now
  encodes to. When the only differences are numbers on parameters that
  `engine.schema` marks `rampable`, they go as `rig.patch` `set_param` ops while the
  control moves.
- Patches go no more often than every 10 ms, with one in flight at a time. Whatever is
  waiting when that time comes is sent, so the last value of a drag always arrives.
- The engine ramps each value inside its node, with no compile and no crossfade. It
  writes the value into its own document, so a later structural edit keeps it.

**Anything else is the whole document**, once the rig has been still for 250 ms. That
covers adding, removing or moving a block; picking a model, IR or slope; a bypass; the
rig's name; and a layout.
- It waits because a rebuild compiles a new plan, reloads and restarts every model in
  it, and renders both plans for the fade. A burst of edits should cost one rebuild.
- For a control whose parameter can't ramp, the wait makes it commit-on-release.
- A change the engine could reach from the waiting document by ramps alone doesn't
  restart the wait. So a lane or output level is heard 250 ms after it leaves 0 dB,
  where its first step adds a gain node, rather than only after the drag ends.

**The comparison is between documents, not rigs**, because the document is what the
engine holds. A lane at 0 dB has no node, an amp's tone knob reaches the tone stack
through a transform, and a bypass is on every node of a block. Anything the
comparison can't show to be a ramp is treated as structural.

**The schema decides what ramps.**
- A device that doesn't answer `engine.schema` gets every edit as a whole document,
  as before.
- If the engine answers a patch with `structural`, meaning it rebuilt for a parameter
  the schema said ramps, that parameter stops streaming for the rest of the
  connection. A disagreement then costs one rebuild, not one per step.
- A refused patch leaves the engine unchanged, so the whole document is sent to bring
  the two back in step.

Not done yet: a bypass that ramps, which needs the engine to fade a node to its dry
input without a rebuild, and an edit history.

## Levels

`engine.levels` answers the one question every other number in `engine.status` cannot: how loud the
audio is. Read-only, small, dBFS with -200 as the floor, and polled rather than subscribed to.

```
{ "levels": {
    "state": "running", "blocks": 2039, "sample_rate": 48000, "period_size": 64,
    "input":  { "peak": [-2.2, -74.9], "rms": [-28.0, -86.0], "clipped": [0, 0] },
    "output": { "peak": [-6.0, -200.0], "rms": [-30.1, -200.0], "clipped": [0, 0] },
    "chains": [ { "id": "…", "name": "Guitar", "output_channel": 0, "muted": false,
                  "out": { "peak": -6.0, "rms": -30.1, "frames": 4224, "clipped": 0 },
                  "nodes": [ { "node": "…", "element": "<block uuid>", "role": "level",
                               "peak": -6.0, "rms": -30.1, "frames": 4224 } ] } ] } }
```

Four things to know before drawing anything from it:

- **`element` is the app's own block identity.** The engine lowers a macro into primitives that keep
  it, so several nodes can share one element and the *block's* level is the loudest of them
  (`EngineChainLevels.level(forElement:)`). `roles` says which primitive each one is, for a client
  that wants to know which half of a cabinet is hot.
- **Each read takes its window.** The probes are read-and-reset, so two polls describe disjoint
  windows and a client polling faster than the engine renders will see `frames: 0` between populated
  ones. `EngineLevels.combining(previous:fresh:)` holds the last window with samples in it, and
  `hasSignal` is the test; a meter that drew an empty window would flicker to silence every time
  anything else asked the engine a question.
- **The engine's floor is silence, not a very quiet signal.** A channel nothing is routed to arrives
  as `-200`, which is below any meter's own scale (`MeterScale.floor` is -70). The difference is what
  stops a bar being drawn for a channel with no signal.
- **Clipping is per device channel and latches in the UI.** `output.clipped[c]` counts the samples
  the encode had to clamp — a listener's saturation, and the only place full scale means anything
  (a node's float output is allowed past 1.0 and routinely is, which is why nodes carry no `clipped`).

In this app the poll is `EngineLevelsModel` (20 Hz, its own observable so the rig canvas is not
invalidated at meter rate) and the meters are `MeterReader` + `LevelBar` (`MeterScale` for the
thresholds, `MeterBallistics` for the release). An engine that does not advertise `levels` in
`engine.hello` hides the meters rather than erroring: an older engine is not a broken one.

**One number in `MeterScale` is still a placeholder, and it is the one that makes the meters
useful.** `clip` is 0 dBFS, but the pedal's input jack is full scale well below that — the level
campaign measured it at −11.2 dBFS, so a bar that reads 0 here promises about 11 dB of headroom the
input does not have. The scale belongs to the hardware, not to the engine, and it can only be
settled by a campaign that drives the input the way a player does: a real guitar into a guitar
buffer pedal, repeated in both **Inst** and **Line** positions once board 1's input stage exists,
and each position measured separately because they cannot share a scale. That work is specified as
pedal.project's `plan.md` Phase 2b item 4 — the first run needs no board 1, and it is where the
calibrated `input_clip_dbfs`, `input_full_scale_dbu` and the matching floor and nominal come back
from. Until it has run, read the thresholds here as provisional and the bars as accurate rather
than meaningful. Note that in `MeterScale` the thresholds and `clip` are one set for every meter,
device input and node alike, so a per-position scale needs `clip` to become a property of the
reading rather than a constant in the view.

## The local engine

Settings → Hardware offers the other way round as well: **Connect to this computer**, which runs a
`namchaind` as a child of this app and points the session at it. It is a development and audition
aid, not a deployment: namchain's `docs/daemon.md` §"The CoreAudio backend" owns what the daemon
promises, and this section owns only what the app does about it.

The daemon is given `--backend coreaudio`, a loopback TCP listener with a token the app generates,
its own `models/`, `irs/` and `rigs/` under Application Support, and **either** a live input device
(`--input-device`, the UID of one of the Mac's own devices) **or** a WAV to loop (`--capture-path`).
The model folder is the user's own when the library has one with a model in it — a folder that holds
nothing is skipped rather than chosen, so an empty first root cannot shadow a full second one.

Two of the arguments are about latency, and they are the difference between playing through this and
waiting for it:

- **`--device-buffer-frames 32` is the latency knob.** The device's own IO buffer is most of the delay
  a player feels — 512 frames is 10.67 ms at 48 kHz, and 32 is 0.67 ms — so the app asks for 32 and
  Settings → Hardware offers 0 (leave my interface alone), 32, 64, 128, 256 and 512. The daemon puts
  the device's previous value back when it stops, so this does not leave Logic configured for 32
  frames, and it reports what the device actually took in `backend_diagnostics.device_buffer_frames`
  — a device that clamps to 512 must not be described as running at 32.
- **`--rt-priority 60` asks for real-time scheduling, and macOS grants it without privilege.** A
  period that short is only survivable if the render thread is not scheduled as ordinary work, which
  is why the app no longer sends `--rt-priority 0`. `engine.status.realtime` and `render_degraded`
  report what was achieved, so a refusal is visible rather than guessed at.

The *measured* period is on the Hardware page's Audio row: `--period-size 1024` is a ceiling on the
plan, not a request, so the number shown there is the one the device gave.

- **Live input is the point, and the file is the fallback.** Picking an input device is what makes a
  guitar audible through the Mac; picking *None* loops a WAV instead, which is what the mode is for on
  a machine with no interface attached (and what the parked work did before the daemon could capture).
  The input device is chosen by UID, for the same reason the daemon takes a UID: it survives a replug
  and a change of default. Reading a device is the one thing here that makes macOS ask for microphone
  permission, and the grant belongs to **this app**, because it is what spawns the daemon — hence
  `NSMicrophoneUsageDescription` and `com.apple.security.device.audio-input` in `project.yml`. A
  refused microphone is *silence*, not an error, so this is worth knowing before debugging the sound.
- **The device fields are disabled and they are the *stored device*.** While the mode is on, the
  session's own settings are `127.0.0.1` and the daemon's generated token, so showing
  `session.settings` in the Host, Port and Token fields would both mislead and invite the Save button
  to write the loopback address and a local secret over the board's configuration — which is exactly
  what the mode promises not to do. They show `EngineSettingsStore`'s copy instead, disabled, and both
  "Connect" buttons go with them. Turning the switch off puts the stored device back into the session.
- **The daemon is started *instead of* connecting to a device, never after.** At launch the app reads
  the remembered choice first: this Mac, or the board. Doing it the other way round spends the launch
  connected to nothing — try the device, fail, start the daemon, and leave the session behind the
  failure it just showed.
- **The child exiting tells the session, so the two panels cannot disagree.** The session retries a
  lost connection every 30 s for ever, which is right for a board that will come back and wrong for a
  daemon that has already exited: without this, "Could not Connect … Trying again" would sit under a
  switch that says "Could not start", both permanently true and neither useful.
- **A child process, not a LaunchAgent.** A LaunchAgent survives quitting the app, needs an installer
  to remove, and "so I can test without a real board" is not a thing that should outlive the test. The
  child is stopped in `applicationWillTerminate`, which is the one hook SwiftUI does not offer:
  `scenePhase` reaches `.background` when the app is hidden and never reaches a terminated state.
- **`LocalEngine` is a singleton**, because the constraints are physical: one daemon per port, one
  audio device held, one child to reap. It is also what lets the termination hook stop the engine
  without having been handed one.
- **An adopted daemon is a success, not a conflict.** If the port already answers a real handshake the
  app uses that process instead of starting a second one, which would fail with "address already in
  use" and read as the app being broken when the thing the user wanted is right there.
- **The child gets the parent's environment minus the `DYLD_*` variables.** Xcode injects
  `DYLD_INSERT_LIBRARIES=@executable_path/__preview.dylib` into an app it launches; the child inherits
  it by default and dyld kills it before `main` because there is no `__preview.dylib` beside *its*
  executable. The symptom is the local engine failing only while the app is run from Xcode, which is
  where it is being tested. `LocalEnginePlan.childEnvironment` is the fix and the test is the record.

## The transport

TCP, default port 47810, off on the device unless an operator turns it on. Every
message is a u32 **little-endian** length prefix and one JSON body, and
`engine.hello` carries a pre-shared token of at least 16 characters before anything
else is answered.

Four things a hand-rolled client gets wrong, all of which the daemon's tests
exercise from the other side and [WireTests.swift](../Tests/WireTests.swift) covers
from this one:

- **One `recv` is not one message.** A body may arrive in pieces; several may arrive
  in one read. [EngineFraming.swift](../Ljoss/Engine/EngineFraming.swift) is
  split out from the client precisely so this is testable without a socket.
- **A network client may never name an absolute path.** Models and impulse responses
  go by library id (`tweed/deluxe`), or the document is refused before it compiles.
- **Adoption is asynchronous.** A reply is an acknowledgement. What the device is
  *hearing* is `audible_generation` catching up with `generation`, and during a
  structural change the two differ for the length of a crossfade.
- **A reply can be far larger than a request.** A request is capped at the daemon's
  1 MiB `tcp_max_message_bytes`. A reply has its own 16 MiB limit, because
  `engine.assets` and `engine.schema` list the device's whole library, about 1 MB each
  for 1,500 impulse responses. The client reads replies up to 16 MiB; until namchain
  `503aac9` it refused anything over 1 MiB, and the daemon hung up after a reply that
  large.

There is no discovery — no mDNS, no Bonjour — so the host is typed in. There is no
TLS either: the token travels in clear text, and off a trusted network the documented
answer is a tunnel. There is no push, so `engine.status` is polled at 2 Hz.

**The app connects by itself.** A device that has been set up is connected at launch
and kept connected.
- A failed or dropped connection is tried again after 1, 2, 5 and 10 s, then every
  30 s, until the device answers or the player presses Disconnect.
- A refusal, such as a wrong token, isn't retried, because it won't change by itself.
- Nothing is retried while the app is in the background, and coming back tries again
  at once.
- When the device closes the connection, the client notices at the next poll, within
  half a second, rather than when a reply times out 10 s later.

Checked against a daemon started late, killed and restarted: online 0.6 s after it
started, the loss noticed in 0.5 s, and online again 1.1 s after the restart.

## Layers

```
Engine/EngineDocument.swift    the wire types
Engine/BlockMapping.swift      which blocks map, and how
Engine/DocumentEncoder.swift   the tree, flattened
Engine/EngineEdits.swift       which edits stream as ramps, and which need the document
Engine/EngineProtocol.swift    requests and responses
Engine/EngineFraming.swift     the length prefix
Engine/EngineClient.swift      an actor over NWConnection
Engine/EngineSettings.swift    host, port, and the token in the keychain
Engine/EngineSession.swift     connection, streamed ramps, debounced documents, status polling
Engine/LocalEnginePlan.swift   the local engine's decisions: paths, refusals, the command line
Engine/LocalEngine.swift       the local engine's child process
Views/CoreAudioDevices.swift   the Mac's own devices, for the settings page that picks two
```

The first six have **no SwiftUI and no Network**, which is what puts them in
`run-model-tests.sh` alongside `Model/`. `EngineSettings.swift` (the keychain) and
`LocalEnginePlan.swift` (the filesystem) are in that set too — neither SwiftUI, neither a socket —
while `EngineClient.swift` and `EngineSession.swift` are not, and `LocalEngine.swift` cannot be: it
spawns a process and watches it. Adding SwiftUI or Network to one of the six breaks the fast test
path, the same discipline `Model/` already keeps.

Every response type is deliberately partial and every field optional: the daemon's
own rule is that responses are supersets, so a client that ignores what it does not
know keeps working across a protocol change.

## Verified, and not

`./Tests/run-model-tests.sh` — 328 assertions. The engine's share covers:
- the split/mix shape and the dry lane;
- chain-to-channel binding, and a hidden chain still being sent;
- bypass on every node of a block;
- the effective-value fallback through the catalogue;
- each class of refusal;
- the framing under fragmentation and coalescing;
- that every request type actually puts its method on the wire. That one is there
  because it did not: `method` began life as a computed property, and synthesised
  `Encodable` writes only stored ones.
- which edits stream ([EditTests.swift](../Tests/EditTests.swift)). Most of those
  cases must come out structural, because a false ramp is the costly mistake.

The assets' share — the sniff, the brand table, the scan and the ordering — is the
newest; [ASSETS.md](ASSETS.md) says what each of them exists to catch.

The local engine's share is in the same set: the command line it hands the daemon in **both** forms
(live input, and a WAV), the ways it refuses what it cannot run, the token rules, the environment
sanitising, and which of the user's folders becomes the daemon's model library. **It has also been
run end to end on a Mac** (2026-10-02): with the toggle on, launching the app started
`namchaind --backend coreaudio --input-device <the SSL 2+> --capture-channels 2 …` as its child,
`engine.status` reported `coreaudio`, running, the device's measured 512-frame period, 2 capture
channels, 6 playback, 0 xruns and `live_input: 1`, and the daemon published the app's rig
(generation 1) — so the session had handshaken and the document had arrived. Quitting the app stopped
the child. The WAV-loop form was run the same way (`live_input: 0`, `loop_wraps: 4`, so the file was
being consumed). **The capture carries signal rather than the silence a refused microphone would
give**: three seconds recorded from the built-in microphone through the daemon (`namchainctl record
start`) is 143,872 samples at peak 0.10 and RMS 0.015, every one of them non-zero, while the playback
file is correctly all zeros with no document loaded. Adoption was exercised too — a daemon already
listening with the stored token was used instead of a second one being started (the app spawned no
child), the rig still reached the engine, and quitting the app left that daemon running, which is what
"it was not started by this app" means.

What that does **not** cover: a run where Xcode's `DYLD_INSERT_LIBRARIES` is genuinely present (the
sanitising is asserted in `Tests/LocalEngineTests.swift`; the launched-from-Xcode case was not
reproducible from a shell); the microphone **prompt**, because the grant was already in place where
this was tested, so the refused-microphone path (silence rather than an error) was not exercised; and
a recording of the *app's own* child's capture — the daemon's `record_dir` default is a Linux path and
the app does not override it, so for the app the evidence is that its input device opens, the stream
runs with 0 xruns, and the entitlement and usage description above are what it carries.

**A knob streams.** `Tools/check-streaming.sh` drives a daemon through `EngineSession`
itself. Run against namchain `abe1f34` on macOS (`--backend null`), it turned a Gain, a
Parametric EQ band and a delay's mix together for two seconds, a step every 10 ms:
- 804 ramps applied, 0 rebuilds and 0 stale;
- the engine's document ended at the final values;
- a bypass afterwards rebuilt once.

Both platforms build, and the macOS app has been run and driven by hand — the device
control, its refusal list, the inspector, and the settings view the device controls and
the connection sheet moved into ([ARCHITECTURE.md](ARCHITECTURE.md#verified-and-not)).

**This has now talked to a real daemon.** `namchaind` builds on macOS on namchain's `main`
(it arrived on the `macos-host` branch), so the whole path runs on one laptop: a WAV looped in as a virtual
input, the output streamed to a pipe, and this app driving it over TCP. What that
established, in order:

- The engine is transparent when asked to be. An empty chain and a chain holding one
  `util.gain` at its 0 dB default both come back **bit-exact** — `max|a-b|` is 0 across
  116 s — through `namchain-render` and through `namchaind --backend file` alike. A
  third rig at +6 dB is the control and fails by exactly 10^(6/20).
- The bytes under test are this app's. `Tools/dump-engine-document.sh` prints what
  `DocumentEncoder` produces for a named rig, and namchain's `tools/macos/null-test.sh`
  takes a directory of those as its input. There is no second encoder to drift.
- `EngineClient` completes the handshake, `rig.apply` is accepted, and
  `audible_generation` catches up — which is the only thing that says a rig is being
  heard rather than acknowledged. `Tools/check-device.sh` is that check, and it needs a
  daemon, so it is a tool rather than a test.
- **A NAM model runs.** `Tools/check-device.sh … amp` applies one Brit 800, which lowers
  to `nc.nam` plus `fx.amp.tonestack`, with its model named by library **id** (`A2`) —
  never a path, since the engine refuses an absolute path from a network client
  (`path_refused`). `engine.assets` listed the models under `--models-root`, the rig went
  audible at generation 1 with no xruns, and over the same ten seconds of the input the
  amp left RMS where it was (-0.8 dB) while taking 6.6 dB off the peak. Only saturation
  moves those two apart; a model loaded and bypassed would not.
- **A parallel section splits and mixes exactly.** `split2`, `split3` and `splitnull` are
  one Y split with a unity Gain in the first lane and the rest dry, so the output is a
  prediction rather than a tolerance: `lanes × input`, and zero when the last lane's
  polarity is inverted. All three hold to the sample through `namchain-render`. Through
  the daemon the result is `clamp(lanes × input, ±1)` to the sample, since a device output
  saturates at full scale and a float file does not. Over TCP, `split2` followed by
  `splitnull` in one session goes from exactly 2 × input to exact zeros through a 5.0 ms
  fade, which is `--fade-ms`.

  Three lanes is the case that matters. `nc.split` declares `outputs` as
  `ParamKind::Flag` with a default of 2 and we send a JSON number, which was the open
  question here; a two-lane split would pass whether or not the parameter is read. The
  engine validates a Flag as a number against its min, max and step, so `outputs: 3` is
  accepted and a third port exists. The declared kind is still wrong — `engine.schema`
  publishes a lane count as `"flag"`, a boolean — but that is namchain's label to fix,
  and nothing on this side reads it.

Since then the macOS app has driven piv, the pedal's stand-in board, over WiFi
(pedal.project's step 8 soak, 2026-09-28). Nothing here has been near iOS.

**macOS does enforce local-network privacy.** A build it hasn't allowed has its
connections refused before a packet leaves, and the refusal shows only in the system
log, as `Local network prohibited`. The permission follows the app's signing identity.
Until 2026-09-28 the app was built unsigned, so the linker gave it a new ad-hoc
identity at every build and each rebuild lost the permission. It is now signed with
the developer team in `project.yml`, so the permission is granted once and kept.
