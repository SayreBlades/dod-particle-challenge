# scripts/ — collect, analyze, serve

All scripts are Python 3 (no shell). The repo's only Python dependency is the
[uv](https://docs.astral.sh/uv/) env (`.venv`, created by `uv sync`); every
script here runs under it (duckdb, zai-sdk, halide — all installed by `uv sync`).

Most day-to-day actions have a `make` shortcut (see the top-level
[`Makefile`](../Makefile)); this file documents the scripts directly, for when
you need the full knobs.

## The model

`experiments/data/` is the **source of truth** — irreducible, per-machine
measurements written by a few **atomic** scripts. `experiments/analysis/` is
**pure derivation** from `data/` (no toolchain needed at report time).
[`collect.py`](#collectpy) orchestrates the atomics over the regime grid.

| script | role |
|-------|------|
| [`collect.py`](#collectpy) | **orchestrator** — drives the atomics over the regime grid (algo × q × N × trials; T=1) |
| [`algo.py`](#algopy) | **atomic** — rebuild + disassemble `step` → `<algo>.json` (the asm bundle) |
| [`bench.py`](#benchpy) | **atomic** — time one `(algo, q)` column → `<algo>.runs.jsonl` (timing + check) |
| [`profile.py`](#profilepy) | **atomic** — cycle-attribution for one point → `<algo>.profile.jsonl` (dispatcher; `profile_xctrace.py` backend) |
| [`hardware_json.py`](#hardware_jsonpy) | **atomic** — machine profile → `hardware.json` (`machine_id` + measured bandwidth) |
| [`build_report.py`](#build_reportpy) | `data/` → the `experiments/analysis/` tree + the `--verify` gate |
| [`analyze_algo.py`](#analyze_algopy) | per-algorithm: evidence `<algo>.json` + LLM narrative `<algo>.md` (reads asm from `data/`) |
| [`algo_hash.py`](#algo_hashpy) | an algorithm's `@import`-closure SHA-256 → `source_hash` |
| [`sweep_config.py`](#sweep_configpy) | the regime grid (machine-aware N list, iters/warmup schedule, death rates) — single source |
| [`layout_facts.py`](#layout_factspy) | static per-layout facts: field sizes, stage→fields, per-AF loop structure → hot bytes |
Removed: `run.py` (resolution → `build.zig -Dselect`; verbs → the Makefile),
`hardware_profile.py` (trivial printer over `hardware_json.py`),
`pmc_collect.py`/`pmc_sweep.py` (→ `profile.py`/`profile_xctrace.py`),
`migrate_data.py` (one-time, done). `migrate_to_per_algo.py` is a one-time
cutover script (legacy `runs.jsonl`/`checks.jsonl` → per-algo files).

---

## Bench binary flags

One binary per algorithm, flat-named `out/bin/<algo>.bench` (e.g.
`ML01.AF06.LP1-halide.LP2-mask.bench`). It is a **single-point primitive**: it
measures ONE `(N, q, threads, trial)` and emits one JSONL row. There is **no
default sweep** — `collect.py` / `bench.py` own the grid. Missing required args
error (no silent default run).

```sh
./out/bin/ML01.AF02.LP1-autovec.LP2-simple.bench --help                       # algo_meta + options
./out/bin/ML01.AF02.LP1-autovec.LP2-simple.bench --n 100000 --q 0.1 --iters 100 --trial 1 --json  # one timing row (--threads optional, default 1)
./out/bin/ML01.AF02.LP1-autovec.LP2-simple.bench --check --q 0.1              # invariant suite (PASS/FAIL)
./out/bin/ML01.AF02.LP1-autovec.LP2-simple.bench --bandwidth                  # streaming-BW microbench
```

- **Timing (default)** requires `--n`, `--q`, `--iters`, `--trial`;
  `--threads` (default 1), `--warmup` (default 5) and `--json` (emit the row) are optional.
- `--check` requires `--q` (runs the invariant suite, prints `checked=PASS|FAIL`).
- `--bandwidth` is a standalone mode (streaming-BW microbench).
- `q` is **runtime** (one binary sweeps the whole death axis; `-Ddeath` is just the build default).

---

## collect.py

The orchestrator. Owns ALL sweep policy + resume, calling the atomics:

```
ensure data/<id>/ ; hardware (once)
for algo in algos:
  algo  → <algo>.json              # when source_hash changes
  for q in DEATH_RATES:
    bench → timing + check rows    # unless SKIP_DONE
  if --with-profile:               # where a profiler backend exists
    for N in N_GRID:
      profile → cycle row          # T=1
```

Default run = timing + check + algo + hardware, **no profiling**. `--with-profile`
adds the profile loop; `--only profile` runs just it (the radar's data source).
Profiling is skipped with a note where no backend is available — never a hard
failure.

### Knobs (env vars or `--flags`)

| knob | default | meaning |
|------|---------|---------|
| `NS` | machine-aware `sweep_config.n_grid(hw)` | comma-list of N, e.g. `10000,1000000` — default brackets this machine's cache transitions (13 pts on M4; the fallback decades when no `hardware.json` yet) |
| `TRIALS` | `3` | trials per point (the report keeps the min) |
| `DEATH_RATES` | `sweep_config.DEATH_RATES` (`0.01 0.1 0.25 0.5`) | space-list of accident rates q |
| `SKIP_DONE` | `1` | skip points already present at the current `source_hash` (resume) |
| `REFRESH_HW` | `0` | rewrite `hardware.json` (re-measure `streaming_bw_gbs`) |
| `VERBOSE` | `0` | `1` = per-step chatter instead of the live progress bar |

```sh
uv run python scripts/collect.py                                  # every algo of every memory layout
uv run python scripts/collect.py ML01                               # one memory layout
uv run python scripts/collect.py ML01.AF02.LP1-autovec.LP2-simple    # one algorithm
uv run python scripts/collect.py ML01 --with-profile                 # + cycle attribution
uv run python scripts/collect.py ML01 --only profile                 # just the profile loop
uv run python scripts/collect.py ML01 --only asm                   # just the asm bundles (schema v2)
uv run python scripts/collect.py ML01 --refresh-asm                # force-rewrite asm bundles
NS=10000,1000000 TRIALS=5 uv run python scripts/collect.py ML01          # quick subset
```

Two phases: **(1) build** one binary per algorithm (parallel); **(2) measure**
serial (clean timing / clean counters). Benches always run serially (concurrent
runs contend for cores and skew `ns_frame`).

---

## algo.py

The disassembly atomic. Rebuilds the algorithm's ReleaseFast binary and captures
the `step` disassembly into `experiments/data/<id>/<algo>.json` — the asm source
of truth, keyed by `source_hash` + `asm.schema` (schema bumps self-invalidate;
`--force` rebuilds). This is the canonical home of the disassembly functions;
`analyze_algo.py` reads the bundle instead of rebuilding.

**Schema v2** (report-v2): `excerpt` + `histogram` as before, plus `insns[]`
(per-instruction address/mnemonic/operands/class/branch-target, classified
per-arch for arm64 + x86-64), `attribution` (DWARF **inline chains** per
instruction via `atos -i` on the dSYM / `llvm-symbolizer`-or-`addr2line` on the
ELF, same codegen debug build; `call_site` = the algo-file frame; `repo_files`
distinguishes repo inlines from zig std), `loops[]` (deterministic loop digest:
insns/iter, vector/scalar FP mix, branchy-respawn note with target line,
byte-scatter, gather, stride, external delegation), `calls[]` (external callees
with source lines), `fconst[]` (arm64 decoded float immediates). Legacy v1
bundles still render (flat asm fallback) until that machine re-runs collect.

```sh
uv run python scripts/algo.py ML01.AF02.LP1-autovec.LP2-simple           # write <algo>.json
uv run python scripts/algo.py ML01.AF02.LP1-autovec.LP2-simple --force
```

## bench.py

The timing atomic. Times ONE `(algo, q)` column — every `(N × trial)`
point via the single-point binary, then one `--check` — appending rows into
`<algo>.runs.jsonl`. Timing rows are `kind:"timing"`; the check row is
`kind:"check"` (one file, kind-discriminated). Owns the N→iters/warmup schedule
(from `sweep_config`). `collect.py` loops algos × q and calls this.

```sh
uv run python scripts/bench.py ML01.AF02.LP1-autovec.LP2-simple --q 0.1
uv run python scripts/bench.py ML01.AF02.LP1-blend.LP2-simple --q 0.25 --trials 3 --skip-done
```

## profile.py

The cycle-attribution atomic (platform-neutral dispatcher). Attributes cycles
for ONE `(algo, N, q, threads, trial)` point via the host's profiler backend and
appends one normalized row to `<algo>.profile.jsonl`. Buckets (sum = `cycles`):
`compute`, `backend_stall`, `frontend_stall`, `branch_flush` (→ the radar's
Compute / Latency / Control axes; frontend is dropped). Graceful absence where no
backend exists. The `profile_xctrace.py` backend (macOS + Xcode) is implemented;
a future `profile_perf.py` (Linux) plugs in without schema/analysis changes.

```sh
uv run python scripts/profile.py ML01.AF02.LP1-autovec.LP2-simple --n 1000000 --q 0.1 --threads 1 --trial 1
```

## hardware_json.py

Emits a JSON hardware profile: `machine_id` (hostname + short hash of the
near-immutable facts) + cache/memory/cpu facts + `streaming_bw_gbs` (measured by
the Zig `--bandwidth` microbench). `collect.py` writes `hardware.json` per host;
the report joins on `machine_id`.

```sh
uv run python scripts/hardware_json.py            # JSON to stdout
uv run python scripts/hardware_json.py --write     # write experiments/data/<machine_id>/hardware.json
```

---

## build_report.py

Pure derivation: reads `experiments/data/` (no toolchain) and builds the
`experiments/analysis/` tree. It is the orchestrator for analysis:

- **per-algorithm bundles** — delegated to [`analyze_algo.py`](#analyze_algopy):
  the evidence `<algo>.json` + LLM narrative `<algo>.md`.
- **aggregation bundles** — `machines.json` (the SPA's slim discovery index:
  machine_id + cpu), per-machine `overview.json` (hardware projected verbatim
  from `data/<mid>/hardware.json`), per-layout `mem_layout.json` (champions
  partitioned by thread group), a browsable markdown tree. (The champion-grid
  SQL lives in `champs_sql()` in this script — its single source of truth.)
- **the `--verify` gate** — every narrative is checked; failures retry once, then
  are marked `verified: false` (the SPA banners them). Nonzero exit if any remain
  unverified — loud, but never blocks the deterministic aggregation.

Re-run after every collect. Needs duckdb — run via `uv run` (or `make report`).

```sh
uv run python scripts/build_report.py            # full: generate + verify + aggregate
uv run python scripts/build_report.py --no-algos # aggregation only (skip per-algo generation)
uv run python scripts/build_report.py --force    # force-regenerate all narratives
```

## analyze_algo.py

The per-algorithm generator. Reads the asm bundle + timing + profile from `data/`,
assembles the evidence `<algo>.json` (algo_meta + cache hierarchy + regimes +
memory floor + layout hot-byte facts + measured series **with per-point
references** — the naive baseline `ML01.AF02.LP1-scalar.LP2-simple` and the
best-in-grid winner, with ×baseline/×winner ratios — + cycle attribution + the
asm histogram/excerpt/digest), then calls the z.ai GLM-5.2 LLM (`zai-sdk`) to
write the 6-section narrative `<algo>.md` (Intent / **Layout & approach** /
Cache saturation / Bandwidth / Assembly / Verdict). `--verify` checks cited
instructions + numbers + section presence (the gate `build_report.py` runs).

```sh
uv run python scripts/analyze_algo.py ML01.AF02.LP1-autovec.LP2-opt        # full: json + md
uv run python scripts/analyze_algo.py ML01.AF02.LP1-autovec.LP2-opt --json-only    # evidence only, no LLM
uv run python scripts/analyze_algo.py ML01 --verify                   # integrity gate (0 FAIL = green)
```

LLM key: `ZAI_API_KEY` env or `.scratch/zai_api_key`; optional `ZAI_BASE_URL` /
`.scratch/zai_base_url`. `MAX_TOKENS` (default 16000) overrides the
reasoning-token budget.

## layout_facts.py

Static per-memory-layout facts for evidence + the SPA layout strip: field
sizes (exact `@sizeOf` per field — Zig structs have no field-order guarantee,
so facts are name+size only), the stage→fields map, the per-AF loop structure,
and `loop_hot_bytes(mem_layout, algo_fam)` → per-loop hot bytes (fields a loop
touches) vs the struct stride — the "useful vs dead bandwidth" framing. Consumed
by `analyze_algo.py` (prompt + attested numbers) and `build_report.py` (ships
`layout_facts` into `<L>.mem_layout.json`).

## algo_hash.py

An algorithm's `@import`-closure SHA-256 — every transitively-imported `.zig`
file plus, for halide algorithms, the generator `.py`. Stamped on every row as
`source_hash` so a row pins the exact code that ran.

```sh
uv run python scripts/algo_hash.py ML01.AF02.LP1-autovec.LP2-simple        # prints the hash
uv run python scripts/algo_hash.py ML01.AF02.LP1-autovec.LP2-simple --files  # also list the closure
```

## sweep_config.py

The single source of truth for the collection grid: the **machine-aware N grid**
(`n_grid(hw)` — decades + 5 points bracketing each cache transition
`size/bytes_per_particle`, ≥1.15× log-spacing dedupe, clamp [300, 1e7]; M4 gets
13 points bracketing the 963 / 61680 spills), computed `iters_for(n)`/`warmup_for(n)`
(≥~18ms timed region at a conservative 8 ns/p floor), the **frozen
`PROFILE_N_GRID`** (dense-N is bench-only), `DEATH_RATES`, and the algorithm
roster (`algo_roster()`/`mem_layout_algos()` — parsed from build.zig's
`algo_labels` registry). Imported by `collect.py`, `bench.py`, and
`analyze_algo.py`. (The legacy
`experiments/sweeps/` config files — `death_rates.txt` + `<ML>.algos` rosters —
were consolidated here; subset sweeps are a CLI concern: pass targets to
`collect.py`.)

---

## The full sweep workflow

```sh
# 1. Collect — algorithms × {0.01,0.1,0.25,0.5} × the machine-aware N grid (T=1)
#    (dense bench grid; SKIP_DONE appends new N points incrementally)
#    → per-algo files under experiments/data/<machine_id>/:
uv run python scripts/collect.py ML01
#    resume without duplicating (default on): SKIP_DONE=1 is the default.

# 2. Build the analysis tree + serve the SPA:
uv run python scripts/build_report.py
uv run python -m http.server -d experiments 8000   # open http://localhost:8000/report.html

# 3. (optional) cycle attribution across the grid (xctrace on macOS):
uv run python scripts/collect.py ML01 --only profile

# 4. Rebuild the report (picks up profile data); commit:
uv run python scripts/build_report.py
git add experiments/data/<machine_id> experiments/analysis experiments/report.html experiments/report.js experiments/style.css
git commit -m "ML01: collect + profile + analysis tree"
```

Or via Makefile shortcuts: `make collect` (all), `make collect ML01`,
`make collect <algo>`, `make report`, `make serve`.
