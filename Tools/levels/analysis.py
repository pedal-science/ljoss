"""Level, loudness and alignment measures for the campaign.

Every measure the campaign reports is computed here, once, so the graphs and the report cannot
disagree about what a number means. Three families:

  * **Digital levels** — peak, true peak (4x oversampled, BS.1770 style), RMS, crest factor, all in
    dBFS. These are what namchain reports and what a sample stream contains.
  * **Perceptual loudness** — A-weighted RMS (IEC 61672, applied to the spectrum, the same weighting
    pedal.project's `scripts/codec-noise.py` uses so the numbers agree across repos) and ITU-R
    BS.1770-4 loudness (K-weighting, gated integrated LUFS, and 400 ms momentary / 3 s short-term
    maxima). A-weighted RMS answers "how loud does this look to a listener at low level"; LUFS
    answers "how loud does this sound", which is what a player means by a level.
  * **Alignment** — the marker in every test signal, found by matched filter, so a Mac capture and a
    pedal capture can be compared at the same instant without assuming a latency.

Runs on numpy alone.
"""
import math
import struct

import numpy as np

# ---------------------------------------------------------------- reading

def read_wav(path, dtype=np.float64):
    """Return (samples as [frames, channels], rate).

    A RIFF reader of our own rather than the `wave` module, which refuses IEEE float (format 3) --
    and float is what this campaign writes, because a 32-bit integer WAV would quantise the very
    noise floors the campaign is comparing. PCM 16/24/32 and float 32/64 are read;
    WAVE_FORMAT_EXTENSIBLE is unwrapped to its sub-format.
    """
    raw = open(path, "rb").read()
    if raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise SystemExit("%s is not a RIFF/WAVE file" % path)
    position = 12
    fmt = None
    data = None
    while position + 8 <= len(raw):
        chunk_id = raw[position : position + 4]
        size = struct.unpack_from("<I", raw, position + 4)[0]
        body = raw[position + 8 : position + 8 + size]
        if chunk_id == b"fmt ":
            fmt = body
        elif chunk_id == b"data":
            data = body
        position += 8 + size + (size & 1)
    if fmt is None or data is None:
        raise SystemExit("%s has no fmt or data chunk" % path)
    tag, channels, rate = struct.unpack_from("<HHI", fmt, 0)
    bits = struct.unpack_from("<H", fmt, 14)[0]
    if tag == 0xFFFE and len(fmt) >= 26:  # WAVE_FORMAT_EXTENSIBLE
        tag = struct.unpack_from("<H", fmt, 24)[0]
    if tag == 3:
        if bits == 32:
            # A float32 file read as float32 is a view over the bytes, not a copy: the pedal's
            # recording of a whole run is hundreds of megabytes and there is no reason to double it.
            samples = np.frombuffer(data, dtype="<f4")
            if dtype == np.float64:
                samples = samples.astype(np.float64)
        elif bits == 64:
            samples = np.frombuffer(data, dtype="<f8").astype(dtype)
        else:
            raise SystemExit("%s: %d-bit float is not supported" % (path, bits))
    elif tag == 1:
        if bits == 16:
            samples = np.frombuffer(data, dtype="<i2").astype(np.float64) / (1 << 15)
        elif bits == 24:
            raw8 = np.frombuffer(data, dtype=np.uint8).reshape(-1, 3)
            values = (raw8[:, 0].astype(np.int32)
                      | (raw8[:, 1].astype(np.int32) << 8)
                      | (raw8[:, 2].astype(np.int32) << 16))
            values = (values ^ 0x800000) - 0x800000
            samples = values.astype(np.float64) / (1 << 23)
        elif bits == 32:
            samples = np.frombuffer(data, dtype="<i4").astype(np.float64) / (1 << 31)
        else:
            raise SystemExit("%s: %d-bit PCM is not supported" % (path, bits))
    else:
        raise SystemExit("%s: WAV format tag %d is not supported" % (path, tag))
    return samples.reshape(-1, channels), rate


