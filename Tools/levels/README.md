# Tools/levels — what the app's level numbers mean

The app shows levels that come from namchain's `engine.levels`: a peak and an RMS in dBFS for the
device's input, each chain, every node in it, and the device's output. This directory is the
apparatus that measures what those numbers mean in the physical world — what a given reading at the
pedal's input jack is, how a node's number relates to the one before it, and how any of it relates
to how loud the thing sounds.

The question it exists to answer: **what scale should the app show, and what maths turns the
engine's dBFS into it?**

## The measurement

```
Mac ──sslgen──▶ SSL output 3 ──────────────▶ SSL input 2      (the analogue reference: the
                                                                 interface's own ADC reading of
                                                                 what its D/A just played)
                SSL output 4 ──▶ pedal in ──▶ pedal out ──▶ SSL input 1
                                  (namchaind on vip)          (the pedal's real output)
```

Two things are read at once, for every segment:

* **what the pedal reports** — `engine.levels` polled at 20 Hz, every window kept with the time it
  was taken, so the numbers the app would show are in the record;
* **what the pedal's converters actually carried** — `engine.record` writes the pedal's own
  `capture.wav` and `playback.wav` for the whole run, so a meter can be checked against the audio
  it was measuring rather than against the Mac's idea of it.

The interface's loopback channels (input 5/6, a unity digital tap of playback 3/4) prove what was
sent without involving any cable or converter.

## Files

| File | What it is |
|---|---|
| `sslgen.c` | The Mac end: plays a WAV out of chosen channels of a CoreAudio device and records others full-duplex, on one clock, writing both to float WAV. `sslgen.c` → `sslgen` with the build line in its header. |
| `signals.py` | The test signals: sines, pink and white noise, plucked bursts, clicks, a log sweep, silence — each wrapped in silence with a 20 ms marker so captures can be aligned without assuming a latency. |
| `analysis.py` | Every measure: peak, true peak (4× oversampled), RMS, crest factor, A-weighted RMS (IEC 61672, the same weighting `pedal.project/scripts/codec-noise.py` uses), and ITU-R BS.1770-4 loudness (K-weighting, gated integrated LUFS, short-term max). `analysis.py --selftest` checks them against figures that are true by definition. |
| `ncclient.py` | A minimal namchaind client over TCP: length-prefixed JSON with the transport token. |
| `campaign.py` | The run: applies a rig from this app's own encoder (`Tools/dump-engine-document.sh`), plays the matrix, polls, records, and puts the pedal back on the rig it found. Refuses to start if a preflight tone does not reach the pedal. |
| `report.py` | Aligns the three clocks (the SSL's, the pedal's, the wall clock the polls are stamped with), slices each segment out of every capture, and writes `dataset.json`. |
| `page.py`, `page/` | The self-contained web page: the graphs, from `dataset.json`. |

## Running it

```sh
PY=/Users/rik/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3
clang -O2 -o Tools/levels/sslgen Tools/levels/sslgen.c \
      -framework CoreAudio -framework AudioUnit -framework AudioToolbox -framework CoreFoundation \
      -I/opt/homebrew/include -L/opt/homebrew/lib -lsndfile

# rough sweep on a rig whose node levels are known, then the same shapes through an amp
$PY Tools/levels/campaign.py --rig levels --out bench-results/<date>-level-scales/run-levels
$PY Tools/levels/campaign.py --rig amp    --out bench-results/<date>-level-scales/run-amp \
     --shapes sine1k,pink,burst --levels -60,-48,-36,-24,-12,0 --fine-shapes "" --fine-levels ""
$PY Tools/levels/report.py bench-results/<date>-level-scales/run-levels
```

`campaign.py` restores the rig it found, stops its recording, and leaves nothing running. The runs
are long (about ten minutes each) because they are the Core host's only job while they last.

**The marker is a chirp, not a tone** (2–8 kHz over 20 ms, `analysis.marker_template`). It started as
a 1 kHz burst, which was a mistake: two of the test shapes contain a 1 kHz tone at the same level as
the marker, so correlating for it found the body as readily as the marker and landed 1.4 s late on
two segments of the first run. The chirp is in nothing else and correlates sharply even against the
log sweep.

## What the numbers mean

Written up with the graphs in `bench-results/<date>-level-scales/README.md`; the page beside it is
the same result with the charts.
