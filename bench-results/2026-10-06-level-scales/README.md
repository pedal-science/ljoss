# What the levels mean: the pedal's input scale, its nodes, and its loudness

**Date:** 2026-10-06
**Question:** ljoss shows levels that come from namchain — a peak and an RMS in dBFS for the device's
input, every node in a chain, and the device's output. The numbers look right; the *scale* is not
obvious to a player. What scale should they be on, and what maths do they need?

**Answer, in one line:** the numbers are accurate to a few hundredths of a decibel, and they are in
the wrong reference — this pedal's input clips at **−11.2 dBFS** (about **+2.7 dBu** at the jack), not
at 0 dBFS, so an input meter drawn to 0 dBFS shows about 11 dB of headroom that does not exist.

**The page:** [index.html](index.html) — the recommendation, and links to both runs' full chart sets.

---

## What was measured

```
Mac ──sslgen──▶ SSL 2+ Mk II output 3 ──────────────▶ SSL input 2      (analogue reference: the
                                                                        interface's own ADC reading
                                                                        of what its D/A just played)
                            output 4 ──▶ pedal in ──▶ pedal out ──▶ SSL input 1
                                          (vip, namchaind)             (the pedal's real output)
```

Two things were recorded at once for every segment:

* **what the pedal reports** — `engine.levels` polled at 20 Hz for the whole run, every window kept
  with the time it was taken, so the numbers the app would show are in the record;
* **what the pedal's converters actually carried** — `engine.record` wrote the pedal's own
  `capture.wav` and `playback.wav`, so every meter could be checked against the audio it was
  measuring rather than against the Mac's idea of it.

The interface's own digital loopback (input 5/6, a unity tap of playback 3/4) proves what was sent
without involving a cable or a converter at all.

**87 segments** on a rig of gains whose values are known (`Tools/TestRigs.swift`'s `levels`: 0 dB,
−12 dB, +12 dB — a null test and an arithmetic test in one), and **43 segments** on the `amp` rig
(Brit 800 + tone stack), covering:

| | |
|---|---|
| levels | −60 → 0 dBFS in 6 dB steps, plus 0.75 dB steps across the input's knee (−13.5 → −7.5) |
| shapes | 1 kHz, 100 Hz and 6.3 kHz sines; pink and white noise; a plucked burst; a click track; a log sweep; digital silence; and a **real guitar DI** (crest factor 16.8 dB) |
| measures | peak, 4× true peak, RMS, crest factor, A-weighted RMS (IEC 61672), ITU-R BS.1770-4 loudness (K-weighted, gated LUFS) |

The apparatus is `Tools/levels/` — `README.md` there says how to run it, and `tests.py` checks the
measures against the standards' own figures and the whole analysis chain against a synthetic run
whose answers are known.

---

## Findings

### 1. The pedal's input scale

| | |
|---|---|
| the pedal's ADC reads, against the digital level played | **+11.78 dB** |
| its input clips when the played level reaches | **−11.25 dBFS** (0.75 dB steps) |
| so 0 dBFS at the pedal's input is | **+2.7 dBu** (the interface's line output is +14.5 dBu at 0 dBFS) |
| its input noise floor, interface connected and silent | **−88.0 dBFS(A)** |
| headroom, noise floor to clipping | **77 dB** |

The +11.78 dB is not a mystery once the parts are named: the WM8960's line input runs out of
headroom at about 1 V rms (+2.2 dBu), and the interface's line output can deliver +14.5 dBu. The
interface therefore has to be turned down about 12 dB — or, equivalently, **the pedal's input meter
should treat −11.2 dBFS as full scale**.

That is the whole of the scale problem for the input meter. Everything above −11.2 dBFS is the
converter clipping, and nothing in the app currently says so.

### 2. The engine's numbers are accurate

| | |
|---|---|
| reported input RMS against the pedal's own samples, linear range | **0.06 dB** |
| a chain's node levels against the rig's own gains | **median 0.00 dB**, mean −0.004 dB, max 0.60 dB over 228 node readings |
| latency of the interface's analogue loopback | 26 ms (out 3 → in 2, i.e. D/A + A/D + buffers) |
| repeats of the same segment across a run | **identical** (0.000 dB spread, both reported and from the samples) |

