// Walk 2 — optimized r1 render (B1 walk 2, r1 schedule).
//
// impl: zig, schedule: r1, parallel: none, variant: none
//
// The optimized splat: comptime color LUT + packed RGBA + one NEON `uqadd`
// per splat row + one whole-box bounds check (render_opt.zig). Byte-identical
// output to r0 (proven by zig build test) at ~3.4× render throughput.

const fw = @import("../../../framework/sim.zig");
const rast = @import("../../../framework/render.zig");
const opt = @import("../../../framework/render_opt.zig");

pub const decl: fw.WalkDecl = .{
    .impl = .zig,
    .schedule = .r1,
    .parallel = .none,
    .variant = .none,
};

pub fn render(sim: anytype, fb: []u8, w: u32, h: u32) void {
    rast.clear(fb);
    for (sim.data.particles) |p| {
        opt.splatFast(fb, w, h, p.pos.x, p.pos.y, opt.lut[@intFromEnum(p.kind)]);
    }
}
