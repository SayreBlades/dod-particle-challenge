# scripts/ — build, collect, and analyze

All scripts are Python 3 (no shell). The repo's only Python dependency is the
[uv](https://docs.astral.sh/uv/) env (`.venv`, created by `uv sync`); every
script here runs under the system `python3` except where Halide is involved.

Most day-to-day actions have a `make` shortcut (see the top-level
[`Makefile`](../Makefile)); this file documents the scripts directly, for
when you need the full knobs.

| script | role |
|-------|------|
| [`run.py`](#runpy) | build / play / profile dispatcher (backing `make`) + raw `bench` |
| [`collect.py`](#collectpy) | the unified data-collection sweep (JSONL append) |
| [`cell_hash.py`](#cell_hashpy) | a cell's `@import`-closure SHA-256 → `source_hash` |
| [`hardware_json.py`](#hardware_jsonpy) | machine profile → JSON (`machine_id` + measured bandwidth) |
| [`hardware_profile.py`](#hardware_profilepy) | human-readable counterpart to `hardware_json.py` |
| [`build_report.py`](#build_reportpy) | JSONL + hardware → the `experiments/analysis/` tree + the `--verify` gate |
| [`analyze_cell.py`](#analyze_cellpy) | per-cell: rebuild+disassemble (cached) → evidence `<cell>.json` + LLM narrative `<cell>.md` |
| [`pmc_collect.py`](#pmc_collectpy) | one-shot PMC cycle-attribution (macOS + Xcode) |
| [`pmc_sweep.py`](#pmc_sweeppy) | PMC across cells × N × trials + rollup |
| [`migrate_data.py`](#migrate_datapy) | one-time: old per-run CSV → host JSONL |

---

## Bench binary flags

Reference for the `out/bin/dod-particles` flags (bench mode). `collect.py` uses
these under the hood; you can also run the binary directly for an ad-hoc
measurement (see [`run.py bench`](#runpy)).

```sh
./out/bin/dod-particles --json --ns 4000,65000,1000000 --trials 5  # sweep, JSONL rows to stderr (collect.py greps `^json,`)
./out/bin/dod-particles --n 1000000 --iters 500                    # single N (PMC mode — clean step() region for xctrace)
./out/bin/dod-particles --threads 8                                # parallel cells only (serial cells ignore this)
./out/bin/dod-particles --check                                    # invariant suite (PASS/FAIL)
./out/bin/dod-particles --record                                   # 10s MP4 via ffmpeg (default: out/record/)
./out/bin/dod-particles --bandwidth                                # streaming-BW microbench (reads `streaming_bw_gbs=` for hardware.json)
```

- `--csv` is the legacy row format; `--json` (default for collection) is what
  `collect.py` greps.
- `-Ddeath=<q>` is a **build option** (not a runtime flag): the competing-risks
  accident rate (`0` = natural, the golden-checked sim; `0.5` = high-churn).
- `-Dmode=<play|bench|audit|manifest>` is also a build option; see the top-level
  README's [Build & run](../README.md#build--run).

---

## run.py

Build / play / profile for a **target** — a full cell name
(`L1.B1.w1-autovec.w2-simple`), a layout (`L1`), or `all`. (Bare strats are
rejected: the B1–B8 strat names recur across layouts, so they're ambiguous
once a second layout lands.) `build`, `play`, and `profile` are what `make build`,
`make play`, and `make profile` call. There's also a `bench` subcommand for a
**raw one-cell measurement** (build + run the table, nothing appended) — it's
intentionally *not* a make target, because at the make level the measurement
workflow is [`collect.py`](#collectpy) (or `make collect`).

```sh
python3 scripts/run.py build                       # build every cell (L1 assumed) into out/
python3 scripts/run.py build L1                    # build every cell of layout L1
python3 scripts/run.py build L1.B1.w1-halide.w2-simple
python3 scripts/run.py play L1.B1.w1-autovec.w2-simple # open the interactive raylib window
python3 scripts/run.py profile L1.B1.w1-autovec.w2-simple   # PMC (one cell, one N)

# Raw one-cell benchmark — build + run the bench table to stderr; no JSONL,
# no death/threads sweep, no provenance. For a quick local number only:
python3 scripts/run.py bench L1.B1.w1-autovec.w2-simple
```

`build` and `bench` accept a layout or `all` (each cell is built in turn,
overwriting `out/`); `play` and `profile` need a single cell (default: the L1
reference `L1.B1.w1-autovec.w2-simple`). To customize the raw bench (N, trials,
threads, JSON output) pass flags to the binary directly — see
[Bench binary flags](#bench-binary-flags). The Makefile wraps the make-backed
subcommands so you can pass the target positionally — `make build L1` — see
the [Makefile](../Makefile).

> **`bench` vs `collect.py`** — `run.py bench` builds one cell at the default
> death=0 and prints a table; it does **not** sweep death rates/threads and
> appends **nothing**. `collect.py` is the real measurement: the full regime
> grid (N × death q × threads) into `runs.jsonl`. Use `bench` for a quick
> sanity number, `collect.py` for data the report reads.

## collect.py

The unified sweep. Runs every cell in a layout (or a subset) across the
**regime grid** — N × death rate × threads — appending one JSONL row per
trial into `experiments/data/<machine_id>/runs.jsonl`, plus one invariant
`--check` row per `(cell, death_q)` into `checks.jsonl`. Data is
host-partitioned + append-only (re-runs duplicate rows; dedup is a
report concern).

Every row is self-describing: the bench binary (`--json`) carries
build-time provenance + the cell's static axes + the measurement, so
`collect.py` just greps `^json,` and appends. `hardware.json` is written once
per host (the report joins on `machine_id`).

### Sweep knobs (env vars or `--flags`)

| knob | default | meaning |
|------|---------|---------|
| `NS` | bench default SWEEP | comma-list of N, e.g. `4000,65000,1000000` |
| `TRIALS` | `3` | trials per N (the report keeps the min) |
| `DEATH_RATES` | `0.01 0.05 0.1 0.25 0.5` (from `death_rates.txt`) | space-list of accident rates q |
| `THREADS` | `1 4 10` | space-list; **parallel cells only** (serial cells run T=1) |
| `PARALLEL` | `1` | up to N `(cell, q)` tasks concurrently (own build dir each) |
| `SKIP_DONE` | `0` | skip `(cell, q)` whose runs.jsonl already covers all threads (resume) |
| `VERBOSE` | `1` | `0` = progress bar only (per-step log suppressed) |
| `REFRESH_HW` | `0` | rewrite `hardware.json` (re-measure `streaming_bw_gbs`) |
| `HALIDE_FORCE` | unset | attempt halide cells even if `import halide` fails |

```sh
python3 scripts/collect.py                       # every cell of every layout (all)
python3 scripts/collect.py L1                    # every cell of layout L1
python3 scripts/collect.py L1.B1.w1-autovec.w2-simple   # one cell (full name)
NS=4000,65000 TRIALS=5 python3 scripts/collect.py L1           # quick subset
DEATH_RATES="0 0.5" python3 scripts/collect.py L1               # override rate set
THREADS="1 4" python3 scripts/collect.py L1.B3.w1-autovec-par.w2-rmerge
```

### Concurrency, resume, and the progress bar

```sh
PARALLEL=4 python3 scripts/collect.py L1                       # 4-way sweep (own build dir each)
PARALLEL=4 SKIP_DONE=1 python3 scripts/collect.py L1           # resume an interrupted sweep
VERBOSE=0 python3 scripts/collect.py                           # quiet: live bar only
```

A live progress bar prints to stderr, one line per completed task:
`[##########--------------------] 2/6 (33%) L1.B1.w1-autovec.w2-simple q=0.05`.

**Caveat (parallel bench):** concurrent bench runs contend for cores and can
skew `ns_frame`. Keep `PARALLEL=1` (the default) for publication-grade data;
use `PARALLEL>1` for "collect everything" passes you intend to re-run clean.

**Halide cells:** `import halide` is the generator's first line and is
q-independent, so if the module is missing (`uv sync --extra halide` to fix)
collect.py skips every halide cell with one notice instead of N×q failed
builds. A cell that fails to build at one `death_q` is skipped at its
remaining rates (build failures are almost always q-independent).

## cell_hash.py

A cell's `@import`-closure SHA-256 — every transitively-imported `.zig` file
plus, for halide cells, the generator `.py`. Stamped on every `runs.jsonl`
row as `source_hash` so a row pins the exact code that ran (catches
uncommitted edits).

```sh
python3 scripts/cell_hash.py L1.B1.w1-autovec.w2-simple        # prints the hash
python3 scripts/cell_hash.py L1.B1.w1-halide.w2-simple         # includes the gen .py
python3 scripts/cell_hash.py L1.B1.w1-autovec.w2-simple --files  # also list the closure
```

## hardware_json.py

Emits a JSON hardware profile to stdout: `machine_id` (hostname + short hash
of the near-immutable facts) + cache/memory/cpu facts + `streaming_bw_gbs`
(measured by the Zig `--bandwidth` microbench, not a Python loop). Used by
`collect.py` (writes `hardware.json` per host) and joined as a dimension by
the report.

```sh
python3 scripts/hardware_json.py                  # JSON to stdout
python3 scripts/hardware_json.py --write           # write experiments/data/<machine_id>/hardware.json
```

## hardware_profile.py

Human-readable counterpart to `hardware_json.py` — prints the same facts as a
labeled block (date, host, machine_id, cpu, cores, cache lines, measured
streaming bandwidth, SIMD flags). The bench (`src/framework/hardware.zig`)
prints the same facts at the start of every run; this is the standalone CLI.

```sh
python3 scripts/hardware_profile.py
```

## build_report.py

Builds the full derived analysis tree under `experiments/analysis/` from the
host-partitioned JSONL + `hardware.json`. It is the orchestrator:

- **per-cell bundles** — delegated to [`analyze_cell.py`](#analyze_cellpy) via
  subprocess: the evidence `<cell>.json` + the LLM narrative `<cell>.md` for
  every measured cell.
- **aggregation bundles** — `analysis/machines.json`, per-machine
  `overview.json`, per-layout `layout.json` (champions partitioned by thread
  group), a browsable markdown tree (a README at every level), + `queries.sql`.
- **the `--verify` gate** — every narrative is checked; a failure is retried
  once (at a higher token budget), then the cell is marked `verified: false`
  (the SPA banners it). The build always finishes; the **exit code is nonzero
  if any cell remains unverified** — loud, but never blocks the deterministic
  aggregation.

Re-run after every collect. Needs duckdb — run under the venv
(`.venv/bin/python`, or `make report`).

```sh
.venv/bin/python scripts/build_report.py            # full build: generate + verify + aggregate
.venv/bin/python scripts/build_report.py --no-cells # aggregation only (skip per-cell generation)
.venv/bin/python scripts/build_report.py --force    # force-regenerate all narratives
.venv/bin/python scripts/build_report.py --verify-only
```

Then serve the SPA from the `experiments/` root and open `report.html`:

```sh
python3 -m http.server -d experiments 8000   # open http://localhost:8000/report.html
```

## analyze_cell.py

The per-cell generator (the Tier-2 narrative, `reporting-and-analysis.md`
decision 2). For one cell (or a whole layout): rebuilds the cell's ReleaseFast
binary into `.scratch/asm_cache/<source_hash>/` (cached, so re-runs are
cheap), disassembles the `step` symbol (`otool`/`objdump`), and writes the
structured evidence `<cell>.json` (cell_decl + cache hierarchy + measured
series + PMC + the asm histogram/excerpt). Then calls the z.ai GLM-5.2 LLM
(`zai-sdk`) to write the 5-section narrative `<cell>.md` (Intent / Cache
saturation / Bandwidth / Assembly / Verdict) from that evidence.

The narrative is **verified**: `--verify` checks every cited instruction's
mnemonic against the asm histogram + that all five sections are present (hard
gate; nonzero exit). Prose numbers are advisory (the model legitimately
derives stride/footprint/% values not 1:1 in the json). `build_report.py` runs
this as its gate.

```sh
.venv/bin/python scripts/analyze_cell.py L1.B1.w1-autovec.w2-opt        # full: json + md
.venv/bin/python scripts/analyze_cell.py L1                           # whole layout (resume-skips existing .md; --force regenerates)
.venv/bin/python scripts/analyze_cell.py L1 --verify                   # integrity gate (0 FAIL = green)
.venv/bin/python scripts/analyze_cell.py L1.B1.w1-autovec.w2-opt --json-only    # evidence only, no LLM call
.venv/bin/python scripts/analyze_cell.py L1.B1.w1-autovec.w2-opt --prompt-only  # print the LLM prompt
```

LLM key: `ZAI_API_KEY` env or `.scratch/zai_api_key`; optional `ZAI_BASE_URL`
/ `.scratch/zai_base_url` for a dedicated endpoint. `MAX_TOKENS` (default
16000) overrides the reasoning-token budget — GLM-5.2 is a reasoning model,
so the budget must cover reasoning + the visible narrative.

## pmc_collect.py

Optional, macOS + Xcode only. Runs the bench under xctrace's "CPU Counters"
template and exports per-process cycle-saturation to CSV — the cycle-side
context that complements the bench's bandwidth view (bandwidth-bound vs
compute-bound, and *why* — frontend/backend/branch). One row per launch.

```sh
python3 scripts/pmc_collect.py L1.B1.w1-autovec.w2-simple 1000000 500 1
# -> .scratch/pmc/<cell>_n1000000_t1.csv
```

## pmc_sweep.py

PMC across every cell of a layout × N × trials (iter counts scaled by N so
each trial is ~1-3s), then a rollup CSV (min cycles per `(cell, N)` across
trials + derived percentages). The separate cycle-attribution layer; the
unified sweep is `collect.py`.

```sh
python3 scripts/pmc_sweep.py L1 3                          # layout=L1, 3 trials
python3 scripts/pmc_sweep.py L1 3 --cells "L1.B1.w1-autovec.w2-simple L1.B3.w1-halide.w2-simple"
```

## migrate_data.py

One-time: converts the old per-run-dir CSV data layout into the new
host-partitioned JSONL layout. Append-only (safe to re-run; `--clean` wipes
the host jsonl targets first). `source_hash` is `null` for migrated rows
(historical; new rows from `collect.py` carry the real hash).

```sh
python3 scripts/migrate_data.py            # migrate all old run dirs
python3 scripts/migrate_data.py --clean    # wipe host jsonl targets first
python3 scripts/migrate_data.py --dry-run  # show counts, write nothing
```

---

## The full layout-sweep workflow

```sh
# 1. Sweep — all cells × {0.01,0.05,0.1,0.25,0.5} × {4K,65K,1M,16M} × {1,4,10}
#    (parallel only); appends JSONL into experiments/data/<machine_id>/:
python3 scripts/collect.py L1
#    (resume an interrupted sweep without duplicating completed units:)
PARALLEL=4 SKIP_DONE=1 python3 scripts/collect.py L1

# 2. Build the analysis tree + serve the SPA:
.venv/bin/python scripts/build_report.py
python3 -m http.server -d experiments 8000   # open http://localhost:8000/report.html

# 3. (Mac + Xcode) PMC cycle-attribution for the champions:
python3 scripts/pmc_sweep.py L1 "L1.<champ1> L1.<champ2> ..."

# 4. Rebuild the report; commit the data + report:
.venv/bin/python scripts/build_report.py
git add experiments/data/<machine_id> experiments/analysis experiments/report.html experiments/report.js experiments/style.css
git commit -m "L1: sweep + PMC + analysis tree"
```

Or via the Makefile shortcuts: `make collect` (all), `make collect L1`,
`make collect <strat>`, `make report`, `make serve`.
