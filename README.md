# DoD (Data-Oriented Design) Particle Challenge

A fountain of 1M particles in three color streams — rendered live with [raylib].
Let's tune the heck out of this!

<br>
<p align="center">
  <img src="assets/fountain.gif" alt="three particle streams: smoke, sparks, debris">
</p>

It's a hands-on challenge *inspired* by the cache/perf lessons from Mike
Acton's CppCon 2014 talk, ["Data-Oriented Design and C++"][acton].

This challenge explores the performance optimization space across several
**memory layouts** — each a different answer to how the particle data is
arranged in memory. To optimize the rendering loop for a particular hardware
target, it will require exploring various implementations of the same four
logical stages of processing a given particle — **Integrate, Decide, Respawn,
Render**. The physics (the math, the seed, the death model) never changes
between them; only the data layout and access pattern do.

[acton]: https://www.youtube.com/watch?v=rX0ItVEVjHc

Here are some current findings:
**[Live report →](https://sayreblades.github.io/dod-particle-challenge/)**

### Memory layouts

A memory layout is a particular approach to the particle representation.

> Memory layouts and Algorithm families below are the design reference — the frozen spec of what varies. Just here to build and run? Skip to [Prerequisites](#prerequisites).


| #  | data model                                     | hot B/p |   status    |
|----|------------------------------------------------|--------:|:-----------:|
| [ML1](src/layouts/ML1/README.md) | AoS, full 11-field, plain alloc                |     ~68 | ✅ complete |
| [ML2](src/layouts/ML2/README.md) | AoS, lean 4-field, plain alloc                 |      29 |   queued    |
| [ML3](src/layouts/ML3/README.md) | hot/cold AoS split                             | ~36 hot |   queued    |
| [ML4](src/layouts/ML4/README.md) | `[]Vec3` pos/vel + age + kind                  |      29 |   queued    |
| [ML5](src/layouts/ML5/README.md) | `[]Vec4` pos/vel (aligned) + age + kind        |      37 |   queued    |
| [ML6](src/layouts/ML6/README.md) | per-component `[]f32` (lean), plain alloc      |      29 |   queued    |
| [ML7](src/layouts/ML7/README.md) | per-component `[]f32`, 128 B-aligned, W-padded |      29 |   queued    |
| [ML8](src/layouts/ML8/README.md) | blocked AoSoA                                  |  ~29–32 |   queued    |
     
### Algorithm families

An **algorithm family** is how the four logical stages — **Integrate, Decide, Respawn,
Render** — fuse into one or more **loops** (sequential passes over the
particles), plus the **intermediate** (none / mask / list) that carries the
death decision between loops. It's pure data flow. There are exactly eight
different algorithm families to explore:

| AF | loop 1                      | loop 2                      | loop 3                      | note                                                          |
|----|-----------------------------|-----------------------------|-----------------------------|---------------------------------------------------------------|
| AF1 | Integrate, Decide, Respawn  | Render                      | —                           | naive baseline (branchy); blend → statistical golden class    |
| AF2 | Integrate                   | Decide, Respawn             | Render                      | the natural seam — Halide Integrate, Zig Decide, Respawn      |
| AF3 | Integrate, Decide→mask      | mask-scan, Respawn          | Render                      | mask makes loop 2 parallelizable via ranked-merge             |
| AF4 | Integrate, Decide→list      | Respawn (dead only)         | Render                      | wins at rare death (loop 2 ≈ dead count), loses at common     |
| AF5 | Integrate, Decide, Respawn, Render | —                    | —                           | fully fused; framebuffer byte-identical (splat is order-free) |
| AF6 | Integrate                   | Decide, Respawn, Render     | —                           | Integrate seam, fused Respawn, Render                         |
| AF7 | Integrate, Decide→mask      | mask-scan, Respawn, Render  | —                           | mask + fused Respawn, Render                                  |
| AF8 | Integrate, Decide→list      | Respawn, Render (dead only) | Render (live, mask-tested)  | dead/live render split — carries both the list and the mask   |

An algorithm family fixes *what* stages a loop fuses, not *how* each stage is
computed. The same loop can have many interchangeable implementations that
agree bit-for-bit (or statistically) but differ in schedule. AF1's loop 1
(`Integrate, Decide, Respawn`) alone has four in ML1:

- [scalar Zig](src/layouts/ML1/AF1.LP1-scalar.LP2-simple.zig) —
  de-vectorized (asm-boxed intermediates), branchy respawn
- [vector Zig](src/layouts/ML1/AF1.LP1-autovec.LP2-simple.zig) —
  auto-vectorized (NEON), branchy respawn
- [blend Zig](src/layouts/ML1/AF1.LP1-blend.LP2-simple.zig) —
  branchless blend respawn (the statistical-golden class)
- [Halide](src/layouts/ML1/AF1.LP1-halide.LP2-simple.zig) —
  AOT-compiled, per-particle hash RNG

## Prerequisites

| tool     | why                                                 | version    |
|----------|-----------------------------------------------------|------------|
| [Zig]    | the build + the sim                                 | 0.16.0     |
| [raylib] | the play-mode renderer (git submodule, built)       | (pinned)   |
| [uv]     | python env management (Halide generator + analysis) | any        |
| [Make]   | the `make` targets (`make init`, `make build`, …)   | GNU make   |
| [ffmpeg] | `--record` video export (raw RGBA pipe)             | any        |
| Xcode    | optional: PMC cycle-attribution (`pmc_collect.py`)  | macOS only |

[Zig]: https://ziglang.org
[raylib]: https://github.com/raysan5/raylib
[uv]: https://docs.astral.sh/uv/
[Make]: https://www.gnu.org/software/make/
[ffmpeg]: https://ffmpeg.org

## Setup

```sh
git clone <this-repo>
cd dod-particle-challenge

make init   # one-time: git submodules (raylib) + python env (duckdb + halide + zai-sdk)
```

`make init` clones the raylib submodule and runs `uv sync` (which installs
everything). Pure-Zig algorithms build and collect without any Python env at all;
the halide algorithms need the `halide` package `uv sync` installs.

## Build & run

The common actions are `make` targets ([Makefile](Makefile));
[`scripts/run.py`](scripts/run.py) is the dispatcher underneath:

```sh
make build                                  # build every algorithm into out/   (target: algo | mem_layout | all)
make build   ML1                            #   …every algorithm of memory layout ML1
make build   ML1.AF1.LP1-autovec.LP2-simple #   …one algorithm (use the full ML1.<algo> name)
make play    ML1.AF1.LP1-autovec.LP2-simple # open the interactive raylib window
make profile ML1.AF1.LP1-autovec.LP2-simple # PMC cycle-attribution (macOS + Xcode)
make report && make serve                   # build + serve the report on http://localhost:8000
```

Under the hood each target shells out to
`zig build -p out -Dmem_layout=<ML> -Dalgo=<algo> -Dmode=<play|bench|audit> -Doptimize=ReleaseFast`,
producing `out/bin/dod-particles`. The algorithm registry lives in
[`build.zig`](build.zig) (`algo_labels`) and [`src/main.zig`](src/main.zig)
(`sim_map`); the buildable ML1 algorithms are listed in
[`experiments/sweeps/ML1.algos`](experiments/sweeps/ML1.algos) (or
`zig build manifests` → prints the registered roster to stdout).

Halide algorithms need the `halide` package (`uv sync`); the build runs the generator in
`src/layouts/ML1/<base>_gen.py` to emit `out/halide/<base>.{h,a}`,
then links it. For the full `dod-particles` bench-binary flag reference
(`--json`, `--ns`, `--n`, `--threads`, `--check`, `--record`, `--bandwidth`,
`-Ddeath`), see [scripts/README.md § Bench binary flags](scripts/README.md#bench-binary-flags).

## Collect & analyze

One loop powers the whole lab: **sweep → report → (optional) PMC**.

- **Sweep** — [`scripts/collect.py`](scripts/collect.py) runs every algorithm across
  the **regime grid** (N × death-rate q × threads), appending one
  self-describing JSONL row per trial into the host-partitioned data dir
  (`experiments/data/<machine_id>/`). Knobs include `PARALLEL=N` (concurrent
  tasks), `SKIP_DONE=1` (resume), `VERBOSE=0`.
- **Report** — [`scripts/build_report.py`](scripts/build_report.py) builds the
  derived analysis tree under [`experiments/analysis/`](experiments/analysis/)
  (per-algorithm evidence + LLM narratives via `analyze_algo.py`, machine/memory-layout
  aggregations, a `--verify` integrity gate) and the thin SPA at
  [`experiments/report.html`](experiments/report.html) (ECharts: performance
  landscapes, champion grid, achieved-vs-ceiling bandwidth, PMC breakdown).
- **PMC** (optional, macOS + Xcode) — [`scripts/pmc_collect.py`](scripts/pmc_collect.py) /
  [`scripts/pmc_sweep.py`](scripts/pmc_sweep.py) add per-process
  cycle-saturation — the *why* behind a bandwidth- or compute-bound result.

```sh
make collect ML1                   # sweep  (`make collect` = all; `make collect <algo>` = one algorithm)
make report && make serve          # build + view the dashboard
```

## Project layout

```
src/
  framework/        instruments: config, sim, bench, audit, correctness, hardware, render, ...
  layouts/ML1/      the ML1 vertical: data.zig + loops/ + algorithms
  bindings/         raylib.zig (hand-written extern)
  main.zig          comptime registry: algo-name -> Sim
experiments/
  sweeps/           <mem_layout>.algos lists + death_rates.txt + regime-grid docs
  data/             host-partitioned JSONL: <machine_id>/{runs,checks,pmc}.jsonl + hardware.json (RAW — collect.py only)
  analysis/         derived analysis tree: <m>/<ML>/<algo>.{md,json} + machine/mem-layout bundles (rebuilt by build_report.py)
  golden/           stage1.bin + frame.sha256 (the byte-exact reference; tracked)
  report.html       the thin SPA (+ report.js + style.css) — machine+thread-scoped, fetches analysis/
scripts/            all Python — run.py, collect.py, build_report.py, analyze_algo.py, algo_hash.py,
                    hardware_json.py, hardware_profile.py, pmc_collect.py, pmc_sweep.py
Makefile            make build|play|profile|report|serve (target: algo|mem_layout|all)
vendor/raylib/      git submodule (the renderer)
```

The design plan (algorithms, algorithm families, the death model, the sweep/analysis
design) lives in `.scratch/plan/optimization-framework.md` (local, gitignored —
reference, not a build target).
