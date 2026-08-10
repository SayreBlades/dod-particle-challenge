# ML01 — Array-of-Structs (AoS), full field set

> The frozen data model for ML01. The full algorithm space (every
> expressible algorithm — built + not-expressible, with declared loop
> axes — is documented below. Measured results live in
> [`experiments/analysis/`](../../experiments/analysis/) and the
> interactive report at [`experiments/report.html`](../../experiments/report.html);
> the framework plan (axes, algorithm families, contracts) in
> [`.scratch/plan/optimization-framework.md`](../../.scratch/plan/optimization-framework.md).

## What this memory layout is

**AoS** (Array-of-Structs) is the natural OOP memory layout: one array of `Particle`
records, each record carrying *every* field the object would own, laid out
contiguously in memory as a single 68-byte struct per particle. Walking the
array touches one full struct after another.

**Full-field** means we kept all 11 fields — the honest strawman, the OOP
object as first written: position and velocity (the hot physics), age and life
(the death decision), color/size/rotation/mass/flags/kind/seed (everything an
object would carry). Nothing trimmed, nothing split off. The dead fields (the
ones the hot loops never read) ARE this memory layout's identity — they're the bytes
later memory layouts reclaim.

This is the **strawman** baseline: the worst-case "OOP" memory layout every later
memory layout is measured against. It wastes bytes, but it's also the simplest
possible thing — no indirection, no vtables, no allocation churn — so it's the
*best-case* OOP too. That gap (best-case OOP vs. the bandwidth floor) is the
honest ceiling for any memory layout win here.

## The struct

```
particles: []Particle        ONE AoS array, plain alloc, natural alignment
┌────────┬────────┬──────┬─────┬───────┬──────┬──────────┬──────┬───────┬──────┬──────┐
│pos 12B │vel 12B │life 4│age 4│color16│size 4│rotation 4│mass 4│flags 1│kind 1│seed 4│  = 68 B
└────────┴────────┴──────┴─────┴───────┴──────┴──────────┴──────┴───────┴──────┴──────┘
```

- **bytes/p:** 68 · **streams:** 1 · **field set:** full (11 fields — the OOP
  object as first written; the dead fields ARE the memory layout's identity)
- **allocation:** plain `alloc`, 4 B alignment, exact length

**Audit fingerprint** (N=1024, 600 steps, gzip oracle — 11 AoS-strided blobs):

| field    |   density |
|----------|----------:|
| pos      |     0.734 |
| vel      |     0.743 |
| age      |     0.879 |
| seed     |     0.361 |
| kind     |     0.317 |
| color    |     0.036 |
| rotation |     0.012 |
| mass     |     0.013 |
| size     |     0.013 |
| life     |     0.013 |
| flags    |     0.038 |
| **MEAN** | **0.361** |

Read: 39 B of the 68 B struct (life/color/size/rotation/mass/flags) carries
~0 bits of information per frame — the indictment that drives ML02 (lean field
set). This is the reference fingerprint every later memory layout's audit compares
against.

## The ML01 algorithm space

An **algorithm** is one frozen assignment of the per-loop axes
(impl · schedule · variant · parallel) to an algorithm family. ML01 has **23 built
algorithms** — one self-contained `.zig` file each, verified `--check` PASS +
golden PASS — spanning all 8 algorithm families. The table below lists those 23
plus every other expressible algorithm in the search space.
Existing algorithms link to their source.

### The five logical stages

Every frame is built from five stages; an algorithm family fuses them into loops.

| stage | what it does |
|---|---|
| **Integrate** | `pos += vel·dt`; `vel += (gravity + drag·vel)·dt`; `age += dt`. Pure physics, per-particle independent. |
| **Decide** | Is this particle dead this frame? Age-out (`age ≥ kill_age`) OR accident (Bernoulli rate q from the kill-RNG). |
| **Respawn** | For the dead: re-roll kind, set impulse+jitter, reset age. Draws from the spawn RNG. |
| **Render** | Splat the particle's color into the 2D framebuffer (saturating add). Commutative + associative → byte-identical for any write order. |

(Read is implicit — every loop loads what it needs.)

### The loop-types

Algorithm families fuse those stages into 1–3 loops. There are 9 distinct loop-types
by stage composition; an algorithm is a choice of loop-type per loop plus a
per-loop axis assignment.

| loop-type | stages fused | appears in | notes |
|---|---|---|---|
| **math** | Integrate | AF02·w1, AF06·w1 | per-particle independent → trivially data-parallel |
| **math+decide+respawn** | Integrate+Decide+Respawn | AF01·w1, AF05·w1 | the "full" loop; the respawn branch is what branchy/blend differ on |
| **decide+respawn** | Decide+Respawn | AF02·w2 | re-reads `age` across the seam — the cost AF03's mask was invented to kill |
| **math+decide→mask** | Integrate+Decide → 1 B/p mask | AF03·w1, AF07·w1 | the mask is what makes the respawn loop parallelizable |
| **mask-scan+respawn** | scan mask, respawn where set | AF03·w2, AF07·w2 | index-order → bit-exact; ranked-merge parallelizes it |
| **math+decide→list** | Integrate+Decide → compact idx[] | AF04·w1, AF08·w1 | variable-length append → irregular, not Halide-expressible |
| **respawn-dead-only** | loop the dead list, respawn each | AF04·w2, AF08·w2 | O(dead) not O(N) → wins at rare death, loses at common |
| **render** | splat | AF01·w2, AF02·w3, AF03·w3, AF04·w3, AF08·w3 | `simple` (per-pixel) or `opt` (LUT + NEON `uqadd`); byte-identical |
| **fused** | render inlined into the physics loop | AF05·w1, AF06·w2, AF07·w2, AF08·w2 | reads post-respawn pos from a register before eviction — the fusion win |

### The per-loop axes

Each loop carries four attributes (declared in the algorithm's `algo_meta`):

- **impl** — `zig` or `halide`. Halide only where expressible: it cannot do
  irregular list appends (AF04/AF08 list loops), fused framebuffer scatter
  (AF05–AF08 fused loops), or branchy respawn (`select` is branchless).
- **schedule** — for compute loops: `scalar` (asm-boxed de-vec control),
  `auto` (let LLVM vectorize), `unroll` (manual loop unroll-by-4 via `inline for`;
  isolates the unroll knob — see AF01.LP1-unroll), `vw4` (explicit `@Vector`); for Halide
  compute loops: `vw{1,2,4,8}` (vector width over the particle dim); for
  render loops: `simple` or `opt`; for fused loops: `fused`.
- **variant** — only respawn-bearing loops: `branchy` (if-dead → respawn,
  ordered spawn RNG, **bit-exact**), `blend` (branchless select, per-particle
  hash RNG, **statistical**), `ordered` (index-order scan respawn via
  mask/list, **bit-exact**). `none` for loops with no respawn.
- **parallel** — `none`, `data_parallel` (`parallel(i)` over particles),
  `ranked_merge` (count → prefix-sum → respawn-by-rank; bit-exact),
  `render_reduce` (per-thread framebuffers, reduce at end — **declared in the
  enum, not yet implemented in any algorithm**).

### Notation in the table

Each loop is written `impl·sched·variant·parallel`; loops separated by ` | `.

| symbol | meaning |
|---|---|
| **impl** | `z`=zig  `h`=halide |
| **sched** | `S`=scalar  `A`=auto  `U`=unroll-by-4  `V4`=explicit-@Vector  `1/2/4/8`=halide vector-width  `simple`/`opt`=render  `F`=fused |
| **variant** | `by`=branchy  `br`=blend  `or`=ordered  `·`=none |
| **parallel** | `·`=none  `dp`=data_parallel  `rm`=ranked_merge  `rr`=render_reduce |

### The algorithms

| algorithm | ex | loops |
|---|---|---|
| [AF01.LP1-scalar.LP2-simple](AF01.LP1-scalar.LP2-simple.zig) | ✓ | z·S·by·· \| z·simple·· |
| [AF01.LP1-unroll.LP2-simple](AF01.LP1-unroll.LP2-simple.zig) | ✓ | z·U·by·· \| z·simple·· |
| [AF01.LP1-autovec.LP2-simple](AF01.LP1-autovec.LP2-simple.zig) | ✓ | z·A·by·· \| z·simple·· |
| [AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.zig) | ✓ | z·A·by·· \| z·opt·· |
| [AF01.LP1-autovec-par.LP2-simple](AF01.LP1-autovec-par.LP2-simple.zig) | ✓ | z·A·by·dp \| z·simple·· |
| [AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.zig) | ✓ | z·A·br·· \| z·simple·· |
| [AF01.LP1-blend-par.LP2-simple](AF01.LP1-blend-par.LP2-simple.zig) | ✓ | z·A·br·dp \| z·simple·· |
| [AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.zig) | ✓ | h·1·br·· \| z·simple·· |
| [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.zig) | ✓ | h·1·br·· \| z·opt·· |
| [AF01.LP1-halide-par.LP2-simple](AF01.LP1-halide-par.LP2-simple.zig) | ✓ | h·1·br·dp \| z·simple·· |
| `AF01.LP1-halide-vw4.LP2-simple` | ✗ | h·4·br·· \| z·simple·· |
| `AF01.LP1-halide-vw2.LP2-simple` | ✗ | h·2·br·· \| z·simple·· |
| `AF01.LP1-halide-vw8.LP2-simple` | ✗ | h·8·br·· \| z·simple·· |
| `AF01.LP1-halide-vw4.LP2-opt` | ✗ | h·4·br·· \| z·opt·· |
| `AF01.LP1-halide-vw4-par.LP2-simple` | ✗ | h·4·br·dp \| z·simple·· |
| `AF01.LP1-halide-vw2-par.LP2-simple` | ✗ | h·2·br·dp \| z·simple·· |
| `AF01.LP1-halide-vw8-par.LP2-simple` | ✗ | h·8·br·dp \| z·simple·· |
| `AF01.LP1-halide-vw2.LP2-opt` | ✗ | h·2·br·· \| z·opt·· |
| `AF01.LP1-halide-vw8.LP2-opt` | ✗ | h·8·br·· \| z·opt·· |
| `AF01.LP1-scalar-par.LP2-simple` | ✗ | z·S·by·dp \| z·simple·· |
| `AF01.LP1-blend.LP2-opt` | ✗ | z·A·br·· \| z·opt·· |
| `AF01.LP1-blend-scalar.LP2-simple` | ✗ | z·S·br·· \| z·simple·· |
| `AF01.LP1-vw4.LP2-simple` | ✗ | z·V4·by·· \| z·simple·· |
| `AF01.LP1-scalar.LP2-opt` | ✗ | z·S·by·· \| z·opt·· |
| `AF01.LP1-autovec-par.LP2-opt` | ✗ | z·A·by·dp \| z·opt·· |
| `AF01.LP1-blend-par.LP2-opt` | ✗ | z·A·br·dp \| z·opt·· |
| `AF01.LP1-vw4.{LP2-opt, LP2-par-simple, LP2-par-opt}` (3) | ✗ | z·V4·by·{·,dp} \| z·{simple,opt} |
| `AF01.LP1-halide-vw{2,4,8}-par.LP2-opt` (3) | ✗ | h·{2,4,8}·br·dp \| z·opt |
| `AF01.LP1-⟨each loop-1⟩.LP2-{simple,opt}-rr` (~18) | ✗ | … \| z·{simple,opt}··rr |
| [AF02.LP1-autovec.LP2-simple](AF02.LP1-autovec.LP2-simple.zig) | ✓ | z·A··· \| z·A·by·· \| z·simple·· |
| [AF02.LP1-autovec-par.LP2-simple](AF02.LP1-autovec-par.LP2-simple.zig) | ✓ | z·A···dp \| z·A·by·· \| z·simple·· |
| [AF02.LP1-halide.LP2-simple](AF02.LP1-halide.LP2-simple.zig) | ✓ | h·1··· \| z·A·by·· \| z·simple·· |
| [AF02.LP1-halide-par.LP2-simple](AF02.LP1-halide-par.LP2-simple.zig) | ✓ | h·1···dp \| z·A·by·· \| z·simple·· |
| `AF02.LP1-halide-vw4.LP2-simple` | ✗ | h·4··· \| z·A·by·· \| z·simple·· |
| `AF02.LP1-halide-vw2.LP2-simple` | ✗ | h·2··· \| … |
| `AF02.LP1-halide-vw8.LP2-simple` | ✗ | h·8··· \| … |
| `AF02.LP1-halide-vw4-par.LP2-simple` | ✗ | h·4···dp \| … |
| `AF02.LP1-halide-vw{2,8}-{,par}.LP2-simple` + `vw4.LP2-opt` (5) | ✗ | various |
| `AF02.LP1-scalar.LP2-simple` | ✗ | z·S··· \| z·A·by·· \| z·simple·· |
| `AF02.LP1-vw4.LP2-simple` | ✗ | z·V4··· \| … |
| `AF02.LP2-blend.LP3-simple` | ✗ | … \| z·A·br·· \| z·simple·· |
| `AF02.LP2-blend-par.LP3-simple` | ✗ | … \| z·A·br·dp \| z·simple·· |
| `AF02.LP3-render_reduce` family (~8) | ✗ | … \| z·{simple,opt}··rr |
| [AF03.LP1-autovec.LP2-simple](AF03.LP1-autovec.LP2-simple.zig) | ✓ | z·A··· \| z·A·or·· \| z·simple·· |
| [AF03.LP1-autovec-par.LP2-rmerge](AF03.LP1-autovec-par.LP2-rmerge.zig) | ✓ | z·A···dp \| z·A·or·rm \| z·simple·· |
| [AF03.LP1-halide.LP2-simple](AF03.LP1-halide.LP2-simple.zig) | ✓ | h·1··· \| z·A·or·· \| z·simple·· |
| `AF03.LP1-halide-vw4.LP2-simple` | ✗ | h·4··· \| z·A·or·· \| z·simple·· |
| `AF03.LP1-halide-vw2.LP2-simple` | ✗ | h·2··· \| … |
| `AF03.LP1-halide-vw8.LP2-simple` | ✗ | h·8··· \| … |
| `AF03.LP1-halide-par.LP2-rmerge` | ✗ | h·{1,4}···dp \| z·A·or·rm \| z·simple·· |
| `AF03.LP1-halide-vw4-par.LP2-rmerge` | ✗ | h·4···dp \| z·A·or·rm \| z·simple·· |
| `AF03.LP1-halide-vw{2,8}-{,par}.LP2-{simple,rmerge}` (3) | ✗ | various |
| `AF03.LP1-scalar.LP2-simple` | ✗ | z·S··· \| z·A·or·· \| z·simple·· |
| `AF03.LP1-vw4.LP2-simple` | ✗ | z·V4··· \| … |
| `AF03.LP2-scalar` | ✗ | … \| z·S·or·· \| … |
| `AF03.LP3-render_reduce` family (~8) | ✗ | … \| z·{simple,opt}··rr |
| [AF04.LP1-autovec.LP2-simple](AF04.LP1-autovec.LP2-simple.zig) | ✓ | z·A··· \| z·A·or·· \| z·simple·· |
| [AF04.LP1-autovec-par.LP2-rmerge](AF04.LP1-autovec-par.LP2-rmerge.zig) | ✓ | z·A···dp \| z·A·or·rm \| z·simple·· |
| `AF04.LP1-scalar.LP2-simple` | ✗ | z·S··· \| z·A·or·· \| z·simple·· |
| `AF04.LP1-vw4.LP2-simple` | ✗ | z·V4··· \| … |
| `AF04.LP1-scalar-par.LP2-rmerge` | ✗ | z·S···dp \| z·A·or·rm \| … |
| `AF04.LP2-scalar` | ✗ | … \| z·S·or·· \| … |
| `AF04.LP3-render_reduce` family (~4) | ✗ | … \| z·{simple,opt}··rr |
| [AF05.LP1-fused](AF05.LP1-fused.zig) | ✓ | z·F·by·· |
| `AF05.LP1-scalar-fused` | ✗ | z·(boxed-math)·by·· |
| `AF05.LP1-blend-fused` | ✗ | z·F·br·· |
| `AF05.LP1-fused-par` | ✗ | z·F·by·(dp+rr) |
| `AF05.LP1-blend-fused-par` | ✗ | z·F·br·(dp+rr) |
| `AF05.LP1-vw4-fused` | ✗ | z·V4·by·· |
| [AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.zig) | ✓ | z·A··· \| z·F·by·· |
| `AF06.LP1-halide.LP2-fused` | ✗ | h·1··· \| z·F·by·· |
| `AF06.LP1-halide-vw4.LP2-fused` | ✗ | h·4··· \| z·F·by·· |
| `AF06.LP1-halide-par.LP2-fused` | ✗ | h·{1,4}···dp \| z·F·by·· |
| `AF06.LP1-halide-vw{2,8}.{,par}.LP2-fused` (4) | ✗ | various |
| `AF06.LP2-fused-par` | ✗ | z·A···{,dp} \| z·F·by·rr |
| `AF06.LP2-blend-fused` | ✗ | z·A··· \| z·F·br·· |
| `AF06.LP2-blend-fused-par` | ✗ | z·A··· \| z·F·br·(dp+rr) |
| `AF06.LP1-scalar.LP2-fused` | ✗ | z·S··· \| z·F·by·· |
| `AF06.LP1-vw4.LP2-fused` | ✗ | z·V4··· \| … |
| [AF07.LP1-autovec.LP2-fused](AF07.LP1-autovec.LP2-fused.zig) | ✓ | z·A··· \| z·F·or·· |
| `AF07.LP1-halide.LP2-fused` | ✗ | h·1··· \| z·F·or·· |
| `AF07.LP1-halide-vw4.LP2-fused` | ✗ | h·4··· \| z·F·or·· |
| `AF07.LP1-halide-par.LP2-fused` | ✗ | h·{1,4}···dp \| z·F·or·· |
| `AF07.LP1-halide-vw{2,8}.{,par}.LP2-fused` (4) | ✗ | various |
| `AF07.LP2-fused-par` | ✗ | z·A···{,dp} \| z·F·or·(rm+rr) |
| `AF07.LP1-scalar.LP2-fused` | ✗ | z·S··· \| z·F·or·· |
| `AF07.LP1-vw4.LP2-fused` | ✗ | z·V4··· \| … |
| [AF08.LP1-autovec.LP2-fused](AF08.LP1-autovec.LP2-fused.zig) | ✓ | z·A··· \| z·F·or·· \| z·simple·· |
| `AF08.LP2-fused-par` | ✗ | z·A···{,dp} \| z·F·or·(rm+rr) \| z·simple··rr |
| `AF08.LP1-scalar.LP2-fused` | ✗ | z·S··· \| … |
| `AF08.LP1-vw4.LP2-fused` | ✗ | z·V4··· \| … |
| `AF08.LP3-render_reduce` | ✗ | … \| z·simple··rr |
