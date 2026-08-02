// Cell L1.B1.w1-halide.w2-opt — B1 (math+decide+respawn | render),
// walk 1 Halide branchless blend, walk 2 optimized r1 splat.
//
// Golden: statistical. Halide blend + r1 splat (byte-identical output to
// w2-simple's r0 splat, proven by `zig build test`).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const layout = @import("data.zig");
const halide = @import("B1.w1-halide_api.zig");
const r1 = @import("../common/render_opt.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B1,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{
            .{ .impl = .halide, .schedule = .scalar, .parallel = .none, .variant = .blend },
            .{ .impl = .zig, .schedule = .r1, .parallel = .none, .variant = .none },
        },
        .golden = .statistical,
        .halide_expressible = "walk1 yes (branchless blend); walk2 n/a (render)",
    };

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // walk 1: Halide branchless blend.
        halide.run(data, dt, sim.frame);
        // walk 2: r1 splat pass (no clear — the driver owns it).
        for (data.particles) |p| {
            r1.splatFast(fb, w, h, p.pos.x, p.pos.y, r1.lut[@intFromEnum(p.kind)]);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);
