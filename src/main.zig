// Entry point. Comptime registry: opts.name -> SimImpl, opts.mode -> driver.
// build.zig resolves -Dmem_layout/-Dalgo (verticals) to a canonical name; every
// name below must match a registry entry in build.zig.
const std = @import("std");
const opts = @import("options");
const fw = @import("framework/sim.zig");

const sim_map = std.StaticStringMap(type).initComptime(.{
    // --- the mem_layout verticals (src/layouts/; -Dmem_layout=MLX -Dalgo=name) ---
    // AF1 algorithms are self-contained (§8 rule 2): each inlines physics + splat
    // in `step`. The Halide algorithms call AF1.LP1-halide_api.run() for loop 1.
    .{ "ML1.AF1.LP1-autovec.LP2-simple", @import("layouts/ML1/AF1.LP1-autovec.LP2-simple.zig").Sim },
    .{ "ML1.AF1.LP1-autovec.LP2-opt", @import("layouts/ML1/AF1.LP1-autovec.LP2-opt.zig").Sim },
    .{ "ML1.AF1.LP1-scalar.LP2-simple", @import("layouts/ML1/AF1.LP1-scalar.LP2-simple.zig").Sim },
    .{ "ML1.AF1.LP1-unroll.LP2-simple", @import("layouts/ML1/AF1.LP1-unroll.LP2-simple.zig").Sim },
    .{ "ML1.AF1.LP1-autovec-par.LP2-simple", @import("layouts/ML1/AF1.LP1-autovec-par.LP2-simple.zig").Sim },
    .{ "ML1.AF1.LP1-blend.LP2-simple", @import("layouts/ML1/AF1.LP1-blend.LP2-simple.zig").Sim },
    .{ "ML1.AF1.LP1-blend-par.LP2-simple", @import("layouts/ML1/AF1.LP1-blend-par.LP2-simple.zig").Sim },
    .{ "ML1.AF1.LP1-halide.LP2-simple", @import("layouts/ML1/AF1.LP1-halide.LP2-simple.zig").Sim },
    .{ "ML1.AF1.LP1-halide.LP2-opt", @import("layouts/ML1/AF1.LP1-halide.LP2-opt.zig").Sim },
    .{ "ML1.AF1.LP1-halide-par.LP2-simple", @import("layouts/ML1/AF1.LP1-halide-par.LP2-simple.zig").Sim },
    .{ "ML1.AF2.LP1-autovec.LP2-simple", @import("layouts/ML1/AF2.LP1-autovec.LP2-simple.zig").Sim },
    .{ "ML1.AF2.LP1-autovec-par.LP2-simple", @import("layouts/ML1/AF2.LP1-autovec-par.LP2-simple.zig").Sim },
    .{ "ML1.AF2.LP1-halide.LP2-simple", @import("layouts/ML1/AF2.LP1-halide.LP2-simple.zig").Sim },
    .{ "ML1.AF2.LP1-halide-par.LP2-simple", @import("layouts/ML1/AF2.LP1-halide-par.LP2-simple.zig").Sim },
    .{ "ML1.AF3.LP1-halide.LP2-simple", @import("layouts/ML1/AF3.LP1-halide.LP2-simple.zig").Sim },
    .{ "ML1.AF3.LP1-autovec.LP2-simple", @import("layouts/ML1/AF3.LP1-autovec.LP2-simple.zig").Sim },
    .{ "ML1.AF3.LP1-autovec-par.LP2-rmerge", @import("layouts/ML1/AF3.LP1-autovec-par.LP2-rmerge.zig").Sim },
    .{ "ML1.AF4.LP1-autovec.LP2-simple", @import("layouts/ML1/AF4.LP1-autovec.LP2-simple.zig").Sim },
    .{ "ML1.AF4.LP1-autovec-par.LP2-rmerge", @import("layouts/ML1/AF4.LP1-autovec-par.LP2-rmerge.zig").Sim },
    .{ "ML1.AF5.LP1-fused", @import("layouts/ML1/AF5.LP1-fused.zig").Sim },
    .{ "ML1.AF6.LP1-autovec.LP2-fused", @import("layouts/ML1/AF6.LP1-autovec.LP2-fused.zig").Sim },
    .{ "ML1.AF7.LP1-autovec.LP2-fused", @import("layouts/ML1/AF7.LP1-autovec.LP2-fused.zig").Sim },
    .{ "ML1.AF8.LP1-autovec.LP2-fused", @import("layouts/ML1/AF8.LP1-autovec.LP2-fused.zig").Sim },
});

const SimImpl = sim_map.get(opts.name) orelse
    @compileError("unknown sim '" ++ opts.name ++ "' (see algo_labels in build.zig / sim_map in main.zig)");

pub fn main(init: std.process.Init) !void {
    // play pulls in raylib (windowing); gate it so bench/audit/manifest builds
    // link no GUI library at all. The condition is comptime-known (opts.mode is
    // a build option), so Zig does NOT analyze the play @import for non-play
    // builds — raylib stays entirely out of the bench binary.
    if (opts.mode == .play) {
        if (!opts.link_raylib) @compileError("play mode requires -Dmode=play (sets link_raylib)");
        return @import("framework/play.zig").run(SimImpl, init);
    }
    return switch (opts.mode) {
        .bench => @import("framework/bench.zig").run(SimImpl, init),
        .audit => @import("framework/audit.zig").run(SimImpl, init),
        .manifest => emitManifest(init),
        .play => unreachable, // handled above
    };
}

/// Manifest mode: print every registered sim's AlgorithmMeta to stdout — a
/// diagnostic of what's registered in `sim_map`. The `algo_meta` in each
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
