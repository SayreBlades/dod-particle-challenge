// Cell L1.B2.w1-halide-par.w2-simple — B2 (math | decide+respawn | render),
// walk 1 Halide math, walk 2 Zig decide+respawn, walk 3 r0 splat. SERIAL.
//
// Golden: bit-exact. The "natural seam": Halide does the math (StrictFloat,
// bit-identical to the Zig cells), Zig keeps decide+respawn (RNG-order). The
// cost on AoS is the second walk (the seam), not Halide's codegen. Diff vs
// B2.w1-autovec.w2-simple: walk-1 impl zig → halide (isolates impl, math-only).

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const config = @import("../../../framework/config.zig");
const layout = @import("../data.zig");
const halide = @import("../B2.w1-halide_api.zig");
const r0 = @import("../../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B2,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{
            .{ .impl = .halide, .schedule = .scalar, .parallel = .data_parallel, .variant = .none },
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .branchy },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "walk1 yes (math); walk2 no (RNG-order); walk3 n/a",
    };

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // walk 1: Halide math (integrate pos/vel/age; no decide).
        halide.run(data, dt);
        // walk 2: Zig decide + respawn (branchy, RNG-order).
        for (data.particles, 0..) |*p, i| {
            if (config.isDead(p.age, &sim.kill_rng)) data.spawn(&sim.rng, i);
        }
        // walk 3: r0 splat pass.
        r0.pass(fb, w, h, data.particles);
    }
};

pub const Sim = fw.Strategy(Data, H);