# Memory layout ML1 on Apple M4 (`minibits-b7641c0e`)

## Champion grid (T=1)

| num-particles＼death | 0.01 | 0.05 | 0.1 | 0.25 | 0.5 |
|---|---|---|---|---|---|
| 4K | [AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 7.73<br>[AF1.LP1-autovec.LP2-simple](AF1.LP1-autovec.LP2-simple.md) 8.09<br>[AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 8.16 | [AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 7.40<br>[AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 8.02<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 8.45 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 7.66<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 8.01<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 8.89 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 7.49<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 10.02<br>[AF5.LP1-fused](AF5.LP1-fused.md) 10.50 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 8.17<br>[AF1.LP1-autovec.LP2-simple](AF1.LP1-autovec.LP2-simple.md) 15.32<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 15.71 |
| 16K | [AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 5.27<br>[AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.40<br>[AF1.LP1-blend.LP2-simple](AF1.LP1-blend.LP2-simple.md) 6.07 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.42<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 5.90<br>[AF1.LP1-blend.LP2-simple](AF1.LP1-blend.LP2-simple.md) 6.32 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.07<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 6.26<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 7.85 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 4.74<br>[AF1.LP1-halide.LP2-simple](AF1.LP1-halide.LP2-simple.md) 7.67<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 7.89 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.32<br>[AF1.LP1-autovec.LP2-simple](AF1.LP1-autovec.LP2-simple.md) 13.12<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 13.55 |
| 65K | [AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 5.13<br>[AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.26<br>[AF1.LP1-blend.LP2-simple](AF1.LP1-blend.LP2-simple.md) 5.90 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.41<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 5.83<br>[AF1.LP1-blend.LP2-simple](AF1.LP1-blend.LP2-simple.md) 6.25 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.07<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 6.24<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 7.88 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 4.69<br>[AF1.LP1-halide.LP2-simple](AF1.LP1-halide.LP2-simple.md) 7.69<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 7.96 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.31<br>[AF1.LP1-autovec.LP2-simple](AF1.LP1-autovec.LP2-simple.md) 13.40<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 13.63 |
| 262K | [AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 5.04<br>[AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.26<br>[AF1.LP1-blend.LP2-simple](AF1.LP1-blend.LP2-simple.md) 5.86 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.38<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 5.76<br>[AF1.LP1-blend.LP2-simple](AF1.LP1-blend.LP2-simple.md) 6.35 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.05<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 6.21<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 7.81 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 4.68<br>[AF1.LP1-halide.LP2-simple](AF1.LP1-halide.LP2-simple.md) 7.72<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 7.98 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.32<br>[AF1.LP1-autovec.LP2-simple](AF1.LP1-autovec.LP2-simple.md) 13.39<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 13.67 |
| 1M | [AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 4.97<br>[AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.21<br>[AF1.LP1-blend.LP2-simple](AF1.LP1-blend.LP2-simple.md) 6.02 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.38<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 5.73<br>[AF1.LP1-blend.LP2-simple](AF1.LP1-blend.LP2-simple.md) 6.29 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.05<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 6.17<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 8.28 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 4.71<br>[AF1.LP1-halide.LP2-simple](AF1.LP1-halide.LP2-simple.md) 7.74<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 7.97 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.30<br>[AF1.LP1-autovec.LP2-simple](AF1.LP1-autovec.LP2-simple.md) 13.42<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 14.12 |
| 4M | [AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 4.90<br>[AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.20<br>[AF1.LP1-blend.LP2-simple](AF1.LP1-blend.LP2-simple.md) 6.15 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.33<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 5.70<br>[AF1.LP1-blend.LP2-simple](AF1.LP1-blend.LP2-simple.md) 6.36 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.04<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 6.17<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 8.43 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 4.71<br>[AF1.LP1-halide.LP2-simple](AF1.LP1-halide.LP2-simple.md) 7.75<br>[AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md) 7.93 | [AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md) 5.32<br>[AF1.LP1-autovec.LP2-simple](AF1.LP1-autovec.LP2-simple.md) 13.42<br>[AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md) 14.24 |

## Featured algos

- **[ML1.AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md)** — 7.73 ns/p — Hypothesis: compiler auto-vectorization of the per-particle update (loop1) can approach the streaming ceiling on death-free workloads, with the optimized render…
- **[ML1.AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md)** — 7.4 ns/p — Hypothesis: compiler auto-vectorization of loop1 combined with a fused scatter loop2 can approach the streaming ceiling on death-free workloads.…
- **[ML1.AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md)** — 7.66 ns/p — Hypothesis: Halide-expressible loop1 (branchless blend) with an optimized loop2 render can approach the streaming ceiling.…

## All algos

- [ML1.AF1.LP1-autovec-par.LP2-simple](AF1.LP1-autovec-par.LP2-simple.md)
- [ML1.AF1.LP1-autovec.LP2-opt](AF1.LP1-autovec.LP2-opt.md)
- [ML1.AF1.LP1-autovec.LP2-simple](AF1.LP1-autovec.LP2-simple.md)
- [ML1.AF1.LP1-blend-par.LP2-simple](AF1.LP1-blend-par.LP2-simple.md)
- [ML1.AF1.LP1-blend.LP2-simple](AF1.LP1-blend.LP2-simple.md)
- [ML1.AF1.LP1-halide-par.LP2-simple](AF1.LP1-halide-par.LP2-simple.md)
- [ML1.AF1.LP1-halide.LP2-opt](AF1.LP1-halide.LP2-opt.md)
- [ML1.AF1.LP1-halide.LP2-simple](AF1.LP1-halide.LP2-simple.md)
- [ML1.AF1.LP1-scalar.LP2-simple](AF1.LP1-scalar.LP2-simple.md)
- [ML1.AF2.LP1-autovec-par.LP2-simple](AF2.LP1-autovec-par.LP2-simple.md)
- [ML1.AF2.LP1-autovec.LP2-simple](AF2.LP1-autovec.LP2-simple.md)
- [ML1.AF2.LP1-halide-par.LP2-simple](AF2.LP1-halide-par.LP2-simple.md)
- [ML1.AF2.LP1-halide.LP2-simple](AF2.LP1-halide.LP2-simple.md)
- [ML1.AF3.LP1-autovec-par.LP2-rmerge](AF3.LP1-autovec-par.LP2-rmerge.md)
- [ML1.AF3.LP1-autovec.LP2-simple](AF3.LP1-autovec.LP2-simple.md)
- [ML1.AF3.LP1-halide.LP2-simple](AF3.LP1-halide.LP2-simple.md)
- [ML1.AF4.LP1-autovec-par.LP2-rmerge](AF4.LP1-autovec-par.LP2-rmerge.md)
- [ML1.AF4.LP1-autovec.LP2-simple](AF4.LP1-autovec.LP2-simple.md)
- [ML1.AF5.LP1-fused](AF5.LP1-fused.md)
- [ML1.AF6.LP1-autovec.LP2-fused](AF6.LP1-autovec.LP2-fused.md)
- [ML1.AF7.LP1-autovec.LP2-fused](AF7.LP1-autovec.LP2-fused.md)
- [ML1.AF8.LP1-autovec.LP2-fused](AF8.LP1-autovec.LP2-fused.md)
