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
arranged in memory.

To optimize the rendering loop for a particular hardware target, it will require
exploring various implementations of the same four logical stages of processing
a given particle — **Integrate, Decide, Respawn, Render**. The physics (the
math, the seed, the death model) never changes between them; only the data
layout and access pattern do.

[acton]: https://www.youtube.com/watch?v=rX0ItVEVjHc

Here are some current findings:
**[Live report →](https://sayreblades.github.io/dod-particle-challenge/)**

### Memory layouts

A memory layout is a particular approach to the particle representation.

> Memory layouts and Algorithm families below are the design reference — the frozen spec of what varies. Just here to build and run? Skip to [Prerequisites](#prerequisites).


|                                  | data model                                     | hot B/p |   status    |
|----------------------------------|------------------------------------------------|--------:|:-----------:|
| [ML01](src/layouts/ML01/README.md) | AoS, full 11-field, plain alloc                |     ~68 | ✅ complete |
| [ML02](src/layouts/ML02/README.md) | AoS, lean 4-field, plain alloc                 |      29 |   queued    |
| [ML03](src/layouts/ML03/README.md) | hot/cold AoS split                             | ~36 hot |   queued    |
| [ML04](src/layouts/ML04/README.md) | `[]Vec3` pos/vel + age + kind                  |      29 |   queued    |
| [ML05](src/layouts/ML05/README.md) | `[]Vec4` pos/vel (aligned) + age + kind        |      37 |   queued    |
| [ML06](src/layouts/ML06/README.md) | per-component `[]f32` (lean), plain alloc      |      29 |   queued    |
| [ML07](src/layouts/ML07/README.md) | per-component `[]f32`, 128 B-aligned, W-padded |      29 |   queued    |
| [ML08](src/layouts/ML08/README.md) | blocked AoSoA                                  |  ~29–32 |   queued    |
     
### Algorithms & algorithm families

**An algorithm is any solution to the problem.** Given the frozen constraints,
it must carry each particle through the four logical stages — **Integrate →
Decide → Respawn → Render**, in that order — and produce exactly the output the
[golden reference](experiments/golden) governs. The physics never moves; what's
free is *how* the work gets done — how many passes over the data, scalar vs.
vectorized, Zig vs. Halide, branchy vs. branchless. Every legal choice is a
different algorithm.

Nothing says the four stages have to run as four separate passes. A **loop**
here is one full sweep over the particles, you can solve this problem using:

- **1 loop** — walk each particle once and do everything inline: integrate it,
  test whether it's dead, respawn it if so, splat it to the framebuffer, then
  move on. Nothing is ever re-read. (AF01 — the fully-fused floor.)
- **4 loops** — the opposite extreme: one pass per logical phase. Integrate
  everything, then decide every fate, then respawn, then render. Maximum
  passes, minimum fusion. (AF08 — the fully-defused ceiling.)
- **2–3 loops** — everything in between: fuse two or three stages into a loop,
  split the rest off.

When considering every possible algorithm that solves this problem, each
approach will sort into **eight algorithm families** — one per distinct
loop-fusion strategy across the four stages (Integrate, Decide, Respawn,
Render). Within a family, the choice of **intermediate** (mask, list,
partition) and whether Render is partially fused with Respawn for dead
particles are implementation-level decisions, not family-level ones:


|      | loop 1                             | loop 2                     | loop 3             | loop 4 | note                                                                                                                    |
|------|------------------------------------|-----------------------------|--------------------|---------|-------------------------------------------------------------------------------------------------------------------------|
| AF01 | Integrate, Decide, Respawn, Render | —                           | —                  | —       | fully fused; framebuffer byte-identical (splat is order-free)                                                           |
| AF02 | Integrate, Decide, Respawn         | Render                      | —                  | —       | naive baseline (branchy); blend → statistical golden class                                                              |
| AF03 | Integrate, Decide                  | Respawn, Render             | —                  | —       | fused Respawn+Render; intermediate is an impl choice                                                                    |
| AF04 | Integrate                          | Decide, Respawn, Render     | —                  | —       | Integrate seam, fused Decide+Respawn+Render                                                                             |
| AF05 | Integrate                          | Decide, Respawn             | Render             | —       | the natural seam — Halide Integrate, Zig Decide+Respawn                                                                 |
| AF06 | Integrate, Decide                  | Respawn                     | Render             | —       | intermediate (mask/list/partition) and dead-render fusion are impl choices; partition reorders storage → stat. golden    |
| AF07 | Integrate                          | Decide                      | Respawn, Render    | —       | Integrate and Decide each isolated; Respawn+Render fused — intermediate carries verdict from Decide to loop 3           |
| AF08 | Integrate                          | Decide                      | Respawn            | Render  | the fully-defused ceiling — Decide as its own loop, re-reading `age` Integrate just wrote (dominated); for completeness |

<details>
<summary><b>The intermediate axis and per-loop implementations</b></summary>

When Decide and Respawn share a loop (AF01, AF02, AF04, AF05), the death verdict
lives in a register and dies with the iteration — no intermediate needed. When
they land in separate loops (AF03, AF06, AF07, AF08), an **intermediate**
carries the verdict across the loop boundary:

- **mask** — Decide writes a 1 byte/p bitmap; the Respawn loop scans it.
- **list** — Decide compacts the dead into an `idx[]`; the Respawn loop walks
  only the dead.
- **partition** — Decide permutes the dead into a contiguous front-slice; the
  Respawn loop walks a dense range with no per-particle test (this reorders
  storage, so it trades the bit-exact golden for a statistical one).

The intermediate is an implementation choice within any family that splits
Decide from Respawn — not a family-defining axis.

An algorithm family fixes *what* stages a loop fuses, not *how* each stage is
computed. The same loop can have many interchangeable implementations that
agree bit-for-bit (or statistically) but differ in schedule. Orthogonal to the
family, **tiling** runs the loops at block granularity so a block of particles
stays cache-resident across loop boundaries — an axis in its own right,
alongside storage **ordering** (identity / kind-sorted / double-buffered),
and explored like unrolling as a per-loop implementation
choice rather than a new family. AF02's loop 1
(`Integrate, Decide, Respawn`) alone has four in ML01:

- [scalar Zig](src/layouts/ML01/AF02.LP1-scalar.LP2-simple.zig) —
  de-vectorized (asm-boxed intermediates), branchy respawn
- [vector Zig](src/layouts/ML01/AF05.LP1-autovec.LP2-simple.zig) —
  auto-vectorized (NEON), branchy respawn
- [blend Zig](src/layouts/ML01/AF02.LP1-blend.LP2-simple.zig) —
  branchless blend respawn (the statistical-golden class)
- [Halide](src/layouts/ML01/AF05.LP1-halide.LP2-simple.zig) —
  AOT-compiled, per-particle hash RNG

</details>

## Prerequisites

| tool     | why                                                 | version    |
|----------|-----------------------------------------------------|------------|
| [Zig]    | the build + the sim                                 | 0.16.0     |
| [raylib] | the play-mode renderer (git submodule, built)       | (pinned)   |
| [uv]     | python env management (Halide generator + analysis) | any        |
| [Make]   | the `make` targets (`make init`, `make build`, …)   | GNU make   |
| [ffmpeg] | `--record` video export (raw RGBA pipe)             | any        |
| Xcode    | optional: cycle-attribution profiler backend (`profile.py` → xctrace)  | macOS only |

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
make build                                     # build every algorithm into out/
make build   ML01                              #   …every algorithm of memory layout ML01
make build   ML01.AF05.LP1-autovec.LP2-simple  #   …one algorithm (use the full ML01.<algo> name)
make play    ML01.AF05.LP1-autovec.LP2-simple  # open the interactive raylib window
make profile ML01.AF05.LP1-autovec.LP2-simple  # PMC cycle-attribution (macOS + Xcode)
make report && make serve                      # build + serve the report on http://localhost:8000
```

Under the hood each target shells out to
`zig build -p out -Dmem_layout=<ML> -Dalgo=<algo> -Dmode=<play|bench|audit> -Doptimize=ReleaseFast`,
producing `out/bin/dod-particles`. The algorithm registry lives in
[`build.zig`](build.zig) (`algo_labels`) and [`src/main.zig`](src/main.zig)
(`sim_map`); the buildable ML01 algorithms are listed in
[`experiments/sweeps/ML01.algos`](experiments/sweeps/ML01.algos) (or
`zig build manifests` → prints the registered roster to stdout).

Halide algorithms need the `halide` package (`uv sync`); the build runs the generator in
`src/layouts/ML01/<base>_gen.py` to emit `out/halide/<base>.{h,a}`,
then links it. For the full `dod-particles` bench-binary flag reference
(`--json`, `--ns`, `--n`, `--threads`, `--check`, `--record`, `--bandwidth`,
`-Ddeath`), see [scripts/README.md § Bench binary flags](scripts/README.md#bench-binary-flags).

## Collect & analyze

One loop powers the whole lab: **collect → report → (optional) profile**.

- **Collect** — [`scripts/collect.py`](scripts/collect.py) orchestrates the atomic
  measurement scripts across the **regime grid** (N × death-rate q × threads):
  `hardware` (machine facts), `algo` (the asm bundle), `bench` (timing + invariant
  check), `profile` (cycle attribution, where a profiler backend exists). Each
  writes per-algorithm files under `experiments/data/<machine_id>/`. Knobs:
  `SKIP_DONE=1` (resume), `NS=`, `THREADS=`, `TRIALS=`.
- **Report** — [`scripts/build_report.py`](scripts/build_report.py) is pure derivation:
  it reads `data/` (no toolchain — zig/otool/xctrace not needed) and builds the
  analysis tree under [`experiments/analysis/`](experiments/analysis/) (per-algorithm
  evidence + LLM narratives via `analyze_algo.py`, machine/memory-layout aggregations,
  a `--verify` integrity gate) and the thin SPA at
  [`experiments/report.html`](experiments/report.html).
- **Profile** (optional) — `collect --with-profile` (or `--only profile`) adds
  cycle attribution across the grid via the host's profiler backend (xctrace on
  macOS) — the *why* behind a bandwidth- or compute-bound result, and the radar's
  data source.

```sh
make collect ML01                   # sweep  (`make collect` = all; `make collect <algo>` = one algorithm)
make collect-profile ML01            # cycle-attribution grid sweep (the radar's data)
make report && make serve          # build + view the dashboard
```

## Project layout

```
src/
  framework/        instruments: config, sim, bench, audit, correctness, hardware, render, ...
  layouts/ML01/      the ML01 vertical: data.zig + loops/ + algorithms
  bindings/         raylib.zig (hand-written extern)
  main.zig          comptime registry: algo-name -> Sim
experiments/
  sweeps/           <mem_layout>.algos lists + death_rates.txt + regime-grid docs
  data/             source-of-truth measurements: <machine_id>/{<algo>.runs,<algo>.profile}.jsonl + <algo>.json + hardware.json (RAW — atomic scripts via collect.py)
  analysis/         derived analysis tree: <m>/<ML>/<algo>.{md,json} + machine/mem-layout bundles (rebuilt by build_report.py)
  golden/           stage1.bin + frame.sha256 (the byte-exact reference; tracked)
  report.html       the thin SPA (+ report.js + style.css) — machine+thread-scoped, fetches analysis/
scripts/            all Python — collect.py (orchestrator) + atomics: algo, bench, profile (+ profile_xctrace),
                    hardware_json; plus build_report, analyze_algo, algo_hash, run.py, sweep_config
Makefile            make build|play|profile|report|serve|collect (target: algo|mem_layout|all)
vendor/raylib/      git submodule (the renderer)
```

The design plan (algorithms, algorithm families, the death model, the sweep/analysis
design) lives in `.scratch/plan/optimization-framework.md` (local, gitignored —
reference, not a build target).
