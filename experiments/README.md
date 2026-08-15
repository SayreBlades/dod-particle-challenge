# experiments/ — data, derived analysis, and the report SPA

Three layers, changing on different clocks (see
[`.scratch/plan/reporting-and-analysis.md`](../.scratch/plan/reporting-and-analysis.md)):

| dir / file | what | changes when | written by |
|---|---|---|---|
| [`data/`](data/) | **RAW** — per-algo `<algo>.{json,runs.jsonl,profile.jsonl}` + `hardware.json` | every sweep | atomic scripts (`algo`/`bench`/`profile`/`hardware`), orchestrated by `collect.py` |
| [`analysis/`](analysis/) | **DERIVED** — per-algorithm bundles + machine/memory layout aggregations + a browsable markdown tree | every report-build | `build_report.py` (+ `analyze_algo.py`) |
| [`report.html`](report.html) + [`report.js`](report.js) + [`style.css`](style.css) | the **SPA** — thin: stores no data, fetches `analysis/` | hand-edited (rare) | (source) |
| [`build.zig`](../build.zig) → `algo_labels` | the algorithm registry (the sweep roster — parsed by `sweep_config.py`) | when an algorithm is added/removed | (source) |
| [`golden/`](golden/) | `stage1.bin` + `frame.sha256` (the byte-exact reference) | when the reference algorithm changes | `correctness.zig` |

`collect.py` orchestrates the atomic measurement scripts (`hardware`, `algo`,
`bench`, `profile`), all writing only `data/`. The asm bundle (`<algo>.json`) and
cycle attribution (`<algo>.profile.jsonl`) are captured at collection time, so
`analysis/` is pure derivation — `build_report.py` needs no toolchain (no zig /
otool / xctrace) at report time; it reads `data/` and computes champion grids,
cache/bandwidth reads, and the LLM narratives.

## Serve the report

```sh
uv run python -m http.server -d experiments 8000   # open http://localhost:8000/report.html
```

(Served from the `experiments/` root so the SPA's `analysis/…` fetches
resolve. Or `make serve`.)

## The SPA

`report.html` is a thin hash-routed SPA (ECharts + marked.js from CDN). It
stores **no data** — every route fetches from `analysis/`:

- Two persistent selectors at the top: **machine** (from
  `analysis/machines.json` — a slim discovery index: machine_id + cpu label;
  hardware facts live in each machine's `overview.json`, projected verbatim
  from `data/<machine_id>/hardware.json`) and **thread group** {1, 4, 8}. Champions are
  partitioned by thread group (a parallel algorithm's T=8 and a serial algorithm's T=1
  never share a podium).
- **`#/`** — global top-3 per (regime × death_q) on the selected
  (machine, threads).
- **`#/memory layout/<L>`** — one memory layout's champion grid + performance landscape +
  achieved-vs-ceiling bandwidth + featured algorithms.
- **`#/algorithm/<algorithm>`** — the per-algorithm deep dive: header + Particle Memory layout +
  the cache-saturation + bandwidth plots (linked brush) + the **bottleneck radar**
  (5 goodness axes — Compute / Bandwidth / Latency / Sync / Control — per `(N, q)`;
  needs `<algo>.profile.jsonl`, else shows a hint) + the colorized
  `step` disassembly + the Tier-2 narrative (rendered from the algorithm's `.md`).
  An algorithm whose narrative failed `--verify` shows a red banner.

## The analysis tree

```
analysis/
  README.md                 machine index (the only honest cross-machine view)
  machines.json             the SPA's machine-selector discovery index (id + cpu)
  <machine_id>/
    README.md               this machine's overview
    overview.json           global top-3 + meta
    <L>/
      README.md             champion grid + featured algorithms + all-algorithms list
      mem_layout.json           top-K + featured + PMC + the struct diagram
      <algorithm>.md             the LLM narrative (Intent / Cache / Bandwidth / Assembly / Verdict)
      <algorithm>.json           the structured evidence the plots read (+ verified flag)
```

Rebuild with [`scripts/build_report.py`](../scripts/README.md#build_reportpy)
(`make report`); it exits nonzero if any algorithm narrative fails `--verify`.
