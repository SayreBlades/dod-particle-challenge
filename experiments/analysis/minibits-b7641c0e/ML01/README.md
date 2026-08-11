# Memory layout ML01 on Apple M4 (`minibits-b7641c0e`)

## Champion grid (T=1)

| num-particles＼death | 0.01 | 0.05 | 0.1 | 0.25 | 0.5 |
|---|---|---|---|---|---|
| 4K | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 6.86<br>[AF01.LP1-blend-par.LP2-simple](AF01.LP1-blend-par.LP2-simple.md) 6.92<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 7.37 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.41<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.57<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.88 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.17<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 6.03<br>[AF01.LP1-blend-par.LP2-simple](AF01.LP1-blend-par.LP2-simple.md) 7.17 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.82<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.77<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 7.95 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.38<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.58<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 10.81 |
| 65K | [AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 4.98<br>[AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.24<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.04 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.45<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.83<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.44 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.09<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 6.30<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.93 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.71<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.67<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 8.19 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.30<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.56<br>[AF03.LP1-halide.LP2-simple](AF03.LP1-halide.LP2-simple.md) 10.47 |
| 262K | [AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 4.89<br>[AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.17<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 5.92 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.37<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.71<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.33 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.07<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 6.24<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.91 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.75<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.66<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 8.24 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.31<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.55<br>[AF03.LP1-halide.LP2-simple](AF03.LP1-halide.LP2-simple.md) 10.65 |
| 1M | [AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 4.60<br>[AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.96<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 5.85 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.22<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.57<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.18 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.01<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 6.18<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.87 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.76<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.71<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 8.22 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.32<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.60<br>[AF03.LP1-halide.LP2-simple](AF03.LP1-halide.LP2-simple.md) 10.88 |
| 4M | [AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 4.31<br>[AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.71<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 5.91 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.83<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 5.16<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.29 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.88<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 6.01<br>[AF01.LP1-blend.LP2-simple](AF01.LP1-blend.LP2-simple.md) 6.74 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 4.75<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.73<br>[AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md) 8.23 | [AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md) 5.34<br>[AF01.LP1-halide.LP2-simple](AF01.LP1-halide.LP2-simple.md) 7.57<br>[AF03.LP1-halide.LP2-simple](AF03.LP1-halide.LP2-simple.md) 10.94 |

## Featured algos

- **[ML01.AF01.LP1-halide.LP2-opt](AF01.LP1-halide.LP2-opt.md)** — 6.86 ns/p — Hypothesis: a Halide-expressible branchless blend over identity-ordered particles can approach the streaming ceiling without cache-spill knees, with death rate …
- **[ML01.AF01.LP1-autovec.LP2-opt](AF01.LP1-autovec.LP2-opt.md)** — 4.98 ns/p — Hypothesis: compiler auto-vectorization over per-particle components can approach the streaming ceiling on death-free workloads.…

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
- [ML01.AF01.LP1-unroll.LP2-simple](AF01.LP1-unroll.LP2-simple.md)
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
