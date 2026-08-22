// report.js — machine/thread-scoped SPA over experiments/analysis/.
// Routes: #/<machine>/ (overview) · #/<machine>/layout/<L> · #/<machine>/algorithm/<algorithm>
//         #/<machine>/rank/<N>/<q> · #/<machine>/compare/<A>+<B>[+<C>]
// Loads ECharts + marked. report-v2: reference-anchored algo page (naive
// baseline + per-point winner), split latency (memory floor) + bandwidth
// (ceiling) charts, bottleneck small-multiples + cycle bars, DWARF-attributed
// folded assembly viewer + loop digest, and the compare route.
const $ = (id) => document.getElementById(id);
const status = (m) => ($("status").textContent = m);
const short = (algo) => algo.split(".").slice(1).join(".");
const fmtq = (d) => (d === 0 ? "0" : String(d));
const fmtN = (n) => n >= 1e6 ? `${n / 1e6}M` : n >= 1e3 ? `${n / 1e3}K` : `${n}`;
const mhref = (path) => `#/${machine}/${path}`;  // machine-scoped hash link
const axisTooltip = { trigger: "axis", formatter(params) { const p = Array.isArray(params) ? params : [params]; const hdr = `<div style="text-align:center;margin-bottom:4px">${fmtN(Math.round(p[0].axisValue))} Particles</div>`; return hdr + p.map(x => { const name = x.seriesName.startsWith('q=') ? '' : x.seriesName + ': '; return `${x.marker} ${name}${x.value[1] != null ? x.value[1].toFixed(2) : '-'}`; }).join('<br/>'); } };
const charts = [];
window.addEventListener("resize", () => charts.forEach((c) => c.resize()));
const AX = { axisLine: { lineStyle: { color: "#666" } }, axisLabel: { color: "#aaa" },
             splitLine: { lineStyle: { color: "#2a2a2a" } }, nameTextStyle: { color: "#aaa" } };

let MACHINES, machine, threads = 1;

// ---- global q multi-select (header) ----
let qSel = [];        // selected death rates (strings); [] = all
let qAvail = [];      // numbers, from the machine's overview death_rates
let qRedraw = null;   // per-page redraw hook, fired on q change
let refSel = { naive: true, winner: true };   // refs shown at single-q; header refs dropdown (naive+winner)
// refs (naive baseline + best-of-grid winner) render only when exactly one
// q is selected — they compare "this algo vs the field at one death rate",
// which is meaningless averaged across multiple q's. The header refs
// dropdown toggles them globally (visible only at single-q).
// Consistent ref coding across ALL charts: naive = gray diamonds, winner =
// white diamonds (radar: gray/white polygons).
const REF_NAIVE = "#9aa", REF_WINNER = "#f0f0f0";
function buildRefsDrop() {
  const wrap = $("refwrap");
  if (!wrap) return;
  const single = activeQs().length === 1;
  wrap.style.display = single ? "" : "none";
  if (!single) { wrap.querySelector(".qdrop")?.classList.remove("open"); return; }
  const el = $("refdrop");
  const items = [["naive", "naive"], ["winner", "winner"]];
  const label = items.filter(([k]) => refSel[k]).map(([, l]) => l).join(", ") || "none";
  el.innerHTML = `<button type="button" class="qbtn" title="reference overlays: naive baseline + per-N winner">${label}</button>
    <div class="qdrop-menu">${items.map(([k, l]) =>
      `<div class="qdrop-item" data-ref="${k}" style="color:${k === "naive" ? REF_NAIVE : REF_WINNER}"><input type="checkbox" tabindex="-1" ${refSel[k] ? "checked" : ""}>${l}</div>`).join("")}</div>`;
  el.querySelector("button").onclick = (e) => { e.stopPropagation(); el.classList.toggle("open"); };
  el.querySelectorAll(".qdrop-item").forEach((it) => {
    it.onclick = (e) => {
      e.preventDefault(); e.stopPropagation();
      refSel[it.dataset.ref] = !refSel[it.dataset.ref];
      buildRefsDrop();
      el.classList.add("open");
      if (qRedraw) qRedraw();
    };
  });
}
function shortMachine(id) {
  // display name: name portion capped at 15 chars, hash suffix kept
  const m = String(id).match(/^(.*)-([0-9a-f]{8})$/);
  const name = m ? m[1] : String(id);
  const trunc = name.length > 15 ? name.slice(0, 14) + "…" : name;
  return m ? `${trunc}-${m[2]}` : trunc;
}
function activeQs() {
  if (!qAvail.length) return [];
  if (!qSel.length) return qAvail.map(String);
  return qAvail.map(String).filter((s) => qSel.includes(s));
}
function setQAvail(qs) {
  qAvail = qs.map(Number).sort((a, b) => a - b);
  const avail = qAvail.map(String);
  qSel = qSel.filter((s) => avail.includes(s));
  if (qSel.length === avail.length) qSel = [];   // all on = default state
  buildQDrop();
  buildRefsDrop();
}
function buildQDrop() {
  const el = $("qdrop");
  if (!el) return;
  const sel = activeQs();
  const all = !qSel.length;
  const pal = churnPalette(qAvail);
  const label = all ? "all" : sel.map((q) => fmtq(q)).join(", ");
  el.innerHTML = `<button type="button" class="qbtn" title="death-rate filter (multi-select)">${label}</button>
    <div class="qdrop-menu">${qAvail.map((q) => `<div class="qdrop-item" data-q="${q}"><span class="qdot" style="background:${pal(q)}"></span><input type="checkbox" tabindex="-1" ${all || qSel.includes(String(q)) ? "checked" : ""}>q=${fmtq(q)}</div>`).join("")}</div>`;
  el.querySelector("button").onclick = (e) => { e.stopPropagation(); el.classList.toggle("open"); };
  el.querySelectorAll(".qdrop-item").forEach((it) => {
    it.onclick = (e) => {
      e.preventDefault(); e.stopPropagation();
      const q = String(it.dataset.q);
      const cur = qSel.length ? qSel : qAvail.map(String);        // [] means all-checked
      const next = cur.includes(q) ? cur.filter((x) => x !== q) : [...cur, q];
      if (!next.length) return;                                    // keep ≥ 1 active
      qSel = next.length === qAvail.length ? [] : next;
      buildQDrop();
      buildRefsDrop();
      el.classList.add("open");
      if (qRedraw) qRedraw();
    };
  });
}
const ovCache = {}, layCache = {}, algoCache = {};
const REPORT_V = "v11";   // cache-bust key for SPA fetches — bump when bundle schemas change
const fetchJSON = (u) => fetch(`${u}?${REPORT_V}`).then((r) => r.ok ? r.json() : null);
const fetchText = (u) => fetch(`${u}?${REPORT_V}`).then((r) => r.ok ? r.text() : "");

function getOverview(m)   { return ovCache[m]   ?? (ovCache[m]   = fetchJSON(`analysis/${m}/overview.json`)); }
function getMemLayout(m, L)  { return layCache[m+L]?? (layCache[m+L]= fetchJSON(`analysis/${m}/${L}.mem_layout.json`)); }
function getAlgoJson(m, c){ const k=m+"/"+c; return algoCache[k] ?? (algoCache[k]= (async()=>{return fetchJSON(`analysis/${m}/${c}.json`);})()); }
const asmCache = {};
const getAlgoAsm = (m, c) => { const k=m+"/"+c; return asmCache[k] ?? (asmCache[k] = fetchJSON(`data/${m}/${c}.json`)); };
const gridCache = {};
const getGrid = (m) => gridCache[m] ?? (gridCache[m] = fetchJSON(`analysis/${m}/grid.json`));

const BASELINE = "ML01.AF02.LP1-scalar.LP2-simple";

function cellColor(algo) { let h = 0; for (let i = 0; i < algo.length; i++) h = (h * 31 + algo.charCodeAt(i)) >>> 0; return `hsl(${h % 360} 65% 62%)`; }
// The churn palette: one sequential green→red scale keyed by death-rate q,
// shared by the main chart, radar polygons, cycle bars, and ratio strip.
function churnPalette(qs) {
  const lo = Math.min(...qs), hi = Math.max(...qs);
  return (q) => {
    const t = hi === lo ? 0 : (q - lo) / (hi - lo);
    return `hsl(${145 - 137 * t} 62% ${58 - 8 * t}%)`;
  };
}
function pickThreads(rows) { const t = rows.filter((r) => r.threads === threads); return t.length ? t : rows.filter((r) => r.threads === 1); }

// ---- meta strip ----
function renderMeta(o) {
  $("meta").innerHTML = [
    `<span>${o.cpu ?? "?"}</span>`,
    `<span><b>Mem Bandwidth</b> <code>${o.streaming_bw_gbs ?? "?"} GB/s</code></span>`,
    `<span><b>Mem Cache</b> L1d <code>${(o.l1dcachesize / 1024) | 0} KB</code></span>`,
    `<span><b>Mem Cache</b> L2 <code>${(o.l2cachesize / 1048576) | 0} MB</code></span>`,
  ].join("<br>");
  if (Array.isArray(o.death_rates) && o.death_rates.length) setQAvail(o.death_rates);
  if (Array.isArray(o.thread_groups) && o.thread_groups.length) updateThreadsSel(o.thread_groups);
}
function updateThreadsSel(groups) {
  const ts = $("threads");
  if (!ts || ts.dataset.groups === groups.join(",")) return;
  ts.dataset.groups = groups.join(",");
  const cur = +ts.value;
  ts.innerHTML = "";
  groups.forEach((t) => { const o = document.createElement("option"); o.value = t; o.textContent = `T=${t}`; ts.add(o); });
  ts.value = groups.includes(cur) ? cur : groups[0];
  threads = +ts.value;
}

// ---- chart helper ----
function chart(id, opt, group) {
  const el = document.getElementById(id);
  if (!el) return null;
  const old = echarts.getInstanceByDom(el);          // redraws re-init, not merge
  if (old) { charts.splice(charts.indexOf(old), 1); old.dispose(); }
  const c = echarts.init(el); charts.push(c);
  if (group) { c.group = group; echarts.connect(group); }   // linked brush across plots in a group
  c.setOption(opt);
  return c;
}

