// report.js — fetch report.json (built by scripts/build_report.py), render the
// dashboard with ECharts. Pure-charts: no duckdb-wasm, no SQL console.
// Serve with `python3 -m http.server -d experiments/report 8000`.

const $ = (id) => document.getElementById(id);
const status = (msg) => { $("status").textContent = msg; };

const REGIME_ORDER = ["small", "mid", "large"];
const fmt = (x) => (x == null ? "—" : Number(x).toFixed(3));

// One ECharts instance per rendered chart; kept for resize.
const charts = [];
window.addEventListener("resize", () => charts.forEach((c) => c.resize()));

function makeChart(el) {
  const c = echarts.init(el, null, { renderer: "canvas" });
  charts.push(c);
  return c;
}

// ---- palette / cell colors ----
// Stable color per cell name (hash -> hue). Keeps a cell the same color across charts.
function cellColor(cell) {
  let h = 0;
  for (let i = 0; i < cell.length; i++) h = (h * 31 + cell.charCodeAt(i)) >>> 0;
  return `hsl(${h % 360} 65% 60%)`;
}

// ---- meta strip ----
function renderMeta(m) {
  $("meta").innerHTML = [
    `<span><b>host</b> <code>${m.machine_id ?? "?"}</code></span>`,
    `<span><b>ceiling</b> <code>${m.streaming_bw_gbs ?? "?"} GB/s</code></span>`,
    `<span><b>runs</b> ${m.n_runs}</span>`,
    `<span><b>cells</b> ${m.n_cells}</span>`,
    `<span><b>layouts</b> ${m.layouts.join(", ")}</span>`,
  ].join(" · ");
}

// ---- champion heatmap (one per layout) ----
function renderChampions(data) {
  const root = $("champions");
  root.innerHTML = "";
  for (const layout of data.meta.layouts) {
    const rows = data.champions.filter((r) => r.layout === layout);
    if (!rows.length) continue;
    const deaths = [...new Set(rows.map((r) => r.death_q))].sort((a, b) => a - b);
    const regimes = REGIME_ORDER.filter((rg) => rows.some((r) => r.regime === rg));
    const heat = [];
    let vmin = Infinity, vmax = -Infinity;
    rows.forEach((r) => {
      const xi = deaths.indexOf(r.death_q);
      const yi = regimes.indexOf(r.regime);
      heat.push([xi, yi, r.ns_particle, r.cell, r.achieved_bw_gbs]);
      if (r.ns_particle < vmin) vmin = r.ns_particle;
      if (r.ns_particle > vmax) vmax = r.ns_particle;
    });
    const card = document.createElement("div");
    card.className = "card";
    card.innerHTML = `<h3>${layout}</h3><div class="chart"></div>`;
    root.appendChild(card);
    const el = card.querySelector(".chart");
    const c = makeChart(el);
    c.setOption({
      tooltip: {
        formatter: (p) => {
          const [, , ns, cell, bw] = p.value;
          return `<b>${cell}</b><br/>regime ${regimes[p.value[1]]} · death ${deaths[p.value[0]]}<br/>${fmt(ns)} ns/p · ${bw ?? "?"} GB/s`;
        },
      },
      grid: { left: 70, right: 30, top: 30, bottom: 50, containLabel: true },
      xAxis: {
        type: "category", data: deaths.map(String), name: "death q",
        nameLocation: "middle", nameGap: 30, splitArea: { show: true },
      },
      yAxis: {
        type: "category", data: regimes, name: "regime",
        nameLocation: "middle", nameGap: 40, splitArea: { show: true },
      },
      visualMap: {
        min: vmin, max: vmax, calculable: true, orient: "horizontal",
        left: "center", bottom: 0,
        inRange: { color: ["#2ecc71", "#f1c40f", "#e67e22", "#e74c3c"] },
        textStyle: { color: "#ccc" },
      },
      series: [{
        name: "ns/particle", type: "heatmap", data: heat,
        label: {
          show: true,
          formatter: (p) => p.value[3].replace(/^[^.]+\./, "").slice(0, 18),
          color: "#111", fontSize: 9,
        },
        emphasis: { itemStyle: { borderColor: "#fff", borderWidth: 2 } },
      }],
    });
  }
}

