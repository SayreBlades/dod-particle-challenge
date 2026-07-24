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

| strategy         | technique                                                                                           | golden                      |       step @65K |    step @1M |     step @4M |   frame @65K |     frame @1M |
|------------------|-----------------------------------------------------------------------------------------------------|-----------------------------|----------------:|------------:|-------------:|-------------:|--------------:|
| **naive**        | the baseline (= arc stage 1)                                                                        | bit-exact                   |           1.267 |       1.443 |        1.630 |     384.5 µs |     5098.9 µs |
| **naive_r1**     | + optimized splat (render_opt)                                                                      | bit-exact                   |           1.277 |       1.415 |        1.593 | **239.4 µs** | **2544.1 µs** |
| **par**          | two-phase multicore (T=1 row)                                                                       | bit-exact                   |           1.465 |       1.799 |        1.998 |     401.8 µs |     5221.3 µs |
| **par (best-T)** | T per N: 4/4/10                                                                                     | bit-exact ∀T                | **0.894** (T=4) | 1.464 (T=4) | 1.693 (T=10) |            — |             — |
| **naive_novec**  | naive with auto-vectorization disabled (opaque-asm control, §5c)                                        | bit-exact                   |           1.547 |       1.608 |        1.698 |     403.4 µs |     5232.8 µs |
| **halide_a**     | Halide math, ONE fused nest (pos+vel+age = naive's full branch-free loop body), natural seam (vw=4) | **bit-exact** (StrictFloat) |           2.481 |       2.877 |        2.921 |     467.1 µs |     6383.3 µs |
| **halide_a2**    | a + dead-mask (Zig scans 1 B/p, not the struct), LEAN 9×1-D scalar streams (§5d)                  | **bit-exact** (StrictFloat) |           1.749 |       1.929 |        2.106 |     421.4 µs |     5416.0 µs |
| halide best      | manual vw=8 (sweep optimum)                                                                         | bit-exact                   |               — |       2.794 |            — |            — |             — |

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

**What halide_a is:** naive.zig's complete branch-free loop body —
`pos += vel*dt`, `vel += (g + drag*vel)*dt`, `age += dt` — as an AOT
pipeline over the AoS buffer (2-D interleaved: component stride 1, particle
stride 17 floats), computed in ONE fused loop nest (`compute_with`), in
place; kill/respawn stays in Zig (the natural seam — RNG discipline
untouched by construction). The formulation exists for assembly-level
comparability with naive.zig's step loop (§5b). The generator is
`halide_a_gen.py` (Python bindings — v21 parity; **deviation from the
plan's `<name>_gen.cpp` naming**: no C++ toolchain in the build at all,
same artifacts). `zig build -Dlayout=L1 -Dstrat=halide_a` runs the
generator and links the static lib; the runtime is bundled, no libHalide
at runtime.

**The sweep** (`scripts/halide_sweep.py` → `.scratch/halide/L1.csv` +
`L1_landscape.png`), step ns/p @1M:

| candidate       |      ns/p |   | candidate       |                ns/p |
|-----------------|----------:|---|-----------------|--------------------:|
| manual vw=1     |     3.087 |   | vw=4 + parallel |               15.41 |
| manual vw=2     |     2.945 |   | vw=8 + parallel |               14.14 |
| manual vw=4     |     2.828 |   | Mullapudi2016   |               24.39 |
| **manual vw=8** | **2.794** |   | Adams2019       |                4.53 |
| vw=1 + parallel |     27.23 |   | Li2018          |                6.95 |
| vw=2 + parallel |     23.18 |   | Anderson2021    | excluded (GPU-only) |

(Fused-nest generator. Note the inversion vs the pre-fusion pipeline:
manual schedules now BEAT every autoscheduler — Adams2019 found 3.68 on
the two-output pipeline but only 4.53 here; the third output changed the
cost model's choice, and not for the better. The landscape is
schedule-fragile; the floor is not.)

**Findings:**

1. **The AoS strided-gather floor is ~2.8 ns/p — 1.9× slower than Zig
   naive (1.461) on the same layout, at every N band (2.48 vs 1.27 @65K,
   2.92 vs 1.63 @4M).** Manual vector width barely matters (3.09→2.79:
   the gather IS the cost, not the vector shape), and every autoscheduler
   LOSES to the trivial manual `vectorize(i)` schedule. Nothing approaches
   naive. The mechanism is decomposed in §5a/§5b. This is the planned L1
   measurement: the AoS vectorization cost, proven on a toolchain that
   *does* vectorize — it vindicates the arc's stage-3 SoA premise
   independently of Zig's autovectorization quirks (the old confound,
   resolved).