// CPU topology row for the machine card. Cores/threads and cache SIZES are
// measured (hardware.json); L2/L3 sharing is arch-family knowledge (Zen:
// private L2 per core + L3 per CCD · Apple: L2 per cluster) — labeled as such.
// Pipeline/prefetch counters are NOT collected; stated honestly rather than guessed.
const csz = (b) => b >= 1048576 ? `${+(b / 1048576).toFixed(1).replace(/\.0$/, "")} MB` : `${Math.round(b / 1024)} KB`;
function cpuTopologyHtml(o) {
  const phys = o.physicalcpu, logi = o.logicalcpu;
  const smt = phys && logi && logi > phys ? ` (SMT ×${Math.round(logi / phys)})` : "";
  const apple = o.arch === "arm64" && (o.os || "").startsWith("Darwin");
  const zen = /ryzen|epyc/i.test(o.cpu || "");
  const cs = csz;
  const perCore = [`${cs(o.l1dcachesize)} L1d`, `${cs(o.l1icachesize)} L1i`];
  if (zen) perCore.push(`${cs(o.l2cachesize)} L2`);          // private on Zen
  const shared = [];
  if (apple) shared.push(`${cs(o.l2cachesize)} L2 (per cluster)`);
  if (zen && o.l3cachesize) shared.push(`${cs(o.l3cachesize)} L3 (per CCD)`);
  if (!apple && !zen && o.l3cachesize) shared.push(`${cs(o.l3cachesize)} L3`);
  return [
    `<div><b>CPU</b> ${phys ?? "?"} cores · ${logi ?? "?"} threads${smt}</div>`,
    `<div><b>Per core</b> ${perCore.join(" · ")}</div>`,
    shared.length ? `<div><b>Shared</b> ${shared.join(" · ")}</div>` : "",
    `<div><b>Line / page</b> ${o.cachelinesize} B line · ${(o.pagesize / 1024) | 0} KB page</div>`,
  ].filter(Boolean).join("");
}
async function machineCard() {
  const m = await getOverview(machine);
  if (!m || !m.cpu) return "";
  return `<section class="cellhead machinecard"><h2>${m.cpu}</h2><div class="machinfo">`
    + `<div><b>Mem Bandwidth</b> <code>${m.streaming_bw_gbs ?? "?"} GB/s</code></div>`
    + `<div><b>DRAM</b> <code>${(m.memsize_bytes / 1073741824) | 0} GB</code></div>`
    + `<div><b>Mem Cache</b> L1d <code>${csz(m.l1dcachesize)}</code> · L2 <code>${csz(m.l2cachesize)}</code>${m.l3cachesize ? ` · L3 <code>${csz(m.l3cachesize)}</code>` : ""}</div>`
    + cpuTopologyHtml(m)
    + `</div></section>`;
}
async function renderTopCard() { const el = $("topcard"); if (el) el.innerHTML = await machineCard(); }

// ---------------- overview ----------------
async function renderOverview() {
  const ov = await getOverview(machine);
  if (!ov) { status("no data"); return; }
  renderMeta(ov);
  const qOn = activeQs().map(Number);
  const champs = ov.champions.filter((c) => c.threads === threads && qOn.some((q) => Math.abs(c.death_q - q) < 1e-9));
  const w = champs.filter((c) => c.rk === 1);
  const ns = (w.length ? w : champs).map((c) => c.ns_particle);
  const lo = Math.min(...ns), hi = Math.max(...ns);
  const nvals = ov.n_values, deaths = ov.death_rates.filter((d) => qOn.some((q) => Math.abs(d - q) < 1e-9));
  const algo = (n, d, rk) => champs.find((c) => c.N === n && Math.abs(c.death_q - d) < 1e-9 && c.rk === rk);
  let html = `<section><h2>All Winners (top-3) <span class="sub">per num-particles × death · T=${threads}</span></h2>`;
  html += `<p class="hint">Green = faster. Click a name for the deep dive, or a box to rank all algorithms at that intersection.</p>`;
  html += `<table class="podium"><thead><tr><th>num-particles＼death</th>${deaths.map((d) => `<th>${fmtq(d)}</th>`).join("")}</tr></thead><tbody>`;
  for (const n of nvals) {
    html += `<tr><th>${fmtN(n)}</th>`;
    for (const d of deaths) {
      const top3 = [1, 2, 3].map((rk) => algo(n, d, rk)).filter(Boolean);
      const best = top3.length ? top3[0].ns_particle : null;
      const tint = best != null ? `hsla(${120 * (1 - Math.min(1, (best - lo) / (hi - lo)))},60%,45%,0.20)` : null;
      html += `<td${tint ? ` style="background:${tint}"` : ""} data-n="${n}" data-q="${d}">${
        top3.map((c) => `<div class="prow"><a href="${mhref('algorithm/' + c.algo)}">${short(c.algo)}</a><span class="n">${c.ns_particle.toFixed(2)}</span></div>`).join("") || "—"}</td>`;
    }
    html += `</tr>`;
  }
  html += `</tbody></table></section>`;
  $("page").innerHTML = html;
  status(`overview · ${ov.layouts.length} layout(s) · T=${threads}`);
}
async function renderOverviewQ() { qRedraw = renderOverview; await renderOverview(); }

// ---------------- layout ----------------
async function renderMemLayout(L) {
  const lb = await getMemLayout(machine, L);
  if (!lb) { status(`no bundle for ${L}`); return; }
  renderMeta((await getOverview(machine)) || lb);
  const champs = lb.champions.filter((c) => c.threads === threads);
  const w = champs.filter((c) => c.rk === 1);
  const ns = (w.length ? w : champs).map((c) => c.ns_particle);
  const lo = Math.min(...ns), hi = Math.max(...ns);
  const nvals = lb.n_values, deaths = lb.death_rates;
  const algo = (n, d, rk) => champs.find((c) => c.N === n && Math.abs(c.death_q - d) < 1e-9 && c.rk === rk);
  let podium = `<table class="podium"><thead><tr><th>num-particles＼death</th>${deaths.map((d) => `<th>${fmtq(d)}</th>`).join("")}</tr></thead><tbody>`;
  for (const n of nvals) {
    podium += `<tr><th>${fmtN(n)}</th>`;
    for (const d of deaths) {
      const top3 = [1, 2, 3].map((rk) => algo(n, d, rk)).filter(Boolean);
      const best = top3.length ? top3[0].ns_particle : null;
      const tint = best != null ? `hsla(${120 * (1 - Math.min(1, (best - lo) / (hi - lo)))},60%,45%,0.20)` : null;
      podium += `<td${tint ? ` style="background:${tint}"` : ""}>${top3.map((c) => `<div class="prow"><a href="${mhref('algorithm/' + c.algo)}">${short(c.algo)}</a><span class="n">${c.ns_particle.toFixed(2)}</span></div>`).join("") || "—"}</td>`;
    }
    podium += `</tr>`;
  }
  podium += `</tbody></table>`;
  const feat = lb.featured.map((f) => `<div class="feat"><a href="${mhref('algorithm/' + f.algo)}"><b>${short(f.algo)}</b> <span class="n">${f.ns} ns/p</span></a><div class="tease">${f.teaser}${f.teaser ? `…` : ""}</div></div>`).join("");
  const algos = lb.algos.map((c) => `<a class="celllink" href="${mhref('algorithm/' + c)}">${short(c)}</a>`).join(" ");
  $("page").innerHTML = `
    <section><h2>${L} <span class="sub">top-3 per num-particles × death · T=${threads}</span></h2>${podium}</section>
    <section><h3>Featured</h3>${feat || "<p class=hint>(no champions featured)</p>"}</section>
    <section><h3>All algorithms</h3><div class="cellrow">${algos}</div></section>
    <section><h3>Performance landscape <span class="sub">ns/p vs N · q=${lb.death_rates.includes(0.01) ? 0.01 : lb.death_rates[0]}</span></h3><div id="landscape" class="chart"></div></section>
    <section><h3>Achieved bandwidth vs ceiling</h3><div id="bandwidth" class="chart"></div></section>`;
  status(`${L} · ${lb.algos.length} algorithms · T=${threads}`);
  drawLandscape(lb);
  drawBandwidthMemLayout(lb);
}

async function drawLandscape(lb) {
  const q = lb.death_rates.includes(0.01) ? 0.01 : lb.death_rates[0];
  const js = (await Promise.all(lb.algos.map((c) => getAlgoJson(machine, c)))).filter(Boolean);
  const series = js.map((j) => ({
    name: short(j.algo), type: "line", symbol: "circle", symbolSize: 4,
    lineStyle: { width: 1.5, color: cellColor(j.algo) }, itemStyle: { color: cellColor(j.algo) },
    data: pickThreads(j.series[String(q)] || []).map((r) => [r.N, r.ns_particle]),
  }));
  chart("landscape", {
    tooltip: axisTooltip, legend: { type: "scroll", bottom: 0, textStyle: { color: "#ccc", fontSize: 9 } },
    grid: { left: 55, right: 20, top: 20, bottom: 70, containLabel: true },
    xAxis: { type: "log", name: "N", ...AX, axisLabel: { ...AX.axisLabel, formatter: (v) => v >= 1e6 ? `${v / 1e6}M` : v >= 1e3 ? `${v / 1e3}K` : v } },
    yAxis: { type: "value", name: "ns/particle", ...AX },
    series, dataZoom: [{ type: "slider", bottom: 28, height: 16 }],
  });
}

async function drawBandwidthMemLayout(lb) {
  const q = lb.death_rates.includes(0.01) ? 0.01 : lb.death_rates[0];
  const js = (await Promise.all(lb.algos.map((c) => getAlgoJson(machine, c)))).filter(Boolean);
  const series = js.map((j) => ({
    name: short(j.algo), type: "line", symbol: "none",
    lineStyle: { width: 1.5, color: cellColor(j.algo) }, itemStyle: { color: cellColor(j.algo) },
    data: pickThreads(j.series[String(q)] || []).map((r) => [r.N, r.achieved_bw_gbs]).filter((p) => p[1] != null),
  }));
  const ceil = lb.streaming_bw_gbs;
  chart("bandwidth", {
    tooltip: axisTooltip, legend: { type: "scroll", bottom: 0, textStyle: { color: "#ccc", fontSize: 9 } },
    grid: { left: 55, right: 20, top: 20, bottom: 70, containLabel: true },
    xAxis: { type: "log", name: "N", ...AX, axisLabel: { ...AX.axisLabel, formatter: (v) => v >= 1e6 ? `${v / 1e6}M` : v >= 1e3 ? `${v / 1e3}K` : v } },
    yAxis: { type: "value", name: "GB/s", ...AX },
    series: series.map((s, i) => i === 0 ? { ...s, markLine: { silent: true, symbol: "none", data: [{ yAxis: ceil, lineStyle: { type: "dashed", color: "#e74c3c", width: 2 }, label: { formatter: `ceiling ${ceil}`, color: "#e74c3c", position: "insideEndTop" } }] } } : s),
    dataZoom: [{ type: "slider", bottom: 28, height: 16 }],
  });
}

