// Walk 2 — naive r0 render (B1 walk 2, r0 schedule).
//
// impl: zig, schedule: r0, parallel: none, variant: none
//
// The naive per-particle splat walk over the AoS array — one stream, all
// render fields adjacent. Delegates to Data.renderR0 (the layout's default
// splat). The r0 baseline; w2-opt (r1) is the optimized splat.

const fw = @import("../../../framework/sim.zig");
const layout = @import("../data.zig");

pub const decl: fw.WalkDecl = .{
    .impl = .zig,
    .schedule = .r0,
    .parallel = .none,
    .variant = .none,
};

pub fn render(sim: anytype, fb: []u8, w: u32, h: u32) void {
    sim.data.renderR0(fb, w, h);
}
