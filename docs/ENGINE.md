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

## The transport

TCP, default port 47810, off on the device unless an operator turns it on. Every
message is a u32 **little-endian** length prefix and one JSON body, and
`engine.hello` carries a pre-shared token of at least 16 characters before anything
else is answered.

Four things a hand-rolled client gets wrong, all of which the daemon's tests
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
- **A reply can be far larger than a request.** A request is capped at the daemon's
  1 MiB `tcp_max_message_bytes`. A reply has its own 16 MiB limit, because
  `engine.assets` and `engine.schema` list the device's whole library, about 1 MB each
  for 1,500 impulse responses. The client reads replies up to 16 MiB; until namchain
  `503aac9` it refused anything over 1 MiB, and the daemon hung up after a reply that
  large.

There is no discovery — no mDNS, no Bonjour — so the host is typed in. There is no
TLS either: the token travels in clear text, and off a trusted network the documented
answer is a tunnel. There is no push, so `engine.status` is polled at 2 Hz.

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
```

The first six have **no SwiftUI and no Network**, which is what puts them in
`run-model-tests.sh` alongside `Model/`. Adding either import to one of them breaks
the fast test path, the same discipline `Model/` already keeps.

Every response type is deliberately partial and every field optional: the daemon's
own rule is that responses are supersets, so a client that ignores what it does not
know keeps working across a protocol change.

## Verified, and not

`./Tests/run-model-tests.sh` — 255 assertions. The engine's share covers:
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

And nothing here has been near the board, an audio interface, or iOS. The local-network
permission prompt still has never appeared, because macOS does not ask for one.
