# Memory layout ML01 on Apple M4 (`minibits-b7641c0e`)

## Champion grid (T=1)

| num-particles＼death | 0.01 | 0.05 | 0.1 | 0.25 | 0.5 |
|---|---|---|---|---|---|
| 4K | [AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 7.73<br>[AF01.LP1-autovec.LP2-simple](AF01.LP1-autovec.LP2-simple.md) 8.09<br>[AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 8.16 | [AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 7.40<br>[AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 8.02<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 8.45 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 7.66<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 8.01<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 8.89 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 7.49<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 10.02<br>[AF05.LP1-fused](AF05.LP1-fused.md) 10.50 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 8.17<br>[AF01.LP1-autovec.LP2-simple](AF01.LP1-autovec.LP2-simple.md) 15.32<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 15.71 |
| 16K | [AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.27<br>[AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.40<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.07 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.42<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.90<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.32 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.07<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 6.26<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 7.85 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.74<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.67<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 7.89 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.32<br>[AF01.LP1-autovec.LP2-simple](AF01.LP1-autovec.LP2-simple.md) 13.12<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 13.55 |
| 65K | [AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.13<br>[AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.26<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 5.90 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.41<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.83<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.25 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.07<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 6.24<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 7.88 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.69<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.69<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 7.96 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.31<br>[AF01.LP1-autovec.LP2-simple](AF01.LP1-autovec.LP2-simple.md) 13.40<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 13.63 |
| 262K | [AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.04<br>[AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.26<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 5.86 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.38<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.76<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.35 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.05<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 6.21<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 7.81 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.68<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.72<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 7.98 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.32<br>[AF01.LP1-autovec.LP2-simple](AF01.LP1-autovec.LP2-simple.md) 13.39<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 13.67 |
| 1M | [AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 4.97<br>[AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.21<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.02 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.38<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.73<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.29 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.05<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 6.17<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 8.28 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.71<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.74<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 7.97 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.30<br>[AF01.LP1-autovec.LP2-simple](AF01.LP1-autovec.LP2-simple.md) 13.42<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 14.12 |
| 4M | [AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 4.90<br>[AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.20<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.15 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.33<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.70<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.36 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.04<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 6.17<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 8.43 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.71<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.75<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 7.93 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.32<br>[AF01.LP1-autovec.LP2-simple](AF01.LP1-autovec.LP2-simple.md) 13.42<br>[AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md) 14.24 |

## Featured algos

- **[ML01.AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md)** — 7.73 ns/p — Hypothesis: compiler auto-vectorization over per-particle components can approach the streaming ceiling on death-free workloads.…
- **[ML01.AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md)** — 7.4 ns/p — Hypothesis: compiler auto-vectorization of the per-particle update, fused with a direct framebuffer scatter, can approach the streaming ceiling on low-churn wor…
- **[ML01.AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md)** — 7.66 ns/p — Hypothesis: expressing walk1 as a Halide-generated branchless blend and optimizing the render loop can drive the algo toward the streaming bandwidth ceiling.…

## All algos

- [ML01.AF01.LP1-autovec-par.LP2-simple](AF01.LP1-autovec-par.LP2-simple.md)
- [ML01.AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md)
- [ML01.AF01.LP1-autovec.LP2-simple](AF01.LP1-autovec.LP2-simple.md)
- [ML01.AF01.LP1-blend-par.LP2-simple](AF01.LP1-blend-par.LP2-simple.md)
- [ML01.AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md)
- [ML01.AF01.LP1-halide-par.LP2-simple](AF01.LP1-halide-par.LP2-simple.md)
- [ML01.AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md)
- [ML01.AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md)
- [ML01.AF01.LP1-scalar.LP2-simple](AF01.LP1-scalar.LP2-simple.md)
- [ML01.AF02.LP1-autovec-par.LP2-simple](AF02.LP1-autovec-par.LP2-simple.md)
- [ML01.AF02.LP1-autovec.LP2-simple](AF02.LP1-autovec.LP2-simple.md)
- [ML01.AF02.LP1-halide-par.LP2-simple](AF02.LP1-halide-par.LP2-simple.md)
- [ML01.AF02.LP1-halide.LP2-simple](AF02.LP1-halide.LP2-simple.md)
- [ML01.AF03.LP1-autovec-par.LP2-rmerge](AF03.LP1-autovec-par.LP2-rmerge.md)
- [ML01.AF03.LP1-autovec.LP2-simple](AF03.LP1-autovec.LP2-simple.md)
- [ML01.AF03.LP1-halide.LP2-simple](AF03.LP1-halide.LP2-simple.md)
- [ML01.AF04.LP1-autovec-par.LP2-rmerge](AF04.LP1-autovec-par.LP2-rmerge.md)
- [ML01.AF04.LP1-autovec.LP2-simple](AF04.LP1-autovec.LP2-simple.md)
- [ML01.AF05.LP1-fused](AF05.LP1-fused.md)
- [ML01.AF06.LP1-autovec.LP2-fused](AF06.LP1-autovec.LP2-fused.md)
- [ML01.AF07.LP1-autovec.LP2-fused](AF07.LP1-autovec.LP2-fused.md)
- [ML01.AF08.LP1-autovec.LP2-fused](AF08.LP1-autovec.LP2-fused.md)