// ---------------- algorithm ----------------
const ALGO_FAMS = {
  AF01: [["Integrate", "Decide", "Respawn", "Render"], null, null],
  AF02: [["Integrate", "Decide", "Respawn"], ["Render"], null],
  AF03: [["Integrate", "Decide→mask"], ["scan mask", "Respawn", "Render"], null],
  AF04: [["Integrate"], ["Decide", "Respawn", "Render"], null],
  AF05: [["Integrate"], ["Decide", "Respawn"], ["Render"]],
  AF06: [["Integrate", "Decide→mask/list"], ["Respawn"], ["Render"]],
  AF07: [["Integrate"], ["Decide"], ["Respawn", "Render"]],
  AF08: [["Integrate"], ["Decide"], ["Respawn"], ["Render"]],
};
function loopSchedules(algo) {
  const algoPart = algo.split(".").slice(1).join(".");
  const segs = algoPart.split(/\.LP/);
  const SCHED = { autovec: "autovectorized", scalar: "scalar", blend: "branchless blend",
    halide: "Halide", opt: "optimized splat (r1)", simple: "simple splat (r0)",
    fused: "fused (math+render)", rmerge: "ranked-merge scan+respawn" };
  const out = {};
  for (let i = 1; i < segs.length; i++) {
    let seg = segs[i], par = "";
    if (seg.endsWith("-par")) { par = " · data-parallel"; seg = seg.slice(0, -4); }
    const dash = seg.indexOf("-"), num = seg.slice(0, dash), tok = seg.slice(dash + 1);
    out[num] = (SCHED[tok] || tok) + par;
  }
  return out;
}
function extractHypothesis(md) {
  if (!md) return "";
  // hypothesis may be written as a continuation ("Hypothesis: a …"); it renders
  // standalone on the page, so sentence-case the first character (code/proper left alone)
  const cap = (t) => /^[a-z]/.test(t) ? t[0].toUpperCase() + t.slice(1) : t;
  const s = md.replace(/\*\*/g, "");
  let m = s.match(/Hypothesis:?\s*(.+?)(?:\.\s|\.$|$)/i);
  if (m && m[1].trim()) return cap(m[1].trim().replace(/\.$/, "") + ".");
  m = s.match(/(tests?\s+(?:whether|if)\b.+?)(?:\.\s|\.$|$)/i);
  if (m) return cap(m[1].trim().replace(/\.$/, "") + ".");
  const parts = s.split(/(?<=[.])\s+/).filter(Boolean);
  return cap((parts[parts.length - 1] || "").trim());
}
// merged loop card: stages + schedule + hot-byte budget + asm digest in one stacked card per loop
function loopCards(lb, j, algo) {
  const lf = lb && lb.layout_facts;
  if (!lf || !lf.loops_by_fam) return "";
  const loops = lf.loops_by_fam[j.algo_meta.algo_fam] || [];
  const sched = loopSchedules(algo);
  const ibpp = { none: 0, mask: 1, list: 4, partition: 0 }[j.algo_meta.intermediates] ?? 0;
  const asmLoops = (j.asm && j.asm.loops) || [];
  const cards = loops.map((L, i) => {
    const stages = L.stages.map((s) => s[0].toUpperCase() + s.slice(1)).join("+");
    const pct = Math.round(L.hot_frac * 100);
    const A = asmLoops.find((x) => x.loop === i + 1);
    const srcFile = j.asm && j.asm.algo_source && j.asm.algo_source.file;
    const lnLink = A && A.lines && srcFile
      ? `<a class="lc-ln" href="${REPO_URL}/blob/${j.git_sha || "main"}/${srcFile}#L${A.lines[0]}-L${A.lines[1]}" target="_blank" title="view source on GitHub">@L${A.lines[0]}–${A.lines[1]}</a>`
      : A && A.lines ? `@L${A.lines[0]}–${A.lines[1]}` : "";
    const asmBits = A ? [
      lnLink,
      A.insns != null ? `${A.insns} insns/iter (≈)` : "",
      A.stride_bytes ? `stride ${A.stride_bytes} B` : "",
    ].filter(Boolean) : [];
    return `<div class="loopcard">` +
      `<div class="lc-head"><b>loop ${i + 1}</b><span class="lc-stages">${stages}</span>` +
      (sched[i + 1] ? `<span class="lc-sched">${esc(sched[i + 1])}</span>` : ``) + `</div>` +
      `<div class="lc-bytes">${L.hot_bytes} B/p hot of ${L.stride_bytes} B/p streamed ` +
      `<span class="hotbar"><i style="width:${pct}%"></i></span><span class="lc-pct">${pct}%</span>` +
      (ibpp && i === 0 ? ` <span class="lc-extra">+${ibpp} B/p intermediate</span>` : ``) + `</div>` +
      (asmBits.length ? `<div class="lc-asm">${asmBits.join(" · ")}</div>` : ``) +
      (A && A.notes?.length ? `<div class="lc-notes">${esc(A.notes.join(" · "))}</div>` : ``) + `</div>`;
  }).join("");
  return `<div class="loopcards">${cards}</div>`;
}
function splitNarrative(md) {
  const out = {};
  md = md.replace(/<!--[\s\S]*?-->/, "").trim();
  const re = /^## (.+)$/gm, heads = [];
  let m;
  while ((m = re.exec(md)) !== null) heads.push({ name: m[1], start: m.index, lineEnd: m.index + m[0].length });
  for (let i = 0; i < heads.length; i++) {
    const end = i + 1 < heads.length ? heads[i + 1].start : md.length;
    out[heads[i].name] = md.slice(heads[i].lineEnd, end).trim();
  }
  return out;
}

// ---- merged loop cards: per-loop stages + schedule + hot bytes ----

// ---- latency chart: ns/p vs N, references + memory floor + cache bands ----
function drawLatencyChart(j, grid, qActive) {
  const ceil = j.hardware.streaming_bw_gbs;
  const bpp = j.bytes_per_particle;
  const floorNs = bpp / ceil;
  const qs = Object.keys(j.series).sort((a, b) => +a - +b);
  const pal = churnPalette(qs.map(Number));
  const yMax = Math.max(...Object.values(j.series).flat().map((r) => r.ns_particle)) * 1.12;
  const series = qs.filter((q) => qActive.includes(q)).map((q) => ({
    name: `q=${q}`, type: "line", symbol: "circle", symbolSize: 5,
    lineStyle: { width: 1.8, color: pal(+q) }, itemStyle: { color: pal(+q) },
    data: pickThreads(j.series[q]).map((r) => [r.N, r.ns_particle]),
  }));
  // references, single-q only, consistent coding everywhere:
  // naive = gray diamonds · winner = white diamonds
  const singleQ = qActive.length === 1;
  if (grid && singleQ && refSel.naive && j.algo !== BASELINE) {
    const q = +qActive[0];
    const bl = grid.points.filter((p) => p.algo === BASELINE && p.threads === threads
      && Math.abs(p.death_q - q) < 1e-9).sort((a, b) => a.N - b.N);
    if (bl.length)
      series.push({ name: "naive", type: "scatter", symbol: "diamond", symbolSize: 8,
        itemStyle: { color: REF_NAIVE, borderColor: "#444", borderWidth: 1 },
        data: bl.map((p) => [p.N, p.ns_particle]) });
  }
  if (grid && singleQ && refSel.winner) {
    const q = +qActive[0];
    const byN = {};
    grid.points.filter((p) => p.threads === threads && Math.abs(p.death_q - q) < 1e-9)
      .forEach((p) => { if (!byN[p.N] || p.ns_particle < byN[p.N].ns_particle) byN[p.N] = p; });
    const pts = Object.values(byN).sort((a, b) => a.N - b.N);
    if (pts.length)
      series.push({ name: "winner", type: "scatter", symbol: "diamond", symbolSize: 8,
        itemStyle: { color: REF_WINNER, borderColor: "#555", borderWidth: 1 },
        data: pts.map((p) => [p.N, p.ns_particle]) });
  }
  const bands = cacheBands(j);
  const carrier = { name: "bands", type: "line", data: [], symbol: "none", lineStyle: { opacity: 0 }, silent: true,
    markArea: bands,
    markLine: { silent: true, symbol: "none", data: [
      { yAxis: floorNs, lineStyle: { type: "dotted", color: "#e67e22", width: 2 },
        label: { formatter: `memory floor ${floorNs.toFixed(2)} ns/p = ${bpp} B/p ÷ ${ceil} GB/s`, color: "#e67e22", position: "insideEndBottom" } },
    ] } };
  // knee annotation: steepest adjacent ns-jump at the lowest active q.
  // Lives IN THE CHART ONLY (mark line + label) — not in tooltips or the
  // reference row, so it never reads as an off-chart claim.
  const kd = pickThreads(j.series[qActive[0]] || []).sort((a, b) => a.N - b.N);
  if (kd.length > 2) {
    let best = null;
    for (let i = 0; i + 1 < kd.length; i++) {
      const rel = (kd[i + 1].ns_particle - kd[i].ns_particle) / kd[i].ns_particle;
      if (!best || Math.abs(rel) > Math.abs(best.rel)) best = { rel, at: kd[i + 1] };
    }
    if (best && Math.abs(best.rel) >= 0.08) {
      const band = bandOf(j, best.at.N);
      carrier.markLine.data.push({ xAxis: best.at.N,
        lineStyle: { color: "#888", width: 1, type: "solid" }, symbol: "none",
        label: { formatter: `knee→${band ?? "?"}`, color: "#999", position: "start" } });
    }
  }
  chart("latchart", {
    backgroundColor: "#0f1115",
    tooltip: { trigger: "axis", formatter(ps) {
      if (!ps.length) return "";
      const N = Math.round(ps[0].axisValue);
      const hdr = `<div style="text-align:center;margin-bottom:4px">${fmtN(N)} Particles</div>`;
      const rows = ps.map((x) => {
        const ns = x.value[1];
        return `${x.marker} ${x.seriesName}: ${ns.toFixed(2)} ns/p`;
      });
      return hdr + rows.join("<br/>");
    } },
    legend: { top: 0, textStyle: { color: "#ccc", fontSize: 10 }, data: series.map((s) => s.name) },
    grid: { left: 10, right: 12, top: 30, bottom: 26, containLabel: true },
    xAxis: { type: "log", name: "N", min: bands.axisMin, max: 20e6, ...AX,
      axisLabel: { ...AX.axisLabel, formatter: (v) => v >= 1e6 ? `${v / 1e6}M` : v >= 1e3 ? `${v / 1e3}K` : v } },
    yAxis: { type: "value", name: "ns/particle", max: yMax, ...AX,
      axisLabel: { ...AX.axisLabel, formatter: (v) => +v.toFixed(2) } },
    series: [...series, carrier],
    dataZoom: [{ type: "inside" }],
  });
}

