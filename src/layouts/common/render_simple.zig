// layouts/common/render_simple.zig — the r0 splat primitives (layout-agnostic).
//
// The naive per-particle additive splat into an RGBA framebuffer. The clear
// is NOT here (the driver owns it — play memsets each frame, bench memsets
// once before the timed loop; §17.7). This module assumes an already-allocated
// fb and splats additively. Shared by every unfused cell's r0 walk; the r1
// pass (render_opt.zig) is byte-identical to this and proves it in tests.
//
// World coordinates are in [-view_half, view_half]; the framebuffer covers the
// same extent in both axes (square).

const std = @import("std");
const config = @import("../../framework/config.zig");
const fw = @import("../../framework/sim.zig");

/// Clear the framebuffer to black. (Driver concern, but kept here as the
/// canonical clear so play/bench/correctness all agree on what "cleared"
/// means. The cell's `step` does NOT call this.)
pub fn clear(fb: []u8) void {
    @memset(fb, 0);
}

/// Convert a world x in [-view_half, view_half] to framebuffer pixel x [0, w).
pub fn worldToPxX(x: f32, w: u32) i32 {
    const half: f32 = @floatFromInt(w);
    const norm = (x + config.view_half) / (2.0 * config.view_half); // [0,1)
    return @intFromFloat(norm * half);
}

/// Convert a world y in [-view_half, view_half] to framebuffer pixel y [0, h).
/// World +y is up; framebuffer +y is down → invert.
pub fn worldToPxY(y: f32, h: u32) i32 {
    const half: f32 = @floatFromInt(h);
    const norm = (config.view_half - y) / (2.0 * config.view_half); // [0,1)
    return @intFromFloat(norm * half);
}

/// Draw one particle as a 2x2 additive splat at world (x,y) with color (r,g,b).
/// Color components are f32; clamped to [0,255] internally.
pub fn splat(
    fb: []u8,
    w: u32,
    h: u32,
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
) void {
    const r8: u8 = clamp255(r);
    const g8: u8 = clamp255(g);
    const b8: u8 = clamp255(b);
    const px = worldToPxX(x, w);
    const py = worldToPxY(y, h);
    var dy: i32 = 0;
    while (dy < 2) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < 2) : (dx += 1) {
            const fx = px + dx;
            const fy = py + dy;
            if (fx < 0 or fx >= w or fy < 0 or fy >= h) continue;
            const i: usize = @intCast((fy * @as(i32, @intCast(w)) + fx) * 4);
            if (i + 3 >= fb.len) continue;
            fb[i + 0] = addClamp(fb[i + 0], r8);
            fb[i + 1] = addClamp(fb[i + 1], g8);
            fb[i + 2] = addClamp(fb[i + 2], b8);
            fb[i + 3] = 255;
        }
    }
}

fn clamp255(v: f32) u8 {
    if (v <= 0) return 0;
    if (v >= 255) return 255;
    return @intFromFloat(v);
}

fn addClamp(a: u8, b: u8) u8 {
    const sum: u16 = @as(u16, a) + @as(u16, b);
    return if (sum > 255) 255 else @intCast(sum);
}

/// The r0 splat pass for layouts that derive color from kind (no stored
/// color field): smoke gray, spark orange, debris blue. (Inlined at every
/// call site now; this wrapper is kept for layouts without a stored color.)
pub fn passKind(fb: []u8, w: u32, h: u32, particles: anytype) void {
    for (particles) |p| {
        const c = kindColor(p.kind);
        splat(fb, w, h, p.pos.x, p.pos.y, c[0], c[1], c[2]);
    }
}

/// Per-kind colors as u8 triplets (matches the r1 LUT exactly).
pub fn kindColor(k: fw.ParticleKind) [3]u8 {
    return switch (k) {
        .smoke => .{ 120, 120, 120 }, // gray
        .spark => .{ 255, 180, 60 }, // orange
        .debris => .{ 100, 200, 255 }, // blue
    };
}
