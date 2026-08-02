// Cell L1.B1.w1-halide.w2-simple — B1 (math+decide+respawn | render),
// walk 1 Halide branchless blend, walk 2 r0 splat.
//
// Golden: statistical (different RNG model by design — per-particle hash RNG
// vs the branchy variant's ordered spawn stream). Diff vs B1.w1-autovec.w2-simple:
// walk-1 impl zig → halide AND variant branchy → blend (isolates the
// impl+variant axes; the statistical golden is the cost of that isolation).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const layout = @import("data.zig");
const halide = @import("B1.w1-halide_api.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1",
        .blueprint = .B1,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{
            .{ .impl = .halide, .schedule = .scalar, .parallel = .none, .variant = .blend },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .statistical,
        .halide_expressible = "walk1 yes (branchless blend, per-particle hash RNG); walk2 n/a (render)",
    };

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // walk 1: Halide branchless blend (math + decide + respawn in one pipeline).
        halide.run(data, dt, sim.frame);
        // walk 2: r0 splat pass (no clear — the driver owns it).
        for (data.particles) |p| {
            r0.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);