// ---- bandwidth chart: achieved GB/s vs N, streaming ceiling + cache bands ----
function drawBandwidthChart(j, grid, qActive) {
  const ceil = j.hardware.streaming_bw_gbs;
  const bpp = j.bytes_per_particle;
  const qs = Object.keys(j.series).sort((a, b) => +a - +b);
  const pal = churnPalette(qs.map(Number));
  const bwOf = (r) => (r.achieved_bw_gbs ?? (r.ns_particle ? bpp / r.ns_particle : null));
  const all = Object.values(j.series).flat().map(bwOf).filter((v) => v != null);
  const yMax = Math.max(ceil * 1.15, ...(all.length ? all : [1])) * 1.05;
  const series = qs.filter((q) => qActive.includes(q)).map((q) => ({
    name: `q=${q}`, type: "line", symbol: "circle", symbolSize: 5,
    lineStyle: { width: 1.8, color: pal(+q) }, itemStyle: { color: pal(+q) },
    data: pickThreads(j.series[q]).map((r) => [r.N, bwOf(r)]).filter((p) => p[1] != null),
  }));
  // references: naive line + winner diamonds, palette-styled like the q plots;
  // only at single-q selection (see latency chart)
  const singleQ = qActive.length === 1;
  if (grid && singleQ && refSel.naive && j.algo !== BASELINE) {
    const gbw = (p) => p.achieved_bw_gbs ?? (p.ns_particle ? bpp / p.ns_particle : null);
    const q = +qActive[0];
    const bl = grid.points.filter((p) => p.algo === BASELINE && p.threads === threads
      && Math.abs(p.death_q - q) < 1e-9).sort((a, b) => a.N - b.N);
    if (bl.length)
      series.push({ name: "naive", type: "scatter", symbol: "diamond", symbolSize: 8,
        itemStyle: { color: REF_NAIVE, borderColor: "#444", borderWidth: 1 },
        data: bl.map((p) => [p.N, gbw(p)]).filter((d) => d[1] != null) });
  }
  if (grid && singleQ && refSel.winner) {
    const gbw = (p) => p.achieved_bw_gbs ?? (p.ns_particle ? bpp / p.ns_particle : null);
    const q = +qActive[0];
    const byN = {};
    grid.points.filter((p) => p.threads === threads && Math.abs(p.death_q - q) < 1e-9)
      .forEach((p) => { if (!byN[p.N] || p.ns_particle < byN[p.N].ns_particle) byN[p.N] = p; });
    const pts = Object.values(byN).sort((a, b) => a.N - b.N);
    if (pts.length)
      series.push({ name: "winner", type: "scatter", symbol: "diamond", symbolSize: 8,
        itemStyle: { color: REF_WINNER, borderColor: "#555", borderWidth: 1 },
        data: pts.map((p) => [p.N, gbw(p)]).filter((d) => d[1] != null) });
  }
  const bands = cacheBands(j);
  const carrier = { name: "bands", type: "line", data: [], symbol: "none", lineStyle: { opacity: 0 }, silent: true,
    markArea: bands,
    markLine: { silent: true, symbol: "none", data: [
      { yAxis: ceil, lineStyle: { type: "dashed", color: "#e74c3c", width: 2, opacity: 0.9 },
        label: { formatter: `streaming ceiling ${ceil} GB/s`, color: "#e74c3c", position: "insideEndTop" } },
    ] } };
  chart("bwchart", {
    backgroundColor: "#0f1115",
    tooltip: { trigger: "axis", formatter(ps) {
      const rows = ps.filter((x) => x.value != null && x.value[1] != null);
      if (!rows.length) return "";
      const hdr = `<div style="text-align:center;margin-bottom:4px">${fmtN(Math.round(rows[0].axisValue))} Particles</div>`;
      return hdr + rows.map((x) => `${x.marker} ${x.seriesName}: ${x.value[1].toFixed(2)} GB/s (${(x.value[1] / ceil * 100).toFixed(0)}% ceiling)`).join("<br/>");
    } },
    legend: { top: 0, textStyle: { color: "#ccc", fontSize: 10 }, data: series.map((s) => s.name) },
    grid: { left: 10, right: 12, top: 30, bottom: 26, containLabel: true },
    xAxis: { type: "log", name: "N", min: bands.axisMin, max: 20e6, ...AX,
      axisLabel: { ...AX.axisLabel, formatter: (v) => v >= 1e6 ? `${v / 1e6}M` : v >= 1e3 ? `${v / 1e3}K` : v } },
    yAxis: { type: "value", name: "GB/s", max: yMax, ...AX,
      axisLabel: { ...AX.axisLabel, formatter: (v) => +v.toFixed(2) } },
    series: [...series, carrier],
    dataZoom: [{ type: "inside" }],
  });
}
function bandOf(j, N) {
  const t = j.cache_transitions || [];
  let cur = "DRAM";
  for (const [name, cut] of t) if (N < cut) return `${name}-resident`;
  return cur;
}
function cacheBands(j) {
  const t = j.cache_transitions || [];
  const ns = Object.values(j.series).flat().map((r) => r.N);
  if (!ns.length) return { silent: true, data: [], axisMin: null };
  const lo = Math.min(...ns), hi = Math.max(...ns);
  const cuts = t.map((x) => x[1]), names = t.map((x) => x[0]);
  const axisMin = lo;
  const intervals = [];
  let prev = 0;
  for (let i = 0; i < cuts.length; i++) { intervals.push([prev, cuts[i], names[i]]); prev = cuts[i]; }
  intervals.push([prev, Infinity, "DRAM"]);
  const colors = { L1d: "rgba(46,204,113,0.12)", L2: "rgba(241,196,15,0.10)", L3: "rgba(230,126,34,0.10)", DRAM: "rgba(231,76,60,0.10)" };
  const data = [];
  for (const [a, b, name] of intervals) {
    const s = Math.max(a, axisMin), e = Math.min(b, hi);
    if (e > s) data.push([{ xAxis: s, itemStyle: { color: colors[name] || colors.DRAM } },
                          { xAxis: e, label: { show: true, formatter: name, position: "insideTopLeft", color: "#9aa", fontSize: 9 } }]);
  }
  return { silent: true, data, axisMin };
}

