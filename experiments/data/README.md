# experiments/data/ — collected runs (host-partitioned, JSONL)

One directory per **host** (`<machine_id>/`), holding append-only JSONL files
that are the historical audit of every run on that machine:

```
<machine_id>/
  hardware.json   # machine facts (one per host; the machine_id join key)
  runs.jsonl      # one JSON object per (algorithm, death_q, threads, N, trial)
  checks.jsonl    # one JSON object per (algorithm, death_q) --check (invariant suite)
  pmc.jsonl       # one JSON object per (algorithm, N, death_q, trial) PMC row (optional)
```

**Committed** (JSONL + JSON are small and are the whole point — runs from
different machines combine in one repo). Raw `.trace` files from the optional
PMC instrument stay local under `.scratch/` (gitignored).

`runs.jsonl` row schema (denormalized — every row is self-describing):

```
run_id, ts_utc, host, machine_id, memory layout, algorithm, source_hash, git_sha,
git_branch, zig_version, death_q, threads, N, bytes_per_particle, trial,
ns_frame, ns_particle, algorithm family, ordering, intermediates, golden_class,
halide_expressible
```

- `machine_id` is on every row (the hardware dimension); the full facts are in
  `hardware.json` (joined on `machine_id`).
- `source_hash` is the algorithm's `@import`-closure SHA-256 (`scripts/algo_hash.py`);
  it pins the exact algorithm code that ran (catches uncommitted edits). `null` for
  migrated historical rows (pre-refactor); new rows from `collect.py` carry it.
- `trial` indexes the bench's repeated runs per N; the report keeps the min
  (cleanest sample) and reports spread.
- Static algorithm facts (`algorithm family`, `ordering`, `intermediates`, `golden_class`,
  `halide_expressible`) are denormalized onto every row so duckdb `GROUP BY
  algorithm family` works without a join.
- `achieved_bw_gbs` is **derived in the report** (`bytes/p × N / ns_frame`),
  not stored — it compares against the host's `streaming_bw_gbs`.

Append-only by design: re-runs duplicate rows; dedup/filtering is a
loader/report concern. **Nothing else is written here** — `collect.py` is the
only writer. The derived analysis (champion grids, per-algorithm bundles, the
LLM narratives) lives in [`../analysis/`](../analysis/); the interactive
report is [`../report.html`](../report.html) (served from the `experiments/`
root). Both are built by
[`scripts/build_report.py`](../../scripts/README.md#build_reportpy).
