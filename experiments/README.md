# experiments/ — data, derived analysis, and the report SPA

Three layers, changing on different clocks (see
[`.scratch/plan/reporting-and-analysis.md`](../.scratch/plan/reporting-and-analysis.md)):

| dir / file | what | changes when | written by |
|---|---|---|---|
| [`data/`](data/) | **RAW** — host-partitioned JSONL + `hardware.json` | every sweep | `collect.py` (the only writer) |
| [`analysis/`](analysis/) | **DERIVED** — per-cell bundles + machine/layout aggregations + a browsable markdown tree | every report-build | `build_report.py` (+ `analyze_cell.py`) |
| [`report.html`](report.html) + [`report.js`](report.js) + [`style.css`](style.css) | the **SPA** — thin: stores no data, fetches `analysis/` | hand-edited (rare) | (source) |
| [`sweeps/`](sweeps/) | the regime grid + `<layout>.cells` rosters + sweep-knob docs | when the sweep policy changes | (source) |
| [`golden/`](golden/) | `stage1.bin` + `frame.sha256` (the byte-exact reference) | when the reference cell changes | `correctness.zig` |

`collect.py` is pure measurement (writes only `data/`); **all** analysis —
champion grids, cache/bandwidth reads, the LLM narratives, the assembly
evidence — is computed at report-build time into `analysis/`. The asm is
reproduced by rebuilding each cell from its pinned source (cached by
`source_hash`), not captured during the sweep.

## Serve the report

```sh
python3 -m http.server -d experiments 8000   # open http://localhost:8000/report.html
```

(Served from the `experiments/` root so the SPA's `analysis/…` fetches
resolve. Or `make serve`.)

## The SPA

`report.html` is a thin hash-routed SPA (ECharts + marked.js from CDN). It
stores **no data** — every route fetches from `analysis/`:

- Two persistent selectors at the top: **machine** (from
  `analysis/machines.json`) and **thread group** {1, 4, 10}. Champions are
  partitioned by thread group (a parallel cell's T=10 and a serial cell's T=1
  never share a podium).
- **`#/`** — global top-3 per (regime × death_q) on the selected
  (machine, threads).
- **`#/layout/<L>`** — one layout's champion grid + performance landscape +
  achieved-vs-ceiling bandwidth + featured cells.
- **`#/cell/<cell>`** — the per-cell deep dive: header + Particle Layout +
  the cache-saturation + bandwidth plots (linked brush) + the colorized
  `step` disassembly + the Tier-2 narrative (rendered from the cell's `.md`).
  A cell whose narrative failed `--verify` shows a red banner.

## The analysis tree

```
analysis/
  README.md                 machine index (the only honest cross-machine view)
  machines.json             the SPA's machine selector source
  queries.sql               the canonical champion-grid SQL (documentary)
  <machine_id>/
    README.md               this machine's overview
    overview.json           global top-3 + meta
    <L>/
      README.md             champion grid + featured cells + all-cells list
      layout.json           top-K + featured + PMC + the struct diagram
      <cell>.md             the LLM narrative (Intent / Cache / Bandwidth / Assembly / Verdict)
      <cell>.json           the structured evidence the plots read (+ verified flag)
```

Rebuild with [`scripts/build_report.py`](../scripts/README.md#build_reportpy)
(`make report`); it exits nonzero if any cell narrative fails `--verify`.
