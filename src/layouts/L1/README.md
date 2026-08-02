# L1 — Array-of-Structs (AoS), full field set

> The frozen data model for L1. The full cell space (every expressible
> cell, existing + missing, with per-cell value ratings) and the champion
> grid are documented below. The auto-generated manifest lives in
> `experiments/cells/L1.md`; the framework plan (axes, blueprints,
> contracts) in `.scratch/plan/optimization-framework.md`. All numbers:
> Apple M4, ReleaseFast, min-of-3-trials.

## What this layout is

**AoS** (Array-of-Structs) is the natural OOP layout: one array of `Particle`
records, each record carrying *every* field the object would own, laid out
contiguously in memory as a single 68-byte struct per particle. Walking the
array touches one full struct after another.

**Full-field** means we kept all 11 fields — the honest strawman, the OOP
object as first written: position and velocity (the hot physics), age and life
(the death decision), color/size/rotation/mass/flags/kind/seed (everything an
object would carry). Nothing trimmed, nothing split off. The dead fields (the
ones the hot loops never read) ARE this layout's identity — they're the bytes
later layouts reclaim.

This is the **strawman** baseline: the worst-case "OOP" layout every later
layout is measured against. It wastes bytes, but it's also the simplest
possible thing — no indirection, no vtables, no allocation churn — so it's the
*best-case* OOP too. That gap (best-case OOP vs. the bandwidth floor) is the
honest ceiling for any layout win here.

## The struct

```
particles: []Particle        ONE AoS array, plain alloc, natural alignment
┌────────┬────────┬──────┬─────┬───────┬──────┬──────────┬──────┬───────┬──────┬──────┐
│pos 12B │vel 12B │life 4│age 4│color16│size 4│rotation 4│mass 4│flags 1│kind 1│seed 4│  = 68 B
└────────┴────────┴──────┴─────┴───────┴──────┴──────────┴──────┴───────┴──────┴──────┘
```

