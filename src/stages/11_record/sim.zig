// Stage 11: --record video export (P12) — determinism enables headless replay.
//
// The Sim is exactly stage 9's synthesis (re-exported, not wrapped — nothing
// about the sim or the renderer changes in this stage). What changes is the
// DRIVER: bench mode gains a `--record <dir>` flag that runs 600 fixed steps
// headlessly, renders every 2nd step to a PNG via stb_image_write, and shells
// out to ffmpeg to encode <dir>/video.mp4 (30 fps × 300 frames = 10 s at
// 1024²). Because the sim is deterministic (fixed seed, fixed dt — the same
// property the golden check relies on), the recorded video is a bit-exact
// replay of the play-mode visualization.

pub const Sim = @import("../09_synthesis/sim.zig").Sim;
