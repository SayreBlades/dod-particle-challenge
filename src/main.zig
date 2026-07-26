// Entry point. Comptime registry: opts.name -> SimImpl, opts.mode -> driver.
// build.zig resolves -Dlayout/-Dstrat (verticals) or -Dstage (arc) to a
// canonical name; every name below must match a registry entry in build.zig.
const std = @import("std");
const opts = @import("options");
const fw = @import("framework/sim.zig");

const sim_map = std.StaticStringMap(type).initComptime(.{
    // --- the arc (src/stages/, untouched history; -Dstage=N) ---
    .{ "stage1", @import("stages/01_naive/sim.zig").Sim },
    .{ "stage2", @import("stages/02_hotcold/sim.zig").Sim },
    .{ "stage3", @import("stages/03_soa/sim.zig").Sim },
    .{ "stage4", @import("stages/04_compact/sim.zig").Sim },
    .{ "stage5", @import("stages/05_sortbykind/sim.zig").Sim },
    .{ "stage6", @import("stages/06_simd/sim.zig").Sim },
    .{ "stage7", @import("stages/07_align/sim.zig").Sim },
    .{ "stage8", @import("stages/08_alloc/sim.zig").Sim },
    .{ "stage9", @import("stages/09_synthesis/sim.zig").Sim },
    .{ "stage10", @import("stages/10_rasterizer/sim.zig").Sim },
    .{ "stage11", @import("stages/11_record/sim.zig").Sim },
    // --- the layout verticals (src/layouts/; -Dlayout=LX -Dstrat=name) ---
    .{ "L1.naive", @import("layouts/L1_aos_full/naive.zig").Sim },
    .{ "L1.naive_r1", @import("layouts/L1_aos_full/naive_r1.zig").Sim },
    .{ "L1.par", @import("layouts/L1_aos_full/par.zig").Sim },
    .{ "L1.halide_a", @import("layouts/L1_aos_full/halide_a.zig").Sim },
    .{ "L1.naive_novec", @import("layouts/L1_aos_full/naive_novec.zig").Sim },
    .{ "L1.halide_a2", @import("layouts/L1_aos_full/halide_a2.zig").Sim },
    .{ "L1.halide_b1", @import("layouts/L1_aos_full/halide_b1.zig").Sim },
    .{ "L1.halide_a2_viz", @import("layouts/L1_aos_full/halide_a2_viz.zig").Sim },
});

const SimImpl = sim_map.get(opts.name) orelse
    @compileError("unknown sim '" ++ opts.name ++ "' (see strat_labels in build.zig / sim_map in main.zig)");

pub fn main(init: std.process.Init) !void {
    return switch (opts.mode) {
        .play => @import("framework/play.zig").run(SimImpl, init),
        .bench => @import("framework/bench.zig").run(SimImpl, init),
        .audit => @import("framework/audit.zig").run(SimImpl, init),
    };
}