The node arithmetic chart (`4b` in the run page) is the null test: a 0 dB gain node must report
exactly what its input reports, a −12 dB node exactly 12 dB less. It does, to two decimals, for every
steady shape; the largest deviations (0.6 dB on the click track, 0.19 dB on the guitar DI) are
window-boundary effects on sparse signals, which is a property of reading a meter in windows rather
than of the level maths.

### 3. Three real defects the campaign found

**(a) The RMS meter cannot read below about −78 dBFS per sample.** The probe accumulates
`x * x * 2^26` in an integer and rounds each term, so a sample quieter than 1.22 × 10⁻⁴ contributes
nothing at all — the engine's own header says as much ("one sample's square keeps about 1.5e-8 of a
unit"). Consequences: a −12 dB-attenuated noise floor reports the floor (`-200.0`) while its sibling
reports −86.5 dBFS; and on the silence segments the meter reads **1.84 dB low** against the pedal's
own samples. Nothing a player does is affected, but a "no signal" reading at −200 is not "silence",
it is "below the meter".

**(b) The clip counter is blind on the positive rail.** It counts samples at or past `1.0f`, and a
24-bit converter left-justified in a 32-bit slot puts its positive rail at 0x7FFFFF00 — 0.99999994f,
just under. At a played level of 0 dBFS, with **66,790 of the pedal's input frames pinned** on the
positive rail, `engine.levels` reports `clipped: 0` and a peak of `-0.0`. At −6 dBFS, where the
*negative* rail pins instead (the overload is asymmetric — the operating point shifts as the input is
driven harder), it counts 51,333 frames against 53,204 pinned samples. So the same fault reads as
"clipping" or as "perfectly clean" depending on which rail the codec happens to pin.

**(c) A window of silence must count in the denominator.** This one was the report's own bug, found
by the null test: aggregating the engine's disjoint windows by energy while *dropping* the windows
that read the floor makes the answer describe only the windows that had signal in them. On the click
track that read 6.3 dB high, and on a guitar it would read high between notes. The engine's
arithmetic was exact throughout; the aggregation now counts frames from every window it is given.

### 4. Loudness: the same peak is not the same sound

All played at a nominal peak of −24 dBFS and measured at the pedal's output through the
interface. The `peak` column is what the analysed window actually contains: the noise and guitar
excerpts measure a decibel or two below the nominal figure, because their loudest sample falls
outside the guard band. The comparison that matters — the spread at one peak — is unaffected.

| shape | peak | RMS | A-weighted | LUFS | crest |
|---|---|---|---|---|---|
| 1 kHz sine | −24.0 | −44.6 | −43.8 | −44.0 | 3.9 |
| 100 Hz sine | −24.0 | −43.8 | **−62.9** | −45.6 | 3.0 |
| 6.3 kHz sine | −24.7 | −44.0 | −44.1 | **−40.6** | 3.0 |
| pink noise | −24.9 | −55.5 | −58.9 | −55.5 | 12.9 |
| white noise | −24.0 | −56.1 | −58.0 | −53.1 | 13.9 |
| **guitar DI** | −26.2 | −58.8 | −63.9 | **−59.4** | 15.8 |
| plucked burst | −24.0 | −49.8 | −49.8 | −49.8 | 9.1 |
| click track | −24.0 | −82.9 | −85.0 | (gated out) | 37.1 |

Three things fall out of that table:

* a peak meter calls the sine and the guitar the same, and they are **18.8 dB** apart in loudness;
* A-weighting and K-weighting are not interchangeable: the 100 Hz sine reads 19 dB down
  A-weighted but only 2 dB down in LUFS, and the 6.3 kHz sine reads *above* its own RMS in LUFS
  (the K-weighting shelf) while A-weighting leaves it alone;
* a click track has no loudness to speak of — its LUFS is gated out entirely, which is the correct
  answer and a reminder that a loudness number needs programme material to mean anything.

### 5. The output path

| | |
|---|---|
| the pedal's DAC → SSL input 1 (interface gain at minimum) | **−28.6 dB** |
| the interface's own analogue loopback, for comparison | −10.4 dB |
| the interface's input 1 with the pedal connected and silent | −113.8 dBFS(A) — the pedal's own output noise is below the interface's floor |

So the pedal's output, at its current headphone level and through the output fixture, arrives about
18 dB below what the interface's own output manages. That is a fact about *this* wiring (headphone
output at −6 dB, a 100 Ω series resistor, and the interface's line input padded at minimum gain), not
about the engine — but it is why the output meter's absolute numbers look low. A player's "output is
quiet" complaint would be answered by this table, not by the engine's dBFS.