// ---- bottlenecks: how-to-read + cycle bars + radar small multiples ----
const BUCKET_META = [
  ["Compute", "compute_pct", "retire-ready cycles — cycles doing work. HIGH is not 'fast': a slow scalar algo can be 100% compute. Read it as 'cycles not lost to waiting'."],
  ["Backend stall", "backend_stall_pct", "data hazards / cache misses — the memory system starving execution (radar: Latency axis = 100 − this)."],
  ["Frontend stall", "frontend_stall_pct", "instruction-fetch starvation (icache/decoder). Usually tiny for these streaming loops."],
  ["Branch flush", "branch_flush_pct", "pipeline flushes from mispredicted branches — the branchy-respawn signature (radar: Control axis = 100 − this)."],
];
function howtoHtml(profiler) {
  const p = profiler === "perf"
    ? "<code>perf stat</code> on AMD Zen 2: compute = cycles − stalls − flush; backend = ic_fetch_stall.ic_stall_back_pressure (cycles the fetch pipeline was blocked because the backend couldn't accept — AMD's Fam17h backend indicator; includes execution-busy ∨ memory-wait overlap); frontend = ic_fetch_stall.ic_stall_dq_empty (dispatch-queue-empty = genuine fetch starvation); branch = ex_ret_brn_misp × 17-cycle penalty. Penalty is a documented approximation (AMD 17h PPR)."
    : "<code>xctrace</code> CPU Counters (Apple): useful / processing / delivery / discarded — retire-ready, data-hazard, fetch-starved, and flushed cycles, normalized to sum = cycles.";
  return `<details class="howto"><summary>How to read the radar & cycle bars</summary>
  <p><b>Where do cycles go?</b> Every CPU cycle lands in exactly one of four buckets (they sum to 100% — that's what the stacked bars show, and what the radar is made of). The classic mental model is the two halves of an out-of-order core:</p>
  <pre class="pipe">FRONTEND                          BACKEND
fetch → decode → rename  →  schedule → execute → retire
(get instructions ready)     (do the work, commit results)</pre>
  <ul>
    <li><b>Frontend stall</b> — the instruction <i>supply</i> failed: icache miss, decoder starved. "I have an empty execution engine and nothing to feed it."</li>
    <li><b>Backend stall</b> — instructions are ready, but the <i>execution side</i> can't advance: a load missed cache and its consumer is waiting; an execution unit is occupied; a dependency chain is too tight to fill the pipeline. "I have work queued and the machinery is blocked or saturated."</li>
    <li><b>Branch flush</b> — the pipeline did speculative work that got thrown away on a mispredict.</li>
    <li><b>Compute</b> — cycles where instructions actually retired.</li>
  </ul>
  <p>The radar plots five <b>goodness axes</b> (bigger = <i>fewer cycles lost</i>, NOT faster — a compute-heavy polygon can still be the slowest algorithm):</p>
  <ul>
    <li><b>Compute</b> = compute_pct (retire-ready)</li>
    <li><b>Bandwidth</b> = achieved GB/s / streaming ceiling × 100 (from timing, not the profiler)</li>
    <li><b>Latency</b> = 100 − backend_stall_pct (memory/data hazards)</li>
    <li><b>Sync</b> = T-scaling efficiency — <i>pinned at 100 while only T=1 data exists</i></li>
    <li><b>Control</b> = 100 − branch_flush_pct (mispredicts)</li>
  </ul>
  <p>Cycle attribution on this machine via ${p}</p>
  <p>One radar per profiled N (the profile grid is frozen at 4 decades); each polygon is one death-rate q in the page-wide churn palette. The stacked bars are the same four buckets as 100%-bars — the ground truth the radar summarizes.</p></details>`;
}
// ---- bottlenecks: one band per profiled N — cycle bars + radar together ----
// refs for the bottleneck bands: naive bundle + winner bundle per profiled N
// (winner can differ by N). Resolved before drawing; nulls skip cleanly.
async function bottleneckRefs(j, grid, qAct) {
  if (!grid || qAct.length !== 1) return { naive: null, winnerByN: {} };
  const q = +qAct[0];
  const ov = await getOverview(machine);   // radarScores needs hardware on each bundle
  const naive = (j.algo === BASELINE) ? null : await getAlgoJson(machine, BASELINE);
  if (naive) naive.hardware = ov;
  const winnerByN = {};
  const profNs = [...new Set((j.profile || []).map((p) => p.N))];
  const algosByN = {};
  for (const n of profNs) {
    const pts = grid.points.filter((p) => p.threads === threads && p.N === n && Math.abs(p.death_q - q) < 1e-9);
    const w = pts.reduce((a, b) => (!a || b.ns_particle < a.ns_particle ? b : a), null);
    if (w && w.algo !== j.algo) algosByN[n] = w.algo;
  }
  const uniq = [...new Set(Object.values(algosByN))];
  const bundles = await Promise.all(uniq.map((a) => getAlgoJson(machine, a)));
  bundles.forEach((b) => { if (b) b.hardware = ov; });
  const byAlgo = Object.fromEntries(uniq.map((a, i) => [a, bundles[i]]));
  for (const [n, a] of Object.entries(algosByN)) winnerByN[n] = byAlgo[a];
  return { naive, winnerByN, winnerNameByN: algosByN };
}
function drawBottleneckBands(j, qActive, refs) {
  const qs = Object.keys(j.series).map(Number).sort((a, b) => a - b);
  const pal = churnPalette(qs);
  const prof = (j.profile || []).filter((p) => p.threads === threads);
  const nsAll = [...new Set(prof.map((p) => p.N))].sort((a, b) => a - b);
  const wrap = $("radargrid");
  if (!wrap) return;
  wrap.innerHTML = nsAll.map((n) => `<div class="radarband"><div class="radartitle">N=${fmtN(n)} · ${j.regimes?.[String(n)] ?? bandOf(j, n)}</div><div id="bars_${n}" class="chart nbars"></div><div id="radar_${n}" style="height:240px"></div></div>`).join("");
  const names = { compute_pct: "Compute", backend_stall_pct: "Backend stall", frontend_stall_pct: "Frontend stall", branch_flush_pct: "Branch flush" };
  const cols = { compute_pct: "#5dade2", backend_stall_pct: "#e67e22", frontend_stall_pct: "#9b59b6", branch_flush_pct: "#e74c3c" };
  const keys = Object.keys(names);
  const AXES = ["Compute", "Bandwidth", "Latency", "Sync", "Control"];
  const singleQ = qActive.length === 1 && refs;
  for (const n of nsAll) {
    const act = qs.filter((q) => qActive.includes(String(q)));
    // bar categories: this algo per active q; at single-q, naive + winner too
    const winB = singleQ && refSel.winner ? refs.winnerByN[n] : null;
    const winNm = singleQ && winB ? short(refs.winnerNameByN[n]) : null;
    const cats = act.map((q) => `q=${fmtq(q)}`);
    if (singleQ && refs.naive && refSel.naive) cats.push("naive");
    if (winNm) cats.push(winNm);
    const profOf = (b) => b && b.profile && b.profile.find((x) => x.N === n && Math.abs(x.death_q - act[0]) < 1e-9 && x.threads === threads);
    const naiveP = singleQ && refs.naive && refSel.naive ? profOf(refs.naive) : null;
    const winP = winB ? profOf(winB) : null;
    // cycle bars for this N: one stacked 100% bar per category
    chart(`bars_${n}`, {
      tooltip: { trigger: "axis", axisPointer: { type: "shadow" },
        formatter: (ps) => `<b>${ps[0].axisValue}</b><br>` + ps.map((x) => `${x.marker} ${x.seriesName}: ${x.value == null ? "?" : x.value.toFixed(1)}%`).join("<br/>") },
      grid: { left: 40, right: 12, top: 8, bottom: 22, containLabel: true },
      xAxis: { type: "category", data: cats,
        axisLabel: { color: "#aaa", fontSize: 9, interval: 0,
          // long winner names wrap at a dot so every bar stays labeled
          formatter: (v) => v.length > 12 ? v.split(".").slice(0, 2).join(".") + "\n" + v.split(".").slice(2).join(".") : v },
        axisLine: { lineStyle: { color: "#666" } } },
      yAxis: { type: "value", max: 100, ...AX, axisLabel: { ...AX.axisLabel, fontSize: 9 } },
      series: keys.map((k) => ({ name: names[k], type: "bar", stack: "c", barMaxWidth: 30,
        itemStyle: { color: cols[k] },
        data: [
          ...act.map((q) => { const p = prof.find((x) => x.N === n && Math.abs(x.death_q - q) < 1e-9); return p ? p[k] : null; }),
          ...(naiveP ? [naiveP[k]] : []),
          ...(winP ? [winP[k]] : []),
        ] })),
    });
    // radar for this N: this algo per active q (churn palette); at single-q,
    // naive (gray, dashed) + winner (white) polygons
    const data = act.map((q) => {
      const s = radarScores(j, n, q, threads);
      return { value: [s.compute, s.bandwidth, s.latency, s.sync, s.control].map((v) => Math.round(v || 0)),
               name: `q=${fmtq(q)}`, lineStyle: { color: pal(q), width: 1.6 },
               itemStyle: { color: pal(q) }, areaStyle: { color: pal(q), opacity: 0.06 } };
    });
    const refPoly = (b, nm, color, dashed) => {
      if (!b) return;
      const s = radarScores(b, n, act[0], threads);
      if (s.compute == null) return;
      data.push({ value: [s.compute, s.bandwidth, s.latency, s.sync, s.control].map((v) => Math.round(v || 0)),
        name: nm, lineStyle: { color, width: 1.6, type: dashed ? "dashed" : "solid" },
        itemStyle: { color }, areaStyle: { color, opacity: 0.04 } });
    };
    if (singleQ && refSel.naive) refPoly(refs.naive, "naive", REF_NAIVE, false);
    if (winB && refSel.winner) refPoly(winB, winNm, REF_WINNER, false);
    chart(`radar_${n}`, {
      tooltip: { formatter: (p) => `${p.name}<br>` + AXES.map((a, i) => `${a}: ${p.value[i]}`).join("<br>") },
      radar: { indicator: AXES.map((a) => ({ name: a, max: 100 })), radius: "55%", splitNumber: 4,
        center: ["50%", "54%"],
        axisName: { color: "#bbb", fontSize: 9 },
        splitLine: { lineStyle: { color: "#2a2a2a" } },
        splitArea: { areaStyle: { color: ["rgba(255,255,255,0.015)", "rgba(255,255,255,0.035)"] } },
        axisLine: { lineStyle: { color: "#333" } } },
      series: [{ type: "radar", data }],
    });
  }
}
function profAt(j, N, q, T) {
  return (j.profile || []).find((p) => p.N === N && Math.abs(p.death_q - q) < 1e-9 && p.threads === T);
}
function radarScores(j, N, q, T) {
  const ceil = j.hardware.streaming_bw_gbs;
  const p = profAt(j, N, q, T), rT = (j.series[String(q)] || []).find((r) => r.N === N && r.threads === T);
  const compute = p ? +p.compute_pct : null;
  const latency = p ? 100 - +p.backend_stall_pct : null;
  const control = p ? 100 - +p.branch_flush_pct : null;
  const bandwidth = rT && ceil ? Math.min(100, ((j.bytes_per_particle / rT.ns_particle) / ceil) * 100) : null;
  let sync = 100;   // T=1-only data: pinned (labeled in the how-to-read)
  return { compute, bandwidth, latency, sync, control };
}
// ---- assembly viewer v2: digest cards + folded interleave + explorer ----
const ASM_LEGEND = [["label", "symbol/label"], ["vload", "NEON/vec load"], ["vstore", "NEON/vec store"],
  ["load", "scalar load"], ["store", "store"], ["fp", "FP math"], ["branch", "branch"],
  ["cmp", "compare"], ["vec", "vector op"], ["other", "other"]];
const ASM_COLORS = ["#2d5a44","#5a2d44","#2d4a5a","#5a442d","#4a2d5a","#2d5a5a","#5a5a2d","#442d5a"];
const REPO_URL = "https://github.com/SayreBlades/dod-particle-challenge";
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/\t/g, "  ");
const srcFileUrl = (file, sha, line) => `${REPO_URL}/blob/${sha || "main"}/${file}${line ? `#L${line}` : ""}`;
const GH_SVG = `<svg width="13" height="13" viewBox="0 0 16 16" fill="currentColor" style="vertical-align:-1px"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>`;
const shortSym = (s) => (s || "").replace(/^_/, "").split(".").pop().split("(")[0];
let asmMode = "explorer";                         // persists across algorithm navigation