// ---- performance landscape: faceted small multiples, one per death_q ----
function renderLandscape(data) {
  const root = $("landscape");
  root.innerHTML = "";
  const layout = data.meta.layouts[0]; // single-layout for now
  const rows = data.landscape;
  if (!rows.length) return;
  const deaths = data.meta.death_rates;
  const cells = [...new Set(rows.map((r) => r.cell))];
  const nValues = data.meta.n_values;
  for (const q of deaths) {
    const card = document.createElement("div");
    card.className = "facet";
    card.innerHTML = `<h4>death q = ${q}</h4><div class="chart small"></div>`;
    root.appendChild(card);
    const el = card.querySelector(".chart");
    const c = makeChart(el);
    const series = cells.map((cell) => ({
      name: cell, type: "line", smooth: false, symbol: "circle", symbolSize: 4,
      lineStyle: { width: 1.5, color: cellColor(cell) },
      itemStyle: { color: cellColor(cell) },
      data: nValues.map((N) => {
        const r = rows.find((x) => x.cell === cell && x.death_q === q && x.N === N);
        return r ? [N, r.ns_particle] : null;
      }).filter(Boolean),
    }));
    c.setOption({
      backgroundColor: "transparent",
      tooltip: { trigger: "axis", axisPointer: { type: "line" } },
      legend: { type: "scroll", bottom: 0, textStyle: { color: "#ccc", fontSize: 9 },
        inactiveColor: "#555", pageIconColor: "#aaa", pageTextStyle: { color: "#aaa" } },
      grid: { left: 50, right: 16, top: 20, bottom: 60, containLabel: true },
      xAxis: { type: "log", name: "N", nameTextStyle: { color: "#aaa" },
        axisLine: { lineStyle: { color: "#666" } },
        axisLabel: { color: "#aaa", formatter: (v) => v >= 1e6 ? `${v/1e6}M` : v >= 1e3 ? `${v/1e3}K` : v } },
      yAxis: { type: "value", name: "ns/particle", nameTextStyle: { color: "#aaa" },
        axisLine: { lineStyle: { color: "#666" } }, axisLabel: { color: "#aaa" },
        splitLine: { lineStyle: { color: "#333" } } },
      series,
    });
  }
}

// ---- achieved vs ceiling bandwidth ----
function renderBandwidth(data) {
  const root = $("bandwidth");
  root.innerHTML = "";
  const rows = data.bandwidth;
  if (!rows.length) return;
  const cells = [...new Set(rows.map((r) => r.cell))];
  const nValues = data.meta.n_values;
  const ceiling = data.meta.streaming_bw_gbs;
  const card = document.createElement("div");
  card.className = "card";
  card.innerHTML = `<div class="chart"></div>`;
  root.appendChild(card);
  const el = card.querySelector(".chart");
  const c = makeChart(el);
  const series = cells.map((cell) => ({
    name: cell, type: "line", smooth: false, symbol: "circle", symbolSize: 4,
    lineStyle: { width: 1.5, color: cellColor(cell) },
    itemStyle: { color: cellColor(cell) },
    data: nValues.map((N) => {
      const r = rows.find((x) => x.cell === cell && x.N === N);
      return r ? [N, r.achieved_bw_gbs] : null;
    }).filter(Boolean),
  }));
  const markLine = ceiling != null ? [{
    symbol: "none", lineStyle: { type: "dashed", color: "#e74c3c", width: 2 },
    label: { formatter: `ceiling ${ceiling} GB/s`, color: "#e74c3c", position: "insideEndTop" },
    yAxis: ceiling,
  }] : [];
  c.setOption({
    tooltip: { trigger: "axis", axisPointer: { type: "line" } },
    legend: { type: "scroll", bottom: 0, textStyle: { color: "#ccc", fontSize: 10 },
      inactiveColor: "#555" },
    grid: { left: 60, right: 24, top: 20, bottom: 70, containLabel: true },
    xAxis: { type: "log", name: "N", nameTextStyle: { color: "#aaa" },
      axisLine: { lineStyle: { color: "#666" } },
      axisLabel: { color: "#aaa", formatter: (v) => v >= 1e6 ? `${v/1e6}M` : v >= 1e3 ? `${v/1e3}K` : v } },
    yAxis: { type: "value", name: "GB/s", nameTextStyle: { color: "#aaa" },
      axisLine: { lineStyle: { color: "#666" } }, axisLabel: { color: "#aaa" },
      splitLine: { lineStyle: { color: "#333" } } },
    series: series.map((s) => ({ ...s, markLine: { silent: true, symbol: ["none","none"], data: markLine } })),
  });
}

