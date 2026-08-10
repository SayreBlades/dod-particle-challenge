// Algorithm ML1.AF1.LP1-halide.LP2-opt — AF1 (math+decide+respawn | render),
// loop 1 Halide branchless blend, loop 2 optimized r1 splat.
//
// Golden: statistical. Halide blend + r1 splat (byte-identical output to
// LP2-simple's r0 splat, proven by `zig build test`).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const layout = @import("data.zig");
const halide = @import("AF1.LP1-halide_api.zig");
const r1 = @import("../common/render_opt.zig");

const Data = layout.Data;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML1",
        .algo_fam = .AF1,
        .ordering = .identity,
        .intermediates = .none,
        .loops = &.{
            .{ .impl = .halide, .schedule = .scalar, .parallel = .none, .variant = .blend },
            .{ .impl = .zig, .schedule = .r1, .parallel = .none, .variant = .none },
        },
        .golden = .statistical,
        .halide_expressible = "loop1 yes (branchless blend); loop2 n/a (render)",
    };

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // loop 1: Halide branchless blend.
        halide.run(data, dt, sim.frame);
        // loop 2: r1 splat pass (no clear — the driver owns it).
        for (data.particles) |p| {
            r1.splatFast(fb, w, h, p.pos.x, p.pos.y, r1.lut[@intFromEnum(p.kind)]);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);