2. **Parallel Halide is catastrophic** (14.1–27.2 ns/p even after fusion): `parallel(i)`
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

halide_a computes naive.zig's COMPLETE branch-free loop body (pos, vel,
age) in ONE fused Halide nest (the pre-fusion two-nest version measured
4.03 @1M; fusion alone bought 29%). Two multiplicative terms remain:

1. **The seam forces TWO walks; AoS makes every walk pay full stride.**
   L1.naive fuses math+age+kill into ONE per-particle loop (1 walk × 68 B).
   halide_a runs the fused Halide math nest, then a Zig kill/respawn walk:
   2 × 68 B = 136 B/p effective traffic. The smoking gun is the bandwidth
   arithmetic at 1M: 136 B/p ÷ 2.877 ns/p = **47.3 GB/s actual — exactly
   naive's bandwidth** (1.443 ns/p × 68 B/p). Halide is AT the DRAM
   ceiling; the entire DRAM-side gap is the second walk. On SoA this term
   is cheap (the kill walk touches only age+kind ≈ 5 B/p, not the whole
   struct) — which is why the seam hurts AoS specifically.
2. **NEON can't gather, and the shuffle tax is the cache-resident gap.**
   Vectorizing `data(c, i..i+3)` at stride 17 lowers to scalar `ldr` +
   per-lane `ld1.s` insertion on the load side and per-lane `st1.s`
   extraction on the store side (no hardware gather on arm64 NEON; `ld3`
   deinterleaves only 3-tuples — the tuple3 layout's opening, not AoS's).
   §5b counts the instructions: ~44/particle vs naive's ~24, with 2× fewer
   math ops. At 65K (bandwidth not binding) that instruction storm IS the
   2.0× gap.
3. **Parallel multiplies the damage.** 68 B stride guarantees chunk
   boundaries split cache lines → false sharing on the strided stores,
   plus Halide pool dispatch, on an already bandwidth-bound walk (14.1–27.2
   ns/p).

**Could any Halide formulation match naive on AoS?** Term (1) is closable:
write the kill decision to a 1 B/p dead mask in the pipeline and let Zig do
the par-style mask scan + serial respawn — traffic ≈ 68+2 B/p ≈ naive's
68, a tie at DRAM-bound N. Term (2) is not closable: the gather is
stride-17's structural cost on NEON. Estimate for the dead-mask variant:
~1.6–2.0 ns/p. Recorded as the optional `halide_a2` follow-up; the
conclusion (no vectorization win exists on AoS) is not in doubt, only the
constant.

### 5b. The assembly comparison — naive.zig vs the Halide nest

naive.zig's compiled step loop
(`_framework.sim.Strategy(...naive.H).step`, ReleaseFast, objdump):
~24 instructions steady-state per particle:

```
ldr  q1, [x21]        # pos.xyz + vel.x in ONE 16 B load
ldr  d2, [x21,#0x10]  # vel.yz
ext  v3, v1, v2, #0xc # build vel.4s
fmul.4s v0, v3, v4    # vel * dt          ← 4-wide, ACROSS COMPONENTS
fadd.4s v0, v1, v0    # pos + vel*dt
str  q0, [x21]        # write pos.xyz (+vel.x) in one 16 B store
fmul.2s / fadd.2s ×2  # vel' = vel + (g + drag*vel)*dt, 2-wide
str  d0, [x21,#0x10]
fadd s0 (age) ; fcmp ; b.lt   # kill branch → rare Data.spawn call
```

Three loads + three stores cover all 28 hot bytes; LLVM **auto-vectorized
per-particle, across the x/y/z components** (the one vectorization AoS
permits). Two honest surprises: the deliberate `switch(kind)` and the
cold-field touches (`_ = p.mass` …) were dead-code-eliminated entirely —
the strawman's remaining cost is the 68 B stride, not the dummy work.

