# The engine

How a rig reaches a namchain device, and why the split of work is where it is.

[namchain](https://github.com/rikkus/namchain) is the real-time engine the pedal
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
[ChainEdits.swift](../RigDesigner/Model/ChainEdits.swift) in C++, and doubling the
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

**Ops address by `node`, not by `element`.** We supply explicit ids
(`<uuid>-nam`, `<uuid>-tone`), so we can always name a node exactly. Addressing a
multi-node element without a role is refused by the daemon, and `role` is the
engine's word to coin — so we do not invent one. `element` still goes on every node,
because that is what makes a `rig.get` dump recognisable as our work.

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

**Engine state is never rig data.** Connection, health, generation and the schema
live in `EngineSession`, beside `RigLibrary` and never inside a `Rig`. Writing a
generation into the document would mark every rig modified and thrash the 400 ms
autosave debounce.

**The engine is a sink, not a mirror.** This app owns the document; `rig.get` is a
diagnostic and nothing is ever rehydrated from it. When the two disagree, the
recovery is to re-send the whole document, which is a button.

## The local engine

Everything above assumes a device somewhere else. Settings → Hardware also offers
the opposite: **Run namchaind on this Mac**, which starts a `namchaind` as a child of
this app, with namchain's `coreaudio` backend — a WAV looped into the machine's output
device, no interface, no guitar, no second machine. It is a development and audition
aid, not a deployment: namchain's `docs/daemon.md` §"The CoreAudio backend" owns what
the daemon promises, and this section owns only what the app does about it.

The daemon is given `--backend coreaudio --capture-path <the chosen WAV>`, its own
`models/`, `irs/` and `rigs/` under Application Support, and a loopback TCP listener
with a token the app generates. The model folder is **the user's own**, when the
library has one with a model in it: a palette full of amps the local engine cannot
play is a worse first experience than no local engine. A folder that holds nothing is
skipped rather than chosen, so an empty first root cannot shadow a full second one.

**The input is a file, and it has a default.** The capture is a WAV looped in place of an
instrument, chosen in Settings → Hardware → Input with a file picker restricted to `.wav`
(because the daemon loops a WAV and refuses anything else by name, so offering an MP3 would
be offering a file that cannot work). It also has a fallback: namchain ships a two-second
mono 48 kHz guitar phrase for its own tests, and `LocalEnginePlan.defaultLoopFile` finds it
by walking up from *the binary that will run* — so a checkout anywhere works, and an
installed `namchaind` outside a checkout comes back empty rather than inventing a path. The
result is that switching the engine on makes a sound without a file being hunted down
first, which is the whole point of a local engine. The search runs again each time the
engine starts, so a checkout that moves or appears is picked up rather than remembered as
broken; the resolved path is written back so the field shows what is actually looping.
There is no fixed list of "likely" checkout paths, deliberately: a path the app guessed is
worse than one the user picked.

Choosing a file **restarts the engine if it was running**, so the choice is audible without a
second trip to the toggle; an engine that was off stays off. And the picker's own parameters are
**constants**: `allowedContentTypes` is `Self.pickerTypes`, and which of the two paths is being
filled comes from separate state. It was first written with the type list derived from the same
optional that opening the picker set — so opening it changed the modifier's configuration,
SwiftUI treated that as a different `.fileImporter`, and the sheet came back with its result
dropped. The symptom was a file chosen in the dialog and then ignored, which reads as the dialog
being broken rather than as the modifier being reconfigured mid-flight.

Four decisions worth stating, because each has a tidier alternative that behaves worse:

- **A child process, not a LaunchAgent.** launchd is the standard way to run a
  per-user daemon and it is wrong here: it outlives the app, it needs an installer to
  remove, and "so I can test without a real device" is not a thing that should outlive
  the test. The child is stopped in `applicationWillTerminate`, which is the one hook
  SwiftUI does not offer — `scenePhase` never reaches a terminated state.
- **`LocalEngine` is a singleton**, because the constraints are physical: one daemon
  per port, one audio device held, one child to reap. A second instance could only fail
  to bind or fight the first, so it is unconstructable rather than discouraged.
- **It is a mode, not a device.** Turning it on points the *session* at `127.0.0.1`
  and does not touch `EngineSettingsStore`. A user with a board configured keeps that
  configuration, and turning the local engine off leaves them pointed at it again.
- **An adopted daemon is a success.** If the port already answers a real handshake,
  the app uses that process instead of starting a second one. A leftover daemon from a
  crash is otherwise a port conflict, which reads as the app being broken when the
  thing the user wanted is already running. A listener that answers but is *not* a
  namchaind shows up as the spawn failing, with the daemon's own last line in the
  message — `address already in use` is the sentence that explains it.

The child also gets the parent's environment **minus the `DYLD_*` variables**. That is
not hygiene for its own sake: Xcode injects `DYLD_INSERT_LIBRARIES` into an app it
launches, the child inherits it, and dyld kills the daemon before `main` because there
is no `__preview.dylib` beside *its* executable — so the toggle would fail only while
being tested from Xcode. `LocalEnginePlan.childEnvironment` is the fix and the test is
the record of why.

### The observation loop this exposed

Worth writing down, because the fix is four words and the symptom is unrecognisable.

`EngineSession`'s private `client`, `poller`, `debounce` and `latest` are `@ObservationIgnored`.
They were not, and the `@Observable` macro tracks a property whether or not it is `private`.
`debounce` is *assigned* on every `rigDidChange`, and `RigEditor.init` calls `rigDidChange` — so
building the editor invalidated every view that reads the session, which rebuilt the editor, which
called `rigDidChange` again. A self-sustaining loop: **3,400 editor constructions per second and
100 % of a core**, found by `Self._printChanges()` printing `ContentView: \EngineSession.debounce
changed.` forever.

It appeared only **while the session was connected**, because that is when a debounce is scheduled at
all — which is why a local engine surfaced it: a daemon on this machine, at this `127.0.0.1`, makes
the session online in seconds and without a board. It was never specific to the local engine; anyone
driving a real device from a built-from-source app would have met it too. The rule it is an instance
of: an `@Observable` type's mutable plumbing belongs to nobody's view, and a write to it must not be
able to invalidate a body that can reach back and write again.

## The transport

TCP, default port 47810, off on the device unless an operator turns it on. Every
message is a u32 **little-endian** length prefix and one JSON body, and
`engine.hello` carries a pre-shared token of at least 16 characters before anything
else is answered.

Three things a hand-rolled client gets wrong, all of which the daemon's tests
exercise from the other side and [WireTests.swift](../Tests/WireTests.swift) covers
from this one:

- **One `recv` is not one message.** A body may arrive in pieces; several may arrive
  in one read. [EngineFraming.swift](../RigDesigner/Engine/EngineFraming.swift) is
  split out from the client precisely so this is testable without a socket.
- **A network client may never name an absolute path.** Models and impulse responses
  go by library id (`tweed/deluxe`), or the document is refused before it compiles.
- **Adoption is asynchronous.** A reply is an acknowledgement. What the device is
  *hearing* is `audible_generation` catching up with `generation`, and during a
  structural change the two differ for the length of a crossfade.

There is no discovery — no mDNS, no Bonjour — so the host is typed in. There is no
TLS either: the token travels in clear text, and off a trusted network the documented
answer is a tunnel. There is no push, so `engine.status` is polled at 2 Hz.

## Layers

```
Engine/EngineDocument.swift    the wire types
Engine/BlockMapping.swift      which blocks map, and how
Engine/DocumentEncoder.swift   the tree, flattened
Engine/EngineProtocol.swift    requests and responses
Engine/EngineFraming.swift     the length prefix
Engine/EngineClient.swift      an actor over NWConnection
Engine/EngineSettings.swift    host, port, and the token in the keychain
Engine/EngineSession.swift     connection, debounced apply, status polling
Engine/LocalEnginePlan.swift   the local engine's decisions: paths, refusals, argv
Engine/LocalEngine.swift       the local engine's child process
```

The first six have **no SwiftUI and no Network**, which is what puts them in
`run-model-tests.sh` alongside `Model/`. Adding either import to one of them breaks
the fast test path, the same discipline `Model/` already keeps. `LocalEnginePlan` is in
that set on purpose and `LocalEngine` is not: the plan is where the mistakes are —
a mistyped flag, a model root pointed at nothing, a token the daemon will refuse — and
the process wrapper has nothing to assert without a real binary.

Every response type is deliberately partial and every field optional: the daemon's
own rule is that responses are supersets, so a client that ignores what it does not
know keeps working across a protocol change.

## Verified, and not

`./Tests/run-model-tests.sh` — 329 assertions, of which the engine's share covers the
split/mix shape and the dry lane, chain-to-channel binding, a hidden chain still
being sent, bypass on every node of a block, the effective-value fallback through the
catalogue, each class of refusal, the framing under fragmentation and coalescing, and
that every request type actually puts its method on the wire. That last one is there
because it did not: `method` began life as a computed property, and synthesised
`Encodable` writes only stored ones. The assets' share — the sniff, the brand table, the
scan and the ordering — is the newest; [ASSETS.md](ASSETS.md) says what each of them
exists to catch. The local engine's share is in the same set: the command line it hands
the daemon, the four ways a loop file is refused, the token rules, and which of the
user's folders becomes the daemon's model library.

Both platforms build, and the macOS app has been run and driven by hand — the device
control, its refusal list, the inspector, and the settings view the device controls and
the connection sheet moved into ([ARCHITECTURE.md](ARCHITECTURE.md#verified-and-not)).

**The local engine has been run end to end on a Mac.** Turning it on started a
`namchaind` with `--backend coreaudio` and a looped WAV, `engine.status` reported
`coreaudio`, `running`, the device's own 1024-frame period, two playback channels and
zero xruns, and quitting the app stopped the child. What that does **not** cover:
capturing from an input device (the app never asks for one), and a run where Xcode's
`DYLD_INSERT_LIBRARIES` is genuinely present — the sanitising is asserted in
`Tests/LocalEngineTests.swift`, but the Xcode-launched case was not reproducible from a
shell, because the preview library is only loadable inside Xcode's own environment.

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

And nothing here has been near the board, an audio interface, or iOS. The local-network
permission prompt still has never appeared, because macOS does not ask for one.
