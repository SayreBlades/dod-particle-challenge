# experiments/data/ — collected runs

One directory per `scripts/collect.sh` invocation:

```
<layout>/<timestamp>-<machine_id>-<short-sha>/
  runs.csv        # one row per (cell, mode, death_q, N, trial) — the data
  hardware.json   # machine facts sidecar (machine_id is the join key)
  meta.json       # run provenance (git sha, zig version, sweep config)
```

**Committed** (CSVs + JSON are small and are the whole point — runs from
different machines must combine in one repo). Raw `.trace`/PNG/video outputs
from the optional PMC / record instruments stay local under `.scratch/`
(gitignored).

`runs.csv` schema:

```
run_id,machine_id,cell,mode,death_q,threads,N,bytes_per_particle,trial,
ns_frame,ns_particle,gbs_eff,step_ns,render_ns
```

- `machine_id` is on every row (the hardware dimension); the full facts are in
  `hardware.json` (joined on `machine_id`).
- `trial` indexes the bench's repeated runs per N; analysis keeps the min
  (cleanest sample) and reports spread.
- `gbs_eff` is the clean step hot-loop bandwidth (step mode only); `step_ns`
  / `render_ns` decompose the frame (frame mode only).

The analysis notebook (`experiments/results/analyze.ipynb`) globs
`*/<layout>/*/runs.csv` — just drop in runs from each machine and re-run it.
