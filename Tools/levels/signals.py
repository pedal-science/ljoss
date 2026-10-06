"""Signals for the level campaign: known digital levels, several shapes.

Everything is written as 32-bit float WAV at 48 kHz, two channels, identical on both, so the same
digital signal leaves SSL output 3 (looped back to input 2 as the reference) and output 4 (into the
pedal). Each file starts with a short alignment marker and ends with silence, so the analysis can
find the body of the signal in a capture without trusting either end's clock.

    python3 signals.py --out DIR [--seconds 5]

Stdlib and numpy only.
"""
import argparse
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analysis import write_wav  # noqa: E402  (one float-WAV writer for the whole campaign)

RATE = 48000


def dbfs_to_amplitude(dbfs):
    return 10.0 ** (dbfs / 20.0)


def sine(frequency, seconds, amplitude, rate=RATE):
    t = np.arange(int(seconds * rate)) / rate
    return amplitude * np.sin(2 * np.pi * frequency * t)


def pink_noise(seconds, amplitude, rate=RATE, seed=1):
    """Voss-McCartney-ish pink noise via spectral shaping of white noise."""
    rng = np.random.default_rng(seed)
    n = int(seconds * rate)
    white = rng.standard_normal(n)
    spectrum = np.fft.rfft(white)
    frequencies = np.fft.rfftfreq(n, 1.0 / rate)
    scale = np.ones_like(frequencies)
    scale[1:] = 1.0 / np.sqrt(frequencies[1:])
    shape = np.fft.irfft(spectrum * scale, n)
    return amplitude * shape / np.max(np.abs(shape))


def white_noise(seconds, amplitude, rate=RATE, seed=2):
    rng = np.random.default_rng(seed)
    n = int(seconds * rate)
    shape = rng.standard_normal(n)
    return amplitude * shape / np.max(np.abs(shape))


