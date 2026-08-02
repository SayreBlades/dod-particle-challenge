# L1 — Array-of-Structs (AoS), full field set

> The frozen data model for L1. The cell/blueprint story lives in
> `experiments/cells/L1.md` and the optimization-framework plan; this
> README documents only the layout itself. All numbers: Apple M4,
> ReleaseFast, min-of-3-trials.

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






