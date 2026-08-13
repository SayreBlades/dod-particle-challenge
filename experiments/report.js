// report.js — machine/thread-scoped SPA over experiments/analysis/.
// Routes: #/<machine>/ (overview) · #/<machine>/layout/<L> · #/<machine>/algorithm/<algorithm> · #/<machine>/rank/<N>/<q>. Loads ECharts + marked.
const $ = (id) => document.getElementById(id);
const status = (m) => ($("status").textContent = m);
const short = (algo) => algo.split(".").slice(1).join(".");
const fmtq = (d) => (d === 0 ? "0" : String(d));
const fmtN = (n) => n >= 1e6 ? `${n / 1e6}M` : n >= 1e3 ? `${n / 1e3}K` : `${n}`;
const mhref = (path) => `#/${machine}/${path}`;  // machine-scoped hash link
const axisTooltip = { trigger: "axis", formatter(params) { const p = Array.isArray(params) ? params : [params]; const hdr = `<div style="text-align:center;margin-bottom:4px">${fmtN(Math.round(p[0].axisValue))} Particles</div>`; return hdr + p.filter(x => x.seriesName !== '__cache' && x.seriesName !== '__marks').map(x => { const name = x.seriesName.startsWith('q=') ? '' : x.seriesName + ': '; return `${x.marker} ${name}${x.value[1] != null ? x.value[1].toFixed(2) : '-'}`; }).join('<br/>'); } };
const charts = [];
window.addEventListener("resize", () => charts.forEach((c) => c.resize()));
const AX = { axisLine: { lineStyle: { color: "#666" } }, axisLabel: { color: "#aaa" },
             splitLine: { lineStyle: { color: "#2a2a2a" } }, nameTextStyle: { color: "#aaa" } };

let MACHINES, machine, threads = 1;
const ovCache = {}, layCache = {}, algoCache = {};
const fetchJSON = (u) => fetch(u).then((r) => r.ok ? r.json() : null);
const fetchText = (u) => fetch(u).then((r) => r.ok ? r.text() : "");

function getOverview(m)   { return ovCache[m]   ?? (ovCache[m]   = fetchJSON(`analysis/${m}/overview.json`)); }
function getMemLayout(m, L)  { return layCache[m+L]?? (layCache[m+L]= fetchJSON(`analysis/${m}/${L}.mem_layout.json`)); }
function getAlgoJson(m, c){ const k=m+"/"+c; return algoCache[k] ?? (algoCache[k]= (async()=>{return fetchJSON(`analysis/${m}/${c}.json`);})()); }
const gridCache = {};
const getGrid = (m) => gridCache[m] ?? (gridCache[m] = fetchJSON(`analysis/${m}/grid.json`));

function cellColor(algo) { let h = 0; for (let i = 0; i < algo.length; i++) h = (h * 31 + algo.charCodeAt(i)) >>> 0; return `hsl(${h % 360} 65% 62%)`; }
function pickThreads(rows) { const t = rows.filter((r) => r.threads === threads); return t.length ? t : rows.filter((r) => r.threads === 1); }

// ---- meta strip ----
function renderMeta(o) {
  $("meta").innerHTML = [
    `<span>${o.cpu ?? "?"}</span>`,
    `<span><b>Mem Bandwidth</b> <code>${o.streaming_bw_gbs ?? "?"} GB/s</code></span>`,
    `<span><b>Mem Cache</b> L1d <code>${(o.l1dcachesize / 1024) | 0} KB</code></span>`,
    `<span><b>Mem Cache</b> L2 <code>${(o.l2cachesize / 1048576) | 0} MB</code></span>`,
  ].join("<br>");
}

// ---- chart helper ----
function chart(id, opt, group) {
  const el = document.getElementById(id);
  if (!el) return null;
  const c = echarts.init(el); charts.push(c);
  if (group) { c.group = group; echarts.connect(group); }   // linked brush across plots in a group
  c.setOption(opt);
  return c;
}

function machineCard() {
  const m = (MACHINES.machines || []).find((x) => x.machine_id === machine) || {};
  if (!m.cpu) return "";
  return `<section class="cellhead machinecard"><h2>${m.cpu}</h2><div class="machinfo"><div><b>Mem Bandwidth</b> <code>${m.streaming_bw_gbs ?? "?"} GB/s</code></div><div><b>Mem Cache</b> L1d <code>${(m.l1dcachesize / 1024) | 0} KB</code></div><div><b>Mem Cache</b> L2 <code>${(m.l2cachesize / 1048576) | 0} MB</code></div><div><b>DRAM</b> <code>${(m.memsize_bytes / 1073741824) | 0} GB</code></div></div></section>`;
}

