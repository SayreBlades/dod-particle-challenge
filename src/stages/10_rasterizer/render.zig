// Stage 10: the renderer is data too (P11) — the optimized rasterizer.
//
// Stages 1–9 optimized the SIM's data layout while the renderer stayed the
// naive shared module (framework/render.zig): per particle, a `switch(kind)`
// for the color, 3 f32→u8 clamps, then 4 per-pixel bounds checks and 12
// per-byte clamped adds. Stage 10 applies the same DOD moves to the
// rasterizer itself, producing BYTE-IDENTICAL output (proven by the tests at
// the bottom of this file — run `zig build test`):
//
//   1. COLOR LUT (P2/P6 — group by use, de-virtualize): the per-particle
//      `switch(kind)` + 3 clamps become a 3-entry table of pre-packed splat
//      rows. The colors are comptime-known constants, so the table is baked
//      into rodata — the per-particle "dispatch" is one indexed load.
//   2. PACKED RGBA (P4): the splat's color is one u8×8 row pattern
//      [r,g,b,255, r,g,b,255] instead of 12 independent byte values.
//   3. SATURATING-ADD SIMD (P7): each 2-pixel row of the 2×2 splat is ONE
//      u8×8 `+|` (saturating add — a single NEON `uqadd` on this target),
//      replacing 6 load/add/clamp/store sequences per row.
//   4. ONE BOUNDS CHECK (P5): the 2×2 splat is fully in- or out-of-bounds by
//      one test on (px,py); the naive rasterizer does 4 per-pixel tests plus
//      4 index-in-range re-checks. Edge/corner splats fall back to the scalar
//      per-pixel path — same semantics, rare in practice.
//
// What the plan's menu itemized that is honestly NOT implemented:
//   - "Tile the framebuffer to 128 B": N/A for a 2×2 point-splat rasterizer.
//     Each splat already touches ≤2 cache lines (8 B in each of two adjacent
//     rows); there is no fill-kernel loop to tile. Tiling pays for large area
//     fills, not point splats.
//   - "SIMD across 4 or 8 PIXELS": the splat is only 2 pixels wide; the
//     natural SIMD unit is the 2-pixel row (u8×8), which is what we
//     vectorize. Wider pixel vectors would need gather/scatter across rows.
//
// Alpha semantics (why byte-identical holds): the naive rasterizer SETS
// alpha=255 per splatted pixel. After clear(), alpha starts at 0; a
// saturating add of 255 gives 255 on the first splat and keeps 255 on
// overlaps (255 +| 255 == 255) — identical to the unconditional set. RGB uses
// clamped add in both paths (naive: u16 add + clamp; here: hardware
// saturating add) — identical results.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const naive = @import("../../framework/render.zig");

/// One splat row = two adjacent pixels, blended with one saturating-add op.
const Row = @Vector(8, u8);

/// The 3-entry per-kind color LUT, pre-packed as splat rows. The colors are
/// compile-time constants, so the whole table is comptime-evaluated into
/// rodata: zero per-frame setup, and the per-particle `switch(kind)` becomes
/// one indexed load (P6: dispatch moved out of the loop into a table — the
/// same move as config.impulse).
const lut: [3]Row = buildLut();

fn buildLut() [3]Row {
    var table: [3]Row = undefined;
    inline for (0..3) |k| {
        const c = kindColor(@enumFromInt(k));
        table[k] = .{ c[0], c[1], c[2], 255, c[0], c[1], c[2], 255 };
    }
    return table;
}

/// Same per-kind colors as the sims' kindColor, pre-clamped to u8. (color
/// became a pure function of kind in stage 4 — a 3-entry dictionary, per
/// stage 1's audit: density 0.036. It has no business being per-particle data
/// OR per-particle math.)
fn kindColor(k: fw.ParticleKind) [3]u8 {
    return switch (k) {
        .smoke => .{ 120, 120, 120 }, // gray
        .spark => .{ 255, 180, 60 }, // orange
        .debris => .{ 100, 200, 255 }, // blue
    };
}