// ---- PMC stacked bars ----
function renderPmc(data) {
  if (!data.pmc) { $("pmc-section").hidden = true; return; }
  $("pmc-section").hidden = false;
  const root = $("pmc");
  root.innerHTML = "";
  const rows = data.pmc;
  const cells = [...new Set(rows.map((r) => r.cell))];
  const card = document.createElement("div");
  card.className = "card";
  card.innerHTML = `<div class="chart"></div>`;
  root.appendChild(card);
  const el = card.querySelector(".chart");
  const c = makeChart(el);
  const cats = cells;
  const pick = (cell, key) => {
    const r = rows.find((x) => x.cell === cell);
    return r ? r[key] : 0;
  };
  c.setOption({
    tooltip: { trigger: "axis", axisPointer: { type: "shadow" } },
    legend: { bottom: 0, textStyle: { color: "#ccc" } },
    grid: { left: 50, right: 24, top: 20, bottom: 60, containLabel: true },
    xAxis: { type: "category", data: cats,
      axisLabel: { color: "#aaa", interval: 0, rotate: 30, fontSize: 9,
        formatter: (v) => v.replace(/^[^.]+\./, "") },
      axisLine: { lineStyle: { color: "#666" } } },
    yAxis: { type: "value", name: "% cycles", nameTextStyle: { color: "#aaa" },
      axisLine: { lineStyle: { color: "#666" } }, axisLabel: { color: "#aaa" },
      splitLine: { lineStyle: { color: "#333" } } },
    series: [
      ["useful_pct", "#2ecc71"], ["processing_pct", "#f1c40f"],
      ["delivery_pct", "#e67e22"], ["discarded_pct", "#e74c3c"],
    ].map(([key, color]) => ({
      name: key.replace("_pct", ""), type: "bar", stack: "cyc", color,
      data: cells.map((cell) => pick(cell, key)),
    })),
  });
}

// ---- invariant checks: status strip ----
function renderChecks(data) {
  if (!data.checks) { $("checks-section").hidden = true; return; }
  $("checks-section").hidden = false;
  const rows = data.checks;
  const root = $("checks");
  root.innerHTML = "";
  const byCell = {};
  for (const r of rows) {
    (byCell[r.cell] ??= []).push(r);
  }
  for (const [cell, rs] of Object.entries(byCell)) {
    const allPass = rs.every((r) => r.checked === "PASS");
    const chip = document.createElement("div");
    chip.className = `chip ${allPass ? "pass" : "fail"}`;
    chip.title = rs.map((r) => `q=${r.death_q}: ${r.checked}`).join("\n");
    chip.textContent = cell.replace(/^[^.]+\./, "");
    root.appendChild(chip);
  }
}

(async () => {
  try {
    status("fetching report.json…");
    const data = await fetch("report.json").then((r) => r.json());
    renderMeta(data.meta);
    status("rendering…");
    renderChampions(data);
    renderLandscape(data);
    renderBandwidth(data);
    renderPmc(data);
    renderChecks(data);
    status(`loaded ${data.meta.n_runs} runs across ${data.meta.n_cells} cells.`);
  } catch (e) {
    status(`error: ${e.message}`);
    console.error(e);
  }
})();