def write_wav(path, samples, rate=48000):
    """Write 32-bit float WAV: no quantisation of the numbers under test."""
    samples = np.asarray(samples, dtype=np.float64)
    if samples.ndim == 1:
        samples = samples[:, None]
    channels = samples.shape[1]
    body = samples.astype("<f4").tobytes()
    fmt = struct.pack("<HHIIHH", 3, channels, rate, rate * channels * 4, channels * 4, 32)
    chunks = b"fmt " + struct.pack("<I", len(fmt)) + fmt
    chunks += b"data" + struct.pack("<I", len(body)) + body
    with open(path, "wb") as handle:
        handle.write(b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks)


def dc_offset(x):
    return float(np.mean(x)) if x.size else 0.0


def centred(x):
    return x - dc_offset(x)


# ---------------------------------------------------------------- digital levels

def amplitude_dbfs(amplitude):
    return 20.0 * math.log10(amplitude) if amplitude > 0 else float("-inf")


def peak_dbfs(x):
    return amplitude_dbfs(float(np.max(np.abs(x))) if x.size else 0.0)


def rms_dbfs(x):
    if not x.size:
        return float("-inf")
    mean_square = float(np.mean(np.square(x)))
    return 10.0 * math.log10(mean_square) if mean_square > 0 else float("-inf")


