"""tests.py — checks for the parts of the campaign that are easy to get subtly wrong.

    python3 tests.py

Three things here have a right answer that does not need a pedal: the measures (checked against
figures that are true by definition, in `analysis.selftest`), the alignment that finds a segment's
body inside a capture taken on another clock, and the energy-weighted aggregation of the engine's
read-and-reset poll windows. A run is ten minutes of somebody's instrument; these run in a second.
"""
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import analysis as A  # noqa: E402
import report  # noqa: E402
import signals as S  # noqa: E402

failures = []


def check(name, got, want, tolerance):
    ok = got is not None and abs(got - want) <= tolerance
    print("  %-52s %9.3f  (want %8.3f ± %.2f) %s" % (name, got if got is not None else float("nan"),
                                                      want, tolerance, "ok" if ok else "FAIL"))
    if not ok:
        failures.append(name)


def test_measures():
    print("measures (analysis.selftest)")
    failures.extend(["analysis.selftest"] if A.selftest() else [])


def test_alignment():
    """A capture is a delayed copy of the played file: the body found in it must be the body.

    The delay stands in for the interface's and the pedal's latency, which is what the marker exists
    to measure rather than assume; a few thousand frames is the range a real run shows.
    """
    print("alignment (a delayed capture, sliced by its marker)")
    rate = 48000
    body = S.with_marker(S.sine(1000.0, 2.0, 10 ** (-20 / 20.0)), rate)
    for delay in (0, 1250, 4999):
        capture = np.concatenate([np.random.default_rng(3).standard_normal(delay) * 1e-6, body])
        window = A.slice_at_marker(capture, rate, body_seconds=2.0)
        if window is None:
            check("marker found at delay %d" % delay, None, delay, 0)
            continue
        start, end = window
        sliced = capture[start:end]
        # The sliced body should be the played body's own level, and its own length.
        check("body level from a capture delayed %4d frames" % delay,
              A.rms_dbfs(sliced), A.rms_dbfs(S.sine(1000.0, 2.0, 10 ** (-20 / 20.0))), 0.35)
        check("body length from a capture delayed %4d frames" % delay,
              float(end - start), 2.0 * rate - 2 * 0.30 * rate, rate * 0.02)


def test_aggregation():
    """The engine's windows are disjoint; their energy mean must be the RMS of the union.

    A window's RMS is the root of its mean square, so a set of windows of unequal length adds up in
    energy and not in decibels. This constructs windows whose union has a known RMS and checks the
    aggregation finds it.
    """
    print("aggregation (energy mean over read-and-reset windows)")
    rng = np.random.default_rng(11)
    windows = []
    expected = 0.0
    total = 0
    for amplitude, frames in ((0.1, 2400), (0.05, 960), (0.2, 5000)):
        windows.append({"rms": A.rms_dbfs(A.centred(rng.standard_normal(frames) * amplitude)),
                        "frames": frames})
        expected += amplitude ** 2 * frames
        total += frames
    check("energy mean of three windows", report.energy_mean_rms(windows),
          10 * math.log10(expected / total), 0.2)
    # Windows with no frames are not levels and must not drag the mean anywhere.
    with_empty = windows + [{"rms": -200.0, "frames": 0}, {"rms": None, "frames": 0}]
    check("an empty window changes nothing", report.energy_mean_rms(with_empty),
          report.energy_mean_rms(windows), 1e-9)


def test_json_safe():
    print("json safety (a silent segment's -inf)")
    safe = report.json_safe({"a": float("-inf"), "b": [1.0, float("nan")], "c": {"d": 2.0}})
    ok = safe["a"] is None and safe["b"][0] == 1.0 and safe["b"][1] is None and safe["c"]["d"] == 2.0
    print("  %-52s %s" % ("-inf and NaN become null, numbers survive", "ok" if ok else "FAIL"))
    if not ok:
        failures.append("json_safe")


def test_synthetic_run():
    """The whole chain, on a run whose answers are known.

    This is the test that matters most: `synthetic.py` builds a run directory from a model (the
    interface's loopback at −10.5 dB, the pedal's input at −12 dB, its output at −14 dB, a meter with
    a +0.05 dB error), and `report.build` has to recover those figures from the files alone. Every
    bug this file has had -- the marker that dominated the peak, the anchor that latched onto a
    silent segment, decibels averaged as if they were numbers -- was found here rather than in a
    twenty-minute run on somebody's pedal.
    """
    import shutil
    import tempfile
    import synthetic
    print("the whole chain (a synthetic run with known answers)")
    directory = tempfile.mkdtemp(prefix="level-scales-synthetic-")
    try:
        synthetic.build(directory, shapes=("sine1k", "pink"),
                        levels=(-48.0, -36.0, -24.0, -12.0, 0.0))
        dataset = report.build(directory)
        got = dataset["calibration"]
        check("loopback transfer recovered", got["loopback_transfer_db"],
              synthetic.LOOPBACK_TRANSFER_DB, 0.3)
        check("pedal input offset recovered", got["pedal_input_offset_db"],
              synthetic.PEDAL_INPUT_OFFSET_DB, 0.6)
        check("pedal output offset recovered", got["pedal_output_offset_db"],
              synthetic.PEDAL_OUTPUT_OFFSET_DB, 0.6)
        check("meter error recovered", got["meter_offset_db"], synthetic.METER_RMS_ERROR_DB, 0.1)
        # The clip point is resolved to the sweep's own grid: the answer is the lowest level played
        # that clipped, so it can be no more than one step from where the model really clips --
        # which is a *played* level of -offset dBFS, since the model's converter is what runs out.
        check("clip point found (within one grid step)",
              got["input_clip_dbfs"], -synthetic.PEDAL_INPUT_OFFSET_DB, 12.0)
        # A segment's own numbers, against the model's.
        segment = [s for s in dataset["segments"]
                   if s["shape"] == "sine1k" and s["level_dbfs_peak"] == -24.0][0]
        check("a segment's pedal capture matches the model",
              segment["pedal"]["capture"]["rms_dbfs"],
              segment["played"]["rms_dbfs"] + synthetic.PEDAL_INPUT_OFFSET_DB, 0.6)
        check("a segment's meter reading matches the model",
              segment["meter"]["input"][0]["rms"],
              segment["played"]["rms_dbfs"] + synthetic.METER_RMS_ERROR_DB, 0.3)
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def main():
    test_measures()
    test_alignment()
    test_aggregation()
    test_json_safe()
    test_synthetic_run()
    print("%d check(s) failed" % len(failures) if failures else "all checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
