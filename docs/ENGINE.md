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
```

The first five have **no SwiftUI and no Network**, which is what puts them in
`run-model-tests.sh` alongside `Model/`. Adding either import to one of them breaks
the fast test path, the same discipline `Model/` already keeps.

Every response type is deliberately partial and every field optional: the daemon's
own rule is that responses are supersets, so a client that ignores what it does not
know keeps working across a protocol change.

## Verified, and not

`./Tests/run-model-tests.sh` — 159 assertions, of which the engine's share covers the
split/mix shape and the dry lane, chain-to-channel binding, a hidden chain still
being sent, bypass on every node of a block, the effective-value fallback through the
catalogue, each class of refusal, the framing under fragmentation and coalescing, and
that every request type actually puts its method on the wire. That last one is there
because it did not: `method` began life as a computed property, and synthesised
`Encodable` writes only stored ones.

Both platforms build, and the macOS app has been run and driven by hand — the status
control, its refusal list, the settings sheet, and the inspector.

**This has now talked to a real daemon.** `namchaind` builds on macOS as of namchain's
`macos-host` branch, so the whole path runs on one laptop: a WAV looped in as a virtual
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

Still open: `nc.split`'s `outputs` is declared `ParamKind::Flag` with a default of 2 and
we send a JSON number. One chain with no parallel section never reaches it, so the runs
above say nothing about it — drop a parallel in and watch.

And nothing here has been near the board, an audio interface, or iOS. The local-network
permission prompt still has never appeared, because macOS does not ask for one.
