# Stage 11 — Bonus: `--record` video export (P12)

> *Determinism enables headless replay and video export.* The same property
> the golden check relies on — fixed seed, fixed dt, no wall-clock input —
> turns the whole simulation into a reproducible film.

- **Checkpoint:** C9 (bonus, with stage 10) — PASS.
- **DOD principle:** P12 (determinism enables replay/export).
- **The change:** `sim.zig` is exactly stage 9's `Sim` (re-exported, not
  wrapped). What changes is the **driver**: bench mode gains a `--record <dir>`
  flag (`framework/bench.zig`) that runs the sim headlessly, renders frames to
  PNGs via stb_image_write, and shells out to ffmpeg for the MP4.

---

## 1. The problem it poses

Sometimes you want a shareable MP4, not an interactive game. Play mode needs a
window, a GPU, and a human. The lab's whole correctness story already rests on
the sim being a *pure function of (seed, steps)* — no wall clock, no input —
so a headless run must be able to reproduce the play-mode visualization
exactly, frame for frame. This stage proves it.

## The transformation

`zig build -Dstage=11 -Dmode=bench -Doptimize=ReleaseFast && ./zig-out/bin/dod-particles --record out/`

1. Golden check runs first (the math is proven before the video is exported).
2. The sim runs **600 fixed steps** at `config.dt` (N=65,000 — play mode's
   DEFAULT_N, for visual parity).
3. Every 2nd step is rendered and written as a PNG via `stb_image_write` →
   **300 frames** in `out/frames/`.
4. `ffmpeg` encodes `out/video.mp4` — **30 fps × 300 frames = 10.0 s at
   1024×1024** (the acceptance spec), H.264 crf 18, yuv420p, faststart.

PNG writing is one minimal `extern "c"` declaration (`src/bindings/stb.zig` —
the same "declare the exact contract you use" philosophy as `raylib.zig`),
compiled from `src/stb_impl.c` against `vendor/stb`. Build note: raylib 6.0
embeds its *own* stb_image_write implementation inside `rtextures.c`, guarded
by `SUPPORT_IMAGE_EXPORT`; `build.zig` compiles raylib with
`-DSUPPORT_IMAGE_EXPORT=0` (we never call `ExportImage*`) so the two
implementations don't collide at link time.

---

## 2. Measured outcome

```
=== Correctness: PASS (max delta = 0.00) ===
=== Record: Stage 11: record ===
  sim: N=65000, seed=0xC0FFEE, 600 steps @ dt=0.016667
  capture: every 2nd step -> 300 frames @ 30 fps = 10.0 s at 1024x1024
  wrote 300 frames to out//frames/ in 8910.4 ms
  encoding out//video.mp4 via ffmpeg...
  wrote out//video.mp4 (3.79 MB, 300 frames @ 30 fps = 10.0 s)
```

ffprobe verification of the acceptance spec:

```
codec_name=h264  width=1024  height=1024  avg_frame_rate=30/1
duration=10.000000  nb_frames=300
```

**Determinism, proven (P12's point):** two independent `--record` runs produce
**byte-identical PNGs** (md5 of frames 0/150/299 compared across runs). The
recorded video is not a *capture* of the visualization — it *is* the
visualization, recomputed.

**Matches play mode:** frame 150 (t=5s) shows the same three streams as the
interactive window — gray smoke drifting down-left, orange sparks arcing
right, blue debris scattering down-right — because the recorded sim *is* play
mode's sim (same stage-9 Sim, same seed, same dt, same N, same rasterizer).
Only the presentation differs (PNG→MP4 vs GPU texture blit).

Cost: ~8.9 s wall to sim+render+encode 300 frames (PNG encode dominates;
sim+render is ~0.2 s of it — stage 9's 0.89 ns/p × 65K × 600 steps ≈ 35 ms).

---

## 3. Data-density audit — identical to stage 9 (MEAN = 0.722)

Same `Sim`, same `dumpFields`. The stage changes the *driver*, not the data.

---

## 4. Correctness

Golden: `PASS (max delta = 0.00)` — the sim is stage 9's by re-export, and the
record driver runs the same fixed-step regime the golden check uses. P12 is
the golden check's own determinism property, productized.

---

## 5. Coda — the lab is complete

With C9 landed, all checkpoints C1–C9 are green. The arc, end to end: the
object was a lie (stage 1's 68 B AoS, 0.361 density) → hot/cold split (2) →
SoA (3) → branchless compaction, sort-by-kind (4, 5 — honest detours) → SIMD,
alignment (6, 7 — the payoff) → allocators (8 — honest detour) → synthesis
(9: ~1.7× at 1M, bandwidth-ceiling-bounded) → the renderer is data too (10:
~3.4× render) → determinism enables replay (11: this stage). Eleven stages,
each measured, each readable as a single-file diff.
