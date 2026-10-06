"""synthetic.py — a fake run directory whose answers are known, to test the analysis chain.

    python3 synthetic.py <dir>

A real campaign is twenty minutes of somebody's instrument, and the analysis that follows it is the
first time most of `report.py` runs on real shapes. This builds a run directory with the same layout
the campaign writes — `run.json`, `polls.jsonl`, `captures/`, `pedal-record/`, `document.json` — from
a *model* with known constants:

    the interface's analogue loopback         −10.5 dB
    the pedal's input against the played level −12.0 dB
    the pedal's input clipping                 when its ADC would pass −20 dBFS
    the pedal's output at the interface        −14.0 dB
    the rig                                    the `levels` rig: 0 dB, −12 dB, +12 dB
    the meters' error                          +0.05 dB and a 12 dB crest allowance

so `tests.py` can check that the report recovers those figures from the files rather than being told
them. Nothing here is a measurement: it exists so that a broken alignment or a wrong aggregation is
found here instead of in a run.
"""
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import analysis as A  # noqa: E402
import signals as S  # noqa: E402

RATE = 48000
LOOPBACK_TRANSFER_DB = -10.5
# The pedal model is the one this campaign measured: its ADC reads 11.78 dB above the digital level
# played, and it clips when its own converter reaches full scale -- which puts the pedal's clip point
# at a *played* level of about -11.8 dBFS, not at 0. That is the whole finding, so the rehearsal has
# to have it too, or the test would pass on a model that cannot fail.
PEDAL_INPUT_OFFSET_DB = 11.78
PEDAL_INPUT_CLIP_DBFS = 0.0
PEDAL_OUTPUT_OFFSET_DB = -14.0
METER_RMS_ERROR_DB = 0.05
BODY_SECONDS = 4.0


def _levels_rig_nodes():
    """The node list of the `levels` rig, as a document and as the engine would report it."""
    elements = ["E1", "E2", "E3"]
    gains = [0.0, -12.0, 12.0]
    document = {
        "name": "Levels (synthetic)",
        "chains": [{
            "id": "chain-1", "name": "Guitar", "input_channel": 0, "output_channel": 0,
            "nodes": [{"id": "in", "type": "nc.input", "element": "IN"}] +
                     [{"id": element + "-gain", "type": "nc.gain", "element": element,
                       "gain_db": gain} for element, gain in zip(elements, gains)] +
                     [{"id": "out", "type": "nc.output", "element": "OUT"}],
            "connections": [],
        }],
    }
    return document, elements, gains