/// Float colors for the reference path (renderSceneNaive), matching the sims'
/// kindColor exactly (naive.splat takes f32 and clamps internally).
fn kindColorF(k: fw.ParticleKind) fw.Vec4 {
    return switch (k) {
        .smoke => .{ .x = 120, .y = 120, .z = 120, .w = 1 },
        .spark => .{ .x = 255, .y = 180, .z = 60, .w = 1 },
        .debris => .{ .x = 100, .y = 200, .z = 255, .w = 1 },
    };
}

/// Optimized render: clear + per-particle 2×2 additive splat. Byte-identical
/// to renderSceneNaive for every input (see tests).
pub fn renderScene(
    pos_x: []const f32,
    pos_y: []const f32,
    kind: []const fw.ParticleKind,
    fb: []u8,
    w: u32,
    h: u32,
) void {
    naive.clear(fb);
    const n = pos_x.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        splatFast(fb, w, h, pos_x[i], pos_y[i], lut[@intFromEnum(kind[i])]);
    }
}

/// The reference pipeline: exactly the sims' render loop over the shared
/// (naive) rasterizer. Exists so the tests can prove byte-equivalence and so
/// the win can be A/B'd within one binary.
pub fn renderSceneNaive(
    pos_x: []const f32,
    pos_y: []const f32,
    kind: []const fw.ParticleKind,
    fb: []u8,
    w: u32,
    h: u32,
) void {
    naive.clear(fb);
    const n = pos_x.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const col = kindColorF(kind[i]);
        naive.splat(fb, w, h, pos_x[i], pos_y[i], col.x, col.y, col.z);
    }
}

fn splatFast(fb: []u8, w: u32, h: u32, x: f32, y: f32, src: Row) void {
    const px = naive.worldToPxX(x, w);
    const py = naive.worldToPxY(y, h);
    const wi: i32 = @intCast(w);
    const hi: i32 = @intCast(h);
    if (px >= 0 and px + 2 <= wi and py >= 0 and py + 2 <= hi) {
        // Fast path: the whole 2×2 is in bounds. One bounds test (vs naive's
        // four per-pixel tests), then two saturating-add vector rows (vs
        // twelve per-byte clamped adds). `@Vector(8,u8) +|` lowers to a
        // single NEON `uqadd` on this target.
        const x0: usize = @intCast(px);
        const y0: usize = @intCast(py);
        const r0 = (y0 * @as(usize, w) + x0) * 4;
        const d0: *align(1) Row = @ptrCast(fb[r0..][0..8]);
        d0.* = d0.* +| src;
        const d1: *align(1) Row = @ptrCast(fb[r0 + @as(usize, w) * 4 ..][0..8]);
        d1.* = d1.* +| src;
    } else {
        // Slow path: edge/corner splat — per-pixel bounds checks,
        // byte-identical to the naive rasterizer's scalar loop (a +| b ==
        // min(a+b, 255) == naive's addClamp; alpha set to 255 == alpha +| 255
        // from a cleared base).
        var dy: i32 = 0;
        while (dy < 2) : (dy += 1) {
            var dx: i32 = 0;
            while (dx < 2) : (dx += 1) {
                const fx = px + dx;
                const fy = py + dy;
                if (fx < 0 or fx >= wi or fy < 0 or fy >= hi) continue;
                const idx: usize = (@as(usize, @intCast(fy)) * @as(usize, w) + @as(usize, @intCast(fx))) * 4;
                if (idx + 3 >= fb.len) continue;
                fb[idx + 0] = fb[idx + 0] +| src[0];
                fb[idx + 1] = fb[idx + 1] +| src[1];
                fb[idx + 2] = fb[idx + 2] +| src[2];
                fb[idx + 3] = 255;
            }
        }
    }
}

// --- tests: the optimized rasterizer must be byte-identical to the naive one ---

