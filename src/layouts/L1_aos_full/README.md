# L1 — AoS full-field (the strawman layout)

> Vertical V1, landed on branch `layout-verticals`. This README follows the
> layout-verticals.md §3 template: the layout, the strategy table, champions
> per regime, the render story, the Halide section, cross-references.
> All numbers: Apple M4, ReleaseFast, min-of-3-trials, this branch's code.
> Old-branch numbers are cited as priors only.

## 1. The layout

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

## 2. The strategy table

Step: ns/particle (step-only sweep). Frame: ns/frame (step+render, `--frame`).
Gate Ns: 65K (cache-resident) / 1M (L2-spill) / 4M (DRAM).

| strategy         | technique                               | golden                      |       step @65K |    step @1M |     step @4M |   frame @65K |     frame @1M |
|------------------|-----------------------------------------|-----------------------------|----------------:|------------:|-------------:|-------------:|--------------:|
| **naive**        | the baseline (= arc stage 1)            | bit-exact                   |           1.267 |       1.443 |        1.630 |     384.5 µs |     5098.9 µs |
| **naive_r1**     | + optimized splat (render_opt)          | bit-exact                   |           1.277 |       1.415 |        1.593 | **239.4 µs** | **2544.1 µs** |
| **par**          | two-phase multicore (T=1 row)           | bit-exact                   |           1.465 |       1.799 |        1.998 |     401.8 µs |     5221.3 µs |
| **par (best-T)** | T per N: 4/4/10                         | bit-exact ∀T                | **0.894** (T=4) | 1.464 (T=4) | 1.693 (T=10) |            — |             — |
| **halide_a**     | Halide math passes, natural seam (vw=4) | **bit-exact** (StrictFloat) |          2.686 |       4.033 |       4.654 |     477.6 µs |     7678.3 µs |
| halide best      | Adams2019 autoschedule                  | bit-exact                   |               — |       3.677 |            — |            — |             — |

PMC profile, naive @1M (xctrace): **useful 42.8% · discarded 33.0% ·
processing 21.1% · delivery 3.2%** — a third of all slots are discarded work
(the branchy kill + strawman over-fetch); the arc's stage-1 picture,
reproduced on this branch.

## 3. Champion per regime (natural death)

| workload × N-band             | champion                                       | numbers                                                   | why                                                                                                                                                |
|-------------------------------|------------------------------------------------|-----------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| step × cache-resident (≤262K) | **par, best-T** (T=2 at 4–16K, T=4 at 65–262K) | 0.894 @65K, 0.797 @262K vs naive 1.267/1.246 (−30…−36%)   | compute/overhead-bound band: 10 cores share no bandwidth bottleneck yet; the two-phase cost is amortized                                           |
| step × L2-spill (1M)          | **naive**                                      | 1.443 vs par best-T 1.464 (T=4)                           | 68 B/p at ~47 GB/s eff is already at the single-core streaming ceiling; parallel adds no bandwidth and pays the two-phase overhead. Parity at best |
| step × DRAM (≥4M)             | **naive**                                      | 1.630 @4M / 1.649 @64M vs par best-T 1.693/1.726          | same roofline story, worse: dead-mask stream is pure overhead                                                                                      |
| frame × all bands             | **naive_r1**                                   | frame @65K 384.5→239.4 µs (−38%), @1M 5099→2544 µs (−50%) | render dominates the frame (78% @65K, 71% @1M on naive); the r1 splat is 3.2× faster @1M. Step champion is irrelevant to the frame winner here     |

**The parallel story, precisely.** par's thread sweep at 1M: T=1 1.799,
T=2 1.508, T=4 1.464, T=6 1.593, T=8 1.546, T=10 1.523. Best-T is ~4
(the 4 P-cores; E-cores add nothing). **Crossover N ≈ 1M**: below it par
wins clearly (compute-bound band), above it naive wins (shared DRAM
bandwidth — the roofline applies to cores too). The T=1 pool-overhead row:
1.799 vs naive 1.443 @1M = **+25%** — the dead-mask write + block scan is
real money on a 68 B/p walk (2 extra streams on top of the fattest layout).
This is §4.3's hardware truth, measured on the layout where it hurts most.

