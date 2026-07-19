# Stage 10 — Bonus: optimize the rasterizer (P11)

> *The renderer is data too.* Stages 1–9 optimized the sim's data layout while
> the renderer stayed the naive shared module. Stage 10 applies the same DOD
> moves to the rasterizer itself.

- **Checkpoint:** C9 (bonus, with stage 11) — PASS.
- **DOD principle:** P11 (the renderer is data too) — built from P2/P4/P5/P6/P7 moves.
- **The change:** `sim.zig` re-uses stage 9's `Sim` wholesale (the layout lesson
  is done) and overrides only `render()` to dispatch to this stage's
  `render.zig`. `git diff` against stage 9 shows only the render swap.

---

## 1. The problem it poses

The shared rasterizer (`framework/render.zig`, used by stages 1–9) does per
particle: a `switch(kind)` for the color, 3 f32→u8 clamps, then **4 per-pixel
bounds checks** and **12 per-byte clamped adds** (`u16` add + compare + select
per channel per pixel). The splat is only 2×2 pixels, but the op count per
particle is ~60–80 scalar ops.

None of that work is per-particle *signal*: the color is a 3-entry dictionary
(stage 1's audit measured `color` density 0.036 — a pure function of `kind`),
the clamp is the same arithmetic every time, and the 4 bounds checks test one
contiguous 2×2 box.

## The DOD transformation (four moves, same output bytes)

1. **Color LUT (P2/P6).** The per-particle `switch(kind)` + 3 clamps become a
   3-entry table of pre-packed splat rows. The colors are comptime-known
   constants, so the table is comptime-evaluated into rodata — zero per-frame
   setup; the per-particle "dispatch" is one indexed load.
2. **Packed RGBA (P4).** The splat's color is one `u8×8` row pattern
   `[r,g,b,255, r,g,b,255]` instead of 12 independent byte values.
3. **Saturating-add SIMD (P7).** Each 2-pixel row of the 2×2 splat is ONE
   `u8×8` saturating add (`+|`). Verified in the disassembly: the whole splat
   is two `uqadd.8b` instructions (one per row) — the exact NEON lowering P7
   predicts.
4. **One bounds check (P5).** The 2×2 box is fully in- or out-of-bounds by one
   test on `(px,py)` — replacing 4 per-pixel tests + 4 index re-checks. Edge
   splats fall back to the scalar per-pixel path (rare; same semantics).

**Byte-identical output.** Alpha: naive *sets* 255 per splatted pixel; the
vector path saturating-adds 255 onto a cleared base (0→255, then 255+|255=255)
— identical. RGB: naive's `min(a+b,255)` == hardware `uqadd` — identical.
Proven by property test over 20K random particles (including off-screen,
edge-exact, subpixel-negative, and 500 overlapping splats) on two framebuffer
sizes, comparing full framebuffers byte-for-byte:

```sh
zig build test        # 2/2 tests pass — fast rasterizer == naive rasterizer
```

**Honestly NOT implemented from the plan's menu:** "tile the framebuffer to
128 B" (N/A for 2×2 point splats — each splat already touches ≤2 cache lines;
tiling pays for area-fill kernels, not points) and "SIMD across 4 or 8 pixels"
(the splat is 2 pixels wide; the 2-pixel row `u8×8` is the natural vector).

---

## 2. Render benchmark — `--render` flag, stage 9 (naive) vs stage 10 (optimized)

```sh
zig build -Dstage=9  -Dmode=bench -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles --render
zig build -Dstage=10 -Dmode=bench -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles --render
```

(render() timed end-to-end — 4 MB clear + N splats — after 120 settle steps;
min of 3 trials; iters scale ~1/N.)

|         N | naive ns/frame | opt ns/frame | naive ns/p | opt ns/p | speedup |
|----------:|---------------:|-------------:|-----------:|---------:|--------:|
|     4,000 |         52,853 |       38,913 |     13.213 |    9.728 |   1.36× |
|    16,000 |         93,292 |       48,931 |      5.831 |    3.058 |   1.91× |
|    65,000 |        305,275 |       99,061 |      4.697 |    1.524 | **3.08×** |
|   262,000 |      1,145,585 |      327,738 |      4.373 |    1.251 |   3.50× |
| 1,000,000 |      4,244,196 |    1,162,218 |      4.244 |    1.162 |   3.65× |
| 4,000,000 |     16,080,796 |    4,665,721 |      4.020 |    1.166 |   3.45× |
|16,000,000 |     63,053,529 |   18,367,446 |      3.941 |    1.148 |   3.43× |
|64,000,000 |    252,197,371 |   74,269,475 |      3.941 |    1.160 |   3.40× |

**How to read it:**

- **~3.4–3.65× at N≥262K** — the plateau where splats dominate. Fewer ops per
  splat (LUT load + 1 bounds test + 2 `uqadd` rows vs switch + 3 clamps + 4
  bounds tests + 12 clamped byte-adds) translates directly into time.
- **The small-N ratio is compressed by Amdahl:** the 4 MB `@memset` clear is a
  fixed ~35 µs in BOTH renderers. At play-mode's N=65K that's 35% of stage
  10's 99 µs frame but only 11% of stage 9's 305 µs — so the end-to-end ratio
  (3.08×) understates the splat-side win ((305−35)/(99−35) ≈ **4.2×**). The
  clear was already optimal (a vectorized memset); it just doesn't scale with N.
- **Play-mode FPS:** at the default N=65K both renderers fit the 60 FPS vsync
  cap with huge margin (3,276 vs 10,095 frames/sec headroom), so the win shows
  as headroom, not a raised cap — the render bench is the honest instrument.
- **At 64M both curves plateau** (~3.94 / ~1.16 ns/p): the framebuffer (4 MB)
  is exactly L2-sized, so splat writes stay cache-resident and the per-frame
  cost tracks the pos/kind stream reads + loop ops — the render is
  compute/latency-bound (~8 GB/s eff, far under the ~54 GB/s ceiling), which is
  why the op-count reduction keeps paying at full scale.

## Step-side bench (unchanged by construction)

`step()` forwards to stage 9's `Sim` untouched, so the N-sweep reproduces
stage 9's numbers (measured: 0.865 ns/p at 1M vs stage 9's 0.867 — noise).
Golden: `PASS (max delta = 0.00)`.

---

## 3. Data-density audit — identical to stage 9 (MEAN = 0.722)

`dumpFields` forwards to stage 9's, so the fingerprint is unchanged (8
per-component SoA streams, `life` long gone). The renderer transformation
touches *how* the framebuffer is written, not *what* the sim stores.

---

## 4. What the next stage must do (acceptance gate for stage 11)

Stage 11 (`--record` video export) lands when:

1. `zig build -Dstage=11 -Dmode=bench -- --record out/` produces
   `out/video.mp4` (30 fps, 10 s, 1024²) matching the play-mode visualization.
2. The sim is exactly stage 9's (golden PASS) — determinism (fixed seed, fixed
   dt) is what makes headless replay possible at all (P12).
