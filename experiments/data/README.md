# experiments/data/ — the source-of-truth measurement layer (host-partitioned, per-algo)

One directory per **host** (`<machine_id>/`). Each algorithm's measurements live
in per-algorithm files — the irreducible, machine-specific evidence that can't be
regenerated without re-running on that machine. [`../analysis/`](../analysis/) is
pure derivation from this layer (no toolchain needed at report time).

```
<machine_id>/
  hardware.json          # machine facts (one per host; the machine_id join key)
  <algo>.json            # ASM BUNDLE (immutable per source version; written by algo.py):
                         #   {source_hash, asm{symbol, n_instructions, vector_insns,
                         #     histogram, excerpt, source_attributed, algo_source}}
  <algo>.runs.jsonl      # append-only, kind-discriminated rows:
                         #   timing: {kind:"timing", provenance…, death_q, threads,
                         #            N, trial, iters, warmup, ns_frame, ns_particle,
                         #            bytes_per_particle, algo_meta…}
                         #   check:  {kind:"check", provenance…, death_q, threads, checked}
  <algo>.profile.jsonl   # append-only cycle-attribution rows (WHERE A PROFILER BACKEND
                         # EXISTS — xctrace on macOS now; absent on hosts without one):
                         #   {provenance…, N, death_q, threads, trial, iters,
                         #    profiler, cycles, compute, backend_stall, frontend_stall,
                         #    branch_flush, *_pct}
```

`<algo>` is the full algorithm name, e.g. `ML01.AF02.LP1-autovec.LP2-simple`.

**Writers** — all orchestrated by [`collect.py`](../../scripts/README.md#collectpy);
each is also a standalone atomic script:
- [`hardware_json.py`](../../scripts/README.md) → `hardware.json` (once per host)
- [`algo.py`](../../scripts/README.md) → `<algo>.json` (rebuilt when `source_hash` changes)
- [`bench.py`](../../scripts/README.md) → `<algo>.runs.jsonl` (timing rows + one check row per `(q, threads)`)
- [`profile.py`](../../scripts/README.md) (+ the `profile_xctrace.py` backend) → `<algo>.profile.jsonl`

**Committed** (the JSONL + JSON are small and are the whole point — runs from
different machines combine in one repo). Bulky profiler `.trace` files stay local
under `.scratch/` (gitignored) and are deleted after the numbers are extracted.

### Row semantics
- `machine_id` is on every row (the hardware dimension); full facts are in
  `hardware.json` (joined on `machine_id`).
- `source_hash` is the algorithm's `@import`-closure SHA-256
  ([`algo_hash.py`](../../scripts/README.md)); it pins the exact code that ran.
  Rows from a prior source version coexist (append-only); the report/loader
  filters to the current `source_hash`.
- `trial` indexes repeated runs per `(q, N, threads)`; the report takes the min
  (cleanest sample). With the single-point bench binary, the caller (`bench.py` /
  `collect.py`) loops trials and labels each row.
- `achieved_bw_gbs` is **derived in the report** (`bytes/p × N / ns_frame`), not
  stored — it compares against the host's `streaming_bw_gbs`.
- Profile buckets (`compute + backend_stall + frontend_stall + branch_flush`) sum
  to `cycles`; the `*_pct` fields sum to ~100. The `profiler` field names the
  backend (e.g. `xctrace`) so cross-machine comparisons carry an honest caveat.

Append-only by design: re-runs duplicate rows; dedup/filtering is a loader/report
concern. The derived analysis (champion grids, per-algo bundles, the LLM
narratives) lives in [`../analysis/`](../analysis/); the interactive report is
[`../report.html`](../report.html). Both are built by
[`build_report.py`](../../scripts/README.md#build_reportpy).
