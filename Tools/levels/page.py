"""page.py — write the campaign's self-contained web page from a run's dataset.

    python3 report.py <run-dir>          # builds dataset.json and calls this

The page is one HTML file with the styles, the scripts and the data inlined, so it opens from
`file://` with no server and no network, and it can be mailed as evidence. Everything it shows comes
from `dataset.json`; the calibration constants below are the only numbers computed here rather than
read, and each one is derived from the measurements with the derivation in a comment.
"""
import json
import math
import os
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE_DIR = os.path.join(HERE, "page")

# What the interface's own documentation says, as the anchor for absolute levels. SSL publishes
# these maxima and no reference level: nothing says which dBFS "+14.5 dBu" is measured at, so the
# page reports absolute dBu as "pinned by the published maximum" and never as a calibration.
SSL_LINE_OUT_MAX_DBU = 14.5
SSL_LINE_IN_MAX_DBU = 24.0


def median(values):
    values = [v for v in values if v is not None and math.isfinite(v)]
    return statistics.median(values) if values else None


def node_labels(run_dir):
    """element UUID -> a name a reader recognises, from the document the run applied."""
    path = os.path.join(run_dir, "document.json")
    if not os.path.exists(path):
        return {}
    document = json.load(open(path))
    labels = {}
    for chain in document.get("chains", []):
        for node in chain.get("nodes", []):
            element = node.get("element")
            if not element:
                continue
            name = node.get("name") or node.get("type", "")
            if node.get("type") == "nc.gain":
                gain = node.get("gain_db")
                name = "Gain %s dB" % ("{:+.0f}".format(gain) if gain is not None else "?")
            elif node.get("type") == "nc.nam":
                name = "Amp model"
            labels[element] = name
    return labels


def node_predictions(run_dir):
    """What each node's level must be if the chain's own gains are all there is.

    Only meaningful for a chain of gains -- a rig with a model, an EQ or a cab in it has nodes whose
    gain depends on the signal, and predicting those would be inventing a number. So this returns an
    empty map for anything else, and the page draws the arithmetic check only where it is arithmetic.
    """
    path = os.path.join(run_dir, "document.json")
    if not os.path.exists(path):
        return {}
    document = json.load(open(path))
    chain = (document.get("chains") or [{}])[0]
    predictable = all(node.get("type") in ("nc.input", "nc.gain", "nc.output")
                      for node in chain.get("nodes", []))
    if not predictable:
        return {}
    offset = 0.0
    predictions = {}
    for node in chain.get("nodes", []):
        if node.get("type") == "nc.gain":
            gain = node.get("gain_db")
            if gain is None:
                return {}
            offset += float(gain)
        predictions[node["element"]] = {"offset_db": offset, "type": node.get("type")}
    return predictions


def input_series(segment, channel=0):
    rows = (segment.get("meter") or {}).get("input") or []
    return rows[channel] if channel < len(rows) else None


def output_series(segment, channel=0):
    rows = (segment.get("meter") or {}).get("output") or []
    return rows[channel] if channel < len(rows) else None


def value(entry, key):
    return entry.get(key) if entry else None


def write_page(dataset, run_dir):
    labels = node_labels(run_dir)
    calibration_values = dataset.get("calibration") or report_module.calibration(dataset)
    import report as report_module

    payload = {
        "node_labels": labels,
        "node_predictions": node_predictions(run_dir),
        "calibration": calibration_values,
        "pedal_host": dataset.get("rig_requested") and "vip" or "vip",
    }
    for key, val in dataset.items():
        payload[key] = val
    payload["calibration"] = calibration_values

    import report as report_module

    style = open(os.path.join(PAGE_DIR, "style.css")).read()
    app = open(os.path.join(PAGE_DIR, "app.js")).read()
    charts = open(os.path.join(PAGE_DIR, "charts.js")).read()
    html = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Level scales — pedal input, chain nodes, output</title>
<style>
%s
</style>
</head>
<body>
<header>
  <h1>What the levels mean</h1>
  <div class="sub">
    A measured map from the signal at the pedal's input jack to every number the app can show:
    the engine's input, node and output levels, the interface's own readings of the same signal,
    and the loudness a listener would hear. Measured by playing known signals out of an SSL 2+
    Mk II — one output looped straight back as an analogue reference, one into the pedal — while
    polling <code>engine.levels</code> at 20 Hz and recording the pedal's own converters.
  </div>
  <div class="meta"></div>
</header>
<main id="main"></main>
<script>window.DATA = %s;</script>
<script>
%s
</script>
<script>
%s
</script>
</body>
</html>
""" % (style, json.dumps(report_module.json_safe(payload), default=str), app, charts)
    path = os.path.join(run_dir, "index.html")
    with open(path, "w") as handle:
        handle.write(html)
    print("wrote %s (%.0f kB)" % (path, os.path.getsize(path) / 1024.0))
    return path


if __name__ == "__main__":
    import sys
    sys.path.insert(0, HERE)
    import report
    run_dir = sys.argv[1]
    write_page(report.build(run_dir), run_dir)