## 4. The adversarial section (−Ddeath=half @1M)

| strategy    | natural @1M |  half @1M | ratio |
|-------------|------------:|----------:|------:|
| naive       |       1.443 |     9.334 |  6.5× |
| par T=1     |       1.799 |     8.117 |  4.5× |
| **par T=4** |       1.464 | **6.288** |  4.3× |
| par T=8     |       1.546 |     6.436 |  4.2× |

At 50% churn the branchy kill branch in naive mispredicts on every other
particle — the worst case the arc documented but never measured. par's
phase-1 dead-flag write is unconditional (no branch to mispredict) and
phase-2's block scan skips live runs at vector speed, so par degrades
gracefully: **par (best-T) is L1's adversarial champion** even though it
only ties at 1M natural. Best-T stays ~4 under half.

## 5. The Halide section

**The FP gate — decided in V1, applies lab-wide.** Halide pipelines compile
with `TargetFeature.StrictFloat`. Result on L1.halide_a: sim golden **max
delta 0.00** and framebuffer golden PASS — Halide's codegen is bit-identical
to Zig's scalar fmul+fadd for this kernel. **No gate relaxation is needed;
Halide strategies are bit-exact class.** (Re-confirmed per vertical.)

**What halide_a is:** the two math passes (integrate+forces) as an AOT
pipeline over the AoS buffer (2-D interleaved: component stride 1, particle
stride 17 floats), in place; age/kill/respawn stays in Zig (the natural
seam — RNG discipline untouched by construction). The generator is
`halide_a_gen.py` (Python bindings — v21 parity; **deviation from the
plan's `<name>_gen.cpp` naming**: no C++ toolchain in the build at all,
same artifacts). `zig build -Dlayout=L1 -Dstrat=halide_a` runs the
generator and links the static lib; the runtime is bundled, no libHalide
at runtime.

**The sweep** (`scripts/halide_sweep.py` → `.scratch/halide/L1.csv` +
`L1_landscape.png`), step ns/p @1M:

| candidate       |  ns/p |   | candidate       |                ns/p |
|-----------------|------:|---|-----------------|--------------------:|
| manual vw=1     | 4.170 |   | vw=4 + parallel |               35.92 |
| manual vw=2     | 4.052 |   | vw=8 + parallel |               29.24 |
| manual vw=4     | 4.003 |   | Mullapudi2016   |               16.73 |
| manual vw=8     | 4.002 |   | **Adams2019**   |           **3.677** |
| vw=1 + parallel | 37.03 |   | Li2018          |                5.50 |
| vw=2 + parallel | 28.88 |   | Anderson2021    | excluded (GPU-only) |

**Findings:**

