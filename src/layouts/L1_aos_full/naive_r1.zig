// Strategy L1.naive_r1 — L1.naive with the optimized splat render
// (framework/render_opt.zig, the stage-10 moves). Same sim; render() walks
// the AoS array and calls splatFast + the packed color LUT: one bounds check
// + one u8x8 saturating add per splat row, replacing the naive per-pixel
// checks and clamped adds.
//
// Output is BYTE-IDENTICAL to naive's r0 render: the LUT colors equal the
// stored per-particle colors (the stage-1 audit fact: color ≡ kindColor(kind)),
// and the saturating-add blend is order-independent. The framebuffer golden
// gates this claim on every bench run.
//
// Note the r1 render uses the LUT, not the stored color field — so the color
// field is never READ by this render. It is still stored (L1's data model is
// frozen); a layout that doesn't store color is L2's business, not L1's.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const rast = @import("../../framework/render.zig");
const opt = @import("../../framework/render_opt.zig");
const Data = @import("data.zig").Data;

const H = struct {
    // Same schedule as naive (re-exported, not copied — the step is not
    // what this strategy changes).
    pub const step = @import("naive.zig").H.step;

    pub fn render(sim: *const Sim, fb: []u8, w: u32, h: u32) void {
        rast.clear(fb);
        for (sim.data.particles) |p| {
            opt.splatFast(fb, w, h, p.pos.x, p.pos.y, opt.lut[@intFromEnum(p.kind)]);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);