def clicks(seconds, amplitude, rate=RATE, interval=0.25):
    """Single-sample impulses: the peak-to-RMS ratio a meter has to survive."""
    n = int(seconds * rate)
    out = np.zeros(n)
    step = int(interval * rate)
    out[step // 2 :: step] = amplitude
    return out


def burst_train(seconds, amplitude, frequency=1000.0, rate=RATE, on=0.1, off=0.1):
    """Plucked-guitar-like envelope: short decaying bursts of a tone."""
    n = int(seconds * rate)
    out = np.zeros(n)
    period = int((on + off) * rate)
    length = int(on * rate)
    t = np.arange(length) / rate
    envelope = np.exp(-t * 8.0)
    shape = np.sin(2 * np.pi * frequency * t) * envelope
    for start in range(0, n - period, period):
        out[start : start + length] += amplitude * shape
    return out


def log_sweep(seconds, amplitude, rate=RATE, low=20.0, high=20000.0):
    n = int(seconds * rate)
    t = np.arange(n) / rate
    duration = n / rate
    ratio = high / low
    phase = 2 * np.pi * low * duration / math.log(ratio) * (ratio ** (t / duration) - 1)
    return amplitude * np.sin(phase)


# A real instrument, because every synthetic shape in this file is a guess about what a player's
# hands do. This is a DI recording (mono, 48 kHz, peak -0.1 dBFS, crest factor 17.6 dB) from
# NAMBench's `audio-input/`; the campaign records its hash so a run says which one it used. Point
# GUITAR_DI somewhere else for a different one.
GUITAR_DI = os.environ.get("GUITAR_DI", os.path.expanduser("~/code.local/pedal/NAMBench/audio-input/input.wav"))


def guitar(seconds, amplitude, rate=RATE, source=None):
    """An excerpt of a real guitar DI, looped if the segment is longer than the recording."""
    from analysis import read_wav

    samples, file_rate = read_wav(source or GUITAR_DI)
    samples = samples[:, 0]
    if file_rate != rate:
        raise SystemExit("%s is %d Hz; the campaign runs at %d" % (source or GUITAR_DI, file_rate, rate))
    wanted = int(seconds * rate)
    # Start a little in, so the excerpt opens on a note rather than on the recording's own fade-in.
    start = int(0.2 * rate)
    if samples.size - start >= wanted:
        return amplitude * samples[start : start + wanted]
    repeats = int(np.ceil(wanted / max(1, samples.size - start)))
    return amplitude * np.tile(samples[start:], repeats)[:wanted]


def silence(seconds, amplitude, rate=RATE):
    """Nothing at all: the segment that measures everyone's noise floor."""
    return np.zeros(int(seconds * rate))


SHAPES = {
    "silence": silence,
    "guitar": guitar,
    "sine1k": lambda s, a: sine(1000.0, s, a),
    "sine100": lambda s, a: sine(100.0, s, a),
    "sine6k3": lambda s, a: sine(6300.0, s, a),
    "pink": lambda s, a: pink_noise(s, a),
    "white": lambda s, a: white_noise(s, a),
    "burst": lambda s, a: burst_train(s, a),
    "clicks": lambda s, a: clicks(s, a),
    "sweep": lambda s, a: log_sweep(s, a),
}


def with_marker(body, rate=RATE, lead=0.5, tail=0.75, marker_amplitude=None):
    """Wrap a body in silence with a 20 ms 1 kHz tone burst at `lead` seconds.

    The marker is what lets the analysis find the same instant in the SSL's capture, the pedal's
    capture and the played file without assuming a latency.

    **The marker is as loud as the body and no louder** (`marker_amplitude=None`). A fixed-level
    marker at, say, −6 dBFS would be the loudest thing in a −50 dBFS segment: it would be the peak
    the levels are compared against, and — worse — it would make the pedal's input clip on every
    segment, so `input.clipped` could never say where this rig actually runs out of headroom. At the
    body's own level it costs nothing: a segment quiet enough that the marker cannot be found in the
    pedal's own recording is a segment whose level is at the pedal's noise floor anyway, and the
    analysis falls back to the timeline the neighbouring segments establish.
    """
    lead_samples = int(lead * rate)
    tail_samples = int(tail * rate)
    if marker_amplitude is None:
        marker_amplitude = float(np.max(np.abs(body))) if body.size else 0.0
    from analysis import marker_template

    marker = marker_amplitude * marker_template(rate)
    out = np.concatenate(
        [np.zeros(lead_samples), marker, np.zeros(int(0.2 * rate)), body, np.zeros(tail_samples)]
    )
    # 5 ms edges so nothing starts on a step: a click at the beginning would be measured as signal.
    edge = int(0.005 * rate)
    out[:edge] *= np.linspace(0, 1, edge)
    out[-edge:] *= np.linspace(1, 0, edge)
    return out


def write_stereo(path, samples, rate=RATE):
    """The same signal on both output channels: output 3 (the loopback reference) and output 4
    (into the pedal). Must be a 32-bit *float* WAV -- an integer one would reinterpret the float bit
    patterns as PCM and play something else entirely."""
    write_wav(path, np.repeat(np.asarray(samples)[:, None], 2, axis=1), rate)


def build(directory, seconds=5.0, shapes=None, levels=None):
    """Write one WAV per (shape, level) and return the list of what was written."""
    shapes = shapes or list(SHAPES)
    levels = levels or [-30.0]
    os.makedirs(directory, exist_ok=True)
    written = []
    for shape in shapes:
        for level in levels:
            name = "%s_%s" % (shape, ("%+.1f" % level).replace("+", "p").replace("-", "m").replace(".", "d"))
            path = os.path.join(directory, name + ".wav")
            body = SHAPES[shape](seconds, dbfs_to_amplitude(level))
            peak = float(np.max(np.abs(body))) or 1.0
            # Normalise to the *peak* asked for, so "level" means peak dBFS for every shape.
            body = body * (dbfs_to_amplitude(level) / peak)
            samples = with_marker(body)
            write_stereo(path, samples)
            written.append(
                {
                    "path": path,
                    "shape": shape,
                    "level_dbfs_peak": level,
                    "seconds": len(samples) / RATE,
                }
            )
    return written


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="signals")
    parser.add_argument("--seconds", type=float, default=5.0)
    parser.add_argument("--shapes", default=",".join(SHAPES))
    parser.add_argument("--levels", default="-30")
    args = parser.parse_args()
    shapes = [s for s in args.shapes.split(",") if s]
    levels = [float(v) for v in args.levels.split(",") if v]
    for item in build(args.out, args.seconds, shapes, levels):
        print("%-40s %s peak %.1f dBFS, %.2f s" % (os.path.basename(item["path"]), item["shape"],
                                                   item["level_dbfs_peak"], item["seconds"]))


if __name__ == "__main__":
    main()