// persistent machine card above the banner; refreshed on every route
function renderTopCard() { const el = $("topcard"); if (el) el.innerHTML = machineCard(); }

// ---------------- overview ----------------
async function renderOverview() {
  const ov = await getOverview(machine);
  if (!ov) { status("no data"); return; }
  renderMeta(ov);
  const champs = ov.champions.filter((c) => c.threads === threads);
  // color scale spans the WINNING (rank-1) times only: best winner → green, worst → red.
  // (all ranks pegged hi with slow 3rd-place times, so every box tinted green.)
  const w = champs.filter((c) => c.rk === 1);
  const ns = (w.length ? w : champs).map((c) => c.ns_particle);
  const lo = Math.min(...ns), hi = Math.max(...ns);
  const nvals = ov.n_values, deaths = ov.death_rates;
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

// ---------------- layout ----------------
async function renderMemLayout(L) {
  const lb = await getMemLayout(machine, L);
  if (!lb) { status(`no bundle for ${L}`); return; }
  renderMeta({ ...lb, cpu: (MACHINES.machines.find((m) => m.machine_id === machine) || {}).cpu });
  const champs = lb.champions.filter((c) => c.threads === threads);
  // color scale spans the WINNING (rank-1) times only: best winner → green, worst → red.
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
// ---- Algorithm section (deterministic, from algo_meta + name) ----
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
  // Pull just the testable claim out of the Intent narrative — the Algorithm
  // table already states the declaration, so the rest is redundant.
  if (!md) return "";
  const s = md.replace(/\*\*/g, "");
  let m = s.match(/Hypothesis:?\s*(.+?)(?:\.\s|\.$|$)/i);
  if (m && m[1].trim()) return m[1].trim().replace(/\.$/, "") + ".";
  m = s.match(/(tests?\s+(?:whether|if)\b.+?)(?:\.\s|\.$|$)/i);
  if (m) return m[1].trim().replace(/\.$/, "") + ".";
  const parts = s.split(/(?<=[.])\s+/).filter(Boolean);
  return (parts[parts.length - 1] || "").trim();
}

function algoFamTable(j, algo) {
  const loops = ALGO_FAMS[j.algo_meta.algo_fam] || [];
  const algoPart = loopSchedules(algo);
  let t = `<table class="alg"><tbody>`;
  for (let i = 0; i < 3; i++) {
    if (loops[i]) t += `<tr><td class="walknum">loop ${i + 1}</td><td>${loops[i].join(", ")}</td><td>${algoPart[i + 1] || ""}</td></tr>`;
  }
  return t + `</tbody></table>`;
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

function classByMnem(b, raw) {
  if (/^ld[1-4]$/.test(b)) return "vload";
  if (/^st[1-4]$/.test(b)) return "vstore";
  if (/^(ldp|ldr|ldur|ldrb|ldrh)$/.test(b)) return "load";
  if (/^(stp|str|stur|strb|strh)$/.test(b)) return "store";
  if (/^(fmul|fadd|fmla|fmls|fsub|fdiv|fmov|fmin|fmax|fsqrt|fneg|fabs|fcmp|fcsel|fcvt|scvtf|ucvtf)$/.test(b)) return "fp";
  if (/^(b|bl|br|ret|cbz|cbnz|tbz|tbnz)$/.test(b) || /^b\./.test(raw)) return "branch";
  if (/^(cmp|cmn|tst|ccmp)$/.test(b)) return "cmp";
  if (/^(dup|ext|movi|ins|umov|smov)$/.test(b)) return "vec";
  return "other";
}
function asmClass(line) {
  const t = line.split("\t");
  if (t.length >= 2 && /^[0-9a-f]{16}$/.test(t[0])) return classByMnem((t[1].split(".")[0] || "").toLowerCase(), t[1]);
  if (line.startsWith("_") && line.trim().endsWith(":")) return "label";
  return "other";
}
function asmClassMnem(line) {            // attributed line: "mnem\toperands"
  const first = (line.split("\t")[0] || "");
  return classByMnem((first.split(".")[0] || "").toLowerCase(), first);
}

const ASM_LEGEND = [["label", "symbol/label"], ["vload", "NEON load (ld1–4)"], ["vstore", "NEON store (st1–4)"],
  ["load", "scalar load (ldr/ldp)"], ["store", "store (str/stp)"], ["fp", "FP math (fmul/fadd…)"],
  ["branch", "branch (b/cbz/ret)"], ["cmp", "compare (cmp/ccmp)"], ["vec", "vector op (dup/ext/movi)"], ["other", "other"]];

// ---- assembly viewer (godbolt-like, with view modes + GitHub source link) ----
// j.asm.algo_source      = {file, lines[], group_lines[gi] -> srcLineNo|null}
// j.asm.source_attributed = [{source, asm[]}] in address order
// Four modes share aligned mnemonic/operand columns:
//   link (side-by-side, hover/click) · interleave (src + nested asm) · source · asm
const ASM_COLORS = ["#2d5a44","#5a2d44","#2d4a5a","#5a442d","#4a2d5a","#2d5a5a","#5a5a2d","#442d5a"];
const REPO_URL = "https://github.com/SayreBlades/dod-particle-challenge";
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/\t/g, "  ");
const srcFileUrl = (file, sha, line) => `${REPO_URL}/blob/${sha || "main"}/${file}${line ? `#L${line}` : ""}`;
const splitAsm = (line) => { const t = line.indexOf("\t"); return t < 0 ? [line, ""] : [line.slice(0, t), line.slice(t + 1)]; };
let asmMode = "link";                          // persists across algorithm navigation

const GH_SVG = `<svg width="13" height="13" viewBox="0 0 16 16" fill="currentColor" style="vertical-align:-1px"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>`;

function asmRowHtml(line, ln) {
  const [mnem, ops] = splitAsm(line);
  return `<div class="asm-row ${asmClassMnem(line)}">${ln != null ? `<span class="gb-ln">${ln}</span>` : ""}<span class="asm-mnem">${esc(mnem)}</span><span class="asm-ops">${esc(ops)}</span></div>`;
}
function asmGroupHtml(g, gi, ln, color) {    // ln: running counter or null; color: explicit border or undefined→cycle
  const c = color != null ? color : ASM_COLORS[gi % ASM_COLORS.length];
  let rows = "";
  for (const line of g.asm) rows += asmRowHtml(line, ln != null ? ln++ : null);
  return { html: `<div class="asm-grp" data-g="${gi}" style="border-left-color:${c}">${rows}</div>`, ln };
}
function flatAsmHtml(j) {                     // fallback when no source attribution
  let html = "";
  (j.asm.excerpt || "").split("\n").forEach((ln0, i) => {
    html += `<span class="ic ${asmClass(ln0)}"><span class="ln">${String(i + 1).padStart(3, " ")}</span>${esc(ln0)}</span>`;
  });
  return html;
}

function asmToolbar(j, mode) {
  const cs = j.asm.algo_source;
  const tabs = [["link", "Linked", "Side-by-side with hover/click linking (godbolt)"],
                ["interleave", "Interleaved", "Source with its assembly nested beneath each line"],
                ["source", "Source", "The original source file"],
                ["asm", "Assembly", "Full disassembly, grouped by source line"]]
    .map(([m, label, title]) => `<button type="button" class="asm-tab${mode === m ? " on" : ""}" data-mode="${m}" title="${title}">${label}</button>`).join("");
  const fileLink = cs
    ? `<a class="asm-gh" href="${srcFileUrl(cs.file, j.git_sha)}" target="_blank" title="Open ${esc(cs.file)} on GitHub">${GH_SVG}${esc(cs.file)} ↗</a>`
    : `<span class="asm-gh none">${esc(j.asm.symbol)}</span>`;
  return `<div class="asm-toolbar"><div class="asm-tabs">${tabs}</div><span class="asm-info">${j.asm.n_instructions} instructions · ${j.asm.vector_insns} vector</span>${fileLink}</div>`;
}

function asmViewer(j) {
  const legend = `<div class="asmleg">${ASM_LEGEND.map(([c, l]) => `<span class="asmlegitem"><i class="icdot ${c}"></i>${l}</span>`).join("")}</div>`;
  return `${asmToolbar(j, asmMode)}${legend}<div id="asmbody" class="asm-body"></div>`;
}

// ---- mode renderers ----
function sideBySideHtml(j) {
  const attributed = j.asm.source_attributed, cs = j.asm.algo_source;
  if (!attributed || !cs) return `<pre class="asm">${flatAsmHtml(j)}</pre>`;
  const lineGroup = {};
  cs.group_lines.forEach((cl, gi) => { if (cl && !(cl in lineGroup)) lineGroup[cl] = gi; });
  let srcHtml = "";
  cs.lines.forEach((line, i) => {
    const ln = i + 1, gi = lineGroup[ln], linked = gi !== undefined;
    const c = linked ? ASM_COLORS[gi % ASM_COLORS.length] : null;
    srcHtml += `<div class="gb-src${linked ? " linked" : ""}"${linked ? ` data-g="${gi}"` : ""} data-line="${ln}"${c ? ` style="border-left-color:${c}"` : ""}><span class="gb-ln">${ln}</span>${esc(line) || " "}</div>`;
  });
  let asmHtml = "", ln = 1;
  attributed.forEach((g, gi) => { const r = asmGroupHtml(g, gi, ln); ln = r.ln; asmHtml += r.html; });
  const fileLabel = esc(cs.file.split("/").slice(-2).join("/"));
  return `<div class="gb-head"><a class="gb-h gb-h-src" href="${srcFileUrl(cs.file, j.git_sha)}" target="_blank" title="Open on GitHub">${GH_SVG} ${fileLabel} ↗</a><span class="gb-h gb-h-asm">arm64 — ReleaseFast</span></div>` +
    `<div class="godbolt" data-grouplines='${JSON.stringify(cs.group_lines)}'>` +
    `<div class="gb-pane gb-pane-src">${srcHtml}</div>` +
    `<div class="gb-pane gb-pane-asm">${asmHtml}</div></div>`;
}

function interleaveHtml(j) {
  // Execution-order (godbolt-style): walk source_attributed in address order;
  // render each group's asm, inserting the attributed source line as a bright
  // divider wherever the disassembler mapped one. Unattributed groups flow on
  // with a faint gutter. (Attribution is sparse, so a file-order interleave would
  // bury most asm in a preamble — this keeps the full asm visible in context.)
  const cs = j.asm.algo_source, sa = j.asm.source_attributed;
  if (!cs || !sa) return `<pre class="asm">${flatAsmHtml(j)}</pre>`;
  const FAINT = "#23262b", lineColor = {};                 // file line → color idx (first-seen order)
  let lc = 0, html = "", ln = 1;
  sa.forEach((g, gi) => {
    const cl = cs.group_lines[gi];                         // file line number or null
    let color = FAINT;
    if (cl != null) {
      if (!(cl in lineColor)) lineColor[cl] = lc++ % ASM_COLORS.length;
      color = ASM_COLORS[lineColor[cl]];
      html += `<div class="il-src linked" style="border-left-color:${color}"><a class="gb-ln" href="${srcFileUrl(cs.file, j.git_sha, cl)}" target="_blank" title="Line ${cl} on GitHub">${cl}</a>${esc(cs.lines[cl - 1] || "")}</div>`;
    }
    const r = asmGroupHtml(g, gi, ln, color); ln = r.ln;
    html += `<div class="il-asmwrap">${r.html}</div>`;
  });
  return `<div class="interleave">${html}</div>`;
}

function sourceOnlyHtml(j) {
  const cs = j.asm.algo_source;
  if (!cs) return `<pre class="asm">${flatAsmHtml(j)}</pre>`;
  let html = "";
  cs.lines.forEach((line, i) => {
    const ln = i + 1;
    html += `<div class="il-src"><a class="gb-ln" href="${srcFileUrl(cs.file, j.git_sha, ln)}" target="_blank" title="Line ${ln} on GitHub">${ln}</a>${esc(line) || " "}</div>`;
  });
  return `<div class="interleave src-only">${html}</div>`;
}

function asmOnlyHtml(j) {
  const sa = j.asm.source_attributed;
  if (!sa) return `<pre class="asm">${flatAsmHtml(j)}</pre>`;
  let html = "", ln = 1;
  sa.forEach((g, gi) => { const r = asmGroupHtml(g, gi, ln); ln = r.ln; html += r.html; });
  return `<div class="asm-full">${html}</div>`;
}

function wireAsmViewer(j) {
  const body = $("asmbody");
  if (!body) return;
  const draw = () => {
    body.className = `asm-body mode-${asmMode}`;
    body.innerHTML = asmMode === "source" ? sourceOnlyHtml(j)
                   : asmMode === "asm" ? asmOnlyHtml(j)
                   : asmMode === "interleave" ? interleaveHtml(j)
                   : sideBySideHtml(j);
    if (asmMode === "link") setupLinked();
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

function setupLinked() {
  const src = document.querySelector(".gb-pane-src");
  const asm = document.querySelector(".gb-pane-asm");
  const gb = document.querySelector(".godbolt");
  if (!src || !asm || !gb) return;
  const groupLines = JSON.parse(gb.dataset.grouplines || "[]");
  const flash = (g) => {
    document.querySelectorAll(".gb-hl").forEach((n) => n.classList.remove("gb-hl"));
    document.querySelectorAll(`[data-g="${g}"]`).forEach((n) => n.classList.add("gb-hl"));
  };
  src.addEventListener("click", (e) => {                       // source line -> its asm block
    const r = e.target.closest("[data-g]"); if (!r) return;
    const g = asm.querySelector(`.asm-grp[data-g="${r.dataset.g}"]`);
    if (g) { asm.scrollTop = g.offsetTop; flash(r.dataset.g); }   // instant — smooth scroll is flaky across browsers/CDP
  });
  asm.addEventListener("click", (e) => {                       // asm block -> its source line (if linked)
    const r = e.target.closest(".asm-grp"); if (!r) return;
    const gi = r.dataset.g, cl = groupLines[gi];
    if (cl) { const s = src.querySelector(`[data-line="${cl}"]`); if (s) s.scrollIntoView({ block: "center" }); }
    flash(gi);
  });
}

async function renderAlgo(algo) {
  const L = algo.split(".")[0];
  const [j, md, lb] = await Promise.all([
    getAlgoJson(machine, algo), fetchText(`analysis/${machine}/${algo}.md`), getMemLayout(machine, L)]);
  if (!j) { $("page").innerHTML = `<section><p>No analysis bundle for ${algo}.</p></section>`; status("missing"); return; }
  renderMeta(j.hardware);
  const d = j.algo_meta;
  const decl = `<div class="decl"><span><b>algo_fam</b> ${d.algo_fam}</span><span><b>ordering</b> ${d.ordering}</span><span><b>intermediates</b> ${d.intermediates}</span><span><b>golden</b> ${d.golden_class}</span><span><b>bytes/p</b> ${j.bytes_per_particle}</span><span><b>source_hash</b> <code>${(j.source_hash || "").slice(0, 12)}</code></span></div>`;
  const n = splitNarrative(md || "");
  const mp = (k) => marked.parse(n[k] || "<p class='hint'>(no narrative)</p>");
  const mem = lb && lb.memory_layout
    ? `<section><h2>Particle Layout</h2><pre class="memlayout">${lb.memory_layout}</pre><p class="hint">Struct stride; this algorithm's bytes/p (${j.bytes_per_particle}) includes its blueprint intermediate (${d.intermediates}).</p></section>`
    : "";
  const wtable = algoFamTable(j, algo);
  const hyp = extractHypothesis(n["Intent"]);
  const hypo = hyp ? `<div class="hypothesis"><b>Hypothesis:</b> ${marked.parseInline(hyp)}</div>` : "";
  const vraw = (n["Verdict"] || "").trim();
  const vkind = /^holds\b/i.test(vraw) ? "holds" : /^partially\b/i.test(vraw) ? "partial" : /^refuted\b/i.test(vraw) ? "refuted" : "";
  const verdict = vraw ? `<section class="verdict ${vkind}"><h3>Verdict</h3>${marked.parse(vraw)}</section>` : "";
  const banner = j.verified === false
    ? `<div class="unverified">⚠ <b>narrative failed verification</b> — the prose cites evidence not in the bundle. Regenerate with <code>scripts/analyze_algo.py ${algo} --force</code>${j.verify_errors?.length ? `<br><span class=hint>${j.verify_errors.join("; ")}</span>` : ""}</div>`
    : "";
  $("page").innerHTML = `
    ${banner}
    ${mem}
    <section class="cellhead"><h2>${short(algo)}</h2><div class="cellfull">${algo}</div>${decl}${wtable}${hypo}${verdict}</section>
    <section class="narrative"><h3>Latency</h3>${mp("Cache saturation")}<div id="cacheplot" class="chart"></div></section>
    <section class="narrative"><h3>Bandwidth</h3>${mp("Bandwidth")}<div id="bwplot" class="chart"></div></section>
${(j.profile || []).length ? `<section class="narrative"><h3>Bottleneck radar <span class="sub">goodness per axis (bigger = better)</span></h3><div style="margin:6px 0;display:flex;gap:12px;align-items:center;font-size:12px;color:#9aa"><label>N <select id=\"radarN\"></select></label><label>q <select id=\"radarQ\"></select></label> <span id="radarcap" class="sub"></span></div><div id="radar" class="chart" style="height:380px"></div></section>` : `<section class="narrative"><h3>Bottleneck radar</h3><p class="hint">No cycle-attribution data for ${short(algo)} — run <code>scripts/collect.py ${algo} --only profile</code> to populate it.</p></section>`}
    <section class="narrative"><h3>Assembly</h3>${mp("Assembly")}<div id="asmplot" class="chart small"></div>${asmViewer(j)}</section>`;
  status(`${algo} · ${j.asm.n_instructions} asm insns`);
  drawCachePlot(j);
  drawBandwidthAlgo(j);
  if ((j.profile || []).length) drawRadar(j);
  drawAsm(j);
  wireAsmViewer(j);
}

function cacheBands(j) {
  const t = j.cache_transitions || [];      // [["L1d",963],["L2",61680], maybe L3]
  const ns = Object.values(j.series).flat().map((r) => r.N);
  if (!ns.length) return { silent: true, data: [], axisMin: null };
  const lo = Math.min(...ns), hi = Math.max(...ns);
  const cuts = t.map((x) => x[1]), names = t.map((x) => x[0]);
  // start the axis at the data's minimum N (a log axis can't reach 0)
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

function drawCachePlot(j) {
  const qs = Object.keys(j.series).sort((a, b) => +a - +b);
  const real = qs.map((q) => ({ name: `q=${q}`, type: "line", symbol: "circle", symbolSize: 5,
    data: pickThreads(j.series[q]).map((r) => [r.N, r.ns_particle]) }));
  const bands = cacheBands(j);
  const carrier = { name: "__cache", type: "line", data: [], symbol: "none", lineStyle: { opacity: 0 }, silent: true, markArea: bands };
  chart("cacheplot", {
    tooltip: axisTooltip, legend: { top: 0, textStyle: { color: "#ccc", fontSize: 10 }, data: real.map((s) => s.name) },
    grid: { left: 55, right: 20, top: 30, bottom: 55, containLabel: true },
    xAxis: { type: "log", name: "N", min: bands.axisMin, ...AX, axisLabel: { ...AX.axisLabel, formatter: (v) => v >= 1e6 ? `${v / 1e6}M` : v >= 1e3 ? `${v / 1e3}K` : v } },
    yAxis: { type: "value", name: "ns/particle", ...AX },
    series: [...real, carrier], dataZoom: [{ type: "slider", bottom: 8, height: 16 }],
  }, "algo-link");
}

function drawBandwidthAlgo(j) {
  const qs = Object.keys(j.series).sort((a, b) => +a - +b);
  const ceil = j.hardware.streaming_bw_gbs;
  const real = qs.map((q) => ({ name: `q=${q}`, type: "line", symbol: "circle", symbolSize: 4,
    data: pickThreads(j.series[q]).map((r) => [r.N, r.achieved_bw_gbs]).filter((p) => p[1] != null) }));
  const bands = cacheBands(j);
  const carrier = { name: "__marks", type: "line", data: [], symbol: "none", lineStyle: { opacity: 0 }, silent: true,
    markArea: bands,
    markLine: { silent: true, symbol: "none", data: [{ yAxis: ceil, lineStyle: { type: "dashed", color: "#e74c3c", width: 2 }, label: { formatter: `ceiling ${ceil}`, color: "#e74c3c", position: "insideEndTop" } }] } };
  chart("bwplot", {
    tooltip: axisTooltip, legend: { top: 0, textStyle: { color: "#ccc", fontSize: 10 }, data: real.map((s) => s.name) },
    grid: { left: 55, right: 20, top: 30, bottom: 55, containLabel: true },
    xAxis: { type: "log", name: "N", min: bands.axisMin, ...AX, axisLabel: { ...AX.axisLabel, formatter: (v) => v >= 1e6 ? `${v / 1e6}M` : v >= 1e3 ? `${v / 1e3}K` : v } },
    yAxis: { type: "value", name: "GB/s", ...AX },
    series: [...real, carrier], dataZoom: [{ type: "slider", bottom: 8, height: 16 }],
  }, "algo-link");
}

function drawAsm(j) {
  const entries = Object.entries(j.asm.histogram).sort((a, b) => b[1] - a[1]).slice(0, 22);
  chart("asmplot", {
    tooltip: {}, grid: { left: 40, right: 16, top: 10, bottom: 60, containLabel: true },
    xAxis: { type: "category", data: entries.map((e) => e[0]), axisLabel: { rotate: 45, color: "#aaa", fontSize: 9 }, axisLine: { lineStyle: { color: "#666" } } },
    yAxis: { type: "value", ...AX },
    series: [{ type: "bar", data: entries.map((e) => e[1]), itemStyle: { color: "#5dade2" } }],
  });
}

// ---------------- bottleneck radar (algo page) ----------------
// 5 goodness axes (0–100, bigger = better). Compute/Latency/Control come from
// cycle attribution (profile, always T=1); Bandwidth/Sync come from timing at
// the global thread count. Per (N, q) — the character shifts with both: high q
// raises branch_flush (Control drops); high N raises backend_stall (Latency drops).
function profAt(j, N, q) {
  return (j.profile || []).find((p) => p.N === N && Math.abs(p.death_q - q) < 1e-9 && p.threads === 1);
}
function seriesAt(j, q, N, T) {
  return (j.series[String(q)] || []).find((r) => r.N === N && r.threads === T);
}
function radarScores(j, N, q, T) {
  const ceil = j.hardware.streaming_bw_gbs;
  const p = profAt(j, N, q), rT = seriesAt(j, q, N, T), r1 = seriesAt(j, q, N, 1);
  const compute = p ? +p.compute_pct : null;
  const latency = p ? 100 - +p.backend_stall_pct : null;
  const control = p ? 100 - +p.branch_flush_pct : null;
  const bandwidth = rT && ceil ? Math.min(100, (rT.achieved_bw_gbs / ceil) * 100) : null;
  let sync = 100;
  if (T !== 1 && r1 && rT) sync = (r1.ns_particle / (rT.ns_particle * T)) * 100;
  return { compute, bandwidth, latency, sync, control, profiler: p ? p.profiler : null };
}
function drawRadar(j) {
  const allN = [...new Set(Object.values(j.series).flat().map((r) => r.N))].sort((a, b) => a - b);
  const allQ = Object.keys(j.series).map(Number).sort((a, b) => a - b);
  const elN = $("radarN"), elQ = $("radarQ");
  if (!elN || !elQ) return;
  allN.forEach((n) => elN.add(new Option(fmtN(n), n)));
  allQ.forEach((q) => elQ.add(new Option(fmtq(q), q)));
  let N = allN[allN.length - 1];
  let q = allQ.includes(0.25) ? 0.25 : allQ[Math.min(2, allQ.length - 1)];
  elN.value = N; elQ.value = q;
  let rc = null;
  const AXES = ["Compute", "Bandwidth", "Latency", "Sync", "Control"];
  const draw = () => {
    const s = radarScores(j, N, q, threads);
    const cap = $("radarcap");
    if (cap) cap.innerHTML = s.compute == null
      ? `<span style="color:#e74c3c">no cycle attribution at N=${fmtN(N)}, q=${fmtq(q)}</span>`
      : `cycle attribution @ T=1 via <b>${s.profiler || "?"}</b> · bandwidth/sync @ T=<b>${threads}</b>`;
    const opt = s.compute == null
      ? { title: { text: "—", left: "center", top: "center", textStyle: { color: "#444" } } }
      : {
          tooltip: { formatter: (p) => AXES.map((a, i) => `${a}: ${p.value[i]}`).join("<br>") },
          radar: {
            indicator: AXES.map((a) => ({ name: a, max: 100 })),
            radius: "62%",
            axisName: { color: "#bbb", fontSize: 11 },
            splitLine: { lineStyle: { color: "#2a2a2a" } },
            splitArea: { areaStyle: { color: ["rgba(255,255,255,0.015)", "rgba(255,255,255,0.035)"] } },
            axisLine: { lineStyle: { color: "#333" } },
          },
          series: [{
            type: "radar",
            data: [{ value: [s.compute, s.bandwidth, s.latency, s.sync, s.control].map((v) => Math.round(v || 0)),
                     name: short(j.algo) }],
            areaStyle: { color: "rgba(93,173,226,0.22)" },
            lineStyle: { color: "#5dade2", width: 2 },
            itemStyle: { color: "#5dade2" },
          }],
        };
    if (!rc) rc = chart("radar", opt); else rc.setOption(opt, true);
  };
  elN.onchange = () => { N = +elN.value; draw(); };
  elQ.onchange = () => { q = +elQ.value; draw(); };
  draw();
}

// ---------------- rank: every algorithm at one (N, death_q, threads) ----------------
async function renderRank(N, q) {
  const g = await getGrid(machine);
  const ment = (MACHINES.machines.find((m) => m.machine_id === machine) || {});
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
  }
  $("page").innerHTML = html;
  status(`${title} · ${pts.length} algorithms`);
  if (pts.length) drawRankCharts(pts, ceil);
}

function drawRankCharts(pts, ceil) {
  const h = Math.max(260, pts.length * 26 + 40);
  const el = document.getElementById("rankpyramid");
  if (el) el.style.height = h + "px";
  // One diverging ("negative-bar") chart, names on the FAR LEFT, sides FLIPPED:
  // bandwidth is negated so its bars grow ← from the 0-line, latency grows → —
  // the two groups are back-to-back at 0 (barGap:-100% lays both series into one
  // row band so they share that back). The 0-line lands where the data ratio
  // puts it, so the two headings are centered over their halves from that split.
  // animation is off — otherwise the dashed ceiling markLine draws in jankily.
  const order = [...pts].sort((a, b) => a.ns_particle - b.ns_particle);
  const names = order.map((p) => short(p.algo));
  const lat = order.map((p) => p.ns_particle);             // positive → grows right of 0
  const bw = order.map((p) => -(p.achieved_bw_gbs ?? 0));  // NEGATED → grows left of 0
  const maxLat = Math.max(...order.map((p) => p.ns_particle));
  const bwExtent = Math.ceil((ceil || 1) * 1.1);          // left-side headroom incl. ceiling
  const plotL = 15, plotR = 95;                            // approx plot edges, % of chart
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
      axisLabel: { color: "#5dade2", fontSize: 11 },       // names styled like links
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
  // pointer cursor over any valid row (a bar OR its name); with the axis shadow
  // the whole row highlights on hover — click anywhere in it → deep dive.
  const zr = c?.getZr?.();
  const rowAt = (y) => {
    if (!c || y == null) return null;
    const idx = Math.round(c.convertFromPixel({ yAxisIndex: 0 }, y));
    return order[idx]?.algo ?? null;
  };
  zr?.on("mousemove", (e) => { zr.setCursorStyle(rowAt(e.offsetY != null ? e.offsetY : e.event?.offsetY) ? "pointer" : "default"); });
  zr?.on("click", (e) => { const algo = rowAt(e.offsetY != null ? e.offsetY : e.event?.offsetY); if (algo) location.hash = mhref(`algorithm/${algo}`); });
}

// ---------------- router ----------------
// Hash format: #/<machine_id>/<view>/<args…>
// Legacy (no machine prefix) redirects to the current/default machine.
function route() {
  charts.length = 0;
  $("page").innerHTML = "";
  const raw = location.hash.replace(/^#\/?/, "");
  const parts = raw.split("/");

  // Detect if first segment is a known machine_id
  const knownIds = MACHINES.machines.map((m) => m.machine_id);
  if (parts[0] && knownIds.includes(parts[0])) {
    machine = parts[0];
    $("machine").value = machine;
    const [, r, a, b] = parts;
    renderTopCard();
    status("loading…");
    if (r === "rank" && a != null && b != null) renderRank(parseInt(a, 10), parseFloat(b));
    else if (!r || (r === "layout" && !a)) renderOverview();
    else if (r === "layout") renderMemLayout(a);
    else if (r === "algorithm") renderAlgo(decodeURIComponent(a));
    else renderOverview();
  } else {
    // Legacy route (no machine prefix) — redirect to current machine
    const view = parts.filter(Boolean).join("/");
    location.replace(`#/${machine}/${view}`);
    // location.replace with hash doesn't always fire hashchange synchronously,
    // so re-enter route to render immediately.
    return route();
  }
}

// godbolt side-by-side: hover a source line / asm row → highlight its whole
// source↔asm group (delegated; survives page rebuilds).
document.addEventListener("mouseover", (e) => { const el = e.target.closest?.("[data-g]"); if (el) document.querySelectorAll(`[data-g="${el.dataset.g}"]`).forEach(n => n.classList.add("hl")); });
document.addEventListener("mouseout",  (e) => { const el = e.target.closest?.("[data-g]"); if (el) document.querySelectorAll(`[data-g="${el.dataset.g}"]`).forEach(n => n.classList.remove("hl")); });

// ---- click a winners box → the full ranked chart view (no popover) ----
document.addEventListener("click", (e) => {
  if (e.target.closest("a")) return;                  // name links navigate to the algorithm page
  const td = e.target.closest("td[data-n]");
  if (td) location.hash = mhref(`rank/${td.dataset.n}/${td.dataset.q}`);
});

(async () => {
  try {
    MACHINES = await fetchJSON("analysis/machines.json");
    const ms = $("machine");
    MACHINES.machines.forEach((m) => { const o = document.createElement("option"); o.value = m.machine_id; o.textContent = `${m.cpu} · ${m.machine_id}`; ms.add(o); });
    // Default machine: prefer what's in the URL hash, else first in list
    const initHash = location.hash.replace(/^#\/?/, "").split("/")[0];
    const knownIds = MACHINES.machines.map((m) => m.machine_id);
    machine = knownIds.includes(initHash) ? initHash : MACHINES.machines[0].machine_id;
    ms.value = machine;
    const ts = $("threads");
    [1, 2, 4, 8].forEach((t) => { const o = document.createElement("option"); o.value = t; o.textContent = `T=${t}`; ts.add(o); });
    ts.value = threads;
    ms.onchange = () => {
      machine = ms.value;
      ovCache._cur = null;
      // Swap machine segment in current hash, preserve the view path
      const raw = location.hash.replace(/^#\/?/, "");
      const parts = raw.split("/");
      const knownIds = MACHINES.machines.map((m) => m.machine_id);
      const view = knownIds.includes(parts[0]) ? parts.slice(1).join("/") : parts.join("/");
      location.hash = `#/${machine}/${view}`;
    };
    ts.onchange = () => { threads = +ts.value; route(); };
    window.addEventListener("hashchange", route);
    route();
  } catch (e) { status(`error: ${e.message}`); console.error(e); }
})();
