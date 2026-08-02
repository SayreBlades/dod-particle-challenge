# experiments/data/ — collected runs (host-partitioned, JSONL)

One directory per **host** (`<machine_id>/`), holding append-only JSONL files
that are the historical audit of every run on that machine:

```
<machine_id>/
  hardware.json   # machine facts (one per host; the machine_id join key)
  runs.jsonl      # one JSON object per (cell, death_q, threads, N, trial)
  checks.jsonl    # one JSON object per (cell, death_q) --check (invariant suite)
  pmc.jsonl       # one JSON object per (cell, N, death_q, trial) PMC row (optional)
```

**Committed** (JSONL + JSON are small and are the whole point — runs from
different machines combine in one repo). Raw `.trace` files from the optional
PMC instrument stay local under `.scratch/` (gitignored).

`runs.jsonl` row schema (denormalized — every row is self-describing):

```
run_id, ts_utc, host, machine_id, layout, cell, source_hash, git_sha,
git_branch, zig_version, death_q, threads, N, bytes_per_particle, trial,
ns_frame, ns_particle, blueprint, ordering, intermediates, golden_class,
halide_expressible
```

- `machine_id` is on every row (the hardware dimension); the full facts are in
  `hardware.json` (joined on `machine_id`).
- `source_hash` is the cell's `@import`-closure SHA-256 (`scripts/cell_hash.py`);
  it pins the exact cell code that ran (catches uncommitted edits). `null` for
  migrated historical rows (pre-refactor); new rows from `collect.sh` carry it.
- `trial` indexes the bench's repeated runs per N; the report keeps the min
  (cleanest sample) and reports spread.
- Static cell facts (`blueprint`, `ordering`, `intermediates`, `golden_class`,
  `halide_expressible`) are denormalized onto every row so duckdb `GROUP BY
  blueprint` works without a join.
- `achieved_bw_gbs` is **derived in the report** (`bytes/p × N / ns_frame`),
  not stored — it compares against the host's `streaming_bw_gbs`.

Append-only by design: re-runs duplicate rows; dedup/filtering is a
loader/report concern. The report (`experiments/report/`) reads these via a
parquet built by `scripts/build_report.py`.