### 6. The amp rig

The `amp` run (Brit 800 + tone stack) tracked its input 1:1 with about 16.5 dB of loss across
−48 → −12 dBFS, with a sine input: no compression was reachable, because the *input* runs out of
headroom at −11.2 dBFS before the model is driven hard. That is itself the finding: **with this input
path, the pedal cannot be driven into the amp's own nonlinearity from a line-level source.** Doing so
needs a hotter input stage (board 1's input buffer) or a hotter source, and that is a hardware
question, not a meter one.

### 7. Two things about the hardware

* the codec emits a **−17 dBFS transient when its stream starts** (its DC-blocking filter settling),
  which any meter — or clip counter — will see as a real event;
* the pedal's input noise floor with a cable connected is −88 dBFS(A) against the −93.5 dBFS(A)
  `codec-bringup-2c` measured with LIN1 shorted to ground, i.e. the cable and the interface's output
  stage add about 5 dB of noise.

---

## The recommendation

**Keep dBFS as the engine's unit, and change what the meters are referenced to.**

1. **The input meter should show headroom to the input's own clip point.** The maths is
   `headroom_db = level_dbfs − clip_dbfs`, with `clip_dbfs` a property of the device rather than a
   constant: for this pedal it is −11.2 dBFS, and it is measurable exactly as this campaign measured
   it. Displayed that way, "−3 dB" means three decibels below clipping whatever the input stage is,
   and the region above 0 is overload — which is true and is not true today. In dBu: the jack's full
   scale is +2.7 dBu, so `dbu = dbfs + 2.7` for this input.

2. **Node meters: keep dBFS, and never clamp at 0.** A node's output is a float; what clips is the
   DAC. Drawing the device output's 0 dBFS onto the same scale separates "this node is hot" from
   "this is about to clip the output" — and the campaign's own +12 dB node exists to prove the
   distinction is real.

3. **The output meter should carry a loudness number beside the peak.** Peak answers "will it clip";
   only K-weighted loudness (or, if a cheap number is wanted, an A-weighted level) answers "how loud
   is it", and the table above shows an 18.8 dB spread at one peak. LUFS needs a stated window
   (400 ms momentary is what a meter shows; 3 s short-term is what a player hears) and must not be
   drawn when the signal is below its gate.

4. **Say what the floor is.** The engine's RMS meter stops at about −78 dBFS per sample. Either draw
   that as the bottom of the scale, or say "below the meter" — but do not draw −200 as if it were a
   measurement of silence.

5. **Ballistics are the client's, and the campaign shows how much that matters.** The engine's
   read-and-reset windows mean two clients polling at different rates get different peaks; the RMS is
   the one number that adds up across windows (which is why the report aggregates it by energy). A
   meter that wants a stable needle should hold a peak and average the RMS over a stated time, and
   should ignore windows with `frames: 0` rather than draw them.

Two of these are engine-side rather than app-side, and both are small: count clips against the
converter's own positive rail, and either raise the RMS accumulator's precision or document the
−78 dBFS floor it imposes. Everything else is a display decision.

---

## Reproducing

```sh
clang -O2 -o Tools/levels/sslgen Tools/levels/sslgen.c \
      -framework CoreAudio -framework AudioUnit -framework AudioToolbox -framework CoreFoundation \
      -I/opt/homebrew/include -L/opt/homebrew/lib -lsndfile

$PY Tools/levels/campaign.py --rig levels --out bench-results/<date>-level-scales/run-levels \
     --shapes "silence,guitar,sine1k,pink,white,burst,clicks" \
     --levels="-60,-54,-48,-42,-36,-30,-24,-18,-12,-6,0" \
     --fine-shapes "sine1k,pink" --fine-levels="-13.5,-12,-11.25,-10.5,-9.75,-9,-8.25,-7.5" \
     --probe-shapes "white,burst,clicks,sine100,sine6k3,sweep" --probe-levels="-48,-36,-24,-12"
$PY Tools/levels/report.py bench-results/<date>-level-scales/run-levels
$PY Tools/levels/summary.py bench-results/<date>-level-scales
```

`campaign.py` refuses to start if a preflight tone does not reach the pedal, restores the rig it
found, stops its recording, and leaves nothing running. The pedal's own recording for the whole run
is fetched into `run-*/pedal-record/` — that is the ground truth every meter was checked against.