1. **The AoS strided-gather floor is ~3.7 ns/p — 2.6× slower than Zig
   scalar naive (1.415) on the same layout; ~2.1× cache-resident (2.686 vs
   1.267 @65K).** Manual vector width barely matters (4.17→4.00: the gather
   IS the cost, not the vector shape), and the best search Halide owns
   (Adams2019's learned cost model) finds 3.68. Nothing approaches scalar.
   The mechanism is decomposed in §5a. This is the planned L1 measurement:
   the AoS vectorization cost, proven on a toolchain that *does*
   vectorize — it vindicates the arc's stage-3 SoA premise independently of
   Zig's autovectorization quirks (the old confound, resolved).
2. **Parallel Halide is catastrophic** (28.9–37.0 ns/p): `parallel(i)`
   spreads a bandwidth-bound strided walk across Halide's runtime pool and
   the cost multiplies. Contrast with L1.par's graceful curve — Zig's
   two-phase pool vs Halide's one-line knob: the knob exists, but the
   hardware truth (shared bandwidth) is not abstracted away.
3. **Attribution:** no ambiguity here — the loss is the layout's, not the
   schedule's. Flat manual sweep + autoscheduler floor ≫ scalar says there
   is no schedule that saves AoS on this kernel. (The Halide-vs-technique
   attribution experiments matter on layouts where Halide can win; L1 is
   not one.)

### 5a. Why halide_a is slow — the mechanism, honestly

Three multiplicative terms, in order of fixability:

1. **The seam forces multi-pass; AoS makes every pass pay full stride.**
   L1.naive fuses math+age+kill into ONE per-particle loop (1 walk × 68 B).
   halide_a runs pos_out and vel_out as separate Halide loop nests, then a
   Zig age/kill loop: 3 walks × 68 B = 204 B/p effective traffic. The
   smoking gun is the bandwidth arithmetic at 1M: 204 B/p ÷ 4.033 ns/p ≈
   51 GB/s actual — Halide is AT the DRAM ceiling (naive: 47 GB/s), it just
   spends 2/3 of the bus re-walking the array. On SoA this term is cheap
   (the age/kill pass touches only age+kind ≈ 5 B/p, not the whole struct)
   — which is why the seam hurts AoS specifically.
2. **NEON can't gather.** Vectorizing `data(c, i..i+3)` at stride 17 lowers
   to scalar `ldr` + `fmov`/`ins` lane-insertion on both the load and store
   side (no hardware gather on arm64 NEON; `ld3` deinterleaves only
   3-tuples — the tuple3 layout's opening, not AoS's). objdump of the vw=4
   loop body: ~170 instructions, of which 3 fmul + 3 fadd are math. The
   cache-resident gap (2.1–2.2× at 4K–262K) is this instruction storm plus
   the extra loop nests, since bandwidth is not binding there.
3. **Parallel multiplies the damage.** 68 B stride guarantees chunk
   boundaries split cache lines → false sharing on the strided stores,
   plus Halide pool dispatch, on an already bandwidth-bound walk (28.9–37.0
   ns/p).

**Could any Halide formulation match naive on AoS?** The fixable term is
(1): fuse pos+vel+age into ONE pipeline pass (Tuple output or
`compute_with`) and write the kill decision to a 1 B/p dead mask, with Zig
doing the par-style mask scan + serial respawn: traffic ≈ 68+2 B/p ≈
naive's 68. That ties naive at DRAM-bound N — but term (2) still taxes
cache-resident N, and a scalar-fused variant that dodges (2) is just
"Halide as a C compiler." Estimate: ~1.6–2.0 ns/p. Recorded as the
optional `halide_a2` follow-up; the conclusion (no vectorization win
exists on AoS) is not in doubt, only the constant.

## 6. Cross-references

- Arc identity: stage 1 (`src/stages/01_naive/sim.zig`, untouched) — same
  code, moved into data.zig + naive.zig. Golden regenerated byte-identical
  (frame hash `ffb583fb…` matches the arc's).
- Old-branch priors (layout-matrix, cited not re-used): L1.naive step
  1.45–1.6 @1M ✓ (this branch: 1.443); L1.lean.r1 frame @65K 149.6 µs —
  not comparable (that was the LEAN layout's frame; full-field L1's r1
  frame is 239.4 µs — the 68 B walk costs render too).
- Hypotheses: old H1 (L1 has the cheapest render walk) is **half-confirmed
  by elimination**: L1's r0 walk is one stream with color adjacent, but at
  68 B/p it is NOT cheap in absolute terms (302 µs @65K r0) — the lean
  layouts will show whether the locality or the bytes dominated. Carried to
  the cross-layout summary.
- Old-branch bug fixed here: r1 renders now clear the framebuffer
  explicitly (the old lean_r1 relied on fresh zero pages).