function asmRowHtml(ins, j, ln, idx) {
  const a = j.asm;
  let ann = "";
  if (ins.cls === "branch") {
    if (ins.bt != null) {
      const tl = a.attribution ? a.attribution.call_site[ins.bt] : null;
      ann = tl ? `→ L${tl}` : (a.insns[ins.bt] && a.insns[ins.bt].t ? `→ ${shortSym(a.insns[ins.bt].t)}` : "");
    } else if (ins.t) ann = `→ ${shortSym(ins.t)}`;
  }
  const fc = (a.fconst || []).find((f) => f.i === idx);
  if (fc) ann += `  ; = ${fc.v}`;
  return `<div class="asm-row ${ins.cls}">${ln != null ? `<span class="gb-ln">${ln}</span>` : ""}<span class="asm-mnem">${esc(ins.m)}</span><span class="asm-ops">${esc(ins.o)}</span><span class="asm-ann">${esc(ann)}</span></div>`;
}
function foldLabel(a, i) {
  const ch = a.attribution.chains[i][0];
  const file = ch ? a.attribution.files[ch[0]] : "?";
  return { file, line: ch ? ch[1] : 0 };
}
function foldedHtml(j) {
  const a = j.asm, cs2 = a.algo_source;
  if (!a.attribution || !cs2) return null;
  const { insns, attribution } = a;
  const algoBase = cs2.file.split("/").pop();
  const repo = new Set(attribution.repo_files || []);
  // group by call-site line (0 = prologue/outlined), source order
  const groups = new Map();
  insns.forEach((ins, i) => {
    const g = attribution.call_site[i] || 0;
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(i);
  });
  let ln = 1, html = "";
  for (const g of [...groups.keys()].sort((x, y) => x - y)) {
    const idxs = groups.get(g);
    const src = g ? cs2.lines[g - 1] : null;
    html += `<div class="fold-group" data-g="${g}">`;
    html += g
      ? `<div class="fold-src"><a class="gb-ln" href="${srcFileUrl(cs2.file, j.git_sha, g)}" target="_blank">${g}</a>${esc(src) || " "}</div>`
      : `<div class="fold-src none"><span class="gb-ln">—</span>prologue / outlined (no line attribution)</div>`;
    // fold runs of foreign-innermost instructions; algo-file rows stay plain
    let i = 0;
    while (i < idxs.length) {
      const idx = idxs[i];
      const ch0 = attribution.chains[idx] && attribution.chains[idx][0];
      const innerFile = ch0 ? attribution.files[ch0[0]] : null;
      if (innerFile && innerFile !== algoBase) {
        let k = i;
        while (k + 1 < idxs.length) {
          const c2 = attribution.chains[idxs[k + 1]] && attribution.chains[idxs[k + 1]][0];
          if (!c2 || attribution.files[c2[0]] !== innerFile) break;
          k++;
        }
        const std = !repo.has(innerFile);
        const n = k - i + 1;
        const l0 = ch0[1];
        const cN = attribution.chains[idxs[k]][0][1];
        const lbl = `${innerFile}:${l0}${cN !== l0 ? `–${cN}` : ""}`;
        html += `<details class="fold${std ? " std" : " repo"}"><summary>⤷ ${esc(lbl)} <span class="foldn">${n} insns${std ? " · std runtime" : ""}</span></summary><div class="fold-body">`;
        for (let z = i; z <= k; z++) html += asmRowHtml(insns[idxs[z]], j, ln++, idxs[z]);
        html += `</div></details>`;
        i = k + 1;
      } else {
        html += asmRowHtml(insns[idx], j, ln++, idx);
        i++;
      }
    }
    html += `</div>`;
  }
  return `<div class="fold-view">${html}</div>`;
}
function explorerHtml(j) {
  const a = j.asm, cs2 = a.algo_source;
  if (!a.attribution || !cs2) return null;
  const { insns, attribution } = a;
  // asm pane: blocks of CONSECUTIVE same call_site in address order
  const blocks = [];
  let cur = null;
  insns.forEach((ins, i) => {
    const g = attribution.call_site[i];
    if (!cur || cur.g !== g) { cur = { g, idxs: [] }; blocks.push(cur); }
    cur.idxs.push(i);
  });
  const linesWithCode = new Set(blocks.map((b) => b.g).filter(Boolean));
  let srcHtml = "";
  cs2.lines.forEach((line, i) => {
    const ln = i + 1, has = linesWithCode.has(ln);
    srcHtml += `<div class="gb-src${has ? " linked" : ""}"${has ? ` data-g="${ln}"` : ""} data-line="${ln}"><span class="gb-ln">${ln}</span>${esc(line) || " "}</div>`;
  });
  let asmHtml = "", ln2 = 1;
  blocks.forEach((b, bi) => {
    const c = ASM_COLORS[bi % ASM_COLORS.length];
    asmHtml += `<div class="asm-grp${b.g ? "" : " unatt"}" data-g="${b.g || ""}" style="border-left-color:${b.g ? c : "#23262b"}"${b.g ? ` data-line="${b.g}"` : ""}>`;
    if (!b.g) asmHtml += `<div class="asm-unatt-h">outlined / unattributed</div>`;
    for (const i of b.idxs) asmHtml += asmRowHtml(insns[i], j, ln2++, i);
    asmHtml += `</div>`;
  });
  const fileLabel = esc(cs2.file.split("/").slice(-2).join("/"));
  return `<div class="gb-head"><a class="gb-h gb-h-src" href="${srcFileUrl(cs2.file, j.git_sha)}" target="_blank">${GH_SVG} ${fileLabel} ↗</a><span class="gb-h gb-h-asm">${a.arch} — ReleaseFast</span></div>` +
    `<div class="godbolt"><div class="gb-pane gb-pane-src">${srcHtml}</div><div class="gb-pane gb-pane-asm">${asmHtml}</div></div>`;
}
function flatAsmHtml(j) {
  let html = "";
  (j.asm.excerpt || "").split("\n").forEach((ln0, i) => {
    const t = ln0.split("\t");
    const cls = t.length >= 2 && /^[0-9a-f]{16}$/.test(t[0]) ? "" : "";
    html += `<span class="ic"><span class="ln">${String(i + 1).padStart(3, " ")}</span>${esc(ln0)}</span>`;
  });
  return `<pre class="asm">${html}</pre>`;
}
function asmToolbar(j, mode) {
  const v2 = j.asm.schema >= 2 && j.asm.attribution;
  const tabs = v2 ? [["folded", "Folded", "Source-order interleave; inlined code folded under its call site"],
                     ["explorer", "Explorer", "Linked two-pane godbolt view"]]
                  : [];
  const tabHtml = tabs.map(([m, label, title]) => `<button type="button" class="asm-tab${mode === m ? " on" : ""}" data-mode="${m}" title="${title}">${label}</button>`).join("");
  const fileLink = j.asm.algo_source
    ? `<a class="asm-gh" href="${srcFileUrl(j.asm.algo_source.file, j.git_sha)}" target="_blank">${GH_SVG}${esc(j.asm.algo_source.file)} ↗</a>`
    : `<span class="asm-gh none">${esc(j.asm.symbol)}</span>`;
  return `<div class="asm-toolbar"><div class="asm-tabs">${tabHtml}</div><span class="asm-info">${j.asm.n_instructions} instructions · ${j.asm.vector_insns} vector${v2 ? ` · ${j.asm.arch}` : ""}${!v2 ? " · legacy bundle (re-collect on this machine to upgrade)" : ""}</span>${fileLink}</div>`;
}
function asmLegendHtml() {
  return `<div class="asmleg">${ASM_LEGEND.map(([c, l]) => `<span class="asmlegitem"><i class="icdot ${c}"></i>${l}</span>`).join("")}</div>`;
}
function wireAsmViewer(j) {
  const body = $("asmbody");
  if (!body) return;
  const v2 = j.asm.schema >= 2 && j.asm.attribution;
  if (!v2) asmMode = "flat";
  const draw = () => {
    body.className = `asm-body mode-${asmMode}`;
    body.innerHTML = asmMode === "explorer" ? (explorerHtml(j) || flatAsmHtml(j))
                   : asmMode === "folded" ? (foldedHtml(j) || flatAsmHtml(j))
                   : flatAsmHtml(j);
    if (asmMode === "explorer") setupLinked();
    if (asmMode === "folded") setupFolds();
  };
  draw();
  document.querySelectorAll(".asm-tab").forEach((b) => {
    b.onclick = () => {
      asmMode = b.dataset.mode;
      document.querySelectorAll(".asm-tab").forEach((x) => x.classList.toggle("on", x === b));
      draw();
    };
  });
}
function setupFolds() {
  document.querySelectorAll(".fold-view details.fold").forEach((d) => {
    d.addEventListener("toggle", () => {
      // keep the gutter readable: open folds scroll into view lazily
      if (d.open) d.scrollIntoView({ block: "nearest" });
    });
  });
}
function setupLinked() {
  const src = document.querySelector(".gb-pane-src");
  const asm = document.querySelector(".gb-pane-asm");
  if (!src || !asm) return;
  const flash = (g) => {
    document.querySelectorAll(".gb-hl").forEach((n) => n.classList.remove("gb-hl"));
    document.querySelectorAll(`[data-g="${g}"]`).forEach((n) => n.classList.add("gb-hl"));
  };
  src.addEventListener("click", (e) => {
    const r = e.target.closest("[data-g]"); if (!r) return;
    const g = asm.querySelector(`.asm-grp[data-line="${r.dataset.g}"]`);
    if (g) { asm.scrollTop = g.offsetTop; flash(r.dataset.g); }
  });
  asm.addEventListener("click", (e) => {
    const r = e.target.closest(".asm-grp"); if (!r || !r.dataset.line) return;
    const s = src.querySelector(`[data-line="${r.dataset.line}"]`);
    if (s) s.scrollIntoView({ block: "center" });
    flash(r.dataset.line);
  });
}

// ---- q chips (shared page-wide state for the algo page) ----
// (moved to the header multi-select — removed)

async function renderAlgo(algo) {
  const L = algo.split(".")[0];
  const [j, md, lb, ov, asmB, grid] = await Promise.all([
    getAlgoJson(machine, algo), fetchText(`analysis/${machine}/${algo}.md`),
    getMemLayout(machine, L), getOverview(machine), getAlgoAsm(machine, algo), getGrid(machine)]);
  if (!j) { $("page").innerHTML = `<section><p>No analysis bundle for ${algo}.</p></section>`; status("missing"); return; }
  j.asm = asmB ? asmB.asm : null;
  j.hardware = ov; j.grid = grid;
  renderMeta(j.hardware);
  const d = j.algo_meta;
  const decl = `<div class="decl"><span><b>ordering</b> ${d.ordering}</span><span><b>intermediates</b> ${d.intermediates}</span><span><b>golden</b> ${d.golden_class}</span><span><b>source_hash</b> <code>${(j.source_hash || "").slice(0, 12)}</code></span></div>`;
  const n = splitNarrative(md || "");
  const mp = (k) => marked.parse(n[k] || "<p class='hint'>(no narrative)</p>");
  const mem = lb && lb.memory_layout
    ? `<h3>${L}: Particle Layout</h3><pre class="memlayout">${lb.memory_layout}</pre>`
    : "";
  const loopFacts = lb && lb.memory_layout
    ? `${loopCards(lb, j, algo)}
       <p class="hint">Struct stride; hot bytes = fields this algo's loops touch per particle vs what the AoS line filler drags. ${esc(short(algo))}'s bytes/p (${j.bytes_per_particle}) includes its ${d.intermediates} intermediate.</p>
       ${n["Layout & approach"] ? `<div class="narrative">${mp("Layout & approach")}</div>` : ""}`
    : "";
  const hyp = extractHypothesis(n["Intent"]);
  const hypo = hyp ? `<h3>Hypothesis</h3><div class="hypothesis">${marked.parseInline(hyp)}</div>` : "";
  const vraw = (n["Verdict"] || "").trim();
  const vkind = /^holds\b/i.test(vraw) ? "holds" : /^partially\b/i.test(vraw) ? "partial" : /^refuted\b/i.test(vraw) ? "refuted" : "";
  const verdict = vraw ? `<div class="verdict ${vkind}"><h3>Verdict</h3>${marked.parse(vraw)}</div>` : "";
  const banner = j.verified === false
    ? `<div class="unverified">⚠ <b>narrative failed verification</b> — the prose cites evidence not in the bundle. Regenerate with <code>scripts/analyze_algo.py ${algo} --force</code>${j.verify_errors?.length ? `<br><span class=hint>${j.verify_errors.join("; ")}</span>` : ""}</div>`
    : "";
  const profiler = (j.profile || [])[0]?.profiler;
  $("page").innerHTML = `
    ${banner}
    <section class="cellhead"><h2>${algo}</h2>${decl}${mem}<h3>${d.algo_fam}: Loops</h3>${loopFacts}${hypo}${verdict}</section>
    <section class="narrative"><h3>Latency <span class="sub">ns/particle vs N · dashed = naive · ◇ = winner · dotted = memory floor · overlays via the header refs dropdown</span></h3>
      <div id="latchart" class="chart"></div>
      ${mp("Cache saturation")}</section>
    <section class="narrative"><h3>Bandwidth <span class="sub">achieved GB/s vs N · dashed = streaming ceiling · bands = cache residency</span></h3>
      <div id="bwchart" class="chart"></div>
      ${mp("Bandwidth")}</section>
    ${(j.profile || []).length ? `<section class="narrative"><h3>Bottlenecks <span class="sub">one band per profiled N: cycle bars (ground truth) + radar (summary) · at single-q, naive + winner bars/polygons join · header q filters all views</span></h3>
      ${howtoHtml(profiler)}
      <div id="radargrid" class="radargrid"></div></section>`
      : `<section class="narrative"><h3>Bottlenecks</h3><p class="hint">No cycle-attribution data for ${short(algo)} — run <code>scripts/collect.py ${algo} --only profile</code> to populate it.</p></section>`}
    <section class="narrative"><h3>Assembly</h3>
      ${j.asm ? `${asmToolbar(j, asmMode)}${asmLegendHtml()}<div id="asmbody" class="asm-body"></div>${mp("Assembly")}`
              : `<p class="hint">asm bundle <code>data/${machine}/${algo}.json</code> not found — run <code>make collect</code> or check the Pages publish step.</p>`}</section>`;
  status(j.asm ? `${algo} · ${j.asm.n_instructions} asm insns` : algo);
  // interactions — q filtering comes from the header selector via qRedraw
  const redraw = async () => {
    try {
      const qAct = activeQs().length ? activeQs() : Object.keys(j.series);
      drawLatencyChart(j, grid, qAct);
      drawBandwidthChart(j, grid, qAct);
      if ((j.profile || []).length) {
        const refs = await bottleneckRefs(j, grid, qAct);
        drawBottleneckBands(j, qAct, refs);
      }
    } catch (e) { status(`algo error: ${e.message}`); console.error(e); }
  };
  qRedraw = redraw;
  redraw();
  if (j.asm) wireAsmViewer(j);
}