The Halide fused nest (`_halide_a`, vw=4), inner loop per component:
~25 instructions per 4 particles per component — per-lane `ld1.s` gathers
(4 scalar-addressed lane loads per input vector), 1 `fmul.4s` + 1
`fadd.4s` of actual math, per-lane `st1.s` scatters; ×7 components
(pos/vel/age) ≈ **44 instructions/particle, ~1.8 of them math**.

The comparison in one line: **LLVM vectorized naive ACROSS COMPONENTS
(xyz lanes — free, no gather); Halide vectorized ACROSS PARTICLES
(`vectorize(i,4)` — stride-17 gather on every load and store).** The
component-lane formulation is the only good SIMD on AoS, and it is not
expressible as a Halide schedule knob on this pipeline shape (`vectorize`
applies to the iteration dimension; the component dim has extent 3 and is
shared across output Funcs). That inexpressibility is itself a finding:
the schedule language assumes you already chose a vectorizable layout.

The two vectorization axes, visualized:

```
naive (lanes = ONE particle's components — memory-adjacent):
  ldr q1:  v1 = [ pos.x │ pos.y │ pos.z │ vel.x ]   16 B contiguous, 1 load
  ext:     v3 = [ vel.x │ vel.y │ vel.z │ drag·vx ] shuffle, no memory
  fmul.4s  v3 × [dt dt dt dt]
  fadd.4s  v1 + that = [ px' │ py' │ pz' │ vx' ]
  str q0:  writes pos' AND vel.x' in ONE 16 B store
  → 1 load feeds 4 lanes; ~24 insns/particle, ~7 math

halide (lanes = FOUR particles' same component — 68 B apart):
  ldur s6 ; ld1.s {v6}[1] ; ld1.s {v6}[2] ; ld1.s {v6}[3]
    v6 = [ px(i) │ px(i+1) │ px(i+2) │ px(i+3) ]   4 loads + 3 inserts
    v7 = [ vx(i) │ vx(i+1) │ vx(i+2) │ vx(i+3) ]   4 more loads + 3 inserts
  fmul.4s ; fadd.4s          ← the only math, 2 ops per 4 particles
  stur s6 ; st1.s {v6}[1..3] ← 4 scalar stores, ~272 B apart
  × 7 components ≈ 44 insns/particle, ~1.8 math
```

(De-vectorizing naive as a control: Zig exposes no `-fno-vectorize`; the
levers are `doNotOptimizeAway` on scalar intermediates (surgical),
interleaving cold fields (a different layout, by our rules), opaque calls
(confounding overhead), volatile (restores the cold touches but forbids
all reordering — a different machine). Recorded as the optional
`naive_novec` control; at DRAM-bound N the prediction is it still beats
halide_a — the gap there is walks, not vector width.)

(Disassemble locally: `objdump -d zig-out/bin/dod-particles | grep -A40
'naive.H).step'` and `objdump -d zig-out/halide/halide_a.a`.)

### 5c. The de-vectorization control (naive_novec)

**Method.** Zig exposes no `-fno-vectorize`, and the obvious
door—`doNotOptimizeAway(&x); return x;`—does NOT work: an input-only asm
operand leaves dataflow transparent, and LLVM re-packs after the barrier
(measured: vel.x/y still became `fmul.2s`). The working lever is an
**opaque-output asm box** (`asm ("" : [ret] "=w" (-> f32) : [in] "w" (x)`)
applied to every input and result of the per-component math: the optimizer
cannot prove the output equals the input, so SLP cannot pack across the
box. Verified by disassembly, not assumed: the loop contains **0 vector
ops** and exactly **19 scalar FP ops** — the hand-count of naive's math
(pos 3 mul + 3 add; vel 3×(2 mul + 2 add); age 1 add). The boxes compile
to no-ops at emission, so there is no barrier tax in the measurement.

**Results** (golden still 0.00 — scalar and packed lanes are both IEEE):

| band    | naive | naive_novec | scalar tax | halide_a | scalar naive still beats the gather by |
|---------|------:|------------:|-----------:|---------:|---------------------------------------:|
| @65K    | 1.267 |       1.547 |       +22% |    2.481 |                                    60% |
| @1M     | 1.443 |       1.608 |       +11% |    2.877 |                                    79% |
| @4M     | 1.630 |       1.698 |        +4% |    2.921 |                                    72% |

Two findings:

