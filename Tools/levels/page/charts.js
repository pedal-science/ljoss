/* charts.js — the page's sections, built from window.DATA.
 *
 * The dataset is one entry per played segment: what the Mac played, what the SSL measured at each
 * of its own inputs, what namchain reported (`meter`), and what the pedal's own converter handed
 * over (`pedal`). Every chart below is a view of that one table, so a number on two charts is the
 * same number.
 */
(function () {
  "use strict";

  const { line, bars, ladder, section, table, el, PALETTE } = window.Campaign;
  const DATA = window.DATA;
  const SEGMENTS = DATA.segments;
  const main = document.getElementById("main");

  // ---------------------------------------------------------------- helpers

  const finite = (v) => v !== null && v !== undefined && isFinite(v);
  const round = (v, digits) => (finite(v) ? Number(v.toFixed(digits === undefined ? 2 : digits)) : null);

  function meterInput(segment, channel) {
    const rows = segment.meter && segment.meter.input;
    return rows && rows[channel] ? rows[channel] : null;
  }
  function meterOutput(segment, channel) {
    const rows = segment.meter && segment.meter.output;
    return rows && rows[channel] ? rows[channel] : null;
  }
  function chain(segment, index) {
    return segment.meter && segment.meter.chains[index] ? segment.meter.chains[index] : null;
  }
  function nodeByLabel(segment, label) {
    // A macro is several primitives under one element, so a node is identified by its element *and*
    // its role: two rows of the same block are two different places in the graph.
    const c = chain(segment, 0);
    if (!c) return null;
    return c.nodes.find((n) => nodeLabel(n) === label) || null;
  }
  function nodeLabel(node) {
    const base = (DATA.node_labels && DATA.node_labels[node.element]) || node.element.slice(0, 8);
    return node.role ? base + " · " + node.role : base;
  }

  function shapes() {
    const seen = [];
    for (const segment of SEGMENTS) if (!seen.includes(segment.shape)) seen.push(segment.shape);
    return seen;
  }
  function levelsFor(shape) {
    return SEGMENTS.filter((s) => s.shape === shape)
      .map((s) => s.level_dbfs_peak)
      .filter((v, i, a) => a.indexOf(v) === i)
      .sort((a, b) => a - b);
  }
  function segmentFor(shape, level) {
    // A repeat is the same shape and level as a coarse segment: prefer the coarse one, so every
    // chart reads from one run of each condition.
    const matches = SEGMENTS.filter((s) => s.shape === shape && s.level_dbfs_peak === level);
    return matches.find((s) => s.group === "coarse") || matches.find((s) => s.group === "fine") || matches[0];
  }
  function points(predicate, x, y) {
    return SEGMENTS.filter(predicate)
      .map((s) => [x(s), y(s)])
      .filter((p) => finite(p[0]) && finite(p[1]))
      .sort((a, b) => a[0] - b[0]);
  }

  function card(title, note) {
    const node = section(title, note);
    main.appendChild(node);
    return node;
  }

  // ---------------------------------------------------------------- header

  function header() {
    const head = document.querySelector("header .meta");
    const before = DATA.status_before || {};
    const format = (before.format && (before.format.format || before.format)) || "?";
    head.innerHTML = [
      `device <b>${DATA.device}</b>`,
      `pedal <b>${DATA.pedal_host || "vip"}</b>`,
      `rig <b>${DATA.rig}</b>`,
      `segments <b>${SEGMENTS.length}</b>`,
      `polls <b>${(DATA.poller && DATA.poller.windows) || 0}</b>`,
      `engine format <b>${typeof format === "string" ? format : JSON.stringify(format)}</b>`,
    ].join(" &nbsp;·&nbsp; ");
  }

  // ---------------------------------------------------------------- A. the path, one level

  function chartLadder() {
    const shapeChoices = shapes();
    const host = card("1. One signal, every stage of the path",
      "Where the level is at each point for a single played signal, as the SSL measures it and as " +
      "the pedal reports it. The digital loopback is the playback stream inside the interface (a " +
      "unity tap, before the converters); the analogue loopback is output 3 cabled back into " +
      "input 2, so it is the same signal after the D/A and A/D. `namchain input` is what the " +
      "engine's meter says its ADC received; `pedal capture` is what the pedal's own recording " +
      "shows the ADC delivered. A meter that agrees with its own samples sits on top of them.");

    const controls = el("div", "controls");
    let shape = shapeChoices.includes("sine1k") ? "sine1k" : shapeChoices[0];
    const levels = levelsFor(shape);
    let level = levels.includes(-20) ? -20 : levels[Math.floor(levels.length / 2)];

    const shapeRow = el("div", "controls");
    shapeRow.appendChild(el("label", null, "shape"));
    const levelRow = el("div", "controls");
    levelRow.appendChild(el("label", null, "level (peak dBFS played)"));
    const chartHost = el("div", null, "");
    const readout = el("div", "legend-inline");

    function draw() {
      const segment = segmentFor(shape, level);
      chartHost.innerHTML = "";
      readout.innerHTML = "";
      if (!segment) { chartHost.appendChild(el("p", "note", "No segment for that combination.")); return; }
      const rows = [];
      const push = (label, value, colour, note, dim) => {
        if (finite(value)) rows.push({ label, value, colour, note, dim });
      };
      push("played (digital)", segment.played.rms_dbfs, "#7d8798", "peak " + segment.played.peak_dbfs.toFixed(1) + " dBFS", true);
      const digital = segment.ssl.digital_out3;
      push("SSL digital loopback out 3", digital && digital.rms_dbfs, PALETTE[9], "the playback stream itself");
      const analogue = segment.ssl.loopback_analogue;
      push("SSL analogue loopback out 3 → in 2", analogue && analogue.rms_dbfs, PALETTE[5], "after D/A and A/D");
      const input = meterInput(segment, 0);
      push("namchain input (reported)", input && input.rms, PALETTE[0], "engine.levels input.rms");
      const c0 = chain(segment, 0);
      if (c0) {
        c0.nodes.forEach((node) => {
          push("  " + nodeLabel(node), node.rms, PALETTE[4], "node output", true);
        });
        if (c0.out) push("chain out (reported)", c0.out.rms, PALETTE[1]);
      }
      const output = meterOutput(segment, 0);
      push("namchain device output (reported)", output && output.rms, PALETTE[2]);
      const pedalPlayback = segment.pedal.playback;
      push("pedal playback samples", pedalPlayback && pedalPlayback.rms_dbfs, "#f2a65a", "the pedal's own DAC stream");
      const pedalCapture = segment.pedal.capture;
      push("pedal capture samples", pedalCapture && pedalCapture.rms_dbfs, "#a0e060", "the pedal's own ADC stream");
      const pedalOut = segment.ssl.pedal_out;
      push("SSL input 1 (pedal output, analogue)", pedalOut && pedalOut.rms_dbfs, PALETTE[3]);
      push("pedal output loudness (LUFS)", segment.ssl.pedal_out && segment.ssl.pedal_out.lufs, "#e07ab0", "perceptual, not a level");
      push("pedal input loudness (LUFS)", pedalCapture && pedalCapture.lufs, "#c58cff", "perceptual, not a level");
      ladder(chartHost, {
        rows,
        xUnit: " dBFS",
        xDomain: [-110, 12],
        references: [
          { x: 0, label: "0 dBFS = full scale", colour: "#ff7a7a" },
          { x: -20, label: "−20 dBFS", colour: "#6b7484" },
        ],
      });
      const captured = segment.pedal.capture;
      const reported = meterInput(segment, 0);
      if (captured && reported && finite(reported.rms) && finite(captured.rms_dbfs)) {
        const delta = reported.rms - captured.rms_dbfs;
        readout.appendChild(el("span", null,
          `meter vs its own samples: <b>${delta.toFixed(2)} dB</b> ` +
          `<span class="badge ${Math.abs(delta) < 0.5 ? "good" : "warn"}">${Math.abs(delta) < 0.5 ? "agrees" : "differs"}</span>`));
      }
      const lufs = segment.ssl.pedal_out && segment.ssl.pedal_out.lufs;
      if (finite(lufs)) {
        readout.appendChild(el("span", null, `pedal output LUFS: <b>${lufs.toFixed(1)}</b>`));
      }
      const crest = segment.played.crest_db;
      readout.appendChild(el("span", null, `played crest factor: <b>${crest.toFixed(1)} dB</b>`));
      if (segment.latency_ms !== null) {
        readout.appendChild(el("span", null, `SSL loopback latency: <b>${segment.latency_ms.toFixed(1)} ms</b>`));
      }
    }

    shapeChoices.forEach((name) => {
      const button = el("button", null, name);
      button.onclick = () => {
        shape = name;
        const available = levelsFor(shape);
        if (!available.includes(level)) level = available[available.length - 1];
        renderLevels();
        draw();
      };
      button.dataset.shape = name;
      shapeRow.appendChild(button);
    });
    function renderLevels() {
      [...shapeRow.children].forEach((b) => b.classList.toggle("active", b.dataset.shape === shape));
      levelRow.innerHTML = "";
      levelRow.appendChild(el("label", null, "level (peak dBFS played)"));
      levelsFor(shape).forEach((value) => {
        const button = el("button", null, value.toFixed(0));
        button.classList.toggle("active", value === level);
        button.onclick = () => { level = value; renderLevels(); draw(); };
        levelRow.appendChild(button);
      });
    }

    host.appendChild(shapeRow);
    host.appendChild(levelRow);
    host.appendChild(chartHost);
    host.appendChild(readout);
    renderLevels();
    draw();
  }

  // ---------------------------------------------------------------- B. transfer

  function chartTransfer() {
    const host = card("2. Input level → reported level",
      "The campaign's question, one line per place a level is read. The x axis is the level played " +
      "out of the SSL (its own digital loopback confirms it), and the y axis is the RMS each place " +
      "reports, per audio shape. A line that is parallel to the dashed 1:1 line has a constant " +
      "offset — that offset is the calibration constant. Where a line bends flat at the top, that " +
      "place ran out of headroom; where it bends flat at the bottom, it is measuring its own noise.");

    const selected = shapes().filter((s) => s !== "silence");
    const shapePicker = el("div", "controls");
    shapePicker.appendChild(el("label", null, "shapes"));
    const active = new Set(selected.slice(0, 3));
    const chartHost = el("div", null, "");
    function draw() {
      chartHost.innerHTML = "";
      const series = [];
      let index = 0;
      for (const shape of selected) {
        if (!active.has(shape)) continue;
        const colour = PALETTE[index++ % PALETTE.length];
        series.push({
          name: shape + " · played", colour, dash: "3 3", markers: false,
          points: points((s) => s.shape === shape, (s) => s.played.rms_dbfs, (s) => s.played.rms_dbfs),
        });
        series.push({
          name: shape + " · namchain input", colour, markers: true,
          points: points((s) => s.shape === shape, (s) => s.played.rms_dbfs,
            (s) => (meterInput(s, 0) || {}).rms),
        });
        series.push({
          name: shape + " · SSL in 1 (pedal out)", colour, dash: "6 3",
          points: points((s) => s.shape === shape, (s) => s.played.rms_dbfs,
            (s) => (s.ssl.pedal_out || {}).rms_dbfs),
        });
      }
      line(chartHost, {
        series, xLabel: "played RMS (dBFS)", yLabel: "measured RMS (dBFS)", yUnit: "",
        height: 460,
        references: [{ y: 0, label: "0 dBFS", colour: "#ff7a7a" }],
      });
    }
    selected.forEach((shape) => {
      const button = el("button", null, shape);
      if (active.has(shape)) button.classList.add("active");
      button.onclick = () => {
        if (active.has(shape)) active.delete(shape); else active.add(shape);
        if (!active.size) active.add(shape);
        [...shapePicker.querySelectorAll("button")].forEach((b) => b.classList.toggle("active", active.has(b.textContent)));
        draw();
      };
      shapePicker.appendChild(button);
    });
    host.appendChild(shapePicker);
    host.appendChild(chartHost);
    draw();
  }

  function chartResidual() {
    const host = card("3. The same curves as an offset from the played level",
      "Each line is (measured − played) in dB. A flat line means the place tracks the input one for " +
      "one; the height of the flat part is its gain relative to the played digital level. The rise " +
      "at the bottom left is the noise floor taking over; the fall at the top right is clipping. " +
      "The middle of the flat part is the only region where a level reading means what it says.");

    const shapesWanted = shapes().filter((s) => s !== "silence");
    const series = [];
    let index = 0;
    for (const shape of shapesWanted) {
      const colour = PALETTE[index++ % PALETTE.length];
      series.push({
        name: shape + " · namchain input", colour, markers: true,
        points: points((s) => s.shape === shape,
          (s) => s.played.rms_dbfs,
          (s) => (finite((meterInput(s, 0) || {}).rms) ? meterInput(s, 0).rms - s.played.rms_dbfs : null)),
      });
    }
    line(host, {
      series, xLabel: "played RMS (dBFS)", yLabel: "reported − played (dB)", height: 420,
      references: [{ y: 0, label: "unity: reported = played", colour: "#6b7484" }],
    });
  }

  // ---------------------------------------------------------------- C. nodes

  function chartNodes() {
    const c0 = SEGMENTS.map((s) => chain(s, 0)).find(Boolean);
    const note = c0
      ? "Every node in the chain, as `engine.levels` reports it, against the level played. The rig " +
        "is built from gains whose values are known (" +
        c0.nodes.map((n) => nodeLabel(n)).join(", ") +
        "), so each line has a predicted height: a node that is not parallel, or not where the " +
        "gain says, is the level plumbing rather than the audio."
      : "No chain levels in this run.";
    const host = card("4. Levels inside the chain", note);
    const series = [];
    let index = 0;
    if (c0) {
      for (const node of c0.nodes) {
        const label = nodeLabel(node);
        series.push({
          name: label, colour: PALETTE[index++ % PALETTE.length], markers: true,
          points: points(() => true, (s) => s.played.rms_dbfs,
            (s) => { const n = nodeByLabel(s, nodeLabel(node)); return n ? n.rms : null; }),
        });
      }
    }
    series.push({
      name: "namchain input", colour: "#ffffff", dash: "4 4",
      points: points(() => true, (s) => s.played.rms_dbfs, (s) => (meterInput(s, 0) || {}).rms),
    });
    line(host, { series, xLabel: "played RMS (dBFS)", yLabel: "node output (dBFS)", height: 440 });
  }

  // ---------------------------------------------------------------- D. output and loudness

  function chartNodeArithmetic() {
    const predictions = DATA.node_predictions || {};
    const elements = Object.keys(predictions);
    if (!elements.length) return;
    const host = card("4b. Does the chain's arithmetic hold?",
      "The same node levels, minus what the document's own gains predict from the level `nc.input` " +
      "reports. Every line should sit on zero: a gain of −12 dB that reports −11.6, or a node whose " +
      "window is a different length from its neighbour's, shows up here as a line that is not flat. " +
      "The bend at the right-hand end is where the device's input runs out of headroom, and no gain " +
      "in the chain can put back what the converter did not capture.");

    const inputNode = SEGMENTS.map((s) => {
      const c = chain(s, 0);
      return c && c.nodes.length ? c.nodes[0] : null;
    });
    const series = [];
    let index = 0;
    for (const element of elements) {
      const prediction = predictions[element];
      if (prediction.type !== "nc.gain") continue;
      const label = (DATA.node_labels && DATA.node_labels[element]) || element.slice(0, 8);
      series.push({
        name: label, colour: PALETTE[index++ % PALETTE.length], markers: true,
        points: points(() => true,
          (s) => s.played.rms_dbfs,
          (s) => {
            const c = chain(s, 0);
            if (!c || !c.nodes.length) return null;
            const first = c.nodes[0].rms;
            const node = c.nodes.find((n) => n.element === element);
            if (!finite(first) || !node || !finite(node.rms)) return null;
            return node.rms - (first + prediction.offset_db);
          }),
      });
    }
    line(host, {
      series, xLabel: "played RMS (dBFS)", yLabel: "reported − predicted (dB)", height: 340,
      references: [{ y: 0, label: "the arithmetic, exactly", colour: "#6b7484" },
                   { y: 0.1, label: "+0.1 dB", colour: "#3a4048" },
                   { y: -0.1, label: "−0.1 dB", colour: "#3a4048" }],
    });
  }

  function chartOutput() {
    const host = card("5. What comes out, and how loud it sounds",
      "The pedal's output measured by the SSL (analogue), against the level played in. Loudness is " +
      "the same signal through K-weighting (ITU-R BS.1770, the scale a loudness meter uses) — it " +
      "sits below the RMS because these test signals are short bursts of tone rather than programme " +
      "material, and because K-weighting takes energy out below 100 Hz.");

    const series = [];
    let index = 0;
    for (const shape of shapes().filter((s) => s !== "silence")) {
      const colour = PALETTE[index++ % PALETTE.length];
      series.push({
        name: shape + " · pedal out RMS", colour, markers: true,
        points: points((s) => s.shape === shape, (s) => s.played.rms_dbfs, (s) => (s.ssl.pedal_out || {}).rms_dbfs),
      });
      series.push({
        name: shape + " · pedal out LUFS", colour, dash: "5 3",
        points: points((s) => s.shape === shape, (s) => s.played.rms_dbfs, (s) => (s.ssl.pedal_out || {}).lufs),
      });
    }
    line(host, { series, xLabel: "played RMS (dBFS)", yLabel: "dBFS / LUFS", height: 460,
      references: [{ y: -23, label: "−23 LUFS (EBU R128 reference)", colour: "#6b7484" },
                   { y: -14, label: "−14 LUFS (streaming reference)", colour: "#6b7484" }] });
  }

  function chartShapeScales() {
    const host = card("6. The same signal on different scales",
      "One level, several shapes: what each measure says about the *same* played peak. The spread " +
      "between peak and loudness is the whole argument about scale — a peak meter is honest about " +
      "headroom and useless about loudness, and the gap between them is the crest factor of the " +
      "signal, which is a property of the player's hands, not of the rig.");

    const usable = [];
    for (const shape of shapes()) {
      for (const level of levelsFor(shape)) {
        if (usable.some((u) => u.shape === shape && u.level === level)) continue;
        usable.push({ shape, level });
      }
    }
    const levelChoices = [...new Set(usable.map((u) => u.level))].sort((a, b) => a - b);
    let level = levelChoices.includes(-20) ? -20 : levelChoices[Math.floor(levelChoices.length / 2)];
    const controls = el("div", "controls");
    controls.appendChild(el("label", null, "level"));
    const chartHost = el("div", null, "");
    const readout = el("div", "legend-inline");

    function draw() {
      chartHost.innerHTML = "";
      readout.innerHTML = "";
      const rows = shapes().map((shape) => segmentFor(shape, level)).filter(Boolean);
      bars(chartHost, {
        categories: rows.map((s) => s.shape),
        yLabel: "dB",
        series: [
          { name: "peak (dBFS)", values: rows.map((s) => (s.ssl.pedal_out || {}).peak_dbfs) },
          { name: "RMS (dBFS)", values: rows.map((s) => (s.ssl.pedal_out || {}).rms_dbfs) },
          { name: "A-weighted (dBFS)", values: rows.map((s) => (s.ssl.pedal_out || {}).a_weighted_dbfs) },
          { name: "LUFS", values: rows.map((s) => (s.ssl.pedal_out || {}).lufs) },
        ],
      });
      const crests = rows.map((s) => (s.ssl.pedal_out || {}).crest_db);
      const spread = Math.max(...crests.filter(finite)) - Math.min(...crests.filter(finite));
      readout.appendChild(el("span", null,
        `at the same played peak, crest factor varies by <b>${spread.toFixed(1)} dB</b> across shapes`));
    }
    levelChoices.forEach((value) => {
      const button = el("button", null, value.toFixed(0));
      button.classList.toggle("active", value === level);
      button.onclick = () => {
        level = value;
        [...controls.querySelectorAll("button")].forEach((b) => b.classList.toggle("active", Number(b.textContent) === level));
        draw();
      };
      controls.appendChild(button);
    });
    host.appendChild(controls);
    host.appendChild(chartHost);
    host.appendChild(readout);
    draw();
  }

  // ---------------------------------------------------------------- E. meter accuracy

  function chartMeterAccuracy() {
    const anySamples = SEGMENTS.some((s) => s.pedal && s.pedal.capture);
    const host = card("7. Does the meter agree with the samples?",
      anySamples
        ? "The pedal records its own converter streams while the campaign runs, so the meter can be " +
          "checked against the audio it was measuring rather than against the Mac's idea of it. A " +
          "perfect meter lies on the 1:1 line: the RMS it reports for a window equals the RMS of " +
          "the frames in that window."
        : "No pedal recording was fetched for this run, so this comparison is missing. It is the run's " +
          "`engine.record` capture — see `campaign.py --pedal-record`.");

    if (!anySamples) return;
    const series = [
      { name: "nominal (1:1)", colour: "#6b7484", dash: "5 4", points: [[-100, -100], [0, 0]] },
      { name: "namchain input vs pedal capture", colour: PALETTE[0], markers: true,
        points: points(() => true, (s) => (s.pedal.capture || {}).rms_dbfs, (s) => (meterInput(s, 0) || {}).rms) },
      { name: "namchain output vs pedal playback", colour: PALETTE[1], markers: true,
        points: points(() => true, (s) => (s.pedal.playback || {}).rms_dbfs, (s) => (meterOutput(s, 0) || {}).rms) },
      { name: "peak: reported vs samples", colour: PALETTE[2], markers: true,
        points: points(() => true, (s) => (s.pedal.capture || {}).true_peak_dbfs, (s) => (meterInput(s, 0) || {}).peak) },
    ];
    line(host, { series, xLabel: "the pedal's own samples (dBFS)", yLabel: "what the meter reported (dBFS)",
      height: 440 });
  }

  function chartWindow() {
    const host = card("8. Window length, and what a meter can say",
      "`engine.levels` reports the window that just ended and empties it as it reads, so what a " +
      "client sees depends on how often it asks. Here the same segment is measured at the campaign's " +
      "poll rate and compared with the whole-body RMS from the samples: a fast poll and a slow one " +
      "disagree about peak (a peak is a maximum over a shorter window) and agree about RMS (energy " +
      "adds up), which is the difference a meter's ballistics has to hide.");
    const rows = SEGMENTS.filter((s) => s.pedal && s.pedal.capture && meterInput(s, 0))
      .map((s) => ({
        segment: s,
        reported: meterInput(s, 0).rms,
        samples: s.pedal.capture.rms_dbfs,
        peakReported: meterInput(s, 0).peak,
        peakSamples: s.pedal.capture.peak_dbfs,
        windows: meterInput(s, 0).windows,
        frames: meterInput(s, 0).frames,
      }));
    if (!rows.length) { host.appendChild(el("p", "note", "No meter windows and samples to compare.")); return; }
    const rmsErrors = rows.map((r) => r.reported - r.samples);
    const peakErrors = rows.map((r) => r.peakReported - r.peakSamples);
    const mean = (values) => values.reduce((a, b) => a + b, 0) / values.length;
    const worst = (values) => values.reduce((a, b) => (Math.abs(b) > Math.abs(a) ? b : a), 0);
    const kv = el("div", "kv");
    const put = (label, value) => { kv.appendChild(el("div", null, label)); kv.appendChild(el("div", null, value)); };
    put("segments compared", String(rows.length));
    put("mean RMS error (reported − samples)", mean(rmsErrors).toFixed(2) + " dB");
    put("worst RMS error", worst(rmsErrors).toFixed(2) + " dB");
    put("mean peak error", mean(peakErrors).toFixed(2) + " dB");
    put("worst peak error", worst(peakErrors).toFixed(2) + " dB");
    put("median window", Math.round(mean(rows.map((r) => r.frames))) + " frames");
    host.appendChild(kv);
  }

  // ---------------------------------------------------------------- F. the scale

  function chartScale() {
    const calibration = DATA.calibration || {};
    const host = card("9. A scale a player can read",
      "The engine's numbers are dBFS, which is the right unit inside the engine and the wrong one " +
      "at the jack: a player wants to know how hot the signal is against the pedal's own limits, " +
      "and how loud it will sound. This chart puts the measured calibration on one axis — where the " +
      "pedal's input clips, where its noise floor is, where the interface's line level sits — so a " +
      "meter scale can be chosen rather than guessed.");

    const rows = [];
    const add = (label, value, colour, note, dim) => {
      if (finite(value)) rows.push({ label, value, colour, note, dim });
    };
    add("pedal input clipping (measured)", calibration.input_clip_dbfs, "#ff7a7a", "where input.clipped starts");
    add("guitar nominal (design target)", calibration.nominal_dbfs, "#5ed39a", "+4 dBu line nominal, if the input is line");
    add("pedal input noise floor", calibration.input_floor_dbfs, "#8b93a1", "A-weighted, input terminated", true);
    add("interface line out at 0 dBFS", calibration.ssl_line_out_dbfs, "#4da3ff", "the SSL's own ADC reading of it");
    add("SSL in 1 noise floor", calibration.ssl_floor_dbfs, "#8b93a1", "nothing connected", true);
    add("pedal output clipping (measured)", calibration.output_clip_dbfs, "#ff7a7a");
    ladder(host, {
      rows, xUnit: " dBFS", xDomain: [-110, 6],
      references: [
        { x: 0, label: "0 dBFS", colour: "#ff7a7a" },
        { x: -18, label: "−18 dBFS (a common nominal)", colour: "#6b7484" },
      ],
    });

    const table = el("div", "kv");
    const put = (label, value) => { if (value !== undefined && value !== null) { table.appendChild(el("div", null, label)); table.appendChild(el("div", null, value)); } };
    put("interface line out → analogue loopback", round(calibration.loopback_transfer_db) + " dB");
    put("interface analogue loopback noise floor", round(calibration.loopback_floor_dbfs) + " dBFS");
    put("pedal input gain (its ADC reading − the SSL's)", round(calibration.pedal_input_offset_db) + " dB");
    put("pedal output gain (SSL reading − the pedal's DAC)", round(calibration.pedal_output_offset_db) + " dB");
    put("0 dBFS at the pedal's input ≈", calibration.input_full_scale_dbu !== null && calibration.input_full_scale_dbu !== undefined ? round(calibration.input_full_scale_dbu, 1) + " dBu (pinned by the SSL's published maxima)" : null);
    put("0 dBFS at the pedal's output ≈", calibration.output_full_scale_dbu !== null && calibration.output_full_scale_dbu !== undefined ? round(calibration.output_full_scale_dbu, 1) + " dBu" : null);
    host.appendChild(table);
  }

  // ---------------------------------------------------------------- G. the numbers

  function chartTable() {
    const host = card("10. Every segment",
      "The run's raw numbers: what was played, what the SSL's three inputs read, what the engine " +
      "reported, and what the pedal's own converters carried. `namchain in` and `namchain out` are " +
      "the engine's RMS over the campaign's poll windows; `pedal cap` and `pedal pb` are the same " +
      "signals measured from the pedal's own recording.");
    const columns = [
      { label: "shape", get: (s) => s.shape },
      { label: "played peak", get: (s) => round(s.played.peak_dbfs, 1) },
      { label: "played RMS", get: (s) => round(s.played.rms_dbfs, 1) },
      { label: "SSL loop RMS", get: (s) => round((s.ssl.loopback_analogue || {}).rms_dbfs, 1) },
      { label: "namchain in", get: (s) => round((meterInput(s, 0) || {}).rms, 1) },
      { label: "namchain in peak", get: (s) => round((meterInput(s, 0) || {}).peak, 1) },
      { label: "clipped", get: (s) => (meterInput(s, 0) || {}).clipped },
      { label: "pedal cap", get: (s) => round((s.pedal.capture || {}).rms_dbfs, 1) },
      { label: "chain out", get: (s) => round(((chain(s, 0) || {}).out || {}).rms, 1) },
      { label: "namchain out", get: (s) => round((meterOutput(s, 0) || {}).rms, 1) },
      { label: "pedal pb", get: (s) => round((s.pedal.playback || {}).rms_dbfs, 1) },
      { label: "SSL in 1", get: (s) => round((s.ssl.pedal_out || {}).rms_dbfs, 1) },
      { label: "SSL in 1 LUFS", get: (s) => round((s.ssl.pedal_out || {}).lufs, 1) },
      { label: "crest", get: (s) => round((s.ssl.pedal_out || {}).crest_db, 1) },
    ];
    table(host, columns, SEGMENTS);
  }

  // ---------------------------------------------------------------- build

  header();
  chartLadder();
  chartTransfer();
  chartResidual();
  chartNodes();
  chartNodeArithmetic();
  chartOutput();
  chartShapeScales();
  chartMeterAccuracy();
  chartWindow();
  chartScale();
  chartTable();
})();