// ---------------- rank: every algorithm at one (N, death_q, threads) ----------------
async function renderRank(N, q) {
  const g = await getGrid(machine);
  const ment = (await getOverview(machine)) || {};
  if (g) renderMeta(ment);
  if (!g) { status("no grid.json for " + machine); return; }
  const ceil = g.streaming_bw_gbs;
  const pts = g.points
    .filter((p) => p.N === N && Math.abs(p.death_q - q) < 1e-9 && p.threads === threads)
    .sort((a, b) => a.ns_particle - b.ns_particle);
  const title = `All algorithms · ${fmtN(N)} particles · ${Math.round(q * 100)}% death rate · ${threads} thread${threads === 1 ? "" : "s"}`;
  let html = `<section class="cellhead"><h2>${title}</h2>`
    + `<p class="hint"><a href="${mhref('')}">← All Winners</a> · ranked by ns/particle (best trial). `
    + `Click a bar for the algorithm deep-dive.</p></section>`;
  if (!pts.length) {
    html += `<section><p class="hint">No algorithms measured at this intersection.</p></section>`;
  } else {
    html += `<section><h3>Latency &amp; Bandwidth <span class="sub">dashed = streaming ceiling · click a row for the deep dive</span></h3>`
      + `<div id="rankpyramid" class="chart"></div></section>`;
    html += `<section><h3>Compare <span class="sub">pick 2–3 and compare on one page</span></h3><div class="chiprow" id="cmpsel">`
      + pts.map((p) => `<label class="cmpk"><input type="checkbox" value="${p.algo}"> ${short(p.algo)}</label>`).join(" ")
      + `</div><button type="button" class="qchip on" id="cmpSelGo">Compare selected</button></section>`;
  }
  $("page").innerHTML = html;
  status(`${title} · ${pts.length} algorithms`);
  if (pts.length) {
    drawRankCharts(pts, ceil);
    $("cmpSelGo").onclick = () => {
      const sel = [...document.querySelectorAll("#cmpsel input:checked")].map((x) => x.value);
      if (sel.length >= 2 && sel.length <= 3)
        location.hash = mhref(`compare/${sel.map(encodeURIComponent).join("+")}`);
    };
  }
}

function drawRankCharts(pts, ceil) {
  const h = Math.max(260, pts.length * 26 + 40);
  const el = document.getElementById("rankpyramid");
  if (el) el.style.height = h + "px";
  const order = [...pts].sort((a, b) => a.ns_particle - b.ns_particle);
  const names = order.map((p) => short(p.algo));
  const lat = order.map((p) => p.ns_particle);             // positive → grows right of 0
  const bw = order.map((p) => -(p.achieved_bw_gbs ?? 0));  // NEGATED → grows left of 0
  const maxLat = Math.max(...order.map((p) => p.ns_particle));
  const bwExtent = Math.ceil((ceil || 1) * 1.1);
  const plotL = 15, plotR = 95;
  const zeroPct = plotL + (plotR - plotL) * bwExtent / (bwExtent + maxLat);
  const c = chart("rankpyramid", {
    animation: false,
    title: [
      { text: "Bandwidth", subtext: "GB/s (higher is better)",
        left: ((plotL + zeroPct) / 2).toFixed(1) + "%", top: 2, textAlign: "center",
        textStyle: { color: "#cfcfcf", fontSize: 13, fontWeight: "normal" }, subtextStyle: { color: "#9aa", fontSize: 11 } },
      { text: "Latency", subtext: "ns/particle (lower is better)",
        left: ((zeroPct + plotR) / 2).toFixed(1) + "%", top: 2, textAlign: "center",
        textStyle: { color: "#cfcfcf", fontSize: 13, fontWeight: "normal" }, subtextStyle: { color: "#9aa", fontSize: 11 } },
    ],
    tooltip: { trigger: "axis", axisPointer: { type: "shadow", shadowStyle: { color: "rgba(133,160,210,0.10)" } },
      formatter: (ps) => {
        const i = ps[0].dataIndex;
        return `<b>${names[i]}</b><br/>latency: ${lat[i].toFixed(2)} ns/p<br/>bandwidth: ${(-bw[i]).toFixed(2)} GB/s`;
      } },
    grid: { left: 12, right: 50, top: 42, bottom: 36, containLabel: true },
    xAxis: { type: "value", min: -bwExtent, max: maxLat, ...AX,
      axisLabel: { ...AX.axisLabel, formatter: (v) => Math.abs(v).toFixed(0) } },
    yAxis: { type: "category", data: names, inverse: true,
      axisLabel: { color: "#5dade2", fontSize: 11 },
      axisLine: { lineStyle: { color: "#666" } }, axisTick: { show: false } },
    series: [
      { name: "Latency", type: "bar", data: lat, barGap: "-100%", barMaxWidth: 18, cursor: "pointer",
        itemStyle: { color: "#5dade2" } },
      { name: "Bandwidth", type: "bar", data: bw, barMaxWidth: 18, cursor: "pointer",
        itemStyle: { color: "#2ecc71" },
        markLine: { silent: true, symbol: "none", data: [{ xAxis: -ceil, lineStyle: { type: "dashed", color: "#e74c3c", width: 2 },
          label: { formatter: `ceiling ${ceil}`, color: "#e74c3c", position: "insideEndTop" } }] } },
    ],
  });
  const zr = c?.getZr?.();
  const rowAt = (y) => {
    if (!c || y == null) return null;
    const idx = Math.round(c.convertFromPixel({ yAxisIndex: 0 }, y));
    return order[idx]?.algo ?? null;
  };
  zr?.on("mousemove", (e) => { zr.setCursorStyle(rowAt(e.offsetY != null ? e.offsetY : e.event?.offsetY) ? "pointer" : "default"); });
  zr?.on("click", (e) => { const algo = rowAt(e.offsetY != null ? e.offsetY : e.event?.offsetY); if (algo) location.hash = mhref(`algorithm/${algo}`); });
}