fn expectSameFrame(
    alloc: std.mem.Allocator,
    w: u32,
    h: u32,
    pos_x: []const f32,
    pos_y: []const f32,
    kind: []const fw.ParticleKind,
) !void {
    const fb_a = try alloc.alloc(u8, @as(usize, w) * h * 4);
    defer alloc.free(fb_a);
    const fb_b = try alloc.alloc(u8, @as(usize, w) * h * 4);
    defer alloc.free(fb_b);
    renderSceneNaive(pos_x, pos_y, kind, fb_a, w, h);
    renderScene(pos_x, pos_y, kind, fb_b, w, h);
    try std.testing.expectEqualSlices(u8, fb_a, fb_b);
}

test "fast rasterizer == naive: random scene incl. off-screen + overlaps" {
    const alloc = std.testing.allocator;
    const config = @import("../../framework/config.zig");
    const n = 20_000;
    const pos_x = try alloc.alloc(f32, n);
    defer alloc.free(pos_x);
    const pos_y = try alloc.alloc(f32, n);
    defer alloc.free(pos_y);
    const kind = try alloc.alloc(fw.ParticleKind, n);
    defer alloc.free(kind);

    var rng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    const r = rng.random();
    for (0..n) |i| {
        // Spread over an EXTENDED view (±1.3×) so a large fraction of splats
        // are partially or fully off-screen on all four sides.
        pos_x[i] = (r.float(f32) * 2.0 - 1.0) * config.view_half * 1.3;
        pos_y[i] = (r.float(f32) * 2.0 - 1.0) * config.view_half * 1.3;
        kind[i] = @enumFromInt(r.intRangeAtMost(u8, 0, 2));
    }
    // Deliberate pile at the origin: overlapping splats must saturate RGB and
    // pin alpha at 255 identically in both paths.
    for (0..500) |i| {
        pos_x[i] = 0;
        pos_y[i] = 0;
        kind[i] = .spark;
    }
    // Exact edge/corner positions (world ±view_half maps to pixel edges).
    const edges = [_][2]f32{
        .{ -config.view_half, -config.view_half },
        .{ config.view_half, config.view_half },
        .{ -config.view_half, config.view_half },
        .{ config.view_half, -config.view_half },
        .{ -config.view_half, 0 },
        .{ config.view_half, 0 },
        .{ 0, -config.view_half },
        .{ 0, config.view_half },
        .{ -config.view_half - 0.001, 0 },
        .{ config.view_half + 0.001, 0 },
        .{ 0, -config.view_half - 0.001 },
        .{ 0, config.view_half + 0.001 },
    };
    for (edges, 0..) |e, j| {
        pos_x[1000 + j] = e[0];
        pos_y[1000 + j] = e[1];
        kind[1000 + j] = .debris;
    }

    // Odd, non-power-of-2 framebuffer: exercises stride math + unaligned rows.
    try expectSameFrame(alloc, 257, 263, pos_x, pos_y, kind);
    // The real play-mode size.
    try expectSameFrame(alloc, 1024, 1024, pos_x, pos_y, kind);
}

test "fast rasterizer == naive: subpixel + near-zero negative coords" {
    const alloc = std.testing.allocator;
    const n = 4096;
    const pos_x = try alloc.alloc(f32, n);
    defer alloc.free(pos_x);
    const pos_y = try alloc.alloc(f32, n);
    defer alloc.free(pos_y);
    const kind = try alloc.alloc(fw.ParticleKind, n);
    defer alloc.free(kind);

    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    const r = rng.random();
    for (0..n) |i| {
        // Hug the left/top edges from both sides: norm*size slightly negative
        // truncates toward zero — both paths must agree on every such splat.
        pos_x[i] = -2.0 + (r.float(f32) - 0.5) * 0.01;
        pos_y[i] = -2.0 + (r.float(f32) - 0.5) * 0.01;
        kind[i] = @enumFromInt(@as(u8, @truncate(i)) % 3);
    }
    try expectSameFrame(alloc, 64, 64, pos_x, pos_y, kind);
}
