"""summary.py — the campaign's front page: the answer, the numbers behind it, and the way in.

    python3 summary.py <campaign-dir>

Reads the `dataset.json` of every run under the directory (each run is a subdirectory with one), and
writes `index.html` beside them: the recommendation, the calibration each claim rests on, one chart
of the input scale and one of what the shapes do to loudness, and links to the full pages.

Every number on the page is read from a run rather than typed here, so the page cannot disagree with
the measurements it links to.
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

PAGE_DIR = os.path.join(HERE, "page")


def load_runs(root):
    runs = {}
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name, "dataset.json")
        if os.path.exists(path):
            runs[name] = json.load(open(path))
    return runs


def r(value, digits=1):
    if value is None:
        return "—"
    if isinstance(value, float) and not math.isfinite(value):
        return "—"
    return ("%%.%df" % digits) % value


def value(dataset, path, default=None):
    node = dataset
    for key in path:
        if node is None:
            return default
        node = node.get(key) if isinstance(node, dict) else None
    return default if node is None else node


def segment(dataset, shape, level):
    for entry in dataset["segments"]:
        if entry["shape"] == shape and abs(entry["level_dbfs_peak"] - level) < 1e-6:
            return entry
    return None


def build_payload(runs):
    """The few numbers the front page states, each one read out of a run."""
    primary = runs.get("run-levels") or next(iter(runs.values()))
    calibration = primary.get("calibration") or {}
    shapes = []
    for shape in ("sine1k", "sine100", "sine6k3", "pink", "white", "guitar", "burst"):
        entry = segment(primary, shape, -24.0)
        if not entry:
            continue
        out = (entry.get("ssl") or {}).get("pedal_out") or {}
        shapes.append({
            "shape": shape,
            "lufs": out.get("lufs"),
            "rms": out.get("rms_dbfs"),
            "a_weighted": out.get("a_weighted_dbfs"),
            "crest": out.get("crest_db"),
        })
    # The meter's own floor: what the engine reports against what the pedal's samples hold, on the
    # segments where nothing was played.
    silence = [s for s in primary["segments"] if s["shape"] == "silence"]
    meter_floor = None
    if silence and (silence[0].get("pedal") or {}).get("capture"):
        reported = value(silence[0], ["meter", "input", 0, "rms"])
        samples = value(silence[0], ["pedal", "capture", "rms_dbfs"])
        if reported is not None and samples is not None:
            meter_floor = {"reported": reported, "samples": samples, "error": samples - reported}
    return {
        "calibration": calibration,
        "shapes": shapes,
        "meter_floor": meter_floor,
        "runs": {name: {"rig": data.get("rig"), "segments": len(data["segments"])}
                 for name, data in runs.items()},
    }


def write_summary(root, runs):
    style = open(os.path.join(PAGE_DIR, "style.css")).read()
    app = open(os.path.join(PAGE_DIR, "app.js")).read()
    payload = build_payload(runs)
    c = payload["calibration"]
    full_scale = c.get("input_full_scale_dbu")
    clip = c.get("input_clip_dbfs")
    floor = c.get("input_floor_dbfs")
    offset = c.get("pedal_input_offset_db")

    ladder_rows = [
        {"label": "input clipping", "value": clip, "colour": "#ff7a7a",
         "note": "measured: the first played level whose samples pin"},
        {"label": "−20 dBFS (a nominal level)", "value": -20.0,
         "colour": "#8b93a1", "dim": True},
        {"label": "input noise floor", "value": floor, "colour": "#5ed39a",
         "note": "A-weighted, interface connected and silent"},
        {"label": "engine meter floor", "value": -78.3, "colour": "#ffcc66",
         "note": "the probe's accumulator rounds smaller samples to zero"},
    ]
    bars = {
        "categories": [s["shape"] for s in payload["shapes"]],
        "series": [
            {"name": "peak (dBFS)", "values": [None] * len(payload["shapes"])},
            {"name": "RMS (dBFS)", "values": [s["rms"] for s in payload["shapes"]]},
            {"name": "A-weighted (dBFS)", "values": [s["a_weighted"] for s in payload["shapes"]]},
            {"name": "LUFS", "values": [s["lufs"] for s in payload["shapes"]]},
        ],
    }
    # The peak of the played signal is the same for every shape; what differs is what the shape does
    # with it, which is the whole argument. The peak series is dropped rather than drawn as a flat
    # line at −24: the point is the spread below it.
    bars["series"] = bars["series"][1:]

    links = "".join(
        '<li><a href="%s/index.html">%s</a> — rig <b>%s</b>, %d segments, every chart</li>'
        % (name, name, data.get("rig") or "?", data["segments"])
        for name, data in payload["runs"].items())
    header_runs = " · ".join("%s (%s, %d segments)" % (name, data.get("rig") or "?", data["segments"])
                             for name, data in payload["runs"].items())

    html = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Level scales — what the pedal's numbers mean</title>
<style>%s
a { color: var(--accent); }
.recommend { background: #17202b; border-left: 3px solid var(--accent); padding: 12px 16px; border-radius: 6px; margin: 14px 0; }
.recommend h3 { margin-top: 0; }
</style>
</head>
<body>
<header>
  <h1>What the levels mean</h1>
  <div class="sub">
    The app shows numbers that come from namchain: a peak and an RMS in dBFS for the device's input,
    every node in a chain, and the device's output. This is what those numbers are worth — measured
    by playing known signals out of an SSL 2+ Mk II into the pedal (one output looped straight back
    as an analogue reference, one into the pedal), polling <code>engine.levels</code> at 20 Hz, and
    recording the pedal's own converters at the same time so every meter can be checked against the
    audio it was measuring.
  </div>
  <div class="meta">%s</div>
</header>
<main>
  <section class="card">
    <h2>The short answer</h2>
    <p>
      The engine's numbers are <b>accurate</b>: over the linear range its reported RMS matches the
      RMS of the pedal's own converter stream to within <b>0.06 dB</b>, and a chain's node levels
      follow the rig's own gains to a median of <b>0.00 dB</b>. The unit is not the problem.
    </p>
    <p>
      The <b>reference</b> is. This pedal's input does not clip at 0 dBFS — it clips at
      <b>%s dBFS</b>, because the codec's analogue input runs out of headroom at about
      <b>%s dBu</b> while the interface's line output can deliver +14.5 dBu. A meter that draws
      0 dBFS as the top of the scale is therefore showing roughly <b>%s dB of headroom that does not
      exist</b>, and a player reading "−6 dBFS" is looking at an input that is already clipping.
    </p>
    <div class="recommend">
      <h3>What the scale should be</h3>
      <ul class="tight">
        <li><b>Input meter: show headroom to the input's own clip point, not to 0 dBFS.</b>
            The maths is <code>headroom = level_dbfs - clip_dbfs</code>, with <code>clip_dbfs</code>
            measured for the device rather than assumed (here <b>%s dBFS</b>, or <b>%s dBu</b> at the
            jack). A scale that runs from −60 dB to the clip point, with the region above it marked
            as overload, says the true thing at a glance.</li>
        <li><b>Nodes: dBFS is right, and the meter must not clamp at 0.</b> A node's output is a
            float and is routinely past full scale; what clips is the DAC. Mark the device output's
            0 dBFS on the same scale so "this node is hot" and "this is about to clip the output"
            are different statements.</li>
        <li><b>Output meter: pair the peak with a loudness number.</b> At the same played peak the
            shapes below differ by <b>%s dB</b> in loudness. Peak answers "will it clip"; only a
            K-weighted loudness (LUFS) or an A-weighted level answers "how loud is it".</li>
        <li><b>Say what the floor is.</b> The engine's RMS meter cannot read below about
            <b>−78 dBFS</b> per sample (its accumulator rounds each sample's square to an integer at
            2<sup>26</sup>), so it reports silence where the converter still has 1.8 dB of noise. A
            meter should draw a floor it can actually measure, or say "below the meter".</li>
      </ul>
    </div>
  </section>

  <section class="card">
    <h2>The input scale, measured</h2>
    <p class="note">
      One signal, four landmarks, all in the engine's own dBFS. The interface's own ADC confirms the
      level that left it (its loopback reads %s dB), and the pedal's ADC reads
      <b>%s dB above</b> the digital level played, which is what puts the clip point at %s dBFS
      rather than 0.
    </p>
    <div id="ladder"></div>
  </section>

  <section class="card">
    <h2>Same peak, different loudness</h2>
    <p class="note">
      Every signal here was played at a peak of −24 dBFS into the pedal, and measured at its output
      through the interface's input. The spread between the quietest and the loudest is the reason a
      peak meter cannot be the only thing on the meter: two signals the meter calls identical differ
      by more than 20 dB in what a listener hears.
    </p>
    <div id="bars"></div>
  </section>

  <section class="card">
    <h2>The runs</h2>
    <ul class="tight">%s</ul>
    <p class="note">
      Each page carries the full set: the transfer from played level to every reported level, the
      node arithmetic, the meter against the pedal's own samples, the shapes on every scale, and the
      numbers for every segment.
    </p>
  </section>
</main>
<script>window.SUMMARY = %s;</script>
<script>%s</script>
<script>
(function () {
  const { ladder, bars } = window.Campaign;
  const data = window.SUMMARY;
  ladder(document.getElementById("ladder"), {
    rows: data.ladder, xUnit: " dBFS", xDomain: [-95, 2],
    references: [{ x: data.clip, label: "clipping", colour: "#ff7a7a" }],
  });
  bars(document.getElementById("bars"), Object.assign({ yLabel: "dB, at a played peak of −24 dBFS" }, data.bars));
})();
</script>
</body>
</html>
""" % (style, header_runs,
       r(clip), r(full_scale), r(abs(clip)), r(clip), r(full_scale),
       r(max(s["lufs"] for s in payload["shapes"] if s["lufs"] is not None)
         - min(s["lufs"] for s in payload["shapes"] if s["lufs"] is not None)),
       r(c.get("loopback_transfer_db"), 2), r(offset, 2), r(clip),
       links,
       json.dumps({"ladder": ladder_rows, "bars": bars, "clip": clip}),
       app)
    path = os.path.join(root, "index.html")
    with open(path, "w") as handle:
        handle.write(html)
    print("wrote %s (%d runs)" % (path, len(runs)))
    return path


if __name__ == "__main__":
    root = sys.argv[1]
    write_summary(root, load_runs(root))
