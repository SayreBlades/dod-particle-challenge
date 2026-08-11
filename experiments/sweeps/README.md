# experiments/sweeps/ — sweep configs

One `<memory layout>.algos` file per memory layout: the algorithms to sweep, one per line (`#`
comments allowed). Sourced by `scripts/collect.py` when no algorithms are passed on
the command line. The `algo_meta` in each algorithm file is the source of truth
for what algorithms exist (`zig build manifests` prints the registered roster to
stdout as a diagnostic); this file selects the subset worth measuring.

## The regime grid (one pass, §17.5)

Every algorithm is swept once across (the grid lives in `scripts/sweep_config.py`;
the bench binary is a single-point primitive with NO built-in sweep):

| axis        | values                       | how it's set                                        |
|-------------|------------------------------|-----------------------------------------------------|
| **N**       | `4K, 65K, 262K, 1M, 4M`      | `sweep_config.N_GRID` (override with `NS=`)         |
| **death q** | `0.01, 0.05, 0.1, 0.25, 0.5` | `death_rates.txt` (override with `DEATH_RATES=`)    |
| **threads** | `1, 2, 4, 8`                 | parallel algorithms only (override with `THREADS=`) |

Serial algorithms run T=1 only (a serial algorithm ignores `--threads`, so looping it
would just emit duplicate rows). The champion grid is read straight off this
single pass — there is no second "champion pass" anymore.

## Sweep knobs (env vars to `collect.py`)

**The grid** (`NS`, `TRIALS`, `DEATH_RATES`, `THREADS`) selects *what* to
measure; **the run knobs** (`PARALLEL`, `SKIP_DONE`, `VERBOSE`) select *how*.

| var | default | meaning |
|-----|---------|---------|
| `NS` | *(sweep_config.N_GRID)* | comma-list of N (e.g. `4000,65000,1000000`) |
| `TRIALS` | `3` | trials per point (the report keeps the min) |
| `DEATH_RATES` | `0.01 0.05 0.1 0.25 0.5` | space-list of accident rates q (competing risks) |
| `THREADS` | `1 2 4 8` | space-list of worker counts (parallel algorithms only) |
| `PARALLEL` | *(cpu count)* | phase-1 build workers (zig's cache is concurrency-safe) |
| `SKIP_DONE` | `1` | skip points already present at the current `source_hash` — resume without duplicating |
| `VERBOSE` | `0` | `1` = per-step chatter; `0` = progress summary |

See also: [`scripts/README.md`](../../scripts/README.md) (full per-script usage
+ the collect → report → profile workflow) and
[`experiments/data/README.md`](../data/README.md) (the per-algo JSONL schema these
sweeps append into).
