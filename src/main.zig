// Entry point. Comptime registry: opts.name -> SimImpl, opts.mode -> driver.
// build.zig resolves -Dlayout/-Dstrat (verticals) to a canonical name; every
// name below must match a registry entry in build.zig.
const std = @import("std");
const opts = @import("options");
const fw = @import("framework/sim.zig");

const sim_map = std.StaticStringMap(type).initComptime(.{
    // --- the layout verticals (src/layouts/; -Dlayout=LX -Dstrat=name) ---
    // B1 cells are self-contained (§8 rule 2): each inlines physics + splat
    // in `step`. The Halide cells call B1.w1-halide_api.run() for walk 1.
    .{ "L1.B1.w1-autovec.w2-simple", @import("layouts/L1/B1.w1-autovec.w2-simple.zig").Sim },
    .{ "L1.B1.w1-autovec.w2-opt", @import("layouts/L1/B1.w1-autovec.w2-opt.zig").Sim },
    .{ "L1.B1.w1-scalar.w2-simple", @import("layouts/L1/B1.w1-scalar.w2-simple.zig").Sim },
    .{ "L1.B1.w1-autovec-par.w2-simple", @import("layouts/L1/B1.w1-autovec-par.w2-simple.zig").Sim },
    .{ "L1.B1.w1-blend.w2-simple", @import("layouts/L1/B1.w1-blend.w2-simple.zig").Sim },
    .{ "L1.B1.w1-blend-par.w2-simple", @import("layouts/L1/B1.w1-blend-par.w2-simple.zig").Sim },
    .{ "L1.B1.w1-halide.w2-simple", @import("layouts/L1/B1.w1-halide.w2-simple.zig").Sim },
    .{ "L1.B1.w1-halide.w2-opt", @import("layouts/L1/B1.w1-halide.w2-opt.zig").Sim },
    .{ "L1.B1.w1-halide-par.w2-simple", @import("layouts/L1/B1.w1-halide-par.w2-simple.zig").Sim },
    .{ "L1.B2.w1-autovec.w2-simple", @import("layouts/L1/B2.w1-autovec.w2-simple.zig").Sim },
    .{ "L1.B2.w1-autovec-par.w2-simple", @import("layouts/L1/B2.w1-autovec-par.w2-simple.zig").Sim },
    .{ "L1.B2.w1-halide.w2-simple", @import("layouts/L1/B2.w1-halide.w2-simple.zig").Sim },
    .{ "L1.B2.w1-halide-par.w2-simple", @import("layouts/L1/B2.w1-halide-par.w2-simple.zig").Sim },
    .{ "L1.B3.w1-halide.w2-simple", @import("layouts/L1/B3.w1-halide.w2-simple.zig").Sim },
    .{ "L1.B3.w1-autovec.w2-simple", @import("layouts/L1/B3.w1-autovec.w2-simple.zig").Sim },
    .{ "L1.B3.w1-autovec-par.w2-rmerge", @import("layouts/L1/B3.w1-autovec-par.w2-rmerge.zig").Sim },
    .{ "L1.B4.w1-autovec.w2-simple", @import("layouts/L1/B4.w1-autovec.w2-simple.zig").Sim },
    .{ "L1.B4.w1-autovec-par.w2-rmerge", @import("layouts/L1/B4.w1-autovec-par.w2-rmerge.zig").Sim },
    .{ "L1.B5.w1-fused", @import("layouts/L1/B5.w1-fused.zig").Sim },
    .{ "L1.B6.w1-autovec.w2-fused", @import("layouts/L1/B6.w1-autovec.w2-fused.zig").Sim },
    .{ "L1.B7.w1-autovec.w2-fused", @import("layouts/L1/B7.w1-autovec.w2-fused.zig").Sim },
    .{ "L1.B8.w1-autovec.w2-fused", @import("layouts/L1/B8.w1-autovec.w2-fused.zig").Sim },
});

const SimImpl = sim_map.get(opts.name) orelse
    @compileError("unknown sim '" ++ opts.name ++ "' (see strat_labels in build.zig / sim_map in main.zig)");

pub fn main(init: std.process.Init) !void {
    return switch (opts.mode) {
        .play => @import("framework/play.zig").run(SimImpl, init),
        .bench => @import("framework/bench.zig").run(SimImpl, init),
        .audit => @import("framework/audit.zig").run(SimImpl, init),
        .manifest => emitManifest(init),
    };
}

/// Manifest mode: print every registered sim's CellDecl to stdout — a
/// diagnostic of what's registered in `sim_map`. The `cell_decl` in each
/// strategy file is the source of truth; there is no checked-in manifest
/// file (reporting-and-analysis.md §9.5 retired experiments/cells/).
fn emitManifest(init: std.process.Init) !void {
    const io = init.io;
    var f = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    try @import("framework/manifest.zig").print(sim_map, &w.interface);
    try w.end();
}
