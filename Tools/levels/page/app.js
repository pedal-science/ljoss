/* app.js — the campaign's graphs, drawn from window.DATA with no dependencies.
 *
 * Three renderers, because the campaign has three kinds of question:
 *   line(host, spec)   how a number moves as the input level moves (transfer curves, loudness,
 *                      node levels, meter accuracy);
 *   bars(host, spec)   several measures of the *same* signal side by side (which scale says what);
 *   ladder(host, spec) where the level is at each stage of one signal, hot at the top.
 *
 * Every chart is an SVG built from a small spec, so a new question is a new spec rather than a new
 * library. Tooltips are shared: one div, positioned per chart on hover.
 */
(function () {
  "use strict";

  const PALETTE = ["#4da3ff", "#5ed39a", "#ffcc66", "#ff7a7a", "#c58cff",
                   "#66d9e8", "#f2a65a", "#a0e060", "#e07ab0", "#8fa3b8"];
  const COLOUR = { grid: "#2b3038", axis: "#4a515c", text: "#c9cfd8", dim: "#8b93a1" };

  const tooltip = document.createElement("div");
  tooltip.className = "tooltip";
  document.addEventListener("DOMContentLoaded", () => document.body.appendChild(tooltip));

  function svgElement(name, attributes) {
    const element = document.createElementNS("http://www.w3.org/2000/svg", name);
    for (const key in attributes) element.setAttribute(key, attributes[key]);
    return element;
  }

  function niceTicks(min, max, count) {
    if (!isFinite(min) || !isFinite(max) || min === max) return [min];
    const span = max - min;
    const raw = span / Math.max(1, count);
    const magnitude = Math.pow(10, Math.floor(Math.log10(raw)));
    const candidates = [1, 2, 2.5, 5, 10].map((m) => m * magnitude);
    const step = candidates.find((c) => c >= raw) || candidates[candidates.length - 1];
    const first = Math.ceil(min / step) * step;
    const ticks = [];
    for (let value = first; value <= max + step * 1e-6; value += step) {
      ticks.push(Math.abs(value) < step * 1e-6 ? 0 : value);
    }
    return ticks;
  }

  function formatTick(value, digits) {
    if (value === 0) return "0";
    const magnitude = Math.abs(value);
    if (magnitude >= 1000 || magnitude < 0.01) return value.toExponential(1);
    let places = digits;
    if (places === undefined) places = magnitude < 10 ? 2 : magnitude < 100 ? 1 : 0;
    return Number(value.toFixed(places)).toString();
  }

  function extent(values) {
    let min = Infinity, max = -Infinity;
    for (const value of values) {
      if (value === null || value === undefined || !isFinite(value)) continue;
      if (value < min) min = value;
      if (value > max) max = value;
    }
    if (min === Infinity) return [0, 1];
    if (min === max) return [min - 1, max + 1];
    return [min, max];
  }

  // ---------------------------------------------------------------- line charts

  function line(host, spec) {
    const width = 900, height = spec.height || 420;
    const margin = { top: 28, right: spec.rightMargin || 200, bottom: 52, left: 66 };
    const plotWidth = width - margin.left - margin.right;
    const plotHeight = height - margin.top - margin.bottom;

    const allX = [], allY = [];
    for (const series of spec.series) {
      for (const point of series.points) {
        if (point[0] === null || point[1] === null) continue;
        allX.push(spec.logX ? Math.log10(point[0]) : point[0]);
        allY.push(point[1]);
      }
    }
    let [xMin, xMax] = spec.xDomain || extent(allX);
    if (spec.logX) { xMin = Math.log10(xMin); xMax = Math.log10(xMax); }
    let [yMin, yMax] = spec.yDomain || extent(allY);
    const pad = (yMax - yMin) * 0.08 || 1;
    yMin -= pad; yMax += pad;

    const xOf = (value) => margin.left + ((spec.logX ? Math.log10(value) : value) - xMin) / (xMax - xMin) * plotWidth;
    const yOf = (value) => margin.top + plotHeight - (value - yMin) / (yMax - yMin) * plotHeight;

    const svg = svgElement("svg", { viewBox: `0 0 ${width} ${height}`, class: "chart" });

    for (const tick of niceTicks(yMin, yMax, 6)) {
      const y = yOf(tick);
      svg.appendChild(svgElement("line", { x1: margin.left, x2: margin.left + plotWidth, y1: y, y2: y, stroke: COLOUR.grid }));
      const label = svgElement("text", { x: margin.left - 8, y: y + 4, "text-anchor": "end", fill: COLOUR.dim, "font-size": 11 });
      label.textContent = formatTick(tick) + (spec.yUnit || "");
      svg.appendChild(label);
    }
    const xTicks = spec.logX
      ? niceTicks(xMin, xMax, 7).map((v) => Math.pow(10, v))
      : niceTicks(xMin, xMax, 7);
    for (const tick of xTicks) {
      const x = xOf(tick);
      if (x < margin.left - 1 || x > margin.left + plotWidth + 1) continue;
      svg.appendChild(svgElement("line", { x1: x, x2: x, y1: margin.top, y2: margin.top + plotHeight, stroke: COLOUR.grid }));
      const label = svgElement("text", { x, y: margin.top + plotHeight + 18, "text-anchor": "middle", fill: COLOUR.dim, "font-size": 11 });
      label.textContent = formatTick(tick, spec.xDigits);
      svg.appendChild(label);
    }
    svg.appendChild(svgElement("line", { x1: margin.left, x2: margin.left + plotWidth, y1: margin.top + plotHeight, y2: margin.top + plotHeight, stroke: COLOUR.axis }));
    svg.appendChild(svgElement("line", { x1: margin.left, x2: margin.left, y1: margin.top, y2: margin.top + plotHeight, stroke: COLOUR.axis }));

    const xLabel = svgElement("text", { x: margin.left + plotWidth / 2, y: height - 10, "text-anchor": "middle", fill: COLOUR.text, "font-size": 12 });
    xLabel.textContent = spec.xLabel || "";
    svg.appendChild(xLabel);
    if (spec.yLabel) {
      const yLabel = svgElement("text", { x: 14, y: margin.top + plotHeight / 2, "text-anchor": "middle", fill: COLOUR.text, "font-size": 12, transform: `rotate(-90 14 ${margin.top + plotHeight / 2})` });
      yLabel.textContent = spec.yLabel;
      svg.appendChild(yLabel);
    }

    for (const reference of spec.references || []) {
      const y = yOf(reference.y);
      if (y < margin.top || y > margin.top + plotHeight) continue;
      svg.appendChild(svgElement("line", { x1: margin.left, x2: margin.left + plotWidth, y1: y, y2: y, stroke: reference.colour || "#5a6472", "stroke-dasharray": "5 4", "stroke-width": 1 }));
      const label = svgElement("text", { x: margin.left + plotWidth - 4, y: y - 5, "text-anchor": "end", fill: reference.colour || COLOUR.dim, "font-size": 10 });
      label.textContent = reference.label;
      svg.appendChild(label);
    }

    const legend = svgElement("g", {});
    spec.series.forEach((series, index) => {
      const colour = series.colour || PALETTE[index % PALETTE.length];
      const points = series.points.filter((p) => p[1] !== null && p[1] !== undefined && isFinite(p[1]));
      if (!points.length) return;
      const path = points.map((p, i) => `${i ? "L" : "M"}${xOf(p[0]).toFixed(1)},${yOf(p[1]).toFixed(1)}`).join(" ");
      svg.appendChild(svgElement("path", { d: path, fill: "none", stroke: colour, "stroke-width": series.width || 2, "stroke-dasharray": series.dash || "none", opacity: series.opacity || 1 }));
      if (series.markers) {
        for (const p of points) {
          svg.appendChild(svgElement("circle", { cx: xOf(p[0]), cy: yOf(p[1]), r: series.markerRadius || 3, fill: colour }));
        }
      }
      const entry = svgElement("g", { class: "legend-entry", style: "cursor:pointer" });
      const y = margin.top + 6 + index * 18;
      entry.appendChild(svgElement("line", { x1: margin.left + plotWidth + 14, x2: margin.left + plotWidth + 34, y1: y, y2: y, stroke: colour, "stroke-width": 3, "stroke-dasharray": series.dash || "none" }));
      const text = svgElement("text", { x: margin.left + plotWidth + 39, y: y + 4, fill: COLOUR.text, "font-size": 11 });
      text.textContent = series.name;
      entry.appendChild(text);
      svg.appendChild(entry);
    });

    const hover = svgElement("line", { x1: 0, x2: 0, y1: margin.top, y2: margin.top + plotHeight, stroke: "#7d8798", "stroke-dasharray": "3 3", opacity: 0 });
    svg.appendChild(hover);
    svg.addEventListener("mousemove", (event) => {
      const box = svg.getBoundingClientRect();
      const px = (event.clientX - box.left) / box.width * width;
      const value = xMin + (px - margin.left) / plotWidth * (xMax - xMin);
      const x = spec.logX ? Math.pow(10, value) : value;
      hover.setAttribute("x1", px); hover.setAttribute("x2", px); hover.setAttribute("opacity", 1);
      const rows = spec.series.map((series, index) => {
        let best = null;
        for (const point of series.points) {
          if (point[1] === null || !isFinite(point[1])) continue;
          const distance = Math.abs(Math.log10(point[0]) - Math.log10(x));
          if (!best || distance < best.distance) best = { distance, point };
        }
        if (!best) return null;
        return `<div><span class="dot" style="background:${series.colour || PALETTE[index % PALETTE.length]}"></span>${series.name}: <b>${best.point[1].toFixed(2)}</b></div>`;
      }).filter(Boolean).join("");
      tooltip.innerHTML = `<div class="tip-head">${spec.xLabel || ""} ${formatTick(x, spec.xDigits)}</div>${rows}`;
      tooltip.style.opacity = 1;
      tooltip.style.left = Math.min(event.clientX + 14, window.innerWidth - 260) + "px";
      tooltip.style.top = (event.clientY + 14) + "px";
    });
    svg.addEventListener("mouseleave", () => { tooltip.style.opacity = 0; hover.setAttribute("opacity", 0); });

    host.appendChild(svg);
  }

  // ---------------------------------------------------------------- bar charts

  function bars(host, spec) {
    const width = 900, height = spec.height || 380;
    const margin = { top: 28, right: 150, bottom: 60, left: 66 };
    const plotWidth = width - margin.left - margin.right;
    const plotHeight = height - margin.top - margin.bottom;
    const values = spec.series.flatMap((s) => s.values.filter((v) => v !== null && isFinite(v)));
    let [yMin, yMax] = spec.yDomain || extent(values);
    const pad = (yMax - yMin) * 0.08 || 1;
    yMin -= pad; yMax += pad;
    const yOf = (value) => margin.top + plotHeight - (value - yMin) / (yMax - yMin) * plotHeight;

    const svg = svgElement("svg", { viewBox: `0 0 ${width} ${height}`, class: "chart" });
    for (const tick of niceTicks(yMin, yMax, 6)) {
      const y = yOf(tick);
      svg.appendChild(svgElement("line", { x1: margin.left, x2: margin.left + plotWidth, y1: y, y2: y, stroke: COLOUR.grid }));
      const label = svgElement("text", { x: margin.left - 8, y: y + 4, "text-anchor": "end", fill: COLOUR.dim, "font-size": 11 });
      label.textContent = formatTick(tick) + (spec.yUnit || "");
      svg.appendChild(label);
    }
    const groupWidth = plotWidth / spec.categories.length;
    const barWidth = Math.min(38, (groupWidth - 12) / spec.series.length);
    spec.categories.forEach((category, index) => {
      const centre = margin.left + groupWidth * (index + 0.5);
      spec.series.forEach((series, s) => {
        const value = series.values[index];
        if (value === null || !isFinite(value)) return;
        const x = centre - (spec.series.length * barWidth) / 2 + s * barWidth;
        const y = yOf(value);
        const zero = yOf(Math.max(yMin, 0));
        const rect = svgElement("rect", {
          x, y: Math.min(y, zero), width: barWidth - 3, height: Math.abs(zero - y),
          fill: series.colour || PALETTE[s % PALETTE.length], rx: 2,
        });
        rect.addEventListener("mouseenter", (event) => {
          tooltip.innerHTML = `<div class="tip-head">${category}</div><div><span class="dot" style="background:${series.colour || PALETTE[s % PALETTE.length]}"></span>${series.name}: <b>${value.toFixed(2)}</b></div>`;
          tooltip.style.opacity = 1;
          tooltip.style.left = (event.clientX + 14) + "px";
          tooltip.style.top = (event.clientY + 14) + "px";
        });
        rect.addEventListener("mouseleave", () => { tooltip.style.opacity = 0; });
        svg.appendChild(rect);
      });
      const label = svgElement("text", { x: centre, y: margin.top + plotHeight + 18, "text-anchor": "middle", fill: COLOUR.text, "font-size": 11 });
      label.textContent = category;
      svg.appendChild(label);
    });
    svg.appendChild(svgElement("line", { x1: margin.left, x2: margin.left + plotWidth, y1: margin.top + plotHeight, y2: margin.top + plotHeight, stroke: COLOUR.axis }));
    svg.appendChild(svgElement("line", { x1: margin.left, x2: margin.left, y1: margin.top, y2: margin.top + plotHeight, stroke: COLOUR.axis }));
    if (spec.yLabel) {
      const yLabel = svgElement("text", { x: 14, y: margin.top + plotHeight / 2, "text-anchor": "middle", fill: COLOUR.text, "font-size": 12, transform: `rotate(-90 14 ${margin.top + plotHeight / 2})` });
      yLabel.textContent = spec.yLabel;
      svg.appendChild(yLabel);
    }
    spec.series.forEach((series, index) => {
      const y = margin.top + 6 + index * 18;
      svg.appendChild(svgElement("rect", { x: margin.left + plotWidth + 14, y: y - 8, width: 12, height: 12, fill: series.colour || PALETTE[index % PALETTE.length], rx: 2 }));
      const text = svgElement("text", { x: margin.left + plotWidth + 32, y: y + 3, fill: COLOUR.text, "font-size": 11 });
      text.textContent = series.name;
      svg.appendChild(text);
    });
    host.appendChild(svg);
  }

  // ---------------------------------------------------------------- ladders

  function ladder(host, spec) {
    const rows = spec.rows;
    const width = 900;
    const rowHeight = 30;
    const height = rows.length * rowHeight + 66;
    const margin = { top: 30, right: 130, bottom: 36, left: 210 };
    const plotWidth = width - margin.left - margin.right;
    const values = rows.map((r) => r.value).filter((v) => v !== null && isFinite(v));
    let [xMin, xMax] = spec.xDomain || extent(values);
    if (spec.xDomain) { xMin = spec.xDomain[0]; xMax = spec.xDomain[1]; }
    const xOf = (value) => margin.left + (value - xMin) / (xMax - xMin) * plotWidth;

    const svg = svgElement("svg", { viewBox: `0 0 ${width} ${height}`, class: "chart" });
    for (const tick of niceTicks(xMin, xMax, 8)) {
      const x = xOf(tick);
      svg.appendChild(svgElement("line", { x1: x, x2: x, y1: margin.top - 10, y2: margin.top + rows.length * rowHeight, stroke: COLOUR.grid }));
      const label = svgElement("text", { x, y: height - 14, "text-anchor": "middle", fill: COLOUR.dim, "font-size": 11 });
      label.textContent = formatTick(tick) + (spec.xUnit || "");
      svg.appendChild(label);
    }
    for (const reference of spec.references || []) {
      const x = xOf(reference.x);
      svg.appendChild(svgElement("line", { x1: x, x2: x, y1: margin.top - 10, y2: margin.top + rows.length * rowHeight, stroke: reference.colour || "#6b7484", "stroke-dasharray": "4 4" }));
      const label = svgElement("text", { x: x + 4, y: margin.top - 16, fill: reference.colour || COLOUR.dim, "font-size": 10 });
      label.textContent = reference.label;
      svg.appendChild(label);
    }
    rows.forEach((row, index) => {
      const y = margin.top + index * rowHeight + rowHeight / 2;
      const label = svgElement("text", { x: margin.left - 12, y: y + 4, "text-anchor": "end", fill: row.dim ? COLOUR.dim : COLOUR.text, "font-size": 12 });
      label.textContent = row.label;
      svg.appendChild(label);
      if (row.value === null || !isFinite(row.value)) return;
      // A value below the axis is not drawn as a bar outside the plot: it gets a stub at the left
      // edge, because "quieter than this scale shows" is the fact worth seeing.
      const below = row.value < xMin;
      const left = xOf(xMin);
      const right = below ? left + 3 : xOf(row.value);
      const bar = svgElement("rect", {
        x: left, y: y - 8, width: Math.max(2, right - left), height: 16,
        fill: row.colour || PALETTE[0], rx: 3, opacity: row.opacity || 0.9,
      });
      bar.addEventListener("mouseenter", (event) => {
        tooltip.innerHTML = `<div class="tip-head">${row.label}</div><div><b>${row.value.toFixed(2)}</b> ${spec.xUnit || ""}${row.note ? "<br><span class='dim'>" + row.note + "</span>" : ""}</div>`;
        tooltip.style.opacity = 1;
        tooltip.style.left = (event.clientX + 14) + "px";
        tooltip.style.top = (event.clientY + 14) + "px";
      });
      bar.addEventListener("mouseleave", () => { tooltip.style.opacity = 0; });
      svg.appendChild(bar);
      const text = svgElement("text", { x: (below ? left + 10 : xOf(row.value) + 8), y: y + 4, fill: below ? COLOUR.dim : COLOUR.text, "font-size": 11 });
      text.textContent = (below ? "< " + xMin.toFixed(0) + " (" + row.value.toFixed(1) + ")" : row.value.toFixed(1)) + (spec.xUnit || "");
      svg.appendChild(text);
    });
    host.appendChild(svg);
  }

  // ---------------------------------------------------------------- page

  function el(tag, className, html) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (html !== undefined) node.innerHTML = html;
    return node;
  }

  function section(title, note) {
    const wrapper = el("section", "card");
    wrapper.appendChild(el("h2", null, title));
    if (note) wrapper.appendChild(el("p", "note", note));
    return wrapper;
  }

  function table(host, columns, rows) {
    const html = [`<table><thead><tr>${columns.map((c) => `<th>${c.label}</th>`).join("")}</tr></thead><tbody>`];
    for (const row of rows) {
      html.push(`<tr>${columns.map((c) => `<td>${c.get(row)}</td>`).join("")}</tr>`);
    }
    html.push("</tbody></table>");
    const wrapper = el("div", "table-wrap", html.join(""));
    host.appendChild(wrapper);
  }

  window.Campaign = { line, bars, ladder, section, table, el, PALETTE, COLOUR };
})();