def true_peak_dbfs(x, oversample=4):
    """Peak of the 4x oversampled signal: what a converter's reconstruction filter will hand on."""
    if not x.size:
        return float("-inf")
    n = x.size
    spectrum = np.fft.rfft(x)
    padded = np.zeros(n * oversample // 2 + 1, dtype=complex)
    padded[: spectrum.size] = spectrum
    upsampled = np.fft.irfft(padded, n * oversample) * oversample
    return peak_dbfs(upsampled)


# "At full scale" has to allow for a converter that is not: a 24-bit ADC left-justified in a 32-bit
# slot puts its positive rail at 0x7FFFFF00, which is 0.99999994 in float -- below `1.0f`, and so
# below any clip test that compares against full scale. This threshold is that rail.
FULL_SCALE_THRESHOLD = 0.999


def full_scale_counts(x):
    """How many samples sit on each rail, which is where a converter's overload shows."""
    if not x.size:
        return 0, 0
    return int(np.sum(x >= FULL_SCALE_THRESHOLD)), int(np.sum(x <= -FULL_SCALE_THRESHOLD))


def crest_factor_db(x):
    return peak_dbfs(x) - rms_dbfs(x)


# ---------------------------------------------------------------- weighting

def a_weight_gain(frequency):
    """IEC 61672 A-weighting as a linear gain (0 dB at 1 kHz by construction)."""
    f2 = np.asarray(frequency, dtype=np.float64) ** 2
    with np.errstate(divide="ignore", invalid="ignore"):
        numerator = (12194.0 ** 2) * (f2 ** 2)
        denominator = ((f2 + 20.6 ** 2)
                       * np.sqrt((f2 + 107.7 ** 2) * (f2 + 737.9 ** 2))
                       * (f2 + 12194.0 ** 2))
        gain = (numerator / denominator) * (10 ** (2.0 / 20))
    return np.where(np.asarray(frequency) > 0, gain, 0.0)


def _spectrum(x, rate, window=1 << 16, max_segments=16):
    """Welch power spectrum, one-sided, in mean-square per bin (so the sum is the mean square).

    This is the shape `codec-noise.py` uses, so an A-weighted number from either script means the
    same thing; a single periodogram of a 5 s window would be spikier and integrate the same.
    """
    n = x.size
    window = int(min(window, 1 << int(math.log2(max(n, 2)))))
    if window < 256:
        window = int(1 << int(math.log2(max(n, 2))))
    step = window // 2
    hann = np.hanning(window)
    # Parseval with a window: sum(y^2) = (1/N) sum(|Y|^2), and the signal's mean square is
    # sum(y^2)/sum(w^2). Dividing by both is what makes the sum of the returned bins the mean square,
    # which is what the weighting then acts on.
    normalisation = float(np.sum(hann ** 2)) * window
    segments = 0
    accumulator = None
    for start in range(0, max(n - window, 0) + 1, step):
        piece = x[start : start + window]
        if piece.size < window:
            break
        spectrum = np.fft.rfft(piece * hann)
        power = (np.abs(spectrum) ** 2) / normalisation
        power[1:-1] *= 2.0  # one-sided
        accumulator = power if accumulator is None else accumulator + power
        segments += 1
        if segments >= max_segments:
            break
    if accumulator is None:  # shorter than one window
        piece = np.zeros(window)
        piece[: n] = x
        spectrum = np.fft.rfft(piece * hann)
        power = (np.abs(spectrum) ** 2) / normalisation
        power[1:-1] *= 2.0
        accumulator = power
        segments = 1
    power = accumulator / segments
    bin_hz = rate / window
    frequencies = np.arange(power.size) * bin_hz
    return frequencies, power


def band_limited(x, rate, low=20.0, high=20000.0):
    frequencies, power = _spectrum(x, rate)
    keep = (frequencies >= low) & (frequencies <= high)
    total = float(np.sum(power[keep]))
    return math.sqrt(total) if total > 0 else 0.0


def a_weighted_rms_dbfs(x, rate, band=(20.0, 20000.0)):
    """A-weighted RMS in dBFS: the same power, heard the way the ear hears it."""
    frequencies, power = _spectrum(x, rate)
    keep = (frequencies >= band[0]) & (frequencies <= band[1])
    weight = a_weight_gain(frequencies[keep]) ** 2
    total = float(np.sum(power[keep] * weight))
    return 10.0 * math.log10(total) if total > 0 else float("-inf")


# ---------------------------------------------------------------- BS.1770 loudness

# K-weighting for 48 kHz, from ITU-R BS.1770-4 Table 1 (the filter coefficients every implementation
# uses, so the numbers are comparable with a meter the player might already own).
_K_STAGE1_B = np.array([1.53512485958697, -2.69169618940638, 1.19839281085285])
_K_STAGE1_A = np.array([1.0, -1.69065929318241, 0.73248077421585])
_K_STAGE2_B = np.array([1.0, -2.0, 1.0])
_K_STAGE2_A = np.array([1.0, -1.99004745483398, 0.99007225036621])


def _biquad_time_domain(x, b, a):
    """The biquad as a sample-by-sample recursion: the definition, and the selftest's reference."""
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(x.size):
        value = b[0] * x[i] + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
        x2, x1 = x1, x[i]
        y2, y1 = y1, value
        y[i] = value
    return y


_K_SECTIONS = ((_K_STAGE1_B, _K_STAGE1_A), (_K_STAGE2_B, _K_STAGE2_A))


def _filter_frequency_domain(x, sections, pad=None):
    """The same IIR, applied in the frequency domain with zero padding at both ends.

    A biquad in a Python loop is a second per four seconds of audio; a run is a few hundred seconds
    of audio and the same filter is wanted for every segment of it. The filter's response is exact
    at every frequency, so multiplying the padded spectrum by H(e^{jw}) is the same filter, and the
    padding is what keeps the circular convolution from wrapping a transient round to the start.
    """
    n = x.size
    if n == 0:
        return x
    pad = pad if pad is not None else min(max(n, 4096), 1 << 16)
    m = 1 << int(math.ceil(math.log2(n + 2 * pad)))
    padded = np.zeros(m)
    padded[pad : pad + n] = x
    spectrum = np.fft.rfft(padded)
    z = np.exp(-2j * np.pi * np.arange(spectrum.size) / m)
    response = np.ones(spectrum.size, dtype=complex)
    for b, a in sections:
        response *= (b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)
    return np.fft.irfft(spectrum * response, m)[pad : pad + n]


def k_weight(x, rate=48000):
    """The K-weighting of BS.1770-4: a high shelf, then the RLB high-pass."""
    if rate != 48000:
        raise SystemExit("K-weighting coefficients here are the 48 kHz ones")
    return _filter_frequency_domain(np.asarray(x, dtype=np.float64), _K_SECTIONS)


def _block_loudness(weighted, rate, block_seconds, hop_seconds):
    """Mean-square per gated block, as (start frame, mean square) pairs."""
    block = int(block_seconds * rate)
    hop = int(hop_seconds * rate)
    if weighted.size < block:
        return []
    squares = np.square(weighted)
    cumulative = np.concatenate([[0.0], np.cumsum(squares)])
    starts = range(0, weighted.size - block + 1, hop)
    return [(start, (cumulative[start + block] - cumulative[start]) / block) for start in starts]


def _loudness_of(mean_square):
    return -0.691 + 10.0 * math.log10(mean_square) if mean_square > 0 else float("-inf")


def lufs_integrated(x, rate=48000, channels=1):
    """Gated integrated loudness, BS.1770-4. `channels` is how many channels the measured signal
    stands for (the pedal is mono, so 1; a stereo capture passes 2)."""
    weighted = k_weight(x, rate)
    blocks = _block_loudness(weighted, rate, 0.4, 0.1)
    if not blocks:
        return float("-inf")
    absolute_gate = [b for b in blocks if _loudness_of(b[1]) > -70.0]
    if not absolute_gate:
        return float("-inf")
    mean_of_gated = float(np.mean([b[1] for b in absolute_gate]))
    relative_gate = _loudness_of(mean_of_gated) - 10.0
    gated = [b[1] for b in absolute_gate if _loudness_of(b[1]) > relative_gate]
    if not gated:
        return float("-inf")
    return _loudness_of(float(np.mean(gated))) + (0.0 if channels == 1 else 0.0)


def lufs_momentary_series(x, rate=48000):
    """(times, loudness) at 400 ms blocks every 100 ms, ungated: what a loudness meter's needle does."""
    weighted = k_weight(x, rate)
    blocks = _block_loudness(weighted, rate, 0.4, 0.1)
    times = np.array([start / rate for start, _ in blocks])
    values = np.array([_loudness_of(mean) for _, mean in blocks])
    return times, values


def lufs_short_term_max(x, rate=48000, block_seconds=3.0):
    weighted = k_weight(x, rate)
    blocks = _block_loudness(weighted, rate, block_seconds, 0.1)
    if not blocks:
        return float("-inf")
    return max(_loudness_of(mean) for _, mean in blocks)


# ---------------------------------------------------------------- alignment

# The alignment marker: a short linear chirp, not a tone. A 1 kHz tone is *in* two of the test
# shapes and at the same level as them, so correlating for it finds the body as readily as the
# marker -- during the campaign it landed 1.4 s late on two segments. A chirp is in nothing else,
# and correlates sharply even against the log sweep, because a sweep only matches a chirp over the
# moment their frequencies cross.
MARKER_SECONDS = 0.02
MARKER_LOW_HZ = 2000.0
MARKER_HIGH_HZ = 8000.0


def marker_template(rate, seconds=MARKER_SECONDS, low=MARKER_LOW_HZ, high=MARKER_HIGH_HZ):
    """The marker's own waveform, so the tool that writes it and the tool that finds it agree."""
    n = max(2, int(seconds * rate))
    t = np.arange(n) / rate
    duration = n / rate
    ratio = high / low
    phase = 2 * np.pi * low * duration / math.log(ratio) * (ratio ** (t / duration) - 1)
    waveform = np.sin(phase) * np.hanning(n)
    return waveform - np.mean(waveform)


def find_marker_near(x, rate, expected_frame, marker_seconds=MARKER_SECONDS,
                     search_seconds=0.25, min_ratio=6.0):
    """The marker, searched for only where the timeline says it should be.

    A run's pedal recording is one file holding every segment, so searching the whole of it for every
    marker would be minutes of correlation for an answer that the wall clock already bounds to a few
    milliseconds of clock drift.

    Returns None when the correlation is not clearly a marker. That matters for a segment with no
    body -- silence has no marker by construction -- where the best of the noise is still the best of
    the noise, and a caller that took it would slice a window that has nothing to do with the
    segment. The caller falls back to the predicted frame instead.
    """
    n = int(marker_seconds * rate)
    half = int(search_seconds * rate)
    start = max(0, int(expected_frame) - half)
    end = min(x.size, int(expected_frame) + half + n)
    if end - start < n + 2:
        frame = find_marker(x, rate, marker_seconds=marker_seconds, search_seconds=search_seconds)
        return frame if frame > 0 else None
    template = marker_template(rate, marker_seconds)
    segment = np.asarray(x[start:end], dtype=np.float64)
    segment = segment - np.mean(segment)
    correlation = np.abs(np.correlate(segment, template, mode="valid"))
    peak = float(np.max(correlation)) if correlation.size else 0.0
    typical = float(np.median(correlation)) if correlation.size else 0.0
    if peak <= 0.0 or peak < min_ratio * max(typical, 1e-12):
        return None
    return start + int(np.argmax(correlation))


def find_marker(x, rate, marker_seconds=MARKER_SECONDS, search_seconds=1.5):
    """Frame index of the alignment marker, by matched filter over the first `search_seconds`.

    Returns the peak of the correlation between the signal and the marker tone, which is where the
    marker sits; the analysis then works in offsets from it, so a capture with a different lead-in
    (the pedal's own clock, or a device that started late) still lines up.
    """
    n = int(marker_seconds * rate)
    template = marker_template(rate, marker_seconds)
    limit = min(x.size, int(search_seconds * rate))
    if limit < n:
        return 0
    segment = x[:limit].astype(np.float64)
    segment = segment - np.mean(segment)
    correlation = np.correlate(segment, template, mode="valid")
    return int(np.argmax(np.abs(correlation)))


# Where the body sits inside a played file, relative to its marker: the lead to the marker plus the
# 20 ms marker plus the 0.2 s gap the marker is followed by.
BODY_AFTER_MARKER_SECONDS = 0.22


def slice_at_marker(x, rate, body_seconds, guard=0.30, search=1.5, expected=None):
    """The body of a played signal inside a capture, found by its marker.

    `expected` is where the marker is already known to be (a whole run's pedal recording is one file,
    so only the first segment needs a full search). Returns (start, end) frame indices, or None when
    no marker is found -- a missing marker is a fact about a capture, not a crash.
    """
    if expected is not None:
        # A predicted frame is a reading of the same clock, not a guess: the wall clock says where
        # the marker must be within a few milliseconds. The search only refines it, and a segment
        # with no marker at all (silence) is sliced where it was predicted to be.
        found = find_marker_near(x, rate, expected, search_seconds=min(search, 0.25))
        marker = found if found is not None else int(expected)
    else:
        marker = find_marker(x, rate, search_seconds=search)
    if marker <= 0:
        return None
    start = marker + int((BODY_AFTER_MARKER_SECONDS + guard) * rate)
    length = int((body_seconds - 2 * guard) * rate)
    if start + length > x.size:
        length = max(0, x.size - start)
    if length < rate // 10:
        return None
    return start, start + length


def measure_slice(x, rate, body_seconds, guard=0.30, search=1.5, expected=None):
    """`measure`, on the body of a capture rather than on the whole file."""
    window = slice_at_marker(x, rate, body_seconds, guard=guard, search=search, expected=expected)
    if window is None:
        return None
    start, end = window
    return measure(x[start:end], rate)


def measure(x, rate=48000, reference=None):
    """Every digital and perceptual measure, for one channel.

    `reference` is the matching channel of the played file: with it, the entry also carries the
    transfer (captured level minus played level in dB), which is the number the campaign is after.
    """
    x = centred(np.asarray(x, dtype=np.float64))
    result = {
        "peak_dbfs": peak_dbfs(x),
        "true_peak_dbfs": true_peak_dbfs(x),
        "rms_dbfs": rms_dbfs(x),
        "a_weighted_dbfs": a_weighted_rms_dbfs(x, rate),
        "lufs": lufs_integrated(x, rate),
        "lufs_short_term_max": lufs_short_term_max(x, rate),
        "crest_db": crest_factor_db(x),
        "dc": dc_offset(x),
        "frames": int(x.size),
    }
    positive, negative = full_scale_counts(x)
    result["pinned_positive"] = positive
    result["pinned_negative"] = negative
    result["full_scale_frames"] = positive + negative
    result["full_scale_fraction"] = (positive + negative) / x.size if x.size else 0.0
    if reference is not None and reference.size >= x.size:
        result["reference_peak_dbfs"] = peak_dbfs(reference[: x.size])
        result["reference_rms_dbfs"] = rms_dbfs(reference[: x.size])
        result["transfer_peak_db"] = result["peak_dbfs"] - result["reference_peak_dbfs"]
        result["transfer_rms_db"] = result["rms_dbfs"] - result["reference_rms_dbfs"]
    return result


# ---------------------------------------------------------------- self-check

def selftest():
    """Check the measures against figures that are true by definition, and print them.

    Nothing downstream is worth reading if these fail: a 1 kHz sine at -20 dBFS peak has an RMS of
    -23.01 dBFS, an A-weighting of exactly 0 dB at 1 kHz, and a K-weighted loudness that equals its
    RMS for a single channel of a 1 kHz tone.
    """
    rate = 48000
    failures = []

    def check(name, got, want, tolerance=0.15):
        ok = abs(got - want) <= tolerance
        print("  %-46s %9.3f  (want %8.3f) %s" % (name, got, want, "ok" if ok else "FAIL"))
        if not ok:
            failures.append(name)

    t = np.arange(rate * 4) / rate
    sine = 10 ** (-20.0 / 20.0) * np.sin(2 * np.pi * 1000 * t)
    check("sine -20 dBFS peak: peak", peak_dbfs(sine), -20.0, 0.01)
    check("sine -20 dBFS peak: rms", rms_dbfs(sine), -23.01, 0.05)
    check("sine -20 dBFS peak: crest", crest_factor_db(sine), 3.01, 0.05)
    check("sine -20 dBFS peak: true peak", true_peak_dbfs(sine), -20.0, 0.2)
    check("sine -20 dBFS peak: A-weighted", a_weighted_rms_dbfs(sine, rate), -23.01, 0.3)
    check("sine -20 dBFS peak: LUFS", lufs_integrated(sine, rate), -23.01, 0.3)

    low = 10 ** (-20.0 / 20.0) * np.sin(2 * np.pi * 100 * t)
    check("A-weighting of a 100 Hz sine (dB)", a_weighted_rms_dbfs(low, rate) - rms_dbfs(low),
          -19.1, 0.4)
    # The standard's table rounds to -30.2 dB at 50 Hz; the analytic curve gives -30.27, so the
    # tolerance here is the rounding in the table, not slack in the code.
    check("A-weighting at 50 Hz (dB)", 20 * math.log10(float(a_weight_gain(50.0))), -30.2, 0.1)
    check("A-weighting at 1 kHz (dB)", 20 * math.log10(float(a_weight_gain(1000.0))), 0.0, 0.01)
    check("A-weighting at 10 kHz (dB)", 20 * math.log10(float(a_weight_gain(10000.0))), -2.5, 0.05)

    # Pink noise: its own loudness is dominated by the low end, so A-weighting takes more off it
    # than it does off a tone at 1 kHz. The value is not a standard figure; the ordering is the check.
    rng = np.random.default_rng(7)
    white = rng.standard_normal(rate * 2) * 0.1
    check("white noise: A-weighting costs about 3.4 dB",
          a_weighted_rms_dbfs(white, rate) - rms_dbfs(white), -3.4, 0.6)

    # The frequency-domain filter and the sample-by-sample recursion are the same filter, and the
    # loudness figures are only comparable across segments if that is true.
    probe = 0.2 * np.sin(2 * np.pi * 220 * t) + 0.05 * np.sin(2 * np.pi * 3000 * t)
    time_domain = _biquad_time_domain(_biquad_time_domain(probe, _K_STAGE1_B, _K_STAGE1_A),
                                      _K_STAGE2_B, _K_STAGE2_A)
    frequency_domain = k_weight(probe, rate)
    check("K-weighting: FFT vs recursion, worst sample", float(np.max(np.abs(time_domain - frequency_domain))), 0.0, 1e-6)

    # A marker at a known place is found where it was put.
    marker = 0.5 * marker_template(rate)
    signal = np.concatenate([np.zeros(12345), marker, np.zeros(rate)])
    check("marker found at the right frame", float(find_marker(signal, rate)), 12345.0, 2.0)

    print("%d checks failed" % len(failures) if failures else "all checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    import sys

    if "--selftest" in sys.argv:
        raise SystemExit(selftest())
    if len(sys.argv) > 1:
        for i, path in enumerate(sys.argv[1:]):
            if path == "--selftest":
                continue
            samples, rate = read_wav(path)
            print(path)
            for channel in range(samples.shape[1]):
                m = measure(samples[:, channel], rate)
                print("  ch%d: peak %7.2f  rms %7.2f  A %7.2f  LUFS %7.2f  crest %5.2f"
                      % (channel + 1, m["peak_dbfs"], m["rms_dbfs"], m["a_weighted_dbfs"],
                         m["lufs"], m["crest_db"]))
    else:
        print(__doc__)