1. **LLVM's component-lane vectorization earns ~10–25%, not 2×** — and it
   earns it cache-resident (+22% @65K; naive's fancy prologue even makes
   novec FASTER at 4K: 1.52 vs 2.12). At DRAM bands the tax nearly
   vanishes (+4–11%): one 68 B walk dominates; vector width is rounding.
2. **The AoS verdict does not depend on naive being secretly vectorized.**
   Even truly scalar, the single-walk loop beats Halide's two-walk gather
   at every band (60–79%). The gather tax and the seam's second walk are
   the whole story — §5a/§5b stand unchanged.

### 5d. Chasing parity: the dead-mask variant (halide_a2)

The user's challenge: *a non-vectorized Halide schedule should produce
nearly naive's assembly and performance, right?* Measured answer, in three
steps:

1. **Scalar schedule (vw=1) alone does NOT tie.** Same 19 scalar FP ops,
   yes — but the strategy still pays the seam's second walk (Zig kill pass
   over the full struct): 3.087 @1M = 136 B/p at the ~44–47 GB/s ceiling.
   The walk count, not the instruction mix, dominates at DRAM.
2. **The dead mask kills the second walk.** Moving the kill decision into
   the pipeline (1 B/p mask, Zig runs par's block scan + serial respawn)
   drops traffic to ~70 B/p ≈ naive's 68. First attempt: 2.66 @1M —
   better, but 26 GB/s actual = ISSUE-bound, not bandwidth-bound. The
   (c,i)-formulated generator made gravity a runtime `select` on c
   (6 fcsel/particle) and Halide emitted per-row clamps: 179 cmp / 27 csel
   / 6 fcsel vs 23 fmul/fadd in the disassembly.
3. **The LEAN reformulation (9 single-component 1-D Funcs, compute_with-
   fused) makes gravity a hoisted constant and every access a plain
   strided walk: 1.749 @65K / 1.929 @1M / 2.106 @4M** — Halide's best on
   AoS: within +34% of naive @1M, +20% of novec. The residual gap, visible
   in the disassembly: per-stream clamp guards inside the fused loop
   (~40 cmp/branch/stack-reload instructions per particle on top of the
   19 FP + 18 memory ops) — Halide's runtime buffer model re-proving
   bounds Zig's static struct layout never has to.

**The honest verdict on "nearly identical assembly":** the FP math is
identical (19 scalar ops, bit-exact); the *frame around it* is not —
Halide's buffer abstraction carries a per-stream, per-particle tax that
Zig's statically-known layout doesn't pay. On AoS the taxes stack:
gather tax (if vectorized) + seam tax (if natural) + abstraction tax
(always). Best-case Halide on L1: **1.93 vs naive 1.44 @1M**. On SoA the
first two taxes vanish and the third is amortized over unit-stride
streams — that is why the interesting Halide layouts are still to come.

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

## 7. Reproduce: build / run / bench / profile

Everything below from the repo root, ReleaseFast. **Bench output goes to
stderr** (pipe `2>&1` when grepping). Every full bench run checks the sim
golden + framebuffer golden BEFORE timing — correctness is not separable
from measurement. All numbers regenerate with these commands; the tables
above are one Apple M4 session.

### The command template (every strategy)

`<NAME>` is one of this layout's strategies:
**`naive` · `naive_r1` · `naive_novec` · `par` · `halide_a` · `halide_a2`**
(unknown names fail the build with the valid list, per `strat_labels` in
build.zig).

```bash
# BUILD
zig build -Dlayout=L1 -Dstrat=<NAME> -Dmode=bench -Doptimize=ReleaseFast

# RUN — golden checks, then the full step sweep (N=4K..64M)
./zig-out/bin/dod-particles

# BENCH variants
./zig-out/bin/dod-particles --frame          # step+render per frame (decomposed)
./zig-out/bin/dod-particles --render         # render only
./zig-out/bin/dod-particles --csv            # machine-readable rows (append to any mode)
./zig-out/bin/dod-particles --n 1000000 --iters 200   # single-N, golden skipped (PMC mode)
./zig-out/bin/dod-particles --threads 4      # worker count (.par strategies)
./zig-out/bin/dod-particles --record out/    # 600 steps -> 300 PNGs -> ffmpeg mp4

# other modes
zig build -Dlayout=L1 -Dstrat=<NAME> -Dmode=audit -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles
zig build -Dlayout=L1 -Dstrat=<NAME> -Dmode=play  -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles

# PROFILE (Apple PMC counters: % useful / processing / delivery / discarded)
scripts/pmc_collect.sh L1.<NAME> 1000000 500 1     # -> .scratch/pmc/

# ADVERSARIAL death regimes (build option; golden skipped loudly)
zig build -Dlayout=L1 -Dstrat=<NAME> -Dmode=bench -Doptimize=ReleaseFast -Ddeath=half

# BATCH collection (appends to .scratch/verticals/L1.csv)
scripts/vertical_collect.sh "L1.<NAME>" "step frame"
DEATH=half THREADS=4 scripts/vertical_collect.sh "L1.<NAME>" "step"
```

### naive

The reference sim — a bench run **regenerates** `golden/stage1.bin` and
`golden/frame.sha256` (identical bytes to arc stage 1's, always).

```bash
zig build -Dlayout=L1 -Dstrat=naive -Dmode=bench -Doptimize=ReleaseFast
./zig-out/bin/dod-particles
scripts/pmc_collect.sh L1.naive 1000000 500 1
# the auto-vectorized loop (README §5b):
objdump -d zig-out/bin/dod-particles | grep -A40 'naive.H).step'
```

### naive_r1

Same sim, optimized splat. The render-side claims live in `--frame` and
`--render`; the framebuffer golden proves byte-identity to naive's r0.

```bash
zig build -Dlayout=L1 -Dstrat=naive_r1 -Dmode=bench -Doptimize=ReleaseFast
./zig-out/bin/dod-particles --frame
./zig-out/bin/dod-particles --render --csv
```

### naive_novec

The de-vectorization control (§5c). Verify the claim yourself — the step
loop must contain ZERO vector ops (`.2s`/`.4s`/q-register math):

```bash
zig build -Dlayout=L1 -Dstrat=naive_novec -Dmode=bench -Doptimize=ReleaseFast
./zig-out/bin/dod-particles
ADDR=$(nm zig-out/bin/dod-particles | grep 'naive_novec.H).step' | awk '{print "0x"$1}')
objdump -d --start-address=$ADDR zig-out/bin/dod-particles | grep -cE '\.2s|\.4s'   # expect: loop has none
```

### par

Two-phase multicore. The honest rows: the T=1 overhead check (vs naive),
the thread sweep (crossover N ≈ 1M), and the adversarial regime (its
championship). Golden is bit-exact at every T — check T=10 explicitly.

```bash
zig build -Dlayout=L1 -Dstrat=par -Dmode=bench -Doptimize=ReleaseFast
./zig-out/bin/dod-particles --threads 10            # golden PASS at T=10 IS the two-phase proof
for t in 1 2 4 6 8 10; do ./zig-out/bin/dod-particles --n 1000000 --iters 200 --threads $t 2>&1 | grep '  1000000'; done
DEATH=half THREADS=4 scripts/vertical_collect.sh "L1.par" "step"
```

### halide_a / halide_a2

Gated toolchain: the build runs the generator (Python bindings) and links
the bundled-runtime `.a` into `zig-out/halide/`. Env setup once:
`uv venv .venv-halide && uv pip install --python .venv-halide/bin/python halide matplotlib`
(override with `HALIDE_PYTHON`).

```bash
zig build -Dlayout=L1 -Dstrat=halide_a -Dmode=bench -Doptimize=ReleaseFast
./zig-out/bin/dod-particles

# ad-hoc schedule candidate (variant path: build links, doesn't regenerate)
.venv-halide/bin/python src/layouts/L1_aos_full/halide_a_gen.py zig-out/halide/halide_a_vw8 '{"vector_width":8}'
zig build -Dlayout=L1 -Dstrat=halide_a -Dhalide_variant=vw8 -Dmode=bench -Doptimize=ReleaseFast
./zig-out/bin/dod-particles --n 1000000 --iters 200

# the schedule sweep + landscape chart (+ autoschedulers; needs matplotlib)
.venv-halide/bin/python scripts/halide_sweep.py        # -> .scratch/halide/L1.csv, L1_landscape.png

# the pipeline's assembly (the gather storm, §5b):
objdump -d zig-out/halide/halide_a.a
```

`halide_a2` builds/runs the same way (its generator defaults to scalar
vw=1, lean 9×1-D formulation, `halide_a2_gen.py`).
