#!/usr/bin/env python3
"""campaign.py — play known signals into the pedal and record what everybody says about them.

One run is a list of segments. Each segment is one (shape, level) pair played out of the SSL's
line outputs 3 and 4 at once:

    Mac --sslgen--> out 3 --------------------> in 2   (the SSL's own ADC reading of its D/A:
                                                        the analogue reference for what was sent)
                     out 4 --> pedal in --> pedal out --> in 1   (the pedal's real output)

while, for the whole run:

  * `engine.levels` is polled at 20 Hz and every window is written to `polls.jsonl`, so the levels
    the app would show are in the record with the times they were taken;
  * `engine.record` captures the pedal's own ADC and DAC (`capture.wav`, `playback.wav`), which is
    the ground truth for what its meters were measuring.

    python3 campaign.py --rig levels --out ../../bench-results/2026-10-06-level-scales/run-levels

The pedal is left on the rig it started with, and a run that fails half way still has its JSONL.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import analysis as A  # noqa: E402
import signals as S  # noqa: E402
from ncclient import NamchainClient  # noqa: E402

MARKER_LEAD = 0.5          # where the marker sits in every played file (signals.with_marker)
BODY_LEAD = 0.72           # where the body starts after the marker's own lead


class Poller(threading.Thread):
    """Polls `engine.levels` and appends every window to a JSONL file.

    Every read takes the window (the engine's probes are read-and-reset), so the file is a
    sequence of disjoint windows in time order and the analysis can sum their energy exactly.
    """

    def __init__(self, client, path, hz=20.0):
        super().__init__(daemon=True)
        self.client = client
        self.path = path
        self.interval = 1.0 / hz
        self.stop_flag = threading.Event()
        self.windows = 0
        self.errors = 0
        self.started = None
        self.finished = None

    def run(self):
        self.started = time.time()
        with open(self.path, "w") as out:
            while not self.stop_flag.is_set():
                try:
                    levels = self.client.levels()
                    self.windows += 1
                    out.write(json.dumps({"t": time.time(), "levels": levels}) + "\n")
                except Exception as error:  # a poll that fails is data too
                    self.errors += 1
                    out.write(json.dumps({"t": time.time(), "error": str(error)}) + "\n")
                self.stop_flag.wait(self.interval)
        self.finished = time.time()

    def stop(self):
        self.stop_flag.set()
        self.join(timeout=5)


def ssh(host, command, check=True):
    return subprocess.run(["ssh", host, command], capture_output=True, text=True, check=check)


def apply_rig(client, document):
    reply = client.call({"method": "rig.apply", "document": document})
    if not reply.get("ok", False):
        raise SystemExit("rig.apply refused: %s" % json.dumps(reply.get("error", reply)))
    return reply


def current_document(client):
    for method in ("rig.get_document", "rig.get"):
        try:
            reply = client.call({"method": method})
            if reply.get("ok") and reply.get("document"):
                return reply["document"]
        except Exception:
            pass
    return None


def played_duration(play_path):
    """How long the body of a played file is: everything but its lead, marker, gap and tail."""
    samples, rate = A.read_wav(play_path)
    return max(0.0, samples.shape[0] / rate - 0.5 - 0.02 - 0.2 - 0.75)


def run_segment(play_path, out_path, device, out_map, in_map, keep):
    command = [os.path.join(HERE, "sslgen"), "--play", play_path, "--out-map", out_map,
               "--record", out_path, "--in-map", in_map, "--device", device]
    started = time.time()
    result = subprocess.run(command, capture_output=True, text=True)
    finished = time.time()
    if result.returncode != 0:
        raise SystemExit("sslgen failed: %s" % result.stderr.strip())
    summary = {}
    for line in result.stdout.strip().splitlines():
        if line.startswith("{"):
            summary = json.loads(line)
    samples, rate = A.read_wav(out_path)
    body_seconds = float(played_duration(play_path))
    measures = {"channels": [], "channel_bodies": []}
    for channel in range(samples.shape[1]):
        measures["channels"].append(A.measure(samples[:, channel], rate))
        measures["channel_bodies"].append(A.measure_slice(samples[:, channel], rate, body_seconds))
    # The marker's position in the played file and in each capture channel: the difference is the
    # latency of that path, and it is what lets the analysis slice the same body out of the pedal's
    # own recording later.
    played, played_rate = A.read_wav(play_path)
    measures["marker_played"] = A.find_marker(played[:, 0], played_rate)
    measures["played_body"] = A.measure_slice(played[:, 0], played_rate, body_seconds)
    measures["marker_amplitude"] = float(np.max(np.abs(played[:, 0]))) if played.size else 0.0
    measures["markers_captured"] = [A.find_marker(samples[:, c], rate)
                                    for c in range(samples.shape[1])]
    measures["sslgen"] = summary
    measures["started"] = started
    measures["finished"] = finished
    if not keep:
        for path in (out_path, out_path + ".playback.wav"):
            try:
                os.remove(path)
            except OSError:
                pass
    return measures


def preflight(client, device, out_map, in_map, out_dir):
    """Prove the wires work before spending ten minutes measuring them.

    This exists because the first attempt at this campaign produced a beautiful run in which the
    pedal's input was 37 dB down from the interface's output — a cable that was plugged in and not
    connected — and every graph was of a noise floor. One loud tone and two level reads turn that
    into a sentence at the start instead of a puzzle at the end.
    """
    tone = S.with_marker(S.sine(1000.0, 1.5, S.dbfs_to_amplitude(-6.0)))
    path = os.path.join(out_dir, "preflight.wav")
    S.write_stereo(path, tone)
    capture = os.path.join(out_dir, "preflight-capture.wav")
    peaks = {"input": [], "output": [], "chain": []}
    stop = threading.Event()

    def watch():
        while not stop.is_set():
            try:
                levels = client.levels()
            except Exception:
                continue
            if levels.get("input", {}).get("frames", [0])[0]:
                peaks["input"].append(max(levels["input"]["peak"]))
                peaks["output"].append(max(levels["output"]["peak"]))
                for chain in levels.get("chains", []):
                    if chain.get("out"):
                        peaks["chain"].append(chain["out"]["peak"])
            time.sleep(0.05)

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    run_segment(path, capture, device, out_map, in_map, True)
    stop.set()
    watcher.join(timeout=5)
    samples, rate = A.read_wav(capture)
    ssl_input_1 = A.rms_dbfs(samples[:, 0])
    ssl_loopback = A.rms_dbfs(samples[:, 1]) if samples.shape[1] > 1 else None
    for name in ("preflight.wav", "preflight-capture.wav", "preflight-capture.wav.playback.wav"):
        try:
            os.remove(os.path.join(out_dir, name))
        except OSError:
            pass
    result = {
        "pedal_input_peak_dbfs": max(peaks["input"]) if peaks["input"] else None,
        "pedal_output_peak_dbfs": max(peaks["output"]) if peaks["output"] else None,
        "pedal_chain_peak_dbfs": max(peaks["chain"]) if peaks["chain"] else None,
        "ssl_input_1_rms_dbfs": ssl_input_1,
        "ssl_loopback_rms_dbfs": ssl_loopback,
        "played_peak_dbfs": A.peak_dbfs(tone),
    }
    def shown(value):
        # 0.0 is a reading, not a missing one: `or -200.0` would print a clipping input as silence.
        return "-200.0 (nothing)" if value is None else "%.1f" % value
    print("preflight: played %.1f dBFS peak · pedal input %s dBFS peak · pedal output %s dBFS "
          "peak · SSL input 1 %.1f dBFS RMS"
          % (result["played_peak_dbfs"], shown(result["pedal_input_peak_dbfs"]),
             shown(result["pedal_output_peak_dbfs"]), ssl_input_1))
    if result["pedal_input_peak_dbfs"] is None or result["pedal_input_peak_dbfs"] < -35.0:
        raise SystemExit(
            "preflight failed: a -6 dBFS tone out of the SSL reaches the pedal at only %.1f dBFS.\n"
            "  The interface is playing (its own loopback reads %.1f dBFS RMS), so the break is "
            "between SSL output %s and the pedal's ADC: check the cable, the pedal's input jack, "
            "and the codec's line-in wiring."
            % (result["pedal_input_peak_dbfs"] or -200.0, ssl_loopback or -200.0, out_map.split(",")[1]))
    return result


def guitar_di_hash():
    """Which recording the `guitar` shape played: a level campaign that names a DI has to say which."""
    import hashlib
    path = S.GUITAR_DI
    if not os.path.exists(path):
        return None
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rig", default="levels", help="a Tools/TestRigs name, or a document path")
    parser.add_argument("--out", required=True)
    parser.add_argument("--device", default="SSL 2+")
    parser.add_argument("--out-map", default="3,4")
    parser.add_argument("--in-map", default="1,2,5,6")
    parser.add_argument("--shapes", default="silence,guitar,sine1k,pink,white,burst,clicks")
    parser.add_argument("--levels", default="-60,-54,-48,-42,-36,-30,-24,-18,-12,-6,0")
    parser.add_argument("--fine-shapes", default="sine1k,sine100,sine6k3,sweep")
    parser.add_argument("--fine-levels", default="-60,-51,-42,-33,-24,-15,-6,0")
    # A third group, because the two questions have different grids: the knee wants fine steps on one
    # or two shapes, and "does the shape change the answer" wants a few levels of every shape.
    parser.add_argument("--probe-shapes", default="")
    parser.add_argument("--probe-levels", default="")
    parser.add_argument("--seconds", type=float, default=4.0)
    parser.add_argument("--polls", type=float, default=20.0)
    parser.add_argument("--sleep-between", type=float, default=0.3)
    parser.add_argument("--keep-captures", action="store_true")
    parser.add_argument("--pedal-record", default="", help="name for the pedal's own recording")
    parser.add_argument("--no-restore", action="store_true")
    parser.add_argument("--host", default="vip")
    parser.add_argument("--skip-preflight", action="store_true")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    signals_dir = os.path.join(args.out, "signals")
    captures_dir = os.path.join(args.out, "captures")
    os.makedirs(signals_dir, exist_ok=True)
    os.makedirs(captures_dir, exist_ok=True)

    # ---- the matrix
    plan = []
    for shape in args.shapes.split(","):
        for level in [float(v) for v in args.levels.split(",") if v]:
            plan.append((shape, level, "coarse"))
    for shape in [s for s in args.fine_shapes.split(",") if s]:
        for level in [float(v) for v in args.fine_levels.split(",") if v]:
            plan.append((shape, level, "fine"))
    for shape in [s for s in args.probe_shapes.split(",") if s]:
        for level in [float(v) for v in args.probe_levels.split(",") if v]:
            plan.append((shape, level, "probe"))
    # Repeatability: the same segment at the start, middle and end of the run.
    plan = ([("sine1k", -24.0, "repeat")] + plan[: len(plan) // 2]
            + [("sine1k", -24.0, "repeat")] + plan[len(plan) // 2 :]
            + [("sine1k", -24.0, "repeat")])

    print("plan: %d segments, about %.1f minutes of audio"
          % (len(plan), len(plan) * (args.seconds + 1.5) / 60.0))

    client = NamchainClient(args.host)
    status_before = client.status()
    original_document = current_document(client)
    if original_document:
        with open(os.path.join(args.out, "rig-before.json"), "w") as out:
            json.dump(original_document, out, indent=1)

    # The rig: a document from this app's own encoder (so the bytes are the app's), or a file.
    rig_name = args.rig
    if os.path.exists(args.rig):
        document = json.load(open(args.rig))
    else:
        dump = subprocess.run([os.path.join(HERE, "..", "dump-engine-document.sh"), args.rig],
                              capture_output=True, text=True, check=True)
        document = json.loads(dump.stdout)
    with open(os.path.join(args.out, "document.json"), "w") as out:
        json.dump(document, out, indent=1)
    apply_rig(client, document)
    print("rig applied: %s (%d nodes)"
          % (document.get("name"), len(document["chains"][0]["nodes"])))

    preflight_result = None
    if not args.skip_preflight:
        preflight_result = preflight(client, args.device, args.out_map, args.in_map, args.out)

    record_name = args.pedal_record or ("levels-" + time.strftime("%Y%m%d-%H%M%S"))
    # The daemon's own default recording length is ten minutes, and a run is longer than that: the
    # first attempt at this campaign lost the pedal's side of its last forty segments to that
    # default, silently, because a recording that ends by length answers a later `stop` with no path
    # in it. So the length is asked for here, and the path is remembered from the start reply.
    planned_seconds = int(len(plan) * (args.seconds + 2.5) + 180)
    recording = client.call({"method": "engine.record", "action": "start", "name": record_name,
                             "seconds": planned_seconds})
    if not recording.get("ok"):
        raise SystemExit("engine.record refused: %s" % json.dumps(recording))
    # When the pedal's recording began, on the Mac's clock. Frame 0 of its capture.wav is a few
    # milliseconds after this, which is what lets every segment be sliced out of that one long file
    # without searching it: the analysis predicts where each marker must be and only refines it.
    record_started = time.time()
    record_path = recording["record"].get("path")
    print("pedal recording: %s (%d s asked for, a run of %d segments)"
          % (record_path, planned_seconds, len(plan)))

    poller = Poller(client, os.path.join(args.out, "polls.jsonl"), hz=args.polls)
    poller.start()
    time.sleep(0.5)

    segments = []
    try:
        for index, (shape, level, group) in enumerate(plan):
            name = "%s_%s_%s" % (group, shape, ("%+.1f" % level).replace("+", "p").replace("-", "m").replace(".", "d"))
            play_path = os.path.join(signals_dir, name + ".wav")
            body = S.SHAPES[shape](args.seconds, S.dbfs_to_amplitude(level))
            peak = float(np.max(np.abs(body))) or 1.0
            body = body * (S.dbfs_to_amplitude(level) / peak)  # "level" means peak dBFS
            played = S.with_marker(body)
            S.write_stereo(play_path, played)
            capture_path = os.path.join(captures_dir, name + ".wav")
            measures = run_segment(play_path, capture_path, args.device, args.out_map,
                                   args.in_map, args.keep_captures)
            measures.update({"name": name, "shape": shape, "level_dbfs_peak": level,
                             "group": group, "play_path": play_path,
                             "body_seconds": args.seconds})
            # The output level of the *device* comes from the played file, which is exact.
            played_measures = A.measure(played, S.RATE)
            measures["played"] = played_measures
            segments.append(measures)
            print("  [%3d/%3d] %-28s in %+6.1f dBFS  ->  out %7.2f dBFS peak, LUFS %7.2f"
                  % (index + 1, len(plan), name, level,
                     measures["channels"][0]["peak_dbfs"], measures["channels"][0]["lufs"]))
            time.sleep(args.sleep_between)
    finally:
        poller.stop()
        stopped = client.call({"method": "engine.record", "action": "stop"})
        status_after = client.status()
        # The pedal is somebody else's instrument: whatever happens above, it goes back on the rig
        # it was on, with no recording left running.
        if original_document and not args.no_restore:
            try:
                apply_rig(client, original_document)
                print("original rig restored")
            except Exception as error:
                print("could not restore the original rig: %s" % error)

    # ---- fetch the pedal's own recording and put the rig back
    #
    # The path comes from the start reply, not the stop one: a recording that reached its length
    # answers `stop` with the recorder's state and no name or path at all, which is exactly how the
    # first run of this campaign came back with no pedal-side audio and no complaint about it.
    stopped_record = (stopped or {}).get("record") or {}
    record_dir = stopped_record.get("path") or record_path
    local_record = None
    if record_dir:
        local_record = os.path.join(args.out, "pedal-record")
        os.makedirs(local_record, exist_ok=True)
        fetched = subprocess.run(
            ["scp", "-q", "%s:%s/capture.wav" % (args.host, record_dir),
             "%s:%s/playback.wav" % (args.host, record_dir),
             "%s:%s/meta.json" % (args.host, record_dir), local_record + "/"],
            capture_output=True, text=True)
        if fetched.returncode != 0 or not os.path.exists(os.path.join(local_record, "capture.wav")):
            print("COULD NOT FETCH the pedal's recording from %s: %s"
                  % (record_dir, (fetched.stderr or "").strip()))
        else:
            seconds = stopped_record.get("seconds")
            # What matters is not whether the recording used all the length it asked for -- a run
            # that finishes early should record less -- but whether it still covered the last
            # segment. That is the check that would have caught the first attempt's silent loss.
            covered = (seconds or 0.0) >= (segments[-1]["finished"] - record_started - 5.0)
            print("pedal recording fetched to %s (%.0f s, %s)"
                  % (local_record, seconds or 0.0,
                     "covers the run" if covered
                     else "** DOES NOT COVER THE RUN: the last segments have no pedal-side audio **"))


    run = {
        "rig": document.get("name"),
        "rig_requested": rig_name,
        "record": stopped.get("record"),
        "record_name": record_name,
        "record_started": record_started,
        "record_finished": time.time(),
        "pedal_record_dir": local_record,
        "segments": segments,
        "poller": {"windows": poller.windows, "errors": poller.errors,
                   "started": poller.started, "finished": poller.finished},
        "status_before": status_before,
        "status_after": status_after,
        "preflight": preflight_result,
        "guitar_di": {"path": S.GUITAR_DI, "sha256": guitar_di_hash()},
        "seconds": args.seconds,
        "in_map": args.in_map,
        "out_map": args.out_map,
        "device": args.device,
        "started": segments[0]["started"] if segments else None,
        "finished": segments[-1]["finished"] if segments else None,
    }
    with open(os.path.join(args.out, "run.json"), "w") as out:
        json.dump(run, out, indent=1)
    print("wrote %s (%d segments, %d poll windows)"
          % (os.path.join(args.out, "run.json"), len(segments), poller.windows))
    client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
