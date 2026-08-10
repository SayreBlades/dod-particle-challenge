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
| [`algo_hash.py`](#algo_hashpy) | an algorithm's `@import`-closure SHA-256 → `source_hash` |
| [`hardware_json.py`](#hardware_jsonpy) | machine profile → JSON (`machine_id` + measured bandwidth) |
| [`hardware_profile.py`](#hardware_profilepy) | human-readable counterpart to `hardware_json.py` |
| [`build_report.py`](#build_reportpy) | JSONL + hardware → the `experiments/analysis/` tree + the `--verify` gate |
| [`analyze_algo.py`](#analyze_algopy) | per-algorithm: rebuild+disassemble (cached) → evidence `<algorithm>.json` + LLM narrative `<algorithm>.md` |
| [`pmc_collect.py`](#pmc_collectpy) | one-shot PMC cycle-attribution (macOS + Xcode) |
| [`pmc_sweep.py`](#pmc_sweeppy) | PMC across algorithms × N × trials + rollup |
| [`migrate_data.py`](#migrate_datapy) | one-time: old per-run CSV → host JSONL |

---

## Bench binary flags

One binary per `(algorithm, mode)`, flat-named `out/bin/<memory layout>.<algo>.<mode>`
(e.g. `ML01.AF03.LP1-halide.LP2-simple.bench`). Behavior is configured at the command
line — **`q` is runtime**, so one binary sweeps the whole death axis (zig *and*
halide). `collect.py` uses these under the hood; run a binary directly for an
ad-hoc measurement. `--help` prints the algorithm's declaration + every flag.

```sh
./out/bin/ML01.AF03.LP1-halide.LP2-simple.bench --help            # algo_meta + options
./out/bin/ML01.AF01.LP1-unroll.LP2-simple.bench -q 0.1 -N 4000    # single N at q=0.1
./out/bin/ML01.AF01.LP1-unroll.LP2-simple.bench --json --ns 4000,65000,1000000 --trials 5  # sweep (collect.py greps `^json,`)
./out/bin/ML01.AF01.LP1-unroll.LP2-simple.bench -N 1000000 --iters 500  # single N (PMC mode — clean step() region for xctrace)
./out/bin/ML01.AF01.LP1-unroll.LP2-simple.bench --threads 8       # parallel algorithms only (serial algorithms ignore this)
./out/bin/ML01.AF01.LP1-unroll.LP2-simple.bench --check           # invariant suite (PASS/FAIL)
./out/bin/ML01.AF01.LP1-unroll.LP2-simple.bench --record          # 10s MP4 via ffmpeg (default: out/record/)
./out/bin/ML01.AF01.LP1-unroll.LP2-simple.bench --bandwidth       # streaming-BW microbench (reads `streaming_bw_gbs=` for hardware.json)
```

- `-q`/`--death <q>` is a **runtime flag**: the competing-risks accident rate
  (`0` = natural, the golden-checked sim; `0.5` = high-churn). Same binary,
  every `q`. (`-Ddeath=<q>` still exists as the build-time default.)
- `-N`/`--n <N>` single particle count; `--ns <a,b,c>` the sweep list.
- `-Dmode=<play|bench|audit|manifest>` is a **build option** (it's the `.mode`
  suffix in the filename). bench/audit/manifest link **no raylib** (headless,
  portable to Linux/CI); play links raylib. See the top-level README's
  [Build & run](../README.md#build--run).
- `--csv` is the legacy row format; `--json` (default for collection) is what
  `collect.py` greps.

---

## run.py

Build / play / profile for a **target** — a full algorithm name
(`ML01.AF01.LP1-autovec.LP2-simple`), a memory layout (`ML01`), or `all`. (Bare algos are
rejected: the AF01–AF08 algo names recur across memory layouts, so they're ambiguous
once a second memory layout lands.) `build`, `play`, and `profile` are what `make build`,
`make play`, and `make profile` call. There's also a `bench` subcommand for a
**raw one-algorithm measurement** (build + run the table, nothing appended) — it's
intentionally *not* a make target, because at the make level the measurement
workflow is [`collect.py`](#collectpy) (or `make collect`).

```sh
uv run python scripts/run.py build                       # build every algorithm (ML01 assumed) into out/
uv run python scripts/run.py build ML01                    # build every algorithm of memory layout ML01
uv run python scripts/run.py build ML01.AF01.LP1-halide.LP2-simple
uv run python scripts/run.py play ML01.AF01.LP1-autovec.LP2-simple # open the interactive raylib window
uv run python scripts/run.py profile ML01.AF01.LP1-autovec.LP2-simple   # PMC (one algorithm, one N)

# Raw one-algorithm benchmark — build + run the bench table to stderr; no JSONL,
# no death/threads sweep, no provenance. For a quick local number only:
uv run python scripts/run.py bench ML01.AF01.LP1-autovec.LP2-simple
```

`build` and `bench` accept a memory layout or `all` (each algorithm builds to its own flat
`out/bin/<algorithm>.bench` — they coexist, no overwriting); `play` and `profile`
need a single algorithm (default: the ML01 reference `ML01.AF01.LP1-autovec.LP2-simple`). To customize the raw bench (N, trials,
threads, JSON output) pass flags to the binary directly — see
[Bench binary flags](#bench-binary-flags). The Makefile wraps the make-backed
subcommands so you can pass the target positionally — `make build ML01` — see
the [Makefile](../Makefile).

> **`bench` vs `collect.py`** — `run.py bench` builds one algorithm at the default
> death=0 and prints a table; it does **not** sweep death rates/threads and
> appends **nothing**. `collect.py` is the real measurement: the full regime
> grid (N × death q × threads) into `runs.jsonl`. Use `bench` for a quick
> sanity number, `collect.py` for data the report reads.

## collect.py

The unified sweep. Runs every algorithm in a memory layout (or a subset) across the
**regime grid** — N × death rate × threads — appending one JSONL row per
trial into `experiments/data/<machine_id>/runs.jsonl`, plus one invariant
`--check` row per `(algorithm, death_q)` into `checks.jsonl`. Data is
host-partitioned + append-only (re-runs duplicate rows; dedup is a
report concern).

Every row is self-describing: the bench binary (`--json`) carries
build-time provenance + the algorithm's static axes + the measurement, so
`collect.py` just greps `^json,` and appends. `hardware.json` is written once
per host (the report joins on `machine_id`).

### Sweep knobs (env vars or `--flags`)

| knob | default | meaning |
|------|---------|---------|
| `NS` | bench default SWEEP | comma-list of N, e.g. `4000,65000,1000000` |
| `TRIALS` | `3` | trials per N (the report keeps the min) |
| `DEATH_RATES` | `0.01 0.05 0.1 0.25 0.5` (from `death_rates.txt`) | space-list of accident rates q |
| `THREADS` | `1 4 10` | space-list; **parallel algorithms only** (serial algorithms run T=1) |
| `PARALLEL` | `1` | reserved — builds are serial into flat `out/` (parallelizing risks `.zig-cache` contention); benches always serial |
| `SKIP_DONE` | `0` | skip `(algorithm, q)` whose runs.jsonl already covers all threads (resume) |
| `VERBOSE` | `1` | `0` = progress bar only (per-step log suppressed) |
| `REFRESH_HW` | `0` | rewrite `hardware.json` (re-measure `streaming_bw_gbs`) |
| `HALIDE_FORCE` | unset | attempt halide algorithms even if `import halide` fails |

```sh
uv run python scripts/collect.py                       # every algorithm of every memory layout (all)
uv run python scripts/collect.py ML01                    # every algorithm of memory layout ML01
uv run python scripts/collect.py ML01.AF01.LP1-autovec.LP2-simple   # one algorithm (full name)
NS=4000,65000 TRIALS=5 uv run python scripts/collect.py ML01           # quick subset
DEATH_RATES="0 0.5" uv run python scripts/collect.py ML01               # override rate set
THREADS="1 4" uv run python scripts/collect.py ML01.AF03.LP1-autovec-par.LP2-rmerge
```

### Phases, resume, and the progress bar

Two phases: **(1) build** one binary per algorithm into the flat `out/bin/` (serial
— `q` is runtime, so zig *and* halide are one binary each, no per-`q` fan-out);
**(2) bench+check** every `(algorithm, q)` serially for clean timing.

```sh
SKIP_DONE=1 uv run python scripts/collect.py ML01           # resume an interrupted sweep (skip done units)
VERBOSE=0 uv run python scripts/collect.py                # quiet: live bar only
```

A live progress bar prints to stderr, one line per completed unit:
`[##########--------------------] 2/6 (33%) ML01.AF01.LP1-autovec.LP2-simple q=0.05`.

Benches always run serially (concurrent runs contend for cores and skew
`ns_frame`); builds are serial too, into the shared `out/` prefix — with one
binary per algorithm the build count is small enough that serial is fine, and
parallelizing flat builds risks `.zig-cache` contention.

**Halide algorithms:** `q` is runtime now, so each halide algorithm is one binary (not one
per `q`). If `import halide` is missing (`uv sync` to fix)
collect.py skips every halide algorithm with one notice. An algorithm that fails to build
is skipped at all its death rates.

## algo_hash.py

An algorithm's `@import`-closure SHA-256 — every transitively-imported `.zig` file
plus, for halide algorithms, the generator `.py`. Stamped on every `runs.jsonl`
row as `source_hash` so a row pins the exact code that ran (catches
uncommitted edits).

```sh
uv run python scripts/algo_hash.py ML01.AF01.LP1-autovec.LP2-simple        # prints the hash
uv run python scripts/algo_hash.py ML01.AF01.LP1-halide.LP2-simple         # includes the gen .py
uv run python scripts/algo_hash.py ML01.AF01.LP1-autovec.LP2-simple --files  # also list the closure
```

## hardware_json.py

Emits a JSON hardware profile to stdout: `machine_id` (hostname + short hash
of the near-immutable facts) + cache/memory/cpu facts + `streaming_bw_gbs`
(measured by the Zig `--bandwidth` microbench, not a Python loop). Used by
`collect.py` (writes `hardware.json` per host) and joined as a dimension by
the report.

```sh
uv run python scripts/hardware_json.py                  # JSON to stdout
uv run python scripts/hardware_json.py --write           # write experiments/data/<machine_id>/hardware.json
```

## hardware_profile.py

Human-readable counterpart to `hardware_json.py` — prints the same facts as a
labeled block (date, host, machine_id, cpu, cores, cache lines, measured
streaming bandwidth, SIMD flags). The bench (`src/framework/hardware.zig`)
prints the same facts at the start of every run; this is the standalone CLI.

```sh
uv run python scripts/hardware_profile.py
```

## build_report.py

Builds the full derived analysis tree under `experiments/analysis/` from the
host-partitioned JSONL + `hardware.json`. It is the orchestrator:

- **per-algorithm bundles** — delegated to [`analyze_algo.py`](#analyze_algopy) via
  subprocess: the evidence `<algorithm>.json` + the LLM narrative `<algorithm>.md` for
  every measured algorithm.
- **aggregation bundles** — `analysis/machines.json`, per-machine
  `overview.json`, per-memory layout `mem_layout.json` (champions partitioned by thread
  group), a browsable markdown tree (a README at every level), + `queries.sql`.
- **the `--verify` gate** — every narrative is checked; a failure is retried
  once (at a higher token budget), then the algorithm is marked `verified: false`
  (the SPA banners it). The build always finishes; the **exit code is nonzero
  if any algorithm remains unverified** — loud, but never blocks the deterministic
  aggregation.

Re-run after every collect. Needs duckdb — run via `uv run` (or `make report`).

```sh
uv run python scripts/build_report.py            # full build: generate + verify + aggregate
uv run python scripts/build_report.py --no-algos # aggregation only (skip per-algorithm generation)
uv run python scripts/build_report.py --force    # force-regenerate all narratives
uv run python scripts/build_report.py --verify-only
```

Then serve the SPA from the `experiments/` root and open `report.html`:

```sh
uv run python -m http.server -d experiments 8000   # open http://localhost:8000/report.html
```

## analyze_algo.py

The per-algorithm generator (the Tier-2 narrative, `reporting-and-analysis.md`
decision 2). For one algorithm (or a whole memory layout): rebuilds the algorithm's ReleaseFast
binary into `.scratch/asm_cache/<source_hash>/` (cached, so re-runs are
cheap), disassembles the `step` symbol (`otool`/`objdump`), and writes the
structured evidence `<algorithm>.json` (algo_meta + cache hierarchy + measured
series + PMC + the asm histogram/excerpt). Then calls the z.ai GLM-5.2 LLM
(`zai-sdk`) to write the 5-section narrative `<algorithm>.md` (Intent / Cache
saturation / Bandwidth / Assembly / Verdict) from that evidence.

The narrative is **verified**: `--verify` checks every cited instruction's
mnemonic against the asm histogram + that all five sections are present (hard
gate; nonzero exit). Prose numbers are advisory (the model legitimately
derives stride/footprint/% values not 1:1 in the json). `build_report.py` runs
this as its gate.

```sh
uv run python scripts/analyze_algo.py ML01.AF01.LP1-autovec.LP2-opt        # full: json + md
uv run python scripts/analyze_algo.py ML01                           # whole memory layout (resume-skips existing .md; --force regenerates)
uv run python scripts/analyze_algo.py ML01 --verify                   # integrity gate (0 FAIL = green)
uv run python scripts/analyze_algo.py ML01.AF01.LP1-autovec.LP2-opt --json-only    # evidence only, no LLM call
uv run python scripts/analyze_algo.py ML01.AF01.LP1-autovec.LP2-opt --prompt-only  # print the LLM prompt
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
uv run python scripts/pmc_collect.py ML01.AF01.LP1-autovec.LP2-simple 1000000 500 1
# -> .scratch/pmc/<algorithm>_n1000000_t1.csv
```

## pmc_sweep.py

PMC across every algorithm of a memory layout × N × trials (iter counts scaled by N so
each trial is ~1-3s), then a rollup CSV (min cycles per `(algorithm, N)` across
trials + derived percentages). The separate cycle-attribution layer; the
unified sweep is `collect.py`.

```sh
uv run python scripts/pmc_sweep.py ML01 3                          # memory layout=ML01, 3 trials
uv run python scripts/pmc_sweep.py ML01 3 --algorithms "ML01.AF01.LP1-autovec.LP2-simple ML01.AF03.LP1-halide.LP2-simple"
```

## migrate_data.py

One-time: converts the old per-run-dir CSV data memory layout into the new
host-partitioned JSONL memory layout. Append-only (safe to re-run; `--clean` wipes
the host jsonl targets first). `source_hash` is `null` for migrated rows
(historical; new rows from `collect.py` carry the real hash).

```sh
uv run python scripts/migrate_data.py            # migrate all old run dirs
uv run python scripts/migrate_data.py --clean    # wipe host jsonl targets first
uv run python scripts/migrate_data.py --dry-run  # show counts, write nothing
```

---

## The full memory layout-sweep workflow

```sh
# 1. Sweep — all algorithms × {0.01,0.05,0.1,0.25,0.5} × {4K,65K,262K,1M,16M} × {1,4,10}
#    (parallel only); appends JSONL into experiments/data/<machine_id>/:
uv run python scripts/collect.py ML01
#    (resume an interrupted sweep without duplicating completed units:)
SKIP_DONE=1 uv run python scripts/collect.py ML01

# 2. Build the analysis tree + serve the SPA:
uv run python scripts/build_report.py
uv run python -m http.server -d experiments 8000   # open http://localhost:8000/report.html

# 3. (Mac + Xcode) PMC cycle-attribution for the champions:
uv run python scripts/pmc_sweep.py ML01 "ML01.<champ1> ML01.<champ2> ..."

# 4. Rebuild the report; commit the data + report:
uv run python scripts/build_report.py
git add experiments/data/<machine_id> experiments/analysis experiments/report.html experiments/report.js experiments/style.css
git commit -m "ML01: sweep + PMC + analysis tree"
```

Or via the Makefile shortcuts: `make collect` (all), `make collect ML01`,
`make collect <algo>`, `make report`, `make serve`.