def build(directory, shapes=("sine1k", "pink"), levels=(-30.0, -20.0, -10.0, 0.0), seed=5):
    os.makedirs(directory, exist_ok=True)
    os.makedirs(os.path.join(directory, "captures"), exist_ok=True)
    os.makedirs(os.path.join(directory, "signals"), exist_ok=True)
    os.makedirs(os.path.join(directory, "pedal-record"), exist_ok=True)
    document, elements, gains = _levels_rig_nodes()
    with open(os.path.join(directory, "document.json"), "w") as handle:
        json.dump(document, handle)

    rng = np.random.default_rng(seed)
    rng8 = np.random.default_rng(seed + 1)
    plan = [("coarse", shape, level) for shape in shapes for level in levels]
    plan.insert(0, ("coarse", "silence", -30.0))

    pedal_capture_parts = []
    pedal_playback_parts = []
    ssl_captures = []
    polls = []
    segments = []
    clock = 1000.0
    record_started = 999.5
    noise_rms = 10 ** (-96.0 / 20.0)

    node_state = {element: {"energy": 0.0, "frames": 0, "peak": -200.0} for element in elements}
    output_state = {"energy": 0.0, "frames": 0, "peak": -200.0, "clipped": 0}

    def pedal_meter(level_dbfs, frames):
        """What the engine would report for one poll window of a signal at `level_dbfs`."""
        window = []
        for element, gain in zip(elements, gains):
            value = level_dbfs + gain
            window.append({"element": element, "role": "", "node": element + "-gain",
                           "peak": value + 12.0 if value > -200 else -200.0,
                           "rms": value, "frames": frames})
        return window

    for index, (group, shape, level) in enumerate(plan):
        name = "%s_%s_%s" % (group, shape, "%+.1f" % level)
        body = S.SHAPES[shape](BODY_SECONDS, S.dbfs_to_amplitude(level))
        peak = float(np.max(np.abs(body))) or 1.0
        body = body * (S.dbfs_to_amplitude(level) / peak)
        played = S.with_marker(body)
        played_rms = A.rms_dbfs(played)
        played_peak = A.peak_dbfs(played)
        S.write_wav(os.path.join(directory, "signals", name + ".wav"), played[:, None])

        # The pedal's converters, as the model says they would be: the input scaled, clipped at the
        # model's own full scale, the output the rig's (unity) rendering of it.
        pedal_in = played * (10 ** (PEDAL_INPUT_OFFSET_DB / 20.0))
        clip = 10 ** (PEDAL_INPUT_CLIP_DBFS / 20.0)
        clipped_frames = int(np.sum(np.abs(pedal_in) > clip))
        pedal_in = np.clip(pedal_in, -clip, clip)
        pedal_out = pedal_in.copy()
        # The pedal records continuously, so the gaps between segments are in its file too: a
        # synthetic run that glued the bodies together would not exercise the alignment at all.
        gap = np.zeros(int(1.25 * RATE)) if index else np.zeros(0)
        pedal_capture_parts.append(gap)
        pedal_playback_parts.append(gap)
        pedal_capture_parts.append(pedal_in + rng8.standard_normal(pedal_in.size) * noise_rms)
        pedal_playback_parts.append(pedal_out + rng8.standard_normal(pedal_out.size) * noise_rms)

        # The interface's four recorded channels, frame-aligned with the played file plus the
        # interface's own round trip (26 ms here, which is what a real run shows).
        latency = 1250
        def delay(signal, gain_db):
            out = np.concatenate([np.zeros(latency), signal * (10 ** (gain_db / 20.0))])
            return out + rng.standard_normal(out.size) * noise_rms
        channels = np.stack([
            delay(pedal_out, PEDAL_OUTPUT_OFFSET_DB),   # input 1: the pedal's output
            delay(played, LOOPBACK_TRANSFER_DB),        # input 2: the analogue loopback
            np.concatenate([np.zeros(latency), played]),  # input 5: digital tap of out 3
            np.concatenate([np.zeros(latency), played]),  # input 6: digital tap of out 4
        ], axis=1)
        capture_path = os.path.join(directory, "captures", name + ".wav")
        A.write_wav(capture_path, channels, RATE)
        ssl_captures.append((capture_path, channels))

        # Poll windows over the body: the meter reads the level it was given, with its own error.
        # The generator knows exactly where the body is, which is the one thing the analysis has to
        # find for itself; the silence segment has no marker to find, so it is the case that matters.
        body_start = int(0.72 * RATE)
        reported = A.rms_dbfs(played[body_start:body_start + int(BODY_SECONDS * RATE)])
        body_start = clock + 0.72
        windows = 0
        for tick in range(28):  # ~1.4 s of the body at 20 Hz
            t = body_start + 0.3 + tick * 0.05
            frames = 2400
            input_peak = played_peak + METER_RMS_ERROR_DB
            input_rms = reported + METER_RMS_ERROR_DB
            chain_nodes = []
            for element in elements:
                node = node_state[element]
                gain = dict(zip(elements, gains))[element]
                node["energy"] += (10 ** ((input_rms + gain) / 10.0)) * frames
                node["frames"] += frames
                node["peak"] = max(node["peak"], input_peak + gain)
                chain_nodes.append({"element": element, "role": "", "node": element + "-gain",
                                    "peak": input_peak + gain, "rms": input_rms + gain,
                                    "frames": frames})
            output_state["energy"] += (10 ** (input_rms / 10.0)) * frames
            output_state["frames"] += frames
            output_state["peak"] = max(output_state["peak"], input_peak)
            output_state["clipped"] += clipped_frames
            polls.append({"t": t, "levels": {
                "blocks": 1, "state": "running",
                "input": {"peak": [input_peak] * 2, "rms": [input_rms] * 2,
                          "clipped": [clipped_frames] * 2, "frames": [frames] * 2},
                "output": {"peak": [input_peak] * 2, "rms": [input_rms, -200.0],
                           "clipped": [0, 0], "frames": [frames] * 2},
                "chains": [{"id": "chain-1", "name": "Guitar", "muted": False,
                            "out": {"peak": input_peak, "rms": input_rms, "frames": frames,
                                    "clipped": 0},
                            "nodes": chain_nodes}]}})
            windows += 1

        segments.append({
            "name": name, "shape": shape, "level_dbfs_peak": level, "group": group,
            "body_seconds": BODY_SECONDS, "play_path": "signals/" + name + ".wav",
            "played": A.measure(played, RATE),
            "played_body": A.measure_slice(played, RATE, BODY_SECONDS),
            "marker_amplitude": float(np.max(np.abs(played))),
            "markers_captured": [latency + 24000] * 4,
            "marker_played": 24000,
            "sslgen": {"rate": RATE, "first_render_wall": clock, "captured_frames": played.size},
            "started": clock, "finished": clock + played.size / RATE + 0.5,
            "channels": [A.measure(channels[:, c], RATE) for c in range(4)],
            "channel_bodies": [A.measure_slice(channels[:, c], RATE, BODY_SECONDS) for c in range(4)],
        })
        clock += played.size / RATE + 1.25

    capture_stream = np.concatenate(pedal_capture_parts)
    playback_stream = np.concatenate(pedal_playback_parts)
    A.write_wav(os.path.join(directory, "pedal-record", "capture.wav"),
                np.stack([capture_stream] * 2, axis=1), RATE)
    A.write_wav(os.path.join(directory, "pedal-record", "playback.wav"),
                np.stack([playback_stream] * 2, axis=1), RATE)
    with open(os.path.join(directory, "pedal-record", "meta.json"), "w") as handle:
        json.dump({"sample_rate": RATE, "capture_channels": 2, "format": "S32_LE"}, handle)
    with open(os.path.join(directory, "polls.jsonl"), "w") as handle:
        for row in polls:
            handle.write(json.dumps(row) + "\n")
    with open(os.path.join(directory, "run.json"), "w") as handle:
        json.dump({
            "rig": document["name"], "rig_requested": "levels", "device": "SSL 2+ Mk II",
            "in_map": "1,2,5,6", "out_map": "3,4",
            "record": {"name": "synthetic", "periods": 1000, "overflows": 0, "xruns": 0},
            "record_started": record_started, "record_finished": clock + 10.0,
            "segments": segments,
            "poller": {"windows": len(polls), "errors": 0},
            "status_before": {"state": "running", "format": "S32_LE"},
            "status_after": {"state": "running", "format": "S32_LE"},
            "started": segments[0]["started"], "finished": segments[-1]["finished"],
        }, handle, indent=1)
    return directory


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "/tmp/synthetic-run"
    build(target)
    print("wrote a synthetic run to %s" % target)
