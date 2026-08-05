# L1 — Array-of-Structs (AoS), full field set

> The frozen data model for L1. The full cell space (every
> expressible cell — built + not-expressible, with declared walk
> axes — is documented below. Measured results live in
> [`experiments/analysis/`](../../experiments/analysis/) and the
> interactive report at [`experiments/report.html`](../../experiments/report.html);
> the framework plan (axes, blueprints, contracts) in
> [`.scratch/plan/optimization-framework.md`](../../.scratch/plan/optimization-framework.md).

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
~0 bits of information per frame — the indictment that drives L2 (lean field
set). This is the reference fingerprint every later layout's audit compares
against.

## The L1 cell space

A **cell** is one frozen assignment of the per-walk axes
(impl · schedule · variant · parallel) to a blueprint. L1 has **22 built
cells** — one self-contained `.zig` file each, verified `--check` PASS +
golden PASS — spanning all 8 blueprints. The table below lists those 22
plus every other expressible cell in the search space.
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

### The cells

| cell | ex | walks |
|---|---|---|
| [B1.w1-scalar.w2-simple](B1.w1-scalar.w2-simple.zig) | ✓ | z·S·by·· \| z·simple·· |
| [B1.w1-autovec.w2-simple](B1.w1-autovec.w2-simple.zig) | ✓ | z·A·by·· \| z·simple·· |
| [B1.w1-autovec.w2-opt](B1.w1-autovec.w2-opt.zig) | ✓ | z·A·by·· \| z·opt·· |
| [B1.w1-autovec-par.w2-simple](B1.w1-autovec-par.w2-simple.zig) | ✓ | z·A·by·dp \| z·simple·· |
| [B1.w1-blend.w2-simple](B1.w1-blend.w2-simple.zig) | ✓ | z·A·br·· \| z·simple·· |
| [B1.w1-blend-par.w2-simple](B1.w1-blend-par.w2-simple.zig) | ✓ | z·A·br·dp \| z·simple·· |
| [B1.w1-halide.w2-simple](B1.w1-halide.w2-simple.zig) | ✓ | h·1·br·· \| z·simple·· |
| [B1.w1-halide.w2-opt](B1.w1-halide.w2-opt.zig) | ✓ | h·1·br·· \| z·opt·· |
| [B1.w1-halide-par.w2-simple](B1.w1-halide-par.w2-simple.zig) | ✓ | h·1·br·dp \| z·simple·· |
| `B1.w1-halide-vw4.w2-simple` | ✗ | h·4·br·· \| z·simple·· |
| `B1.w1-halide-vw2.w2-simple` | ✗ | h·2·br·· \| z·simple·· |
| `B1.w1-halide-vw8.w2-simple` | ✗ | h·8·br·· \| z·simple·· |
| `B1.w1-halide-vw4.w2-opt` | ✗ | h·4·br·· \| z·opt·· |
| `B1.w1-halide-vw4-par.w2-simple` | ✗ | h·4·br·dp \| z·simple·· |
| `B1.w1-halide-vw2-par.w2-simple` | ✗ | h·2·br·dp \| z·simple·· |
| `B1.w1-halide-vw8-par.w2-simple` | ✗ | h·8·br·dp \| z·simple·· |
| `B1.w1-halide-vw2.w2-opt` | ✗ | h·2·br·· \| z·opt·· |
| `B1.w1-halide-vw8.w2-opt` | ✗ | h·8·br·· \| z·opt·· |
| `B1.w1-scalar-par.w2-simple` | ✗ | z·S·by·dp \| z·simple·· |
| `B1.w1-blend.w2-opt` | ✗ | z·A·br·· \| z·opt·· |
| `B1.w1-blend-scalar.w2-simple` | ✗ | z·S·br·· \| z·simple·· |
| `B1.w1-vw4.w2-simple` | ✗ | z·V4·by·· \| z·simple·· |
| `B1.w1-scalar.w2-opt` | ✗ | z·S·by·· \| z·opt·· |
| `B1.w1-autovec-par.w2-opt` | ✗ | z·A·by·dp \| z·opt·· |
| `B1.w1-blend-par.w2-opt` | ✗ | z·A·br·dp \| z·opt·· |
| `B1.w1-vw4.{w2-opt, w2-par-simple, w2-par-opt}` (3) | ✗ | z·V4·by·{·,dp} \| z·{simple,opt} |
| `B1.w1-halide-vw{2,4,8}-par.w2-opt` (3) | ✗ | h·{2,4,8}·br·dp \| z·opt |
| `B1.w1-⟨each walk-1⟩.w2-{simple,opt}-rr` (~18) | ✗ | … \| z·{simple,opt}··rr |
| [B2.w1-autovec.w2-simple](B2.w1-autovec.w2-simple.zig) | ✓ | z·A··· \| z·A·by·· \| z·simple·· |
| [B2.w1-autovec-par.w2-simple](B2.w1-autovec-par.w2-simple.zig) | ✓ | z·A···dp \| z·A·by·· \| z·simple·· |
| [B2.w1-halide.w2-simple](B2.w1-halide.w2-simple.zig) | ✓ | h·1··· \| z·A·by·· \| z·simple·· |
| [B2.w1-halide-par.w2-simple](B2.w1-halide-par.w2-simple.zig) | ✓ | h·1···dp \| z·A·by·· \| z·simple·· |
| `B2.w1-halide-vw4.w2-simple` | ✗ | h·4··· \| z·A·by·· \| z·simple·· |
| `B2.w1-halide-vw2.w2-simple` | ✗ | h·2··· \| … |
| `B2.w1-halide-vw8.w2-simple` | ✗ | h·8··· \| … |
| `B2.w1-halide-vw4-par.w2-simple` | ✗ | h·4···dp \| … |
| `B2.w1-halide-vw{2,8}-{,par}.w2-simple` + `vw4.w2-opt` (5) | ✗ | various |
| `B2.w1-scalar.w2-simple` | ✗ | z·S··· \| z·A·by·· \| z·simple·· |
| `B2.w1-vw4.w2-simple` | ✗ | z·V4··· \| … |
| `B2.w2-blend.w3-simple` | ✗ | … \| z·A·br·· \| z·simple·· |
| `B2.w2-blend-par.w3-simple` | ✗ | … \| z·A·br·dp \| z·simple·· |
| `B2.w3-render_reduce` family (~8) | ✗ | … \| z·{simple,opt}··rr |
| [B3.w1-autovec.w2-simple](B3.w1-autovec.w2-simple.zig) | ✓ | z·A··· \| z·A·or·· \| z·simple·· |
| [B3.w1-autovec-par.w2-rmerge](B3.w1-autovec-par.w2-rmerge.zig) | ✓ | z·A···dp \| z·A·or·rm \| z·simple·· |
| [B3.w1-halide.w2-simple](B3.w1-halide.w2-simple.zig) | ✓ | h·1··· \| z·A·or·· \| z·simple·· |
| `B3.w1-halide-vw4.w2-simple` | ✗ | h·4··· \| z·A·or·· \| z·simple·· |
| `B3.w1-halide-vw2.w2-simple` | ✗ | h·2··· \| … |
| `B3.w1-halide-vw8.w2-simple` | ✗ | h·8··· \| … |
| `B3.w1-halide-par.w2-rmerge` | ✗ | h·{1,4}···dp \| z·A·or·rm \| z·simple·· |
| `B3.w1-halide-vw4-par.w2-rmerge` | ✗ | h·4···dp \| z·A·or·rm \| z·simple·· |
| `B3.w1-halide-vw{2,8}-{,par}.w2-{simple,rmerge}` (3) | ✗ | various |
| `B3.w1-scalar.w2-simple` | ✗ | z·S··· \| z·A·or·· \| z·simple·· |
| `B3.w1-vw4.w2-simple` | ✗ | z·V4··· \| … |
| `B3.w2-scalar` | ✗ | … \| z·S·or·· \| … |
| `B3.w3-render_reduce` family (~8) | ✗ | … \| z·{simple,opt}··rr |
| [B4.w1-autovec.w2-simple](B4.w1-autovec.w2-simple.zig) | ✓ | z·A··· \| z·A·or·· \| z·simple·· |
| [B4.w1-autovec-par.w2-rmerge](B4.w1-autovec-par.w2-rmerge.zig) | ✓ | z·A···dp \| z·A·or·rm \| z·simple·· |
| `B4.w1-scalar.w2-simple` | ✗ | z·S··· \| z·A·or·· \| z·simple·· |
| `B4.w1-vw4.w2-simple` | ✗ | z·V4··· \| … |
| `B4.w1-scalar-par.w2-rmerge` | ✗ | z·S···dp \| z·A·or·rm \| … |
| `B4.w2-scalar` | ✗ | … \| z·S·or·· \| … |
| `B4.w3-render_reduce` family (~4) | ✗ | … \| z·{simple,opt}··rr |
| [B5.w1-fused](B5.w1-fused.zig) | ✓ | z·F·by·· |
| `B5.w1-scalar-fused` | ✗ | z·(boxed-math)·by·· |
| `B5.w1-blend-fused` | ✗ | z·F·br·· |
| `B5.w1-fused-par` | ✗ | z·F·by·(dp+rr) |
| `B5.w1-blend-fused-par` | ✗ | z·F·br·(dp+rr) |
| `B5.w1-vw4-fused` | ✗ | z·V4·by·· |
| [B6.w1-autovec.w2-fused](B6.w1-autovec.w2-fused.zig) | ✓ | z·A··· \| z·F·by·· |
| `B6.w1-halide.w2-fused` | ✗ | h·1··· \| z·F·by·· |
| `B6.w1-halide-vw4.w2-fused` | ✗ | h·4··· \| z·F·by·· |
| `B6.w1-halide-par.w2-fused` | ✗ | h·{1,4}···dp \| z·F·by·· |
| `B6.w1-halide-vw{2,8}.{,par}.w2-fused` (4) | ✗ | various |
| `B6.w2-fused-par` | ✗ | z·A···{,dp} \| z·F·by·rr |
| `B6.w2-blend-fused` | ✗ | z·A··· \| z·F·br·· |
| `B6.w2-blend-fused-par` | ✗ | z·A··· \| z·F·br·(dp+rr) |
| `B6.w1-scalar.w2-fused` | ✗ | z·S··· \| z·F·by·· |
| `B6.w1-vw4.w2-fused` | ✗ | z·V4··· \| … |
| [B7.w1-autovec.w2-fused](B7.w1-autovec.w2-fused.zig) | ✓ | z·A··· \| z·F·or·· |
| `B7.w1-halide.w2-fused` | ✗ | h·1··· \| z·F·or·· |
| `B7.w1-halide-vw4.w2-fused` | ✗ | h·4··· \| z·F·or·· |
| `B7.w1-halide-par.w2-fused` | ✗ | h·{1,4}···dp \| z·F·or·· |
| `B7.w1-halide-vw{2,8}.{,par}.w2-fused` (4) | ✗ | various |
| `B7.w2-fused-par` | ✗ | z·A···{,dp} \| z·F·or·(rm+rr) |
| `B7.w1-scalar.w2-fused` | ✗ | z·S··· \| z·F·or·· |
| `B7.w1-vw4.w2-fused` | ✗ | z·V4··· \| … |
| [B8.w1-autovec.w2-fused](B8.w1-autovec.w2-fused.zig) | ✓ | z·A··· \| z·F·or·· \| z·simple·· |
| `B8.w2-fused-par` | ✗ | z·A···{,dp} \| z·F·or·(rm+rr) \| z·simple··rr |
| `B8.w1-scalar.w2-fused` | ✗ | z·S··· \| … |
| `B8.w1-vw4.w2-fused` | ✗ | z·V4··· \| … |
| `B8.w3-render_reduce` | ✗ | … \| z·simple··rr |
