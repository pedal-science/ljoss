"""report.py — turn a campaign run into the numbers the report is made of, then into a page.

    python3 report.py <run-dir>

Reads `run.json` (what the Mac measured, segment by segment), `polls.jsonl` (every `engine.levels`
window the engine gave us, with the time it was taken) and `pedal-record/` (the pedal's own ADC and
DAC, so the meters can be checked against the samples they were measuring), and writes
`dataset.json` beside them plus a self-contained `index.html`.

The one thing this file is careful about is **alignment**. Three clocks are in play — the SSL's, the
pedal's, and the wall clock the polls are stamped with — and nothing here assumes they agree:

  * the played file and the SSL's capture are frame-aligned by construction (`sslgen` writes both
    from the same render callback, and stamps the wall clock at frame 0), so a poll window's time is
    placed on the played file's frame axis exactly;
  * the pedal's own recording is aligned by finding the same marker in it, so `capture.wav` is
    sliced at the same instant as the SSL's capture without trusting either sample rate.
"""
import json
import math
import os
import statistics
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import analysis as A  # noqa: E402

GUARD_SECONDS = 0.30       # inside each body: skip the edges, where a fade or a transient lives
BODY_LEAD = 0.72           # where the body starts in a played file (see signals.with_marker)


def json_safe(value):
    """JSON has no infinity and no NaN: a silent segment's `-inf` dB becomes null on the way out.

    The distinction the report cares about is kept, because the charts treat null as "no reading"
    and never as a number -- which is exactly what a floor of -200 dB is meant to say.
    """
    if isinstance(value, float):
        return None if (math.isnan(value) or math.isinf(value)) else value
    if isinstance(value, dict):
        return {key: json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    return value


def load_polls(path):
    windows = []
    with open(path) as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "levels" in row:
                windows.append(row)
    return windows


def energy_mean_rms(entries):
    """The RMS of the union of windows, from each window's own RMS and frame count.

    Two things this has to get right, and the campaign found the second the hard way:

      * **Decibels do not average.** The windows' mean squares are added, weighted by their frame
        counts, because that is what "the RMS of this stretch of audio" means.
      * **A window of silence is still a window.** Frames with a floor reading contribute no energy
        but *do* contribute their frames to the denominator. Dropping them makes the answer describe
        only the windows that had something in them — which for a plucked guitar, or a click track,
        is a handful of windows out of a hundred, and reads several decibels high. The engine's own
        arithmetic was exact throughout; this was the report's mistake, and what exposed it was the
        null test: a unity gain node must read exactly what its input reads, and on the click track
        it read 6 dB high.
    """
    total_energy = 0.0
    total_frames = 0
    for entry in entries:
        frames = entry.get("frames", 0) or 0
        if frames <= 0:
            continue  # not a window at all: the engine had nothing to measure in it
        total_frames += frames
        rms = entry.get("rms")
        if rms is None or rms <= -200.0:
            continue  # a window of silence: real frames, no energy
        total_energy += (10.0 ** (rms / 10.0)) * frames
    if total_frames == 0:
        return None
    if total_energy == 0.0:
        return -200.0
    return 10.0 * math.log10(total_energy / total_frames)


def aggregate(entries, peak_key="peak", rms_key="rms", clipped_key="clipped"):
    """One number per field over a set of windows: max peak, energy-mean RMS, summed clips.

    Also the spread of the per-window RMS values, because that is what a meter's display shows: a
    guitar's windows are not all the same level, so a client polling at 20 Hz sees a moving needle
    rather than one number. The energy mean is the number to compare with an offline measurement of
    the same audio; the percentiles are what the needle does while it is being watched.
    """
    peaks = [e[peak_key] for e in entries if e.get(peak_key) is not None]
    clipped = sum(e.get(clipped_key, 0) or 0 for e in entries)
    frames = sum(e.get("frames", 0) or 0 for e in entries)
    result = {
        "peak": max(peaks) if peaks else None,
        "rms": energy_mean_rms(entries),
        "clipped": clipped,
        "frames": frames,
        "windows": len(entries),
    }
    rms_values = sorted(e[rms_key] for e in entries
                        if e.get(rms_key) is not None and e.get(rms_key) > -200.0)
    if rms_values:
        def percentile(fraction):
            index = min(len(rms_values) - 1, max(0, int(round(fraction * (len(rms_values) - 1)))))
            return rms_values[index]
        result["rms_p10"] = percentile(0.10)
        result["rms_median"] = percentile(0.50)
        result["rms_p90"] = percentile(0.90)
    return result


def per_channel(entries):
    """Aggregate a device's per-channel arrays: entries are the `input`/`output` objects."""
    if not entries:
        return []
    channels = len(entries[0].get("peak", []))
    out = []
    for channel in range(channels):
        rows = [{"peak": e["peak"][channel], "rms": e["rms"][channel],
                 "clipped": (e.get("clipped") or [0] * channels)[channel],
                 "frames": (e.get("frames") or [0] * channels)[channel]}
                for e in entries if channel < len(e.get("peak", []))]
        out.append(aggregate(rows))
    return out


def collect_window(levels):
    """The parts of one `engine.levels` reply the report uses, and nothing else."""
    chains = []
    for chain in levels.get("chains", []):
        chains.append({
            "id": chain.get("id"),
            "name": chain.get("name"),
            "muted": chain.get("muted"),
            "out": {"peak": chain["out"]["peak"], "rms": chain["out"]["rms"],
                    "clipped": chain["out"].get("clipped", 0), "frames": chain["out"].get("frames", 0)}
            if chain.get("out") else None,
            "nodes": [{"node": n.get("node"), "element": n.get("element"), "role": n.get("role"),
                       "peak": n.get("peak"), "rms": n.get("rms"), "frames": n.get("frames", 0)}
                      for n in chain.get("nodes", [])],
        })
    return {"t": levels.get("_t"), "input": levels.get("input"), "output": levels.get("output"),
            "chains": chains, "blocks": levels.get("blocks")}


def windows_in(windows, start, end):
    return [w["levels"] for w in windows if start <= w["t"] <= end]


def aggregate_levels(levels_windows):
    """Per-entry aggregates over a set of `engine.levels` replies."""
    if not levels_windows:
        return None
    result = {
        "input": per_channel([l["input"] for l in levels_windows if l.get("input")]),
        "output": per_channel([l["output"] for l in levels_windows if l.get("output")]),
        "chains": [],
        "windows": len(levels_windows),
    }
    names = []
    for levels in levels_windows:
        for chain in levels.get("chains", []):
            if chain["id"] not in names:
                names.append(chain["id"])
    for chain_id in names:
        sample = next(c for l in levels_windows for c in l.get("chains", []) if c["id"] == chain_id)
        entry = {"id": chain_id, "name": sample["name"], "muted": sample.get("muted"),
                 "out": aggregate([c["out"] for l in levels_windows
                                   for c in l.get("chains", [])
                                   if c["id"] == chain_id and c.get("out")]),
                 "nodes": []}
        # A node is identified by its element and role: an element that lowers into several
        # primitives is one block to the player, and the parts are worth keeping.
        seen = []
        for levels in levels_windows:
            for chain in levels.get("chains", []):
                if chain["id"] != chain_id:
                    continue
                for node in chain.get("nodes", []):
                    key = (node.get("element"), node.get("role"), node.get("node"))
                    if key not in seen:
                        seen.append(key)
        for element, role, node_id in seen:
            rows = [n for l in levels_windows for c in l.get("chains", [])
                    if c["id"] == chain_id for n in c.get("nodes", [])
                    if (n.get("element"), n.get("role"), n.get("node")) == (element, role, node_id)]
            entry["nodes"].append({
                "element": element, "role": role, "node": node_id,
                "peak": max((r.get("peak", -200.0) for r in rows), default=None),
                "rms": energy_mean_rms(rows),
                "frames": sum(r.get("frames", 0) or 0 for r in rows),
                "windows": len(rows),
            })
        result["chains"].append(entry)
    return result


def find_record(run_dir):
    for name in ("capture.wav", "playback.wav"):
        if not os.path.exists(os.path.join(run_dir, "pedal-record", name)):
            return None
    return os.path.join(run_dir, "pedal-record")


# ---------------------------------------------------------------- the calibration

def input_series(segment, channel=0):
    rows = (segment.get("meter") or {}).get("input") or []
    return rows[channel] if channel < len(rows) else None


def output_series(segment, channel=0):
    rows = (segment.get("meter") or {}).get("output") or []
    return rows[channel] if channel < len(rows) else None


def value(entry, key):
    return entry.get(key) if entry else None


def median_of(values):
    values = [v for v in values if v is not None and math.isfinite(v)]
    return statistics.median(values) if values else None


# What the interface's own documentation says, used only to put absolute dBu beside the measured
# dBFS. SSL publishes these two maxima and no reference level: nothing states which dBFS "+14.5 dBu"
# is measured at, so a dBu figure derived from them is "pinned by the published maximum" and never a
# calibration. Every relative number in this file is measured and does not depend on them.
SSL_LINE_OUT_MAX_DBU = 14.5
SSL_LINE_IN_MAX_DBU = 24.0


def calibration(dataset):
    """The constants the recommendation rests on, each one measured rather than assumed.

    The three that matter:

      * `loopback_transfer_db` — the interface's own analogue loopback (output 3 cabled to input 2),
        which is what proves the played level really left the box and at what level;
      * `pedal_input_offset_db` — the pedal's ADC reading against the played level. This is the
        number that turns "the engine says −30 dBFS" into "there is −30 + offset dBFS at the jack",
        and with the interface's published maximum, into dBu;
      * `pedal_output_offset_db` — the same for the way back, the pedal's DAC against what the
        interface's input 1 makes of it.
    """
    segments = dataset["segments"]
    # Levels where every path is well above its own noise and below anything's clipping. The ends of
    # the sweep are where the interesting failures are, so they are deliberately not in the fit.
    steady = [s for s in segments
              if s["shape"] not in ("silence",)
              and -40.0 <= s["level_dbfs_peak"] <= -12.0]

    loopback_transfer = median_of([
        s["ssl"]["loopback_analogue"]["rms_dbfs"] - s["played"]["rms_dbfs"]
        for s in steady if s["ssl"].get("loopback_analogue")
    ])
    # The pedal's own recording is the honest reference where there is one: a meter's error is one
    # of the things being measured, so it must not be the thing the calibration is fitted to.
    pedal_input_offset = median_of([
        ((s["pedal"]["capture"]["rms_dbfs"] if (s.get("pedal") or {}).get("capture")
          else value(input_series(s), "rms")) - s["played"]["rms_dbfs"])
        for s in steady
    ])
    meter_offset = median_of([value(input_series(s), "rms") - s["played"]["rms_dbfs"]
                              for s in steady if value(input_series(s), "rms") is not None])
    pedal_output_offset = median_of([
        s["ssl"]["pedal_out"]["rms_dbfs"] - s["pedal"]["playback"]["rms_dbfs"]
        for s in steady
        if s["ssl"].get("pedal_out") and (s.get("pedal") or {}).get("playback")
    ])

    # Where the input clips, measured from the pedal's own samples rather than from the engine's
    # counter. It has to be: the engine counts samples at or past `1.0f`, and this codec's positive
    # rail -- a 24-bit converter left-justified in a 32-bit slot -- lands at 0.99999994, just under.
    # So at 0 dBFS played, with 40% of the pedal's input frames pinned on the positive rail, the
    # engine's count is zero while its sibling on the negative rail is not. The samples do not have
    # that blind spot, so the clip point comes from them and the counter is reported beside it.
    sample_clip, engine_clip = None, None
    clipped_levels = [s["level_dbfs_peak"] for s in segments
                      if (value(input_series(s), "clipped") or 0) > 0]
    if clipped_levels:
        engine_clip = min(clipped_levels)
    for s in sorted(segments, key=lambda s: s["level_dbfs_peak"]):
        capture = (s.get("pedal") or {}).get("capture")
        if capture and capture.get("full_scale_fraction", 0.0) > 0.01:
            sample_clip = s["level_dbfs_peak"]
            break
    input_clip = sample_clip if sample_clip is not None else engine_clip
    if input_clip is None:
        # Where the input stops following the played level, for a run whose clip counter never fired
        # (a rig that never reaches the codec's full scale).
        reference = median_of([value(input_series(s), "rms") - s["played"]["rms_dbfs"]
                               for s in steady if value(input_series(s), "rms") is not None])
        if reference is not None:
            for s in sorted(segments, key=lambda s: s["level_dbfs_peak"]):
                measured = value(input_series(s), "rms")
                if measured is None or s["shape"] == "silence":
                    continue
                if measured - s["played"]["rms_dbfs"] < reference - 1.0:
                    input_clip = s["level_dbfs_peak"]
                    break

    output_clipped = [s["level_dbfs_peak"] for s in segments
                      if (value(output_series(s), "clipped") or 0) > 0]
    silence = [s for s in segments if s["shape"] == "silence"]

    result = {
        "loopback_transfer_db": loopback_transfer,
        "loopback_floor_dbfs": median_of([s["ssl"]["loopback_analogue"]["a_weighted_dbfs"]
                                          for s in silence if s["ssl"].get("loopback_analogue")]),
        "pedal_input_offset_db": pedal_input_offset,
        "meter_offset_db": meter_offset,
        "pedal_output_offset_db": pedal_output_offset,
        "input_clip_dbfs": input_clip,
        "input_clip_dbfs_by_counting_clips": engine_clip,
        "input_clip_dbfs_from_samples": sample_clip,
        "input_floor_dbfs": median_of([s["pedal"]["capture"]["a_weighted_dbfs"] for s in silence
                                       if (s.get("pedal") or {}).get("capture")]),
        "ssl_floor_dbfs": median_of([s["ssl"]["pedal_out"]["a_weighted_dbfs"] for s in silence
                                     if s["ssl"].get("pedal_out")]),
        "output_clip_dbfs": min(output_clipped) if output_clipped else None,
    }
    # 0 dBFS at the pedal's input, in dBu: playing P dBFS puts P + 14.5 dBu at the interface's line
    # output (its published maximum, taken as full scale), and the pedal reads P + offset dBFS, so
    # its own full scale is 14.5 − offset dBu.
    if pedal_input_offset is not None:
        result["input_full_scale_dbu"] = SSL_LINE_OUT_MAX_DBU - pedal_input_offset
        result["nominal_dbfs"] = 4.0 - result["input_full_scale_dbu"]  # +4 dBu in the pedal's dBFS
    if pedal_output_offset is not None:
        result["output_full_scale_dbu"] = SSL_LINE_IN_MAX_DBU + pedal_output_offset
    return result


def build(run_dir):
    run = json.load(open(os.path.join(run_dir, "run.json")))
    windows = load_polls(os.path.join(run_dir, "polls.jsonl"))
    record_dir = find_record(run_dir)

    pedal_capture = pedal_playback = None
    pedal_rate = 48000
    if record_dir:
        # float32 and no copy: a run's pedal recording is one file of a few hundred megabytes and the
        # measures convert the slices they need, not the whole thing twice.
        pedal_capture, pedal_rate = A.read_wav(os.path.join(record_dir, "capture.wav"),
                                               dtype=np.float32)
        pedal_playback, _ = A.read_wav(os.path.join(record_dir, "playback.wav"), dtype=np.float32)

    # The pedal's recording is one file holding the whole run, so where a segment's marker is in it
    # is predicted from the wall clock -- the recording's start time, which the runner stamped, and
    # the segment's own frame 0 -- and only refined by correlation. That is exact enough to slice a
    # segment with no marker at all (silence) at the right place, and it means no step of this ever
    # searches hundreds of megabytes.
    record_started = run.get("record_started")

    segments = []
    for segment in run["segments"]:
        summary = segment.get("sslgen", {})
        first_frame_wall = summary.get("first_render_wall")
        # Without the stamp (a run recorded before `sslgen` reported it) the poll windows can only be
        # placed approximately: the fallback is the process start plus a typical device start-up, and
        # the segment says so rather than pretending to a precision it does not have.
        aligned = first_frame_wall is not None
        if not aligned:
            first_frame_wall = segment["started"] + 0.15
        rate = summary.get("rate", 48000.0)
        body = segment["body_seconds"]
        start = first_frame_wall + BODY_LEAD + GUARD_SECONDS
        end = first_frame_wall + BODY_LEAD + body - GUARD_SECONDS

        # `played` and each SSL channel carry two readings: the whole file (silence, marker, body,
        # tail) and the body slice alone. Every level comparison uses the body, because the whole
        # file's RMS is diluted by its own silence and its peak is the marker's.
        played = segment.get("played_body") or segment["played"]
        entry = {
            "name": segment["name"],
            "shape": segment["shape"],
            "group": segment["group"],
            "level_dbfs_peak": segment["level_dbfs_peak"],
            "body_seconds": body,
            "played": played,
            "played_whole": segment["played"],
            "started": segment["started"],
            "finished": segment["finished"],
            "ssl": {},
            "markers": segment.get("markers_captured"),
            "marker_played": segment.get("marker_played"),
            "marker_amplitude": segment.get("marker_amplitude"),
            "aligned": aligned,
            "latency_ms": None,
            "meter": None,
            "pedal": {},
        }

        # The SSL's own channels, in the order the run recorded them: input 1 (the pedal's output),
        # input 2 (the analogue loopback of output 3), then the digital loopbacks of outputs 3 and 4.
        channel_names = ["pedal_out", "loopback_analogue", "digital_out3", "digital_out4"]
        for index, name in enumerate(channel_names):
            bodies = segment.get("channel_bodies") or []
            measures = (bodies[index] if index < len(bodies) and bodies[index]
                        else (segment["channels"][index] if index < len(segment["channels"]) else None))
            if measures is None:
                continue
            played_rms = played["rms_dbfs"]
            played_peak = played["peak_dbfs"]
            measures = dict(measures)
            measures["transfer_rms_db"] = measures["rms_dbfs"] - played_rms
            measures["transfer_peak_db"] = measures["peak_dbfs"] - played_peak
            entry["ssl"][name] = measures
            if name == "loopback_analogue":
                # A silent segment has no marker to find, so what the correlation returns is the best
                # of the noise and the difference of two of those is not a latency. Only a segment
                # that played something gets one.
                marker = None
                if segment.get("markers_captured"):
                    marker = segment["markers_captured"][index]
                played_marker = segment.get("marker_played")
                if (marker and played_marker and segment.get("marker_amplitude", 0.0) > 0.0
                        and abs(marker - played_marker) < 0.15 * rate):
                    entry["latency_ms"] = 1000.0 * (marker - played_marker) / rate

        entry["meter"] = aggregate_levels(windows_in(windows, start, end))

        # The pedal's own samples, sliced by the same marker, so the meter's numbers can be checked
        # against the audio it was measuring rather than against the Mac's idea of it.
        if pedal_capture is not None:
            expected = None
            if record_started and aligned:
                # The marker sits 0.5 s into the played file, and the played file's frame 0 is the
                # render callback's own timestamp, so this is the marker's frame in the pedal's
                # recording to within the two clocks' drift since the recording began.
                expected = int((first_frame_wall - record_started + 0.5) * pedal_rate)
            entry["pedal"]["marker_expected"] = expected
            first = A.measure_slice(pedal_capture[:, 0], pedal_rate, body, expected=expected)
            entry["pedal"]["capture"] = first
            entry["pedal"]["capture_right"] = A.measure_slice(pedal_capture[:, 1], pedal_rate, body,
                                                            expected=expected)
            entry["pedal"]["playback"] = A.measure_slice(pedal_playback[:, 0], pedal_rate, body,
                                                       expected=expected)
            entry["pedal"]["playback_right"] = A.measure_slice(pedal_playback[:, 1], pedal_rate, body,
                                                             expected=expected)
        segments.append(entry)

    dataset = {
        "calibration": {},
        "rig": run.get("rig"),
        "rig_requested": run.get("rig_requested"),
        "device": run.get("device"),
        "in_map": run.get("in_map"),
        "out_map": run.get("out_map"),
        "record": run.get("record"),
        "run_dir": os.path.abspath(run_dir),
        "poller": run.get("poller"),
        "status_before": run.get("status_before"),
        "status_after": run.get("status_after"),
        "segments": segments,
    }
    dataset["calibration"] = calibration(dataset)
    return dataset


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: report.py <run-dir> [--no-page]")
    run_dir = sys.argv[1]
    dataset = build(run_dir)
    with open(os.path.join(run_dir, "dataset.json"), "w") as handle:
        json.dump(json_safe(dataset), handle, indent=1)
    print("wrote %s (%d segments)" % (os.path.join(run_dir, "dataset.json"),
                                      len(dataset["segments"])))
    if "--no-page" not in sys.argv:
        import page
        page.write_page(dataset, run_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
