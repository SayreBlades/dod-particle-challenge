# Analysis — machine index

The derived analysis layer, rebuilt by `scripts/build_report.py`. Raw data lives in `experiments/data/<machine_id>/`; this tree is the browsable + machine-readable reading of it. Open `experiments/report.html` for the interactive SPA (machine- + thread-group-scoped, three-tier drill-down).

The only honest cross-machine view: each machine's hardware facts side by side. Absolute ns/p across microarchitectures is meaningless; normalized comparison (% of ceiling, which algo_fam wins) is a Phase-3 deliverable, not built here.

| machine_id | cpu | streaming BW | L1d | L2 | L3 | layouts |
|---|---|---|---|---|---|---|
| [`madbits-8c44a80e`](madbits-8c44a80e/) | AMD Ryzen 9 3900X 12-Core Processor | 12.69 GB/s | 32 KB | 0 MB | 16777216 | ML01 |
| [`minibits-82398588`](minibits-82398588/) | Apple M4 | 29.9 GB/s | 64 KB | 4 MB | — | ML01 |

Per machine: `<machine_id>/README.md` (overview) → `<machine_id>/<L>.mem_layout.md` (mem_layout) → `<machine_id>/<algo>.md` (the per-algo narrative).
