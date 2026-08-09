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
**memory layout strategies** — each a different answer to how the particle data
is arranged in memory. To optimize the rendering loop for a particular hardware
target, it will require exploring various implementations of the same four
logical stages of processing a given particle — **Integrate, Decide, Respawn,
Render**. The physics (the math, the seed, the death model) never changes
between them; only the data layout and access pattern do.

[acton]: https://www.youtube.com/watch?v=rX0ItVEVjHc

Here are some current findings:
**[Live report →](https://sayreblades.github.io/dod-particle-challenge/)**

### Layouts

A (memory) layout is a particular approach to the particle representation.

> Layouts and Blueprints below are the design reference — the frozen spec of what varies. Just here to build and run? Skip to [Prerequisites](#prerequisites).


| #  | data model                                     | hot B/p |   status    |
|----|------------------------------------------------|--------:|:-----------:|
| [L1](src/layouts/L1/README.md) | AoS, full 11-field, plain alloc                |     ~68 | ✅ complete |
| [L2](src/layouts/L2/README.md) | AoS, lean 4-field, plain alloc                 |      29 |   queued    |
| [L3](src/layouts/L3/README.md) | hot/cold AoS split                             | ~36 hot |   queued    |
| [L4](src/layouts/L4/README.md) | `[]Vec3` pos/vel + age + kind                  |      29 |   queued    |
| [L5](src/layouts/L5/README.md) | `[]Vec4` pos/vel (aligned) + age + kind        |      37 |   queued    |
| [L6](src/layouts/L6/README.md) | per-component `[]f32` (lean), plain alloc      |      29 |   queued    |
| [L7](src/layouts/L7/README.md) | per-component `[]f32`, 128 B-aligned, W-padded |      29 |   queued    |
| [L8](src/layouts/L8/README.md) | blocked AoSoA                                  |  ~29–32 |   queued    |
     
### Blueprints

A **blueprint** is how the four logical stages — **Integrate, Decide, Respawn,
Render** — fuse into one or more **walks** (sequential passes over the
particles), plus the **intermediate** (none / mask / list) that carries the
death decision between walks. It's pure data flow. There are exactly eight
different blueprints to explore:

| BP | walk 1                      | walk 2                      | walk 3                      | note                                                          |
|----|-----------------------------|-----------------------------|-----------------------------|---------------------------------------------------------------|
| B1 | Integrate, Decide, Respawn  | Render                      | —                           | naive baseline (branchy); blend → statistical golden class    |
| B2 | Integrate                   | Decide, Respawn             | Render                      | the natural seam — Halide Integrate, Zig Decide, Respawn      |
| B3 | Integrate, Decide→mask      | mask-scan, Respawn          | Render                      | mask makes walk 2 parallelizable via ranked-merge             |
| B4 | Integrate, Decide→list      | Respawn (dead only)         | Render                      | wins at rare death (walk 2 ≈ dead count), loses at common     |
| B5 | Integrate, Decide, Respawn, Render | —                    | —                           | fully fused; framebuffer byte-identical (splat is order-free) |
| B6 | Integrate                   | Decide, Respawn, Render     | —                           | Integrate seam, fused Respawn, Render                         |
| B7 | Integrate, Decide→mask      | mask-scan, Respawn, Render  | —                           | mask + fused Respawn, Render                                  |
| B8 | Integrate, Decide→list      | Respawn, Render (dead only) | Render (live, mask-tested)  | dead/live render split — carries both the list and the mask   |

A blueprint fixes *what* stages a walk fuses, not *how* each stage is
computed. The same walk can have many interchangeable implementations that
agree bit-for-bit (or statistically) but differ in schedule. B1's walk 1
(`Integrate, Decide, Respawn`) alone has four in L1:

- [scalar Zig](src/layouts/L1/B1.w1-scalar.w2-simple.zig) —
  de-vectorized (asm-boxed intermediates), branchy respawn
- [vector Zig](src/layouts/L1/B1.w1-autovec.w2-simple.zig) —
  auto-vectorized (NEON), branchy respawn
- [blend Zig](src/layouts/L1/B1.w1-blend.w2-simple.zig) —
  branchless blend respawn (the statistical-golden class)
- [Halide](src/layouts/L1/B1.w1-halide.w2-simple.zig) —
  AOT-compiled, per-particle hash RNG

## Prerequisites

| tool     | why                                                 | version    |
|----------|-----------------------------------------------------|------------|
| [Zig]    | the build + the sim                                 | 0.16.0     |
| [raylib] | the play-mode renderer (git submodule, built)       | (pinned)   |
| [uv]     | python env management (Halide generator + analysis) | any        |
| [ffmpeg] | `--record` video export (raw RGBA pipe)             | any        |
| Xcode    | optional: PMC cycle-attribution (`pmc_collect.py`)  | macOS only |

[Zig]: https://ziglang.org
[raylib]: https://github.com/raysan5/raylib
[uv]: https://docs.astral.sh/uv/
[ffmpeg]: https://ffmpeg.org

## Setup

```sh
git clone --recurse-submodules <this-repo>
cd dod-particle-challenge

# Python env (one command — creates .venv, installs deps, writes uv.lock):
uv sync                      # analysis env: duckdb (for build_report.py)
uv sync --extra halide       # also installs halide (needed to build the halide cells)
```

`uv sync` gives you the analysis env; add `--extra halide` for the halide
cells. The Zig + Halide cells need this; pure-Zig cells build and collect
without any Python env at all.

## Build & run

The common actions are `make` targets ([Makefile](Makefile));
[`scripts/run.py`](scripts/run.py) is the dispatcher underneath:

```sh
make build                                # build every cell into out/   (target: cell | layout | all)
make build   L1                           #   …every cell of layout L1
make build   L1.B1.w1-autovec.w2-simple   #   …one cell (use the full L1.<strat> name)
make play    L1.B1.w1-autovec.w2-simple   # open the interactive raylib window
make profile L1.B1.w1-autovec.w2-simple   # PMC cycle-attribution (macOS + Xcode)
make report && make serve                 # build + serve the report on http://localhost:8000
```

Under the hood each target shells out to
`zig build -p out -Dlayout=<L> -Dstrat=<strat> -Dmode=<play|bench|audit> -Doptimize=ReleaseFast`,
producing `out/bin/dod-particles`. The cell registry lives in
[`build.zig`](build.zig) (`strat_labels`) and [`src/main.zig`](src/main.zig)
(`sim_map`); the buildable L1 cells are listed in
[`experiments/sweeps/L1.cells`](experiments/sweeps/L1.cells) (or
`zig build manifests` → prints the registered roster to stdout).

Halide cells need `uv sync --extra halide`; the build runs the generator in
`src/layouts/L1/<base>_gen.py` to emit `out/halide/<base>.{h,a}`,
then links it. For the full `dod-particles` bench-binary flag reference
(`--json`, `--ns`, `--n`, `--threads`, `--check`, `--record`, `--bandwidth`,
`-Ddeath`), see [scripts/README.md § Bench binary flags](scripts/README.md#bench-binary-flags).

## Collect & analyze

One loop powers the whole lab: **sweep → report → (optional) PMC**.

- **Sweep** — [`scripts/collect.py`](scripts/collect.py) runs every cell across
  the **regime grid** (N × death-rate q × threads), appending one
  self-describing JSONL row per trial into the host-partitioned data dir
  (`experiments/data/<machine_id>/`). Knobs include `PARALLEL=N` (concurrent
  tasks), `SKIP_DONE=1` (resume), `VERBOSE=0`.
- **Report** — [`scripts/build_report.py`](scripts/build_report.py) builds the
  derived analysis tree under [`experiments/analysis/`](experiments/analysis/)
  (per-cell evidence + LLM narratives via `analyze_cell.py`, machine/layout
  aggregations, a `--verify` integrity gate) and the thin SPA at
  [`experiments/report.html`](experiments/report.html) (ECharts: performance
  landscapes, champion grid, achieved-vs-ceiling bandwidth, PMC breakdown).
- **PMC** (optional, macOS + Xcode) — [`scripts/pmc_collect.py`](scripts/pmc_collect.py) /
  [`scripts/pmc_sweep.py`](scripts/pmc_sweep.py) add per-process
  cycle-saturation — the *why* behind a bandwidth- or compute-bound result.

```sh
make collect L1                   # sweep  (`make collect` = all; `make collect <strat>` = one cell)
make report && make serve         # build + view the dashboard
```

## Project layout

```
src/
  framework/        instruments: config, sim, bench, audit, correctness, hardware, render, ...
  layouts/L1/   the L1 vertical: data.zig + walks/ + cells/
  bindings/         raylib.zig (hand-written extern)
  main.zig          comptime registry: cell-name -> Sim
experiments/
  sweeps/           <layout>.cells lists + death_rates.txt + regime-grid docs
  data/             host-partitioned JSONL: <machine_id>/{runs,checks,pmc}.jsonl + hardware.json (RAW — collect.py only)
  analysis/         derived analysis tree: <m>/<L>/<cell>.{md,json} + machine/layout bundles (rebuilt by build_report.py)
  golden/           stage1.bin + frame.sha256 (the byte-exact reference; tracked)
  report.html       the thin SPA (+ report.js + style.css) — machine+thread-scoped, fetches analysis/
scripts/            all Python — run.py, collect.py, build_report.py, analyze_cell.py, cell_hash.py,
                    hardware_json.py, hardware_profile.py, pmc_collect.py, pmc_sweep.py
Makefile            make build|play|profile|report|serve (target: cell|layout|all)
vendor/raylib/      git submodule (the renderer)
```

The design plan (cells, blueprints, the death model, the sweep/analysis
design) lives in `.scratch/plan/optimization-framework.md` (local, gitignored —
reference, not a build target).