// ---------------- compare: 2–3 algos on one page ----------------
async function renderCompare(algos) {
  const [grid, ov] = await Promise.all([getGrid(machine), getOverview(machine)]);
  if (!grid) { status("no grid.json"); return; }
  renderMeta(ov || grid);
  const js = (await Promise.all(algos.map((a) => getAlgoJson(machine, a)))).filter(Boolean);
  const asms = await Promise.all(js.map((j) => getAlgoAsm(machine, j.algo)));
  js.forEach((j, i) => { j.asm = asms[i] ? asms[i].asm : null; j.hardware = ov; });
  if (js.length < 2) { $("page").innerHTML = `<section><p class="hint">Need 2–3 algorithms to compare.</p></section>`; status("compare"); return; }
  const qs = [...new Set(js.flatMap((j) => Object.keys(j.series)))].sort((a, b) => +a - +b);
  // profile Ns common to all
  const profNs = [...new Set(js.flatMap((j) => (j.profile || []).filter((p) => p.threads === threads).map((p) => p.N)))].sort((a, b) => a - b);
  const state = { N: profNs[profNs.length - 1] };
  const title = `${js.map((j) => short(j.algo)).join(" vs ")}`;
  $("page").innerHTML = `
    <section class="cellhead"><h2>${esc(title)}</h2>
      <p class="hint"><a href="${mhref('')}">← All Winners</a> · one line per algorithm × selected death rate (header q); naive/winner overlays via the header refs dropdown.</p></section>
    <section><h3>Latency &amp; bandwidth <span class="sub">one series per algorithm × selected q</span></h3>
      <div id="cmain" class="chart"></div></section>
    ${profNs.length ? `<section><h3>Cycle composition <span class="sub"><span id="cycq"></span>one N per group</span></h3><div class="chiprow" id="cn"></div><div id="cbars" class="chart" style="height:300px"></div><div id="cradar" style="height:340px"></div></section>` : ""}
    <section><h3>Instruction mix <span class="sub">class share of the step body · loop digest</span></h3><div id="cmix"></div></section>`;
  status(`compare · ${js.length} algos`);
  const redraw = () => {
    try {
    const qAct = activeQs().length ? activeQs() : qs;
    drawCompareMain(js, grid, qAct);
    if (profNs.length) {
      $("cn").innerHTML = profNs.map((n) => `<button type="button" class="qchip${state.N === n ? " on" : ""}" data-n="${n}">N=${fmtN(n)}</button>`).join("");
      document.querySelectorAll("#cn .qchip").forEach((b) => b.onclick = () => { state.N = +b.dataset.n; redraw(); });
      const q0 = qAct[0];
      drawCompareBars(js, q0, state.N);
      drawCompareRadar(js, q0, state.N);
      const sub = $("cycq"); if (sub) sub.textContent = `q=${fmtq(q0)} · `;
    }
    drawCompareMix(js);
    } catch (e) { status(`compare error: ${e.message}`); console.error(e); }
  };
  qRedraw = redraw;
  redraw();
}
function drawCompareMain(js, grid, qAct) {
  const ceil = js[0].hardware.streaming_bw_gbs;
  const bpp = js[0].bytes_per_particle;
  const floorNs = bpp / ceil;
  const vals = js.flatMap((j) => qAct.flatMap((q) => (j.series[q] || []).map((r) => r.ns_particle)));
  const yMax = (vals.length ? Math.max(...vals) : 1) * 1.15;
  const series = [];
  for (const j of js) for (const q of qAct)
    series.push({ name: `${short(j.algo)} q=${fmtq(q)}`, type: "line", symbol: "circle", symbolSize: 6,
      lineStyle: { width: 2, color: cellColor(j.algo) }, itemStyle: { color: cellColor(j.algo) },
      data: pickThreads(j.series[q] || []).map((r) => [r.N, r.ns_particle]) });
  // references, single-q only, consistent coding: naive gray · winner white diamonds
  const singleQ = qAct.length === 1;
  if (singleQ && refSel.naive && !js.some((j) => j.algo === BASELINE)) {
    const q = +qAct[0];
    const bl = grid.points.filter((p) => p.algo === BASELINE && p.threads === threads && Math.abs(p.death_q - q) < 1e-9).sort((a, b) => a.N - b.N);
    if (bl.length)
      series.push({ name: "naive", type: "scatter", symbol: "diamond", symbolSize: 8,
        itemStyle: { color: REF_NAIVE, borderColor: "#444", borderWidth: 1 },
        data: bl.map((p) => [p.N, p.ns_particle]) });
  }
  if (singleQ && refSel.winner) {
    const q = +qAct[0];
    const byN = {};
    grid.points.filter((p) => p.threads === threads && Math.abs(p.death_q - q) < 1e-9)
      .forEach((p) => { if (!byN[p.N] || p.ns_particle < byN[p.N].ns_particle) byN[p.N] = p; });
    const pts = Object.values(byN).sort((a, b) => a.N - b.N);
    if (pts.length)
      series.push({ name: "winner", type: "scatter", symbol: "diamond", symbolSize: 8,
        itemStyle: { color: REF_WINNER, borderColor: "#555", borderWidth: 1 },
        data: pts.map((p) => [p.N, p.ns_particle]) });
  }
  const j0 = js[0];
  const bands = cacheBands(j0);
  chart("cmain", {
    tooltip: { trigger: "axis", formatter(ps) {
      const hdr = `<div style="text-align:center;margin-bottom:4px">${fmtN(Math.round(ps[0].axisValue))} Particles</div>`;
      return hdr + ps.map((x) => `${x.marker} ${x.seriesName}: ${x.value[1].toFixed(2)} ns/p · ${(bpp / x.value[1]).toFixed(2)} GB/s`).join("<br/>");
    } },
    legend: { top: 0, textStyle: { color: "#ccc", fontSize: 10 }, data: series.map((s) => s.name) },
    grid: { left: 55, right: 60, top: 30, bottom: 55, containLabel: true },
    xAxis: { type: "log", name: "N", min: bands.axisMin, max: 20e6, ...AX,
      axisLabel: { ...AX.axisLabel, formatter: (v) => v >= 1e6 ? `${v / 1e6}M` : v >= 1e3 ? `${v / 1e3}K` : v } },
    yAxis: [
      { type: "value", name: "ns/particle", max: yMax, ...AX,
        axisLabel: { ...AX.axisLabel, formatter: (v) => +v.toFixed(2) } },
      { type: "value", name: "GB/s", max: ceil * 1.25, ...AX, splitLine: { show: false } },
    ],
    series: [...series, { name: "bands", type: "line", data: [], symbol: "none", lineStyle: { opacity: 0 }, silent: true,
      markArea: bands,
      markLine: { silent: true, symbol: "none", data: [{ yAxis: floorNs, lineStyle: { type: "dotted", color: "#e67e22", width: 2 },
        label: { formatter: `floor ${floorNs.toFixed(2)} ns/p`, color: "#e67e22", position: "insideEndBottom" } }] } }],
    dataZoom: [{ type: "slider", bottom: 8, height: 16 }],
  });
}
function drawCompareBars(js, q, N) {
  const cats = js.map((j) => short(j.algo));
  const keys = ["compute_pct", "backend_stall_pct", "frontend_stall_pct", "branch_flush_pct"];
  const names = { compute_pct: "Compute", backend_stall_pct: "Backend stall", frontend_stall_pct: "Frontend stall", branch_flush_pct: "Branch flush" };
  const cols = { compute_pct: "#5dade2", backend_stall_pct: "#e67e22", frontend_stall_pct: "#9b59b6", branch_flush_pct: "#e74c3c" };
  const data = {};
  for (const k of keys) data[k] = js.map((j) => {
    const p = (j.profile || []).find((x) => x.N === N && Math.abs(x.death_q - +q) < 1e-9 && x.threads === threads);
    return p ? p[k] : null;
  });
  chart("cbars", {
    tooltip: { trigger: "axis", axisPointer: { type: "shadow" },
      formatter: (ps) => `<b>${ps[0].axisValue}</b><br>` + ps.map((x) => `${x.marker} ${x.seriesName}: ${x.value == null ? "?" : x.value.toFixed(1)}%`).join("<br/>") },
    legend: { top: 0, textStyle: { color: "#ccc", fontSize: 10 } },
    grid: { left: 55, right: 20, top: 30, bottom: 40, containLabel: true },
    xAxis: { type: "category", data: cats, axisLabel: { color: "#aaa", fontSize: 10 }, axisLine: { lineStyle: { color: "#666" } } },
    yAxis: { type: "value", max: 100, name: "% of cycles", ...AX },
    series: keys.map((k) => ({ name: names[k], type: "bar", stack: "c", barMaxWidth: 46,
      itemStyle: { color: cols[k] }, data: data[k] })),
  });
}
function drawCompareRadar(js, q, N) {
  const AXES = ["Compute", "Bandwidth", "Latency", "Sync", "Control"];
  const polys = js.map((j) => {
    const s = radarScores(j, N, +q, threads);
    return { value: [s.compute, s.bandwidth, s.latency, s.sync, s.control].map((v) => Math.round(v || 0)),
             name: short(j.algo), lineStyle: { color: cellColor(j.algo), width: 2 }, itemStyle: { color: cellColor(j.algo) },
             areaStyle: { color: cellColor(j.algo), opacity: 0.08 } };
  });
  chart("cradar", {
    title: { text: `radar overlay · N=${fmtN(N)} · q=${fmtq(q)}`, left: "center", top: 0, textStyle: { color: "#9aa", fontSize: 12, fontWeight: "normal" } },
    tooltip: {},
    legend: { bottom: 0, textStyle: { color: "#ccc", fontSize: 10 } },
    radar: { indicator: AXES.map((a) => ({ name: a, max: 100 })), radius: "58%",
      axisName: { color: "#bbb", fontSize: 10 }, splitLine: { lineStyle: { color: "#2a2a2a" } },
      splitArea: { areaStyle: { color: ["rgba(255,255,255,0.015)", "rgba(255,255,255,0.035)"] } }, axisLine: { lineStyle: { color: "#333" } } },
    series: [{ type: "radar", data: polys }],
  });
}
function drawCompareMix(js) {
  let html = `<div class="mixgrid">`;
  for (const j of js) {
    const a = j.asm;
    if (!a || a.schema < 2 || !a.insns) {
      html += `<div class="digest"><b>${short(j.algo)}</b><div class="dnotes"><span>legacy asm bundle — re-collect to upgrade</span></div></div>`;
      continue;
    }
    const counts = {};
    for (const ins of a.insns) counts[ins.cls] = (counts[ins.cls] || 0) + 1;
    const tot = a.insns.length;
    const orderCls = ["fp", "load", "store", "vload", "vstore", "branch", "cmp", "vec", "other"];
    const cols = { fp: "#2ecc71", load: "#7fb3ff", store: "#e74c3c", vload: "#5dade2", vstore: "#e8a87c",
                   branch: "#bb86fc", cmp: "#f1c40f", vec: "#48c9b0", other: "#888" };
    let bar = `<div class="mixbar">` + orderCls.filter((c) => counts[c]).map((c) =>
      `<i style="width:${(counts[c] / tot * 100).toFixed(1)}%;background:${cols[c]}" title="${c} ${counts[c]}"></i>`).join("") + `</div>`;
    const dig = (a.loops || []).map((L) => `loop ${L.loop}: ${L.notes?.join(", ") || `${L.insns} insns`}`).join("<br>");
    html += `<div class="digest wide"><b>${short(j.algo)}</b> <span class="sub">${tot} insns · ${a.vector_insns} vector</span>${bar}<div class="dnotes">${dig}</div></div>`;
  }
  $("cmix").innerHTML = html + `</div>`;
}

// ---------------- router ----------------
function route() {
  charts.length = 0;
  qRedraw = null;
  $("page").innerHTML = "";
  const raw = location.hash.replace(/^#\/?/, "");
  const parts = raw.split("/");
  const knownIds = MACHINES.machines.map((m) => m.machine_id);
  if (parts[0] && knownIds.includes(parts[0])) {
    machine = parts[0];
    $("machine").value = machine;
    const [, r, a, b] = parts;
    renderTopCard();
    status("loading…");
    if (r === "rank" && a != null && b != null) renderRank(parseInt(a, 10), parseFloat(b));
    else if (r === "compare" && a != null) renderCompare(a.split("+").map(decodeURIComponent));
    else if (!r || (r === "layout" && !a)) renderOverviewQ();
    else if (r === "layout") renderMemLayout(a);
    else if (r === "algorithm") renderAlgo(decodeURIComponent(a));
    else renderOverviewQ();
  } else {
    const view = parts.filter(Boolean).join("/");
    location.replace(`#/${machine}/${view}`);
    return route();
  }
}

// hover a source line / asm block → highlight its pair (delegated)
document.addEventListener("mouseover", (e) => { const el = e.target.closest?.("[data-g]"); if (el && el.dataset.g) document.querySelectorAll(`[data-g="${el.dataset.g}"]`).forEach(n => n.classList.add("hl")); });
document.addEventListener("mouseout",  (e) => { const el = e.target.closest?.("[data-g]"); if (el && el.dataset.g) document.querySelectorAll(`[data-g="${el.dataset.g}"]`).forEach(n => n.classList.remove("hl")); });

// click a winners box → the full ranked chart view
document.addEventListener("click", (e) => {
  if (e.target.closest("a")) return;
  const td = e.target.closest("td[data-n]");
  if (td) location.hash = mhref(`rank/${td.dataset.n}/${td.dataset.q}`);
});

(async () => {
  try {
    MACHINES = await fetchJSON("analysis/machines.json");
    const ms = $("machine");
    MACHINES.machines.forEach((m) => { const o = document.createElement("option"); o.value = m.machine_id; o.textContent = shortMachine(m.machine_id); ms.add(o); });
    const initHash = location.hash.replace(/^#\/?/, "").split("/")[0];
    const knownIds = MACHINES.machines.map((m) => m.machine_id);
    machine = knownIds.includes(initHash) ? initHash : MACHINES.machines[0].machine_id;
    ms.value = machine;
    const ts = $("threads");
    [1].forEach((t) => { const o = document.createElement("option"); o.value = t; o.textContent = `T=${t}`; ts.add(o); });
    ts.value = threads;
    ms.onchange = () => {
      machine = ms.value;
      qSel = [];                      // q selection is machine-scoped; next render repopulates
      buildQDrop();
      const raw = location.hash.replace(/^#\/?/, "");
      const parts = raw.split("/");
      const knownIds = MACHINES.machines.map((m) => m.machine_id);
      const view = knownIds.includes(parts[0]) ? parts.slice(1).join("/") : parts.join("/");
      location.hash = `#/${machine}/${view}`;
    };
    ts.onchange = () => { threads = +ts.value; route(); };
    buildQDrop();
    document.addEventListener("click", (e) => {
      if (!e.target.closest("#qdrop")) $("qdrop")?.classList.remove("open");
    });
    window.addEventListener("hashchange", route);
    route();
  } catch (e) { status(`error: ${e.message}`); console.error(e); }
})();
