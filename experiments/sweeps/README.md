# experiments/sweeps/ — sweep configs

One `<memory layout>.algos` file per memory layout: the algorithms to sweep, one per line (`#`
comments allowed). Sourced by `scripts/collect.py` when no algorithms are passed on
the command line. The `algo_meta` in each algorithm file is the source of truth
for what algorithms exist (`zig build manifests` prints the registered roster to
stdout as a diagnostic); this file selects the subset worth measuring.

## The regime grid (one pass, §17.5)

Every algorithm is swept once across:

| axis         | values                  | how it's set                                   |
|--------------|-------------------------|------------------------------------------------|
| **N**        | `4K, 65K, 1M, 16M`      | bench default `SWEEP` (override with `NS=`)   |
| **death q**  | `0.01, 0.05, 0.1, 0.25, 0.5`      | `death_rates.txt` (override with `DEATH_RATES=`) |
| **threads**  | `1, 4, 10`              | parallel algorithms only (override with `THREADS=`)  |

Serial algorithms run T=1 only (a serial algorithm ignores `--threads`, so looping it
would just emit duplicate rows). The champion grid is read straight off this
single pass — there is no second "champion pass" anymore.

## Sweep knobs (env vars to `collect.py`)

**The grid** (`NS`, `TRIALS`, `DEATH_RATES`, `THREADS`) selects *what* to
measure; **the run knobs** (`PARALLEL`, `SKIP_DONE`, `VERBOSE`) select *how*.

| var | default | meaning |
|-----|---------|---------|
| `NS` | *(bench default)* | comma-list of N (e.g. `4000,65000,1000000`) |
| `TRIALS` | `3` | trials per N (the report keeps the min) |
| `DEATH_RATES` | `0.01 0.05 0.1 0.25 0.5` | space-list of accident rates q (competing risks) |
| `THREADS` | `1 4 10` | space-list of worker counts (parallel algorithms only) |
| `PARALLEL` | `1` | run up to N `(algorithm, q)` tasks concurrently (own build dir each). **Caveat:** concurrent bench runs contend for cores and can skew `ns_frame` — keep `1` for publication-grade data. |
| `SKIP_DONE` | `0` | skip a `(algorithm, q)` whose `runs.jsonl` already covers every thread — resume an interrupted sweep without duplicating. |
| `VERBOSE` | `1` | `0` = suppress per-step chatter, show only the live progress bar. |

The bench's built-in N-sweep (when `NS` is unset):
`4000 65000 1000000 16000000`.

See also: [`scripts/README.md`](../../scripts/README.md) (full per-script usage
+ the sweep → report → PMC workflow) and
[`experiments/data/README.md`](../data/README.md) (the JSONL schema these
sweeps append into).