- **bytes/p:** 68 · **streams:** 1 · **field set:** full (11 fields — the OOP
  object as first written; the dead fields ARE the layout's identity)
- **allocation:** plain `alloc`, 4 B alignment, exact length

**Audit fingerprint** (N=1024, 600 steps, gzip oracle — 11 AoS-strided blobs):

| field | density |   | field    |   density |
|-------|--------:|---|----------|----------:|
| pos   |   0.734 |   | rotation |     0.012 |
| vel   |   0.743 |   | mass     |     0.013 |
| age   |   0.879 |   | size     |     0.013 |
| seed  |   0.361 |   | life     |     0.013 |
| kind  |   0.317 |   | flags    |     0.038 |
| color |   0.036 |   | **MEAN** | **0.361** |

Read: 39 B of the 68 B struct (life/color/size/rotation/mass/flags) carries
~0 bits of information per frame — the indictment that drives L2 (lean field
set). This is the reference fingerprint every later layout's audit compares
against.

## The L1 cell space

A **cell** is one frozen assignment of the per-walk axes
(impl · schedule · variant · parallel) to a blueprint. L1 has **22 built
cells** — one self-contained `.zig` file each, verified `--check` PASS +
golden PASS — spanning all 8 blueprints. The table below lists those 22
plus every other expressible cell in the search space, each rated by
scientific value (**h** / **m** / **l**) so the build queue is visible.
Existing cells link to their source.

### The five logical stages

Every frame is built from five stages; a blueprint fuses them into walks.

| stage | what it does |
|---|---|
| **Integrate** | `pos += vel·dt`; `vel += (gravity + drag·vel)·dt`; `age += dt`. Pure physics, per-particle independent. |
| **Decide** | Is this particle dead this frame? Age-out (`age ≥ kill_age`) OR accident (Bernoulli rate q from the kill-RNG). |
| **Respawn** | For the dead: re-roll kind, set impulse+jitter, reset age. Draws from the spawn RNG. |
| **Render** | Splat the particle's color into the 2D framebuffer (saturating add). Commutative + associative → byte-identical for any write order. |

(Read is implicit — every walk loads what it needs.)

### The walk-types

Blueprints fuse those stages into 1–3 walks. There are 9 distinct walk-types
by stage composition; a cell is a choice of walk-type per walk plus a
per-walk axis assignment.

| walk-type | stages fused | appears in | notes |
|---|---|---|---|
| **math** | Integrate | B2·w1, B6·w1 | per-particle independent → trivially data-parallel |
| **math+decide+respawn** | Integrate+Decide+Respawn | B1·w1, B5·w1 | the "full" walk; the respawn branch is what branchy/blend differ on |
| **decide+respawn** | Decide+Respawn | B2·w2 | re-reads `age` across the seam — the cost B3's mask was invented to kill |
| **math+decide→mask** | Integrate+Decide → 1 B/p mask | B3·w1, B7·w1 | the mask is what makes the respawn walk parallelizable |
| **mask-scan+respawn** | scan mask, respawn where set | B3·w2, B7·w2 | index-order → bit-exact; ranked-merge parallelizes it |
| **math+decide→list** | Integrate+Decide → compact idx[] | B4·w1, B8·w1 | variable-length append → irregular, not Halide-expressible |
| **respawn-dead-only** | walk the dead list, respawn each | B4·w2, B8·w2 | O(dead) not O(N) → wins at rare death, loses at common |
| **render** | splat | B1·w2, B2·w3, B3·w3, B4·w3, B8·w3 | `simple` (per-pixel) or `opt` (LUT + NEON `uqadd`); byte-identical |
| **fused** | render inlined into the physics loop | B5·w1, B6·w2, B7·w2, B8·w2 | reads post-respawn pos from a register before eviction — the fusion win |

### The per-walk axes

Each walk carries four attributes (declared in the cell's `cell_decl`):

- **impl** — `zig` or `halide`. Halide only where expressible: it cannot do
  irregular list appends (B4/B8 list walks), fused framebuffer scatter
  (B5–B8 fused walks), or branchy respawn (`select` is branchless).
- **schedule** — for compute walks: `scalar` (asm-boxed de-vec control),
  `auto` (let LLVM vectorize), `vw4` (explicit `@Vector`); for Halide
  compute walks: `vw{1,2,4,8}` (vector width over the particle dim); for
  render walks: `simple` or `opt`; for fused walks: `fused`.
- **variant** — only respawn-bearing walks: `branchy` (if-dead → respawn,
  ordered spawn RNG, **bit-exact**), `blend` (branchless select, per-particle
  hash RNG, **statistical**), `ordered` (index-order scan respawn via
  mask/list, **bit-exact**). `none` for walks with no respawn.
- **parallel** — `none`, `data_parallel` (`parallel(i)` over particles),
  `ranked_merge` (count → prefix-sum → respawn-by-rank; bit-exact),
  `render_reduce` (per-thread framebuffers, reduce at end — **declared in the
  enum, not yet implemented in any cell**).

### Notation in the table

Each walk is written `impl·sched·variant·parallel`; walks separated by ` | `.

| symbol | meaning |
|---|---|
| **impl** | `z`=zig  `h`=halide |
| **sched** | `S`=scalar  `A`=auto  `V4`=explicit-@Vector  `1/2/4/8`=halide vector-width  `simple`/`opt`=render  `F`=fused |
| **variant** | `by`=branchy  `br`=blend  `or`=ordered  `·`=none |
| **parallel** | `·`=none  `dp`=data_parallel  `rm`=ranked_merge  `rr`=render_reduce |

### Value ratings

- **h** — tests a load-bearing hypothesis, fills a declared axis the framework
  claims to explore but hasn't, or is a current/likely champion whose
  unmeasured axis matters.
- **m** — completes an attribution matrix; plausibly competitive in some
  regime but not champion-critical.
- **l** — redundant loop body (identical elsewhere), near-zero-information
  combo, or pure cross-product noise.

### The cells

| cell | ex | val | walks | why this rating |
|---|---|---|---|---|
| [B1.w1-scalar.w2-simple](B1.w1-scalar.w2-simple.zig) | ✓ | m | z·S·by·· \| z·simple·· | The one de-vec control (asm-boxed math). The baseline for "what does autovec buy on this layout"; not itself a champion. |
| [B1.w1-autovec.w2-simple](B1.w1-autovec.w2-simple.zig) | ✓ | h | z·A·by·· \| z·simple·· | The golden reference (generates `stage1.bin` + `frame.sha256`). Natural-death co-champion baseline. |
| [B1.w1-autovec.w2-opt](B1.w1-autovec.w2-opt.zig) | ✓ | h | z·A·by·· \| z·opt·· | **Natural-death champion at every N-band** (~3 ns/p). The `opt` splat's tight loop wins when the rarely-taken respawn branch is predicted. |
| [B1.w1-autovec-par.w2-simple](B1.w1-autovec-par.w2-simple.zig) | ✓ | m | z·A·by·dp \| z·simple·· | Parallel bit-exact baseline; isolates what data-parallelism buys the branchy walk. Not a champion (parallel loses at DRAM on L1). |
| [B1.w1-blend.w2-simple](B1.w1-blend.w2-simple.zig) | ✓ | h | z·A·br·· \| z·simple·· | The Zig blend control — same math + RNG model as the Halide blend, isolating impl (zig vs halide) with variant held at blend. Attribution anchor for the high-death story. |
| [B1.w1-blend-par.w2-simple](B1.w1-blend-par.w2-simple.zig) | ✓ | m | z·A·br·dp \| z·simple·· | Parallel blend (statistical). Tests parallelism on the branchless walk. |
| [B1.w1-halide.w2-simple](B1.w1-halide.w2-simple.zig) | ✓ | h | h·1·br·· \| z·simple·· | Halide blend baseline (vw=1). The branchless floor at natural death. |
| [B1.w1-halide.w2-opt](B1.w1-halide.w2-opt.zig) | ✓ | h | h·1·br·· \| z·opt·· | **High-death champion everywhere** (q≥0.05). Branchless blend is death-rate-invariant; the branchy cells' mispredict cost rises with churn. |
| [B1.w1-halide-par.w2-simple](B1.w1-halide-par.w2-simple.zig) | ✓ | m | h·1·br·dp \| z·simple·· | Parallel halide blend. Predicted DRAM champion but measured losing to serial at DRAM on L1. |
| `B1.w1-halide-vw4.w2-simple` | ✗ | h | h·4·br·· \| z·simple·· | **The key gather-tax measurement.** NEON is 4 lanes; vw4 forces across-particle vectorization on stride-17 AoS — the central §5 prediction (Halide loses on AoS via gather), currently asserted not measured. |
| `B1.w1-halide-vw2.w2-simple` | ✗ | m | h·2·br·· \| z·simple·· | Density-sweep low end; sub-saturating point that completes the vw curve. |
| `B1.w1-halide-vw8.w2-simple` | ✗ | m | h·8·br·· \| z·simple·· | Density-sweep high end (2 vectors wide); tests over-wide diminishing cost. |
| `B1.w1-halide-vw4.w2-opt` | ✗ | m | h·4·br·· \| z·opt·· | Best density × best render; plausible high-death champion if the gather tax is smaller than the opt-splat win. |
| `B1.w1-halide-vw4-par.w2-simple` | ✗ | m | h·4·br·dp \| z·simple·· | Density + data-parallel; tests whether vectorization and parallelism compose on the blend walk. |
| `B1.w1-halide-vw2-par.w2-simple` | ✗ | l | h·2·br·dp \| z·simple·· | Covered by the vw4-par representative; no new axis point. |
| `B1.w1-halide-vw8-par.w2-simple` | ✗ | l | h·8·br·dp \| z·simple·· | Covered by vw4-par. |
| `B1.w1-halide-vw2.w2-opt` | ✗ | l | h·2·br·· \| z·opt·· | Covered by vw4-opt. |
| `B1.w1-halide-vw8.w2-opt` | ✗ | l | h·8·br·· \| z·opt·· | Covered by vw4-opt. |
| `B1.w1-scalar-par.w2-simple` | ✗ | m | z·S·by·dp \| z·simple·· | Scalar + parallel: with autovec disabled, isolates pure parallel speedup from the autovec interaction. Clean par-overhead measurement. |
| `B1.w1-blend.w2-opt` | ✗ | m | z·A·br·· \| z·opt·· | Blend is high-death-competitive; pairing with the `opt` splat may extend its lead over halide-opt at some regime. |
| `B1.w1-blend-scalar.w2-simple` | ✗ | l | z·S·br·· \| z·simple·· | Blend is already branchless (its whole point); the scalar de-vec control has near-nothing to isolate here. |
| `B1.w1-vw4.w2-simple` | ✗ | l | z·V4·by·· \| z·simple·· | Explicit `@Vector` on stride-17 AoS — §5 predicts the gather tax makes it lose; this is L5's (tuple4) question, not L1's. |
| `B1.w1-scalar.w2-opt` | ✗ | l | z·S·by·· \| z·opt·· | Scalar control + `opt` splat: the two axes are orthogonal, so this confirms rather than informs. |
| `B1.w1-autovec-par.w2-opt` | ✗ | l | z·A·by·dp \| z·opt·· | par × opt cross; orthogonal axes, low info. |
| `B1.w1-blend-par.w2-opt` | ✗ | l | z·A·br·dp \| z·opt·· | par × opt cross; low info. |
| `B1.w1-vw4.{w2-opt, w2-par-simple, w2-par-opt}` (3) | ✗ | l | z·V4·by·{·,dp} \| z·{simple,opt} | Explicit-SIMD crosses; L5 territory. |
| `B1.w1-halide-vw{2,4,8}-par.w2-opt` (3) | ✗ | l | h·{2,4,8}·br·dp \| z·opt | density × par × opt triple cross — pure combinatorial noise. |
| `B1.w1-⟨each walk-1⟩.w2-{simple,opt}-rr` (~18) | ✗ | l | … \| z·{simple,opt}··rr | `render_reduce` only pays when render is *fused* into a compute walk; B1's render is a separate pass, so per-thread framebuffers + reduce is pure overhead here. |
| [B2.w1-autovec.w2-simple](B2.w1-autovec.w2-simple.zig) | ✓ | h | z·A··· \| z·A·by·· \| z·simple·· | The "natural seam" baseline (math separable from decide+respawn). Bit-exact; isolates the seam cost. |
| [B2.w1-autovec-par.w2-simple](B2.w1-autovec-par.w2-simple.zig) | ✓ | m | z·A···dp \| z·A·by·· \| z·simple·· | Parallel math walk (walk 1 is the only parallelizable one — walk 2 is RNG-order bound). |
| [B2.w1-halide.w2-simple](B2.w1-halide.w2-simple.zig) | ✓ | h | h·1··· \| z·A·by·· \| z·simple·· | Halide does math, Zig keeps decide+respawn. The canonical Halide-on-AoS cell. |
| [B2.w1-halide-par.w2-simple](B2.w1-halide-par.w2-simple.zig) | ✓ | m | h·1···dp \| z·A·by·· \| z·simple·· | Parallel Halide math + serial Zig decide+respawn. |
| `B2.w1-halide-vw4.w2-simple` | ✗ | h | h·4··· \| z·A·by·· \| z·simple·· | **Cleanest density point in the whole layout** — walk 1 is pure math (no respawn), so vw4 measures the gather tax on compute alone, uncontaminated by blend/branchy effects. |
| `B2.w1-halide-vw2.w2-simple` | ✗ | m | h·2··· \| … | Sweep low end. |
| `B2.w1-halide-vw8.w2-simple` | ✗ | m | h·8··· \| … | Sweep high end. |
| `B2.w1-halide-vw4-par.w2-simple` | ✗ | m | h·4···dp \| … | Density + parallel math. |
| `B2.w1-halide-vw{2,8}-{,par}.w2-simple` + `vw4.w2-opt` (5) | ✗ | l | various | Covered crosses; no new axis point. |
| `B2.w1-scalar.w2-simple` | ✗ | m | z·S··· \| z·A·by·· \| z·simple·· | Scalar twin for the pure-math walk-type. Without it, "Halide math vs Zig math" can't separate Halide's schedule from autovec leaving performance on the table. |
| `B2.w1-vw4.w2-simple` | ✗ | l | z·V4··· \| … | Explicit SIMD; L5. |
| `B2.w2-blend.w3-simple` | ✗ | l | … \| z·A·br·· \| z·simple·· | Blend's value (death-rate-invariance) requires respawn fused with math; separated in walk 2 it loses the advantage — low info. |
| `B2.w2-blend-par.w3-simple` | ✗ | l | … \| z·A·br·dp \| z·simple·· | The only safely-parallel walk-2 for B2 (statistical), but the blend-here-loses point above makes it low value. |
| `B2.w3-render_reduce` family (~8) | ✗ | l | … \| z·{simple,opt}··rr | Separate render pass; `render_reduce` doesn't pay. |
| [B3.w1-autovec.w2-simple](B3.w1-autovec.w2-simple.zig) | ✓ | h | z·A··· \| z·A·or·· \| z·simple·· | The mask baseline. Bit-exact; the two-walk split that makes the respawn walk parallelizable. |
| [B3.w1-autovec-par.w2-rmerge](B3.w1-autovec-par.w2-rmerge.zig) | ✓ | h | z·A···dp \| z·A·or·rm \| z·simple·· | The parallel mask cell (ranked-merge) — the bit-exact parallel walk-2, the framework's main parallelism finding; validates `pool.zig`. |
| [B3.w1-halide.w2-simple](B3.w1-halide.w2-simple.zig) | ✓ | m | h·1··· \| z·A·or·· \| z·simple·· | Halide math+decide→mask; Zig scan+respawn. Tests Halide on the mask-producing walk. |
| `B3.w1-halide-vw4.w2-simple` | ✗ | h | h·4··· \| z·A·or·· \| z·simple·· | **Gather-tax measurement on the math+decide→mask walk** — the third density point; confirms whether the tax is walk-shape-invariant. |
| `B3.w1-halide-vw2.w2-simple` | ✗ | m | h·2··· \| … | Sweep low end. |
| `B3.w1-halide-vw8.w2-simple` | ✗ | m | h·8··· \| … | Sweep high end. |
| `B3.w1-halide-par.w2-rmerge` | ✗ | m | h·{1,4}···dp \| z·A·or·rm \| z·simple·· | **Mixed Halide walk-1 + Zig ranked-merge walk-2** — both halves are expressible and individually built, but never combined. Completes the B3 parallel matrix. |
| `B3.w1-halide-vw4-par.w2-rmerge` | ✗ | m | h·4···dp \| z·A·or·rm \| z·simple·· | Density + the mixed-parallel combo. |
| `B3.w1-halide-vw{2,8}-{,par}.w2-{simple,rmerge}` (3) | ✗ | l | various | Covered crosses. |
| `B3.w1-scalar.w2-simple` | ✗ | m | z·S··· \| z·A·or·· \| z·simple·· | Scalar twin for the math+decide→mask walk-type. |
| `B3.w1-vw4.w2-simple` | ✗ | l | z·V4··· \| … | Explicit SIMD; L5. |
| `B3.w2-scalar` | ✗ | l | … \| z·S·or·· \| … | The mask-scan walk is branch/index-bound (prefix sum), not SIMD-bound; scalar control ≈ zero info. |
| `B3.w3-render_reduce` family (~8) | ✗ | l | … \| z·{simple,opt}··rr | Separate render pass. |
| [B4.w1-autovec.w2-simple](B4.w1-autovec.w2-simple.zig) | ✓ | m | z·A··· \| z·A·or·· \| z·simple·· | The list baseline. Bit-exact; wins only at rare death (walk 2 ≈ N·death_rate work). |
| [B4.w1-autovec-par.w2-rmerge](B4.w1-autovec-par.w2-rmerge.zig) | ✓ | m | z·A···dp \| z·A·or·rm \| z·simple·· | Parallel list cell; ranked-merge over the dead list. |
| `B4.w1-scalar.w2-simple` | ✗ | m | z·S··· \| z·A·or·· \| z·simple·· | Scalar twin for the math+decide→list walk-type. |
| `B4.w1-vw4.w2-simple` | ✗ | l | z·V4··· \| … | Explicit SIMD; L5. |
| `B4.w1-scalar-par.w2-rmerge` | ✗ | l | z·S···dp \| z·A·or·rm \| … | Scalar + par cross on a non-champion blueprint. |
| `B4.w2-scalar` | ✗ | l | … \| z·S·or·· \| … | Index-bound dead-list walk; no SIMD signal. |
| `B4.w3-render_reduce` family (~4) | ✗ | l | … \| z·{simple,opt}··rr | Separate render pass. |
| [B5.w1-fused](B5.w1-fused.zig) | ✓ | h | z·F·by·· | Fully-fused baseline (math+decide+respawn+render in one loop). Small-N champion candidate; the fusion-hypothesis measurement. |
| `B5.w1-scalar-fused` | ✗ | h | z·(boxed-math)·by·· | **Schedule sensitivity of a fused champion.** The fused loop is a *distinct body* — math interleaved with framebuffer scatter — so the scalar control tests whether autovec on the math survives scatter. None of the unfused scalar twins answer this. |
| `B5.w1-blend-fused` | ✗ | m | z·F·br·· | Fully-fused branchless. The death-rate-invariant *fused* champion candidate (blend + fusion combined). |
| `B5.w1-fused-par` | ✗ | h | z·F·by·(dp+rr) | **Parallel + fused-render hypothesis** — the framework predicts both "parallel wins at cache-resident N" and "fused-render wins at cache-resident N"; their product is untested. Requires implementing `render_reduce`. |
| `B5.w1-blend-fused-par` | ✗ | m | z·F·br·(dp+rr) | Parallel branchless fused (statistical) — the fully-unlocked blend cell. |
| `B5.w1-vw4-fused` | ✗ | l | z·V4·by·· | Explicit SIMD interleaved with scatter; noisy and L5's territory. |
| [B6.w1-autovec.w2-fused](B6.w1-autovec.w2-fused.zig) | ✓ | h | z·A··· \| z·F·by·· | **Small-N / mid-churn champion** (grid: q=0.05 small). The render-fusion win confirmed at the cache-resident corner. |
| `B6.w1-halide.w2-fused` | ✗ | m | h·1··· \| z·F·by·· | Mixed Halide math + Zig fused-render. Tests whether Halide math helps when render is fused. |
| `B6.w1-halide-vw4.w2-fused` | ✗ | m | h·4··· \| z·F·by·· | Density point on a fused-render blueprint. |
| `B6.w1-halide-par.w2-fused` | ✗ | m | h·{1,4}···dp \| z·F·by·· | Parallel Halide math + fused render. |
| `B6.w1-halide-vw{2,8}.{,par}.w2-fused` (4) | ✗ | l | various | Covered crosses. |
| `B6.w2-fused-par` | ✗ | h | z·A···{,dp} \| z·F·by·rr | **Parallel fused-render on the actual grid champion.** The highest-value parallel cell because the base is already a champion. Requires `render_reduce`. |
| `B6.w2-blend-fused` | ✗ | m | z·A··· \| z·F·br·· | Fused branchless respawn. |
| `B6.w2-blend-fused-par` | ✗ | m | z·A··· \| z·F·br·(dp+rr) | Parallel branchless fused. |
| `B6.w1-scalar.w2-fused` | ✗ | l | z·S··· \| z·F·by·· | Walk-1 loop body is byte-identical to B2.w1 → scalar delta == B2.w1-scalar's (redundant; per-blueprint reading would raise to m). |
| `B6.w1-vw4.w2-fused` | ✗ | l | z·V4··· \| … | Explicit SIMD; L5. |
| [B7.w1-autovec.w2-fused](B7.w1-autovec.w2-fused.zig) | ✓ | m | z·A··· \| z·F·or·· | Mask + fused-render baseline. |
| `B7.w1-halide.w2-fused` | ✗ | m | h·1··· \| z·F·or·· | Mixed Halide walk-1 + Zig fused walk-2. |
| `B7.w1-halide-vw4.w2-fused` | ✗ | m | h·4··· \| z·F·or·· | Density point. |
| `B7.w1-halide-par.w2-fused` | ✗ | m | h·{1,4}···dp \| z·F·or·· | Parallel math + fused render. |
| `B7.w1-halide-vw{2,8}.{,par}.w2-fused` (4) | ✗ | l | various | Covered crosses. |
| `B7.w2-fused-par` | ✗ | m | z·A···{,dp} \| z·F·or·(rm+rr) | Parallel; combines ranked_merge AND `render_reduce` — the hardest parallel cell (two coordination schemes). |
| `B7.w1-scalar.w2-fused` | ✗ | l | z·S··· \| z·F·or·· | Walk-1 ≡ B3.w1 body → redundant with B3's scalar twin. |
| `B7.w1-vw4.w2-fused` | ✗ | l | z·V4··· \| … | Explicit SIMD; L5. |
| [B8.w1-autovec.w2-fused](B8.w1-autovec.w2-fused.zig) | ✓ | m | z·A··· \| z·F·or·· \| z·simple·· | The most complex blueprint: list + mask + dead/live render split. |
| `B8.w2-fused-par` | ✗ | m | z·A···{,dp} \| z·F·or·(rm+rr) \| z·simple··rr | Parallel; three coordination schemes combined (ranked_merge + `render_reduce` × 2 walks). |
| `B8.w1-scalar.w2-fused` | ✗ | l | z·S··· \| … | Walk-1 ≡ B4.w1 body → redundant with B4's scalar twin. |
| `B8.w1-vw4.w2-fused` | ✗ | l | z·V4··· \| … | Explicit SIMD; L5. |
| `B8.w3-render_reduce` | ✗ | l | … \| z·simple··rr | B8 already splits render (dead/live); a `render_reduce` on the live pass adds little. |

### Roll-up

| blueprint | exist ✓ | ✗ **h** | ✗ **m** | ✗ **l** (rows) | ✗ **l** (family members) |
|---|---|---|---|---|---|
| B1 | 9 | 1 | 6 | 5 | ~21 |
| B2 | 4 | 1 | 4 | 2 | ~8 |
| B3 | 3 | 1 | 4 | 2 | ~8 |
| B4 | 2 | 0 | 1 | 2 | ~4 |
| B5 | 1 | 2 | 2 | 1 | — |
| B6 | 1 | 1 | 4 | 2 | — |
| B7 | 1 | 0 | 3 | 2 | — |
| B8 | 1 | 0 | 1 | 2 | ~1 |
| **total** | **22** | **6** | **25** | **18** | **~42** |

**The six high-value cells to build** (the visible queue):

1. `B1.w1-halide-vw4.w2-simple` — gather-tax measurement on the champion family
2. `B2.w1-halide-vw4.w2-simple` — cleanest density point (pure math walk)
3. `B3.w1-halide-vw4.w2-simple` — density on math+decide→mask
4. `B5.w1-scalar-fused` — schedule sensitivity of a fused-scatter champion
5. `B5.w1-fused-par` — parallel + fused-render hypothesis (needs `render_reduce`)
6. `B6.w2-fused-par` — same hypothesis on the actual grid champion (needs `render_reduce`)

Two themes dominate: **Halide schedule density at vw4** (cells 1–3 — pure
build wiring, the generators already accept `vector_width`), and **parallel
fused-render via `render_reduce`** (cells 5–6 + the scheme's own
implementation). The `B5.w1-scalar-fused` cell is the one-off.

## The L1 champion grid

22 cells across all 8 blueprints (B1–B8) were implemented, verified
(`--check` PASS + golden PASS for all), and swept across the probe rate set
{0.01, 0.05, 0.25} × 6 N-bands (4K–4M) × 3 trials. The 4 champions graduated
to the full rate set {0, 0.01, 0.05, 0.1, 0.25, 0.5, 0.75}. All numbers:
Apple M4, ReleaseFast, min-of-3-trials.

### Champion per regime × death rate (frame, ns/particle)

| N-band       | q=0   | q=0.01 | q=0.05      | q=0.1       | q=0.25      | q=0.5       | q=0.75      |
|-------------|-------|--------|-------------|-------------|-------------|-------------|-------------|
| small ≤65K  | **autovec-opt** 3.4 | **autovec-simple** 7.7 | **B6-fused** 7.4 | **halide-opt** 7.7 | **halide-opt** 7.5 | **halide-opt** 8.2 | **halide-opt** 9.1 |
| mid 262K–1M | **autovec-opt** 3.0 | **autovec-opt** 5.0 | **halide-opt** 5.4 | **halide-opt** 5.1 | **halide-opt** 4.7 | **halide-opt** 5.3 | **halide-opt** 6.4 |
| large ≥4M   | **autovec-opt** 3.2 | **autovec-opt** 4.9 | **halide-opt** 5.3 | **halide-opt** 5.0 | **halide-opt** 4.7 | **halide-opt** 5.3 | **halide-opt** 6.4 |

Cell key: `autovec-opt` = B1.w1-autovec.w2-opt · `autovec-simple` =
B1.w1-autovec.w2-simple · `halide-opt` = B1.w1-halide.w2-opt · `B6-fused` =
B6.w1-autovec.w2-fused.

### What the grid says

1. **At natural death (q=0)**, B1.w1-autovec.w2-opt dominates everywhere
   (~3 ns/p, ~21 GB/s achieved vs the 5.6 GB/s streaming ceiling). The r1
   splat's tight loop wins when the rarely-taken branch is predicted and cheap.

2. **As death rate rises (q≥0.05)**, B1.w1-halide.w2-opt takes over. The
   branchless blend (Halide, per-particle hash RNG) is death-rate-invariant —
   its cost doesn't rise with churn, while the branchy autovec cell's
   mispredict cost does. The crossover is at q≈0.05 (mid/large N).

3. **At small N, q=0.05**, B6.w1-autovec.w2-fused wins — a surprise. The fused
   render saves a pos re-read when the working set is cache-resident; at small
   N the extra instruction cost of the fused loop is cheaper than the second
   pass's memory traffic. This is the render-fusion hypothesis (§3 B5/B6)
   confirmed at the small-N/cache-resident corner.

4. **No global winner.** The champion moves autovec-opt → halide-opt as death
   rises, and B6-fused edges in at small-N/mid-churn. Every declaration carries
   regime + numbers (§16.9).

### PMC cycle attribution (champions, N=1M, q=0)

| cell              | cycles  | %useful | %processing | %discarded |
|-------------------|--------:|--------:|------------:|-----------:|
| B1.w1-autovec.w2-opt    | 44.8M | 60.0% | 22.0% | 17.9% |
| B1.w1-halide.w2-opt     | 44.3M | 59.3% | 22.9% | 17.8% |
| B1.w1-autovec.w2-simple | 46.1M | 58.9% | 23.5% | 17.5% |
| B6.w1-autovec.w2-fused  | 45.1M | 59.1% | 23.2% | 17.7% |

At natural death all four champions are ~59–60% useful cycles, ~22%
processing-bottleneck, ~18% discarded. They share the same bottleneck — the
AoS gather (stride-17) and memory stalls — not the blueprint. The death-rate
differentiation (branchy vs blend) would show up in the discarded/processing
breakdown at q>0; at q=0 the branch is rarely taken so the profiles converge.

<!-- AUTO-GENERATED by scripts/build_report.py — do not edit. -->
## Champion grid

The fastest cell per (regime, death_q), min ns/particle across trials. The canonical SQL lives in `experiments/report/queries.sql`; reproduced here verbatim so the README is self-contained:

```sql
-- Champion grid for L1: the fastest cell per (regime, death_q).
-- regime: small <=65K, mid 262K-1M, large >=16M. min ns/particle across trials.
WITH ranked AS (
  SELECT cell, death_q,
    CASE WHEN N <= 65000 THEN 'small' WHEN N <= 1000000 THEN 'mid' ELSE 'large' END AS regime,
    min(ns_particle) AS ns_particle,
    min(achieved_bw_gbs) AS achieved_bw_gbs,
    row_number() OVER (PARTITION BY
      CASE WHEN N <= 65000 THEN 'small' WHEN N <= 1000000 THEN 'mid' ELSE 'large' END,
      death_q
      ORDER BY min(ns_particle)) AS rk
  FROM report
  WHERE layout = 'L1' AND machine_id = (
    SELECT machine_id FROM report WHERE layout='L1'
    GROUP BY machine_id ORDER BY count(*) DESC LIMIT 1)
  GROUP BY cell, death_q, regime
)
SELECT regime, death_q, cell,
       round(ns_particle, 3) AS ns_particle,
       round(achieved_bw_gbs, 2) AS achieved_bw_gbs,
       (SELECT streaming_bw_gbs FROM hardware LIMIT 1) AS streaming_bw_gbs
FROM ranked WHERE rk = 1
ORDER BY regime, death_q
```

| regime | death_q | cell | ns_particle | achieved_bw_gbs | streaming_bw_gbs |
|---|---|---|---|---|---|
| large | 0.0 | L1.B1.w1-autovec.w2-opt | 3.227 | 20.03 | 25.22 |
| large | 0.01 | L1.B1.w1-autovec.w2-opt | 4.897 | 13.46 | 25.22 |
| large | 0.05 | L1.B1.w1-halide.w2-opt | 5.33 | 12.56 | 25.22 |
| large | 0.1 | L1.B1.w1-halide.w2-opt | 5.04 | 13.45 | 25.22 |
| large | 0.25 | L1.B1.w1-halide.w2-opt | 4.707 | 14.33 | 25.22 |
| large | 0.5 | L1.B1.w1-halide.w2-opt | 5.321 | 12.76 | 25.22 |
| large | 0.75 | L1.B1.w1-halide.w2-opt | 6.395 | 10.62 | 25.22 |
| mid | 0.0 | L1.B1.w1-autovec.w2-opt | 3.001 | 20.55 | 25.22 |
| mid | 0.01 | L1.B1.w1-autovec.w2-opt | 4.974 | 12.96 | 25.22 |
| mid | 0.05 | L1.B1.w1-halide.w2-opt | 5.375 | 12.49 | 25.22 |
| mid | 0.1 | L1.B1.w1-halide.w2-opt | 5.054 | 12.55 | 25.22 |
| mid | 0.25 | L1.B1.w1-halide.w2-opt | 4.675 | 14.36 | 25.22 |
| mid | 0.5 | L1.B1.w1-halide.w2-opt | 5.304 | 12.71 | 25.22 |
| mid | 0.75 | L1.B1.w1-halide.w2-opt | 6.382 | 10.61 | 25.22 |
| small | 0.0 | L1.B1.w1-autovec.w2-opt | 3.056 | 17.45 | 25.22 |
| small | 0.01 | L1.B1.w1-autovec.w2-opt | 5.128 | 5.4 | 25.22 |
| small | 0.05 | L1.B1.w1-halide.w2-opt | 5.409 | 6.26 | 25.22 |
| small | 0.1 | L1.B1.w1-halide.w2-opt | 5.068 | 6.71 | 25.22 |
| small | 0.25 | L1.B1.w1-halide.w2-opt | 4.687 | 6.81 | 25.22 |
| small | 0.5 | L1.B1.w1-halide.w2-opt | 5.313 | 6.5 | 25.22 |
| small | 0.75 | L1.B1.w1-halide.w2-opt | 6.396 | 5.75 | 25.22 |
<!-- /AUTO-GENERATED -->






