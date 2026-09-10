import Foundation

// Generated data table. Split into one array per category: a single literal of
// this size makes the Swift type-checker crawl, and per-category arrays also
// keep the browse order explicit.

extension Catalogue {

    static let ampComponents: [ComponentSpec] = [
        ComponentSpec("amp.cleanblack", "Black Panel Clean", "Scooped American clean", .amp, [.guitar, .bass], "amplifier",
            [.knob("gain", "Gain", 4.0, min: 0.0, max: 10.0), .knob("bass", "Bass", 5.0, min: 0.0, max: 10.0), .knob("mid", "Mid", 5.0, min: 0.0, max: 10.0), .knob("treble", "Treble", 5.0, min: 0.0, max: 10.0), .knob("presence", "Presence", 6.0, min: 0.0, max: 10.0), .knob("master", "Master", 7.0, min: 0.0, max: 10.0)]),
        ComponentSpec("amp.tweed", "Tweed Combo", "Woody breakup, early drive", .amp, [.guitar, .bass], "amplifier",
            [.knob("gain", "Gain", 6.0, min: 0.0, max: 10.0), .knob("tone", "Tone", 6.0, min: 0.0, max: 10.0), .knob("master", "Master", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("amp.britplexi", "Brit Plexi", "Cranked British rock", .amp, [.guitar, .bass], "amplifier",
            [.knob("gain", "Gain", 7.0, min: 0.0, max: 10.0), .knob("bass", "Bass", 5.0, min: 0.0, max: 10.0), .knob("mid", "Mid", 6.0, min: 0.0, max: 10.0), .knob("treble", "Treble", 6.0, min: 0.0, max: 10.0), .knob("presence", "Presence", 5.0, min: 0.0, max: 10.0), .knob("master", "Master", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("amp.brit800", "Brit 800", "Hot-rodded 80s lead", .amp, [.guitar, .bass], "amplifier",
            [.knob("gain", "Gain", 7.0, min: 0.0, max: 10.0), .knob("bass", "Bass", 5.0, min: 0.0, max: 10.0), .knob("mid", "Mid", 5.0, min: 0.0, max: 10.0), .knob("treble", "Treble", 6.0, min: 0.0, max: 10.0), .knob("master", "Master", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("amp.rectified", "Recto Modern", "High-gain modern rhythm", .amp, [.guitar, .bass], "amplifier",
            [.knob("gain", "Gain", 8.0, min: 0.0, max: 10.0), .knob("bass", "Bass", 6.0, min: 0.0, max: 10.0), .knob("mid", "Mid", 4.0, min: 0.0, max: 10.0), .knob("treble", "Treble", 6.0, min: 0.0, max: 10.0), .knob("presence", "Presence", 5.0, min: 0.0, max: 10.0), .knob("master", "Master", 5.0, min: 0.0, max: 10.0)]),
        ComponentSpec("amp.chime", "Chime Top Boost", "British jangle", .amp, [.guitar, .bass], "amplifier",
            [.knob("gain", "Gain", 5.0, min: 0.0, max: 10.0), .knob("cut", "Cut", 5.0, min: 0.0, max: 10.0), .knob("bass", "Bass", 5.0, min: 0.0, max: 10.0), .knob("treble", "Treble", 7.0, min: 0.0, max: 10.0), .knob("master", "Master", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("amp.hiwattage", "Hi Wattage", "Clean headroom, stiff", .amp, [.guitar, .bass], "amplifier",
            [.knob("gain", "Gain", 4.0, min: 0.0, max: 10.0), .knob("bass", "Bass", 5.0, min: 0.0, max: 10.0), .knob("mid", "Mid", 5.0, min: 0.0, max: 10.0), .knob("treble", "Treble", 5.0, min: 0.0, max: 10.0), .knob("presence", "Presence", 6.0, min: 0.0, max: 10.0), .knob("master", "Master", 7.0, min: 0.0, max: 10.0)]),
        ComponentSpec("amp.leadchannel", "Solo Lead", "Singing sustain lead", .amp, [.guitar, .bass], "amplifier",
            [.knob("gain", "Gain", 8.0, min: 0.0, max: 10.0), .knob("bass", "Bass", 5.0, min: 0.0, max: 10.0), .knob("mid", "Mid", 7.0, min: 0.0, max: 10.0), .knob("treble", "Treble", 6.0, min: 0.0, max: 10.0), .knob("master", "Master", 5.0, min: 0.0, max: 10.0)]),
        ComponentSpec("amp.bassflip", "Flip-Top Bass", "Vintage valve bass amp", .amp, [.bass], "amplifier",
            [.knob("gain", "Gain", 5.0, min: 0.0, max: 10.0), .knob("bass", "Bass", 6.0, min: 0.0, max: 10.0), .knob("mid", "Mid", 5.0, min: 0.0, max: 10.0), .knob("treble", "Treble", 5.0, min: 0.0, max: 10.0), .knob("master", "Master", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("amp.bassrock", "Rock Bass Stack", "Aggressive modern bass", .amp, [.bass], "amplifier",
            [.knob("gain", "Gain", 6.0, min: 0.0, max: 10.0), .knob("bass", "Bass", 6.0, min: 0.0, max: 10.0), .knob("lowmid", "Low Mid", 5.0, min: 0.0, max: 10.0), .knob("himid", "High Mid", 5.0, min: 0.0, max: 10.0), .knob("treble", "Treble", 6.0, min: 0.0, max: 10.0), .knob("master", "Master", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("amp.acoustic", "Acoustic DI Amp", "Transparent acoustic voice", .amp, [.guitar, .bass], "amplifier",
            [.knob("gain", "Gain", 5.0, min: 0.0, max: 10.0), .knob("bass", "Bass", 5.0, min: 0.0, max: 10.0), .knob("mid", "Mid", 5.0, min: 0.0, max: 10.0), .knob("treble", "Treble", 5.0, min: 0.0, max: 10.0), .knob("master", "Master", 7.0, min: 0.0, max: 10.0)]),
    ]

    static let cabComponents: [ComponentSpec] = [
        ComponentSpec("cab.412brit", "4x12 British", "Classic greenback stack", .cab, [.guitar, .bass], "hifispeaker.2",
            [.pick("mic", "Mic", ["Dyn 57", "Ribbon 121", "Cond 87", "Dyn 421"], "Dyn 57"), .range("distance", "Distance", 2.0, 0.0, 12.0, unit: "in"), .range("axis", "Off Axis", 0.0, 0.0, 90.0, unit: "deg"), .range("level", "Level", 0.0, -30.0, 12.0, unit: "dB")]),
        ComponentSpec("cab.212chime", "2x12 Chime", "Alnico jangle pair", .cab, [.guitar, .bass], "hifispeaker.2",
            [.pick("mic", "Mic", ["Dyn 57", "Ribbon 121", "Cond 87"], "Cond 87"), .range("distance", "Distance", 3.0, 0.0, 12.0, unit: "in"), .range("level", "Level", 0.0, -30.0, 12.0, unit: "dB")]),
        ComponentSpec("cab.112open", "1x12 Open Back", "Airy American combo", .cab, [.guitar, .bass], "hifispeaker.2",
            [.pick("mic", "Mic", ["Dyn 57", "Ribbon 121", "Cond 87"], "Dyn 57"), .range("distance", "Distance", 2.0, 0.0, 12.0, unit: "in"), .range("level", "Level", 0.0, -30.0, 12.0, unit: "dB")]),
        ComponentSpec("cab.810bass", "8x10 Bass Fridge", "Full-range bass wall", .cab, [.bass], "hifispeaker.2",
            [.pick("mic", "Mic", ["Dyn 20", "Dyn 421", "Cond 87"], "Dyn 20"), .range("distance", "Distance", 4.0, 0.0, 12.0, unit: "in"), .range("level", "Level", 0.0, -30.0, 12.0, unit: "dB")]),
        ComponentSpec("cab.ir", "IR Loader", "User impulse response", .cab, [.guitar, .bass, .vocal], "waveform.path",
            [.pick("slot", "Slot", ["Slot 1", "Slot 2", "Slot 3", "Slot 4"], "Slot 1"), .range("lowcut", "Low Cut", 80.0, 20.0, 400.0, unit: "Hz"), .range("highcut", "High Cut", 8000.0, 2000.0, 20000.0, unit: "Hz"), .range("level", "Level", 0.0, -30.0, 12.0, unit: "dB")]),
    ]

    static let driveComponents: [ComponentSpec] = [
        ComponentSpec("drive.green", "Green Overdrive", "Mid-humped tube screamer", .drive, [.guitar, .bass], "flame",
            [.knob("drive", "Drive", 5.0, min: 0.0, max: 10.0), .knob("tone", "Tone", 6.0, min: 0.0, max: 10.0), .knob("level", "Level", 5.0, min: 0.0, max: 10.0)]),
        ComponentSpec("drive.transparent", "Transparent Drive", "Clean boost with grit", .drive, [.guitar, .bass], "flame",
            [.knob("drive", "Drive", 4.0, min: 0.0, max: 10.0), .knob("tone", "Tone", 5.0, min: 0.0, max: 10.0), .knob("level", "Level", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("drive.yellowbox", "Yellow Box", "Symmetrical soft clip", .drive, [.guitar, .bass], "flame",
            [.knob("drive", "Drive", 5.0, min: 0.0, max: 10.0), .knob("tone", "Tone", 5.0, min: 0.0, max: 10.0), .knob("level", "Level", 5.0, min: 0.0, max: 10.0)]),
        ComponentSpec("drive.klone", "Gold Horse", "Transparent mid boost", .drive, [.guitar, .bass], "flame",
            [.knob("drive", "Drive", 4.0, min: 0.0, max: 10.0), .knob("treble", "Treble", 5.0, min: 0.0, max: 10.0), .knob("level", "Level", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("drive.rat", "Rodent Distortion", "Gritty filtered distortion", .drive, [.guitar, .bass], "flame",
            [.knob("distortion", "Distortion", 6.0, min: 0.0, max: 10.0), .knob("filter", "Filter", 5.0, min: 0.0, max: 10.0), .knob("level", "Level", 5.0, min: 0.0, max: 10.0)]),
        ComponentSpec("drive.muff", "Big Fuzz", "Sustaining scooped fuzz", .drive, [.guitar, .bass], "burst",
            [.knob("sustain", "Sustain", 7.0, min: 0.0, max: 10.0), .knob("tone", "Tone", 5.0, min: 0.0, max: 10.0), .knob("level", "Level", 5.0, min: 0.0, max: 10.0)]),
        ComponentSpec("drive.fuzzface", "Round Fuzz", "Germanium vintage fuzz", .drive, [.guitar, .bass], "burst",
            [.knob("fuzz", "Fuzz", 7.0, min: 0.0, max: 10.0), .knob("level", "Level", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("drive.octafuzz", "Octave Fuzz", "Upper-octave splat", .drive, [.guitar, .bass], "burst",
            [.knob("fuzz", "Fuzz", 7.0, min: 0.0, max: 10.0), .knob("octave", "Octave", 6.0, min: 0.0, max: 10.0), .knob("level", "Level", 5.0, min: 0.0, max: 10.0)]),
        ComponentSpec("drive.metaldist", "Metal Distortion", "Tight high-gain", .drive, [.guitar, .bass], "flame",
            [.knob("gain", "Gain", 7.0, min: 0.0, max: 10.0), .knob("low", "Low", 5.0, min: 0.0, max: 10.0), .knob("mid", "Mid", 4.0, min: 0.0, max: 10.0), .knob("high", "High", 6.0, min: 0.0, max: 10.0), .knob("level", "Level", 5.0, min: 0.0, max: 10.0)]),
        ComponentSpec("drive.bassdrive", "Bass Overdrive", "Blendable bass grit", .drive, [.bass], "flame",
            [.knob("drive", "Drive", 5.0, min: 0.0, max: 10.0), .knob("blend", "Blend", 5.0, min: 0.0, max: 10.0), .knob("tone", "Tone", 5.0, min: 0.0, max: 10.0), .knob("level", "Level", 5.0, min: 0.0, max: 10.0)]),
        ComponentSpec("drive.bassfuzz", "Bass Fuzz", "Octave-fat bass fuzz", .drive, [.bass], "burst",
            [.knob("fuzz", "Fuzz", 6.0, min: 0.0, max: 10.0), .knob("blend", "Blend", 6.0, min: 0.0, max: 10.0), .knob("tone", "Tone", 5.0, min: 0.0, max: 10.0), .knob("level", "Level", 5.0, min: 0.0, max: 10.0)]),
        ComponentSpec("drive.boost", "Clean Boost", "Level and edge", .drive, [.guitar, .bass, .vocal], "bolt",
            [.range("gain", "Gain", 6.0, 0.0, 20.0, unit: "dB"), .knob("tone", "Tone", 5.0, min: 0.0, max: 10.0)]),
    ]

    static let dynamicsComponents: [ComponentSpec] = [
        ComponentSpec("dyn.comp.studio", "Studio Compressor", "Smooth VCA levelling", .dynamics, [.guitar, .bass, .vocal], "waveform.path.ecg",
            [.range("threshold", "Threshold", -18.0, -60.0, 0.0, unit: "dB"), .pick("ratio", "Ratio", ["2:1", "4:1", "8:1", "20:1"], "4:1"), .range("attack", "Attack", 10.0, 0.1, 100.0, unit: "ms"), .range("release", "Release", 120.0, 10.0, 1000.0, unit: "ms"), .range("makeup", "Makeup", 3.0, 0.0, 20.0, unit: "dB")]),
        ComponentSpec("dyn.comp.optical", "Optical Comp", "Slow, musical levelling", .dynamics, [.guitar, .bass, .vocal], "waveform.path.ecg",
            [.knob("peak", "Peak Reduce", 5.0, min: 0.0, max: 10.0), .knob("gain", "Gain", 5.0, min: 0.0, max: 10.0), .pick("mode", "Mode", ["Compress", "Limit"], "Compress")]),
        ComponentSpec("dyn.comp.squish", "Studio Squeeze", "Snappy pedal compressor", .dynamics, [.guitar, .bass], "waveform.path.ecg",
            [.knob("sustain", "Sustain", 6.0, min: 0.0, max: 10.0), .knob("attack", "Attack", 4.0, min: 0.0, max: 10.0), .knob("level", "Level", 5.0, min: 0.0, max: 10.0)]),
        ComponentSpec("dyn.comp.bass", "Bass Compressor", "Tight low-end control", .dynamics, [.bass], "waveform.path.ecg",
            [.range("threshold", "Threshold", -20.0, -60.0, 0.0, unit: "dB"), .pick("ratio", "Ratio", ["2:1", "4:1", "10:1"], "4:1"), .range("makeup", "Makeup", 4.0, 0.0, 20.0, unit: "dB"), .knob("blend", "Blend", 7.0, min: 0.0, max: 10.0)]),
        ComponentSpec("dyn.gate", "Noise Gate", "Silence between notes", .dynamics, [.guitar, .bass, .vocal], "waveform.badge.minus",
            [.range("threshold", "Threshold", -55.0, -90.0, 0.0, unit: "dB"), .range("attack", "Attack", 2.0, 0.1, 50.0, unit: "ms"), .range("release", "Release", 120.0, 10.0, 1000.0, unit: "ms"), .range("depth", "Depth", 60.0, 0.0, 90.0, unit: "dB")]),
        ComponentSpec("dyn.deesser", "De-Esser", "Tame sibilance", .dynamics, [.vocal], "waveform.badge.minus",
            [.range("freq", "Frequency", 6500.0, 2000.0, 12000.0, unit: "Hz"), .range("amount", "Amount", 5.0, 0.0, 10.0), .pick("mode", "Mode", ["Wideband", "Split"], "Split")]),
        ComponentSpec("dyn.limiter", "Brickwall Limiter", "Catch the peaks", .dynamics, [.guitar, .bass, .vocal], "arrow.down.right.and.arrow.up.left",
            [.range("ceiling", "Ceiling", -1.0, -12.0, 0.0, unit: "dB"), .range("release", "Release", 100.0, 10.0, 1000.0, unit: "ms")]),
        ComponentSpec("dyn.expander", "Expander", "Open up the dynamics", .dynamics, [.guitar, .bass, .vocal], "arrow.up.left.and.arrow.down.right",
            [.range("threshold", "Threshold", -40.0, -80.0, 0.0, unit: "dB"), .pick("ratio", "Ratio", ["1.5:1", "2:1", "4:1"], "2:1")]),
    ]

    static let eqComponents: [ComponentSpec] = [
        ComponentSpec("eq.graphic10", "10-Band Graphic", "Classic slider EQ", .eq, [.guitar, .bass, .vocal], "slider.vertical.3",
            [.range("b31", "31 Hz", 0.0, -12.0, 12.0, unit: "dB"), .range("b125", "125 Hz", 0.0, -12.0, 12.0, unit: "dB"), .range("b500", "500 Hz", 0.0, -12.0, 12.0, unit: "dB"), .range("b2k", "2 kHz", 0.0, -12.0, 12.0, unit: "dB"), .range("b8k", "8 kHz", 0.0, -12.0, 12.0, unit: "dB"), .range("level", "Level", 0.0, -30.0, 12.0, unit: "dB")]),
        ComponentSpec("eq.parametric", "Parametric EQ", "Three surgical bands", .eq, [.guitar, .bass, .vocal], "slider.vertical.3",
            [.range("lowfreq", "Low Freq", 120.0, 20.0, 500.0, unit: "Hz"), .range("lowgain", "Low Gain", 0.0, -15.0, 15.0, unit: "dB"), .range("midfreq", "Mid Freq", 800.0, 200.0, 5000.0, unit: "Hz"), .range("midgain", "Mid Gain", 0.0, -15.0, 15.0, unit: "dB"), .range("midq", "Mid Q", 1.0, 0.2, 8.0), .range("highgain", "High Gain", 0.0, -15.0, 15.0, unit: "dB")]),
        ComponentSpec("eq.tilt", "Tilt EQ", "One knob, dark to bright", .eq, [.guitar, .bass, .vocal], "slider.horizontal.3",
            [.range("tilt", "Tilt", 0.0, -6.0, 6.0, unit: "dB"), .range("pivot", "Pivot", 900.0, 200.0, 4000.0, unit: "Hz")]),
        ComponentSpec("eq.lowcut", "Low Cut", "Clean up the mud", .eq, [.guitar, .bass, .vocal], "line.3.horizontal.decrease",
            [.range("freq", "Frequency", 80.0, 20.0, 500.0, unit: "Hz"), .pick("slope", "Slope", ["6 dB", "12 dB", "24 dB"], "12 dB")]),
        ComponentSpec("eq.highcut", "High Cut", "Tame the fizz", .eq, [.guitar, .bass, .vocal], "line.3.horizontal.decrease",
            [.range("freq", "Frequency", 8000.0, 1000.0, 20000.0, unit: "Hz"), .pick("slope", "Slope", ["6 dB", "12 dB", "24 dB"], "12 dB")]),
        ComponentSpec("eq.vocalair", "Vocal Air", "High shelf sheen", .eq, [.vocal], "sparkles",
            [.range("freq", "Frequency", 10000.0, 4000.0, 16000.0, unit: "Hz"), .range("gain", "Gain", 3.0, 0.0, 10.0, unit: "dB")]),
    ]

    static let modulationComponents: [ComponentSpec] = [
        ComponentSpec("mod.chorus", "Analog Chorus", "Lush bucket-brigade chorus", .modulation, [.guitar, .bass, .vocal], "water.waves",
            [.range("rate", "Rate", 0.6, 0.05, 10.0, unit: "Hz"), .knob("depth", "Depth", 5.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("mod.chorus.tri", "Tri Chorus", "Three-voice shimmer", .modulation, [.guitar, .bass, .vocal], "water.waves",
            [.range("rate", "Rate", 0.4, 0.05, 8.0, unit: "Hz"), .knob("depth", "Depth", 6.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("mod.flanger", "Flanger", "Jet sweep", .modulation, [.guitar, .bass], "water.waves",
            [.range("rate", "Rate", 0.3, 0.02, 8.0, unit: "Hz"), .knob("depth", "Depth", 6.0, min: 0.0, max: 10.0), .knob("feedback", "Feedback", 5.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("mod.phaser4", "Phaser 4-Stage", "Classic swirl", .modulation, [.guitar, .bass, .vocal], "water.waves",
            [.range("rate", "Rate", 0.5, 0.02, 8.0, unit: "Hz"), .knob("depth", "Depth", 6.0, min: 0.0, max: 10.0), .knob("feedback", "Feedback", 4.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("mod.phaser12", "Phaser 12-Stage", "Deep liquid phase", .modulation, [.guitar, .bass], "water.waves",
            [.range("rate", "Rate", 0.3, 0.02, 8.0, unit: "Hz"), .knob("depth", "Depth", 7.0, min: 0.0, max: 10.0), .knob("feedback", "Feedback", 6.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("mod.tremolo", "Tremolo", "Amplitude pulse", .modulation, [.guitar, .bass, .vocal], "waveform",
            [.range("rate", "Rate", 4.5, 0.1, 20.0, unit: "Hz"), .knob("depth", "Depth", 6.0, min: 0.0, max: 10.0), .pick("shape", "Shape", ["Sine", "Triangle", "Square"], "Sine")]),
        ComponentSpec("mod.harmtrem", "Harmonic Tremolo", "Split-band throb", .modulation, [.guitar, .bass], "waveform",
            [.range("rate", "Rate", 3.5, 0.1, 20.0, unit: "Hz"), .knob("depth", "Depth", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("mod.vibrato", "Vibrato", "Pitch wobble", .modulation, [.guitar, .bass, .vocal], "waveform",
            [.range("rate", "Rate", 5.0, 0.1, 15.0, unit: "Hz"), .knob("depth", "Depth", 4.0, min: 0.0, max: 10.0)]),
        ComponentSpec("mod.rotary", "Rotary Speaker", "Spinning horn cabinet", .modulation, [.guitar, .bass, .vocal], "tornado",
            [.pick("speed", "Speed", ["Slow", "Fast", "Brake"], "Slow"), .knob("depth", "Depth", 7.0, min: 0.0, max: 10.0), .knob("drive", "Drive", 4.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("mod.uvibe", "Uni-Vibe", "Photocell throb", .modulation, [.guitar, .bass], "water.waves",
            [.range("rate", "Rate", 1.2, 0.05, 8.0, unit: "Hz"), .knob("intensity", "Intensity", 6.0, min: 0.0, max: 10.0), .pick("mode", "Mode", ["Chorus", "Vibrato"], "Chorus")]),
        ComponentSpec("mod.ringmod", "Ring Modulator", "Clangorous sidebands", .modulation, [.guitar, .bass], "circle.hexagongrid",
            [.range("freq", "Frequency", 220.0, 20.0, 4000.0, unit: "Hz"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("mod.autopan", "Auto Pan", "Sweep across the stereo field", .modulation, [.guitar, .bass, .vocal], "arrow.left.arrow.right",
            [.range("rate", "Rate", 2.0, 0.05, 12.0, unit: "Hz"), .knob("width", "Width", 7.0, min: 0.0, max: 10.0)]),
        ComponentSpec("mod.doubler", "Doubler", "Detuned thickening", .modulation, [.vocal], "person.2.wave.2",
            [.range("detune", "Detune", 12.0, 0.0, 50.0, unit: "cent"), .range("delay", "Delay", 22.0, 5.0, 60.0, unit: "ms"), .knob("width", "Width", 7.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
    ]

    static let delayComponents: [ComponentSpec] = [
        ComponentSpec("delay.digital", "Digital Delay", "Clean precise repeats", .delay, [.guitar, .bass, .vocal], "timer",
            [.range("time", "Time", 380.0, 10.0, 2000.0, unit: "ms"), .knob("feedback", "Feedback", 4.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%"), .toggle("sync", "Tempo Sync", true)]),
        ComponentSpec("delay.tape", "Tape Echo", "Warm wowing repeats", .delay, [.guitar, .bass, .vocal], "timer",
            [.range("time", "Time", 420.0, 20.0, 1500.0, unit: "ms"), .knob("feedback", "Feedback", 5.0, min: 0.0, max: 10.0), .knob("wow", "Wow & Flutter", 3.0, min: 0.0, max: 10.0), .knob("age", "Tape Age", 4.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("delay.analog", "Analog Delay", "Dark bucket-brigade", .delay, [.guitar, .bass, .vocal], "timer",
            [.range("time", "Time", 320.0, 20.0, 900.0, unit: "ms"), .knob("feedback", "Feedback", 4.0, min: 0.0, max: 10.0), .knob("tone", "Tone", 4.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("delay.pingpong", "Ping Pong", "Bouncing stereo", .delay, [.guitar, .bass, .vocal], "arrow.left.arrow.right",
            [.range("time", "Time", 400.0, 10.0, 2000.0, unit: "ms"), .knob("feedback", "Feedback", 5.0, min: 0.0, max: 10.0), .knob("width", "Width", 8.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%"), .toggle("sync", "Tempo Sync", true)]),
        ComponentSpec("delay.dualdelay", "Dual Delay", "Independent L/R times", .delay, [.guitar, .bass, .vocal], "timer",
            [.range("timel", "Time L", 300.0, 10.0, 2000.0, unit: "ms"), .range("timer", "Time R", 450.0, 10.0, 2000.0, unit: "ms"), .knob("feedback", "Feedback", 4.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("delay.slapback", "Slapback", "Short rockabilly bounce", .delay, [.guitar, .bass, .vocal], "timer",
            [.range("time", "Time", 95.0, 40.0, 200.0, unit: "ms"), .knob("feedback", "Feedback", 1.5, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("delay.reverse", "Reverse Delay", "Backwards swells", .delay, [.guitar, .bass], "arrow.uturn.left",
            [.range("time", "Time", 600.0, 100.0, 2000.0, unit: "ms"), .knob("feedback", "Feedback", 3.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("delay.modulated", "Modulated Delay", "Chorused repeats", .delay, [.guitar, .bass, .vocal], "timer",
            [.range("time", "Time", 420.0, 10.0, 2000.0, unit: "ms"), .knob("feedback", "Feedback", 4.0, min: 0.0, max: 10.0), .knob("moddepth", "Mod Depth", 4.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("delay.multitap", "Multi-Tap", "Rhythmic tap pattern", .delay, [.guitar, .bass, .vocal], "timer",
            [.range("time", "Time", 500.0, 50.0, 2000.0, unit: "ms"), .pick("pattern", "Pattern", ["1/4", "1/8", "Dotted 1/8", "Triplet"], "Dotted 1/8"), .knob("feedback", "Feedback", 4.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("delay.vocalthrow", "Vocal Throw", "Ducked vocal delay", .delay, [.vocal], "timer",
            [.range("time", "Time", 375.0, 50.0, 1200.0, unit: "ms"), .knob("feedback", "Feedback", 3.0, min: 0.0, max: 10.0), .knob("duck", "Ducking", 6.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%"), .toggle("sync", "Tempo Sync", true)]),
    ]

    static let reverbComponents: [ComponentSpec] = [
        ComponentSpec("verb.room", "Room", "Small natural space", .reverb, [.guitar, .bass, .vocal], "aqi.medium",
            [.range("decay", "Decay", 1.1, 0.1, 10.0, unit: "s"), .range("predelay", "Pre-Delay", 12.0, 0.0, 200.0, unit: "ms"), .knob("damping", "Damping", 5.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("verb.hall", "Hall", "Large concert space", .reverb, [.guitar, .bass, .vocal], "aqi.medium",
            [.range("decay", "Decay", 2.8, 0.2, 20.0, unit: "s"), .range("predelay", "Pre-Delay", 28.0, 0.0, 200.0, unit: "ms"), .knob("damping", "Damping", 4.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("verb.plate", "Plate", "Dense bright plate", .reverb, [.guitar, .bass, .vocal], "aqi.medium",
            [.range("decay", "Decay", 2.0, 0.2, 12.0, unit: "s"), .range("predelay", "Pre-Delay", 18.0, 0.0, 200.0, unit: "ms"), .knob("tone", "Tone", 6.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("verb.spring", "Spring", "Boingy amp reverb", .reverb, [.guitar, .bass], "aqi.medium",
            [.range("decay", "Decay", 1.6, 0.2, 8.0, unit: "s"), .knob("tone", "Tone", 5.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("verb.shimmer", "Shimmer", "Octave-up ambient wash", .reverb, [.guitar, .bass, .vocal], "sparkles",
            [.range("decay", "Decay", 4.5, 0.5, 20.0, unit: "s"), .knob("shimmer", "Shimmer", 6.0, min: 0.0, max: 10.0), .knob("damping", "Damping", 3.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("verb.ambient", "Ambient Cloud", "Diffuse pad texture", .reverb, [.guitar, .bass, .vocal], "cloud",
            [.range("decay", "Decay", 6.0, 1.0, 30.0, unit: "s"), .knob("diffusion", "Diffusion", 8.0, min: 0.0, max: 10.0), .knob("modulation", "Modulation", 4.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("verb.gated", "Gated Reverb", "Abrupt 80s tail", .reverb, [.guitar, .bass, .vocal], "aqi.medium",
            [.range("decay", "Decay", 1.2, 0.2, 4.0, unit: "s"), .range("hold", "Hold", 180.0, 20.0, 600.0, unit: "ms"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("verb.vocalplate", "Vocal Plate", "Silky vocal sheen", .reverb, [.vocal], "aqi.medium",
            [.range("decay", "Decay", 1.8, 0.2, 8.0, unit: "s"), .range("predelay", "Pre-Delay", 30.0, 0.0, 200.0, unit: "ms"), .range("lowcut", "Low Cut", 250.0, 20.0, 800.0, unit: "Hz"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
    ]

    static let pitchComponents: [ComponentSpec] = [
        ComponentSpec("pitch.octaver", "Octaver", "Sub and upper octave", .pitch, [.guitar, .bass], "arrow.up.arrow.down",
            [.knob("sub1", "Sub Octave", 6.0, min: 0.0, max: 10.0), .knob("up1", "Up Octave", 0.0, min: 0.0, max: 10.0), .knob("dry", "Dry", 7.0, min: 0.0, max: 10.0)]),
        ComponentSpec("pitch.shifter", "Pitch Shifter", "Fixed interval shift", .pitch, [.guitar, .bass, .vocal], "arrow.up.arrow.down",
            [.range("semitones", "Semitones", 7.0, -24.0, 24.0, unit: "st"), .range("cents", "Fine", 0.0, -50.0, 50.0, unit: "cent"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("pitch.harmonizer", "Harmonizer", "Diatonic harmony voice", .pitch, [.guitar, .bass, .vocal], "person.2.wave.2",
            [.pick("key", "Key", ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"], "G"), .pick("scale", "Scale", ["Major", "Minor", "Dorian", "Mixolydian"], "Major"), .pick("interval", "Interval", ["3rd Up", "5th Up", "3rd Down", "Octave Up"], "3rd Up"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("pitch.whammy", "Whammy", "Expression pitch dive", .pitch, [.guitar, .bass], "arrow.up.arrow.down",
            [.pick("range", "Range", ["1 Octave Up", "2 Octave Up", "1 Octave Down", "Dive Bomb"], "1 Octave Up"), .knob("position", "Pedal", 0.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("pitch.detune", "Detune", "Subtle thickening", .pitch, [.guitar, .bass, .vocal], "arrow.up.arrow.down",
            [.range("detune", "Detune", 8.0, 0.0, 50.0, unit: "cent"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("pitch.correct", "Pitch Correction", "Snap to key", .pitch, [.vocal], "tuningfork",
            [.pick("key", "Key", ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"], "C"), .pick("scale", "Scale", ["Major", "Minor", "Chromatic"], "Major"), .knob("speed", "Speed", 7.0, min: 0.0, max: 10.0), .knob("amount", "Amount", 8.0, min: 0.0, max: 10.0)]),
        ComponentSpec("pitch.synth", "Guitar Synth", "Tracked synth voice", .pitch, [.guitar, .bass], "pianokeys",
            [.pick("wave", "Wave", ["Saw", "Square", "Pulse"], "Saw"), .range("filter", "Filter", 2000.0, 100.0, 12000.0, unit: "Hz"), .knob("attack", "Attack", 2.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
    ]

    static let filterComponents: [ComponentSpec] = [
        ComponentSpec("filter.wah", "Wah", "Vocal sweep filter", .filter, [.guitar, .bass], "camera.filters",
            [.knob("position", "Pedal", 5.0, min: 0.0, max: 10.0), .range("range", "Range", 5.0, 0.0, 10.0), .knob("q", "Q", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("filter.autowah", "Auto Wah", "Envelope-triggered wah", .filter, [.guitar, .bass], "camera.filters",
            [.knob("sensitivity", "Sensitivity", 6.0, min: 0.0, max: 10.0), .range("range", "Range", 5.0, 0.0, 10.0), .knob("q", "Q", 6.0, min: 0.0, max: 10.0), .pick("direction", "Direction", ["Up", "Down"], "Up")]),
        ComponentSpec("filter.envfilter", "Envelope Filter", "Funk quack", .filter, [.guitar, .bass], "camera.filters",
            [.knob("sensitivity", "Sensitivity", 6.0, min: 0.0, max: 10.0), .range("freq", "Frequency", 600.0, 100.0, 4000.0, unit: "Hz"), .knob("q", "Q", 7.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("filter.formant", "Formant Filter", "Vowel morphing", .filter, [.guitar, .bass, .vocal], "camera.filters",
            [.pick("vowela", "Vowel A", ["A", "E", "I", "O", "U"], "A"), .pick("vowelb", "Vowel B", ["A", "E", "I", "O", "U"], "O"), .range("rate", "Rate", 1.0, 0.05, 8.0, unit: "Hz"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("filter.talkbox", "Talk Box", "Mouth-tube voice", .filter, [.guitar, .bass], "mouth",
            [.knob("amount", "Amount", 7.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("filter.bitcrusher", "Bit Crusher", "Lo-fi digital grit", .filter, [.guitar, .bass, .vocal], "square.grid.3x3",
            [.range("bits", "Bit Depth", 8.0, 1.0, 16.0, unit: "bit"), .range("rate", "Sample Rate", 12000.0, 500.0, 44100.0, unit: "Hz"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("filter.lofi", "Lo-Fi", "Telephone and radio", .filter, [.guitar, .bass, .vocal], "antenna.radiowaves.left.and.right",
            [.range("lowcut", "Low Cut", 400.0, 50.0, 2000.0, unit: "Hz"), .range("highcut", "High Cut", 3000.0, 800.0, 12000.0, unit: "Hz"), .knob("noise", "Noise", 2.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
    ]

    static let vocalComponents: [ComponentSpec] = [
        ComponentSpec("vocal.preamp", "Vocal Preamp", "Valve character front end", .vocal, [.vocal], "mic",
            [.range("gain", "Gain", 30.0, 0.0, 60.0, unit: "dB"), .knob("drive", "Drive", 3.0, min: 0.0, max: 10.0), .range("lowcut", "Low Cut", 90.0, 20.0, 300.0, unit: "Hz")]),
        ComponentSpec("vocal.channelstrip", "Channel Strip", "Comp, EQ and gate in one", .vocal, [.vocal], "slider.vertical.3",
            [.range("threshold", "Comp Threshold", -18.0, -60.0, 0.0, unit: "dB"), .range("lowcut", "Low Cut", 90.0, 20.0, 300.0, unit: "Hz"), .range("presence", "Presence", 2.0, -10.0, 10.0, unit: "dB"), .range("air", "Air", 3.0, -10.0, 10.0, unit: "dB")]),
        ComponentSpec("vocal.exciter", "Exciter", "Harmonic brightness", .vocal, [.vocal], "sparkles",
            [.range("freq", "Frequency", 4000.0, 1000.0, 12000.0, unit: "Hz"), .knob("amount", "Amount", 4.0, min: 0.0, max: 10.0), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("vocal.harmony", "Vocal Harmony", "Two-part backing", .vocal, [.vocal], "person.3",
            [.pick("key", "Key", ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"], "C"), .pick("scale", "Scale", ["Major", "Minor"], "Major"), .pick("voices", "Voices", ["Above", "Below", "Both"], "Above"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("vocal.megaphone", "Megaphone", "Distorted PA shout", .vocal, [.vocal], "megaphone",
            [.knob("drive", "Drive", 6.0, min: 0.0, max: 10.0), .range("lowcut", "Low Cut", 500.0, 200.0, 1500.0, unit: "Hz"), .range("highcut", "High Cut", 3500.0, 1500.0, 8000.0, unit: "Hz"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("vocal.gender", "Voice Character", "Shift formants", .vocal, [.vocal], "person.wave.2",
            [.range("formant", "Formant", 0.0, -12.0, 12.0, unit: "st"), .range("pitch", "Pitch", 0.0, -12.0, 12.0, unit: "st"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("vocal.breath", "Breath Control", "Reduce breath noise", .vocal, [.vocal], "wind",
            [.range("threshold", "Threshold", -40.0, -70.0, 0.0, unit: "dB"), .knob("amount", "Amount", 5.0, min: 0.0, max: 10.0)]),
    ]

    static let utilityComponents: [ComponentSpec] = [
        ComponentSpec("util.volume", "Volume Pedal", "Expression volume", .utility, [.guitar, .bass, .vocal], "dial.high",
            [.knob("position", "Pedal", 10.0, min: 0.0, max: 10.0), .pick("taper", "Taper", ["Linear", "Logarithmic"], "Logarithmic")]),
        ComponentSpec("util.gain", "Gain", "Trim the level", .utility, [.guitar, .bass, .vocal], "dial.medium",
            [.range("gain", "Gain", 0.0, -24.0, 24.0, unit: "dB")]),
        ComponentSpec("util.pan", "Pan", "Place in the stereo field", .utility, [.guitar, .bass, .vocal], "arrow.left.arrow.right",
            [.range("pan", "Pan", 0.0, -100.0, 100.0, unit: "%")]),
        ComponentSpec("util.tuner", "Tuner", "Mute and tune", .utility, [.guitar, .bass, .vocal], "tuningfork",
            [.range("ref", "Reference", 440.0, 415.0, 460.0, unit: "Hz"), .toggle("mute", "Mute Output", true)]),
        ComponentSpec("util.looper", "Looper", "Record and overdub", .utility, [.guitar, .bass, .vocal], "repeat",
            [.range("maxtime", "Max Time", 60.0, 10.0, 300.0, unit: "s"), .knob("playback", "Playback", 7.0, min: 0.0, max: 10.0), .toggle("halfspeed", "Half Speed", false)]),
        ComponentSpec("util.sendreturn", "FX Loop", "Send to outboard gear", .utility, [.guitar, .bass, .vocal], "arrow.triangle.branch",
            [.range("send", "Send", 0.0, -30.0, 12.0, unit: "dB"), .range("ret", "Return", 0.0, -30.0, 12.0, unit: "dB"), .knob("mix", "Mix", 35.0, min: 0.0, max: 100.0, unit: "%")]),
        ComponentSpec("util.noiseeliminator", "Hum Eliminator", "Kill mains hum", .utility, [.guitar, .bass, .vocal], "waveform.badge.minus",
            [.pick("freq", "Frequency", ["50 Hz", "60 Hz"], "50 Hz"), .knob("amount", "Amount", 6.0, min: 0.0, max: 10.0)]),
        ComponentSpec("util.di", "DI Box", "Direct injection", .utility, [.guitar, .bass, .vocal], "cable.connector",
            [.toggle("lift", "Ground Lift", false), .range("pad", "Pad", 0.0, -20.0, 0.0, unit: "dB")]),
    ]

    /// Every component, in browse order.
    static let allComponents: [ComponentSpec] =
        ampComponents
        + cabComponents
        + driveComponents
        + dynamicsComponents
        + eqComponents
        + modulationComponents
        + delayComponents
        + reverbComponents
        + pitchComponents
        + filterComponents
        + vocalComponents
        + utilityComponents
}
