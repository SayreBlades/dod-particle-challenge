// Algorithm ML01.AF02.LP1-halide-par.LP2-simple — AF02 (math | decide+respawn | render),
// loop 1 Halide math, loop 2 Zig decide+respawn, loop 3 r0 splat. SERIAL.
//
// Golden: bit-exact. The "natural seam": Halide does the math (StrictFloat,
// bit-identical to the Zig cells), Zig keeps decide+respawn (RNG-order). The
// cost on AoS is the second loop (the seam), not Halide's codegen. Diff vs
// AF02.LP1-autovec.LP2-simple: loop-1 impl zig → halide (isolates impl, math-only).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const halide = @import("AF02.LP1-halide_api.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML01",
        .algo_fam = .AF02,
        .ordering = .identity,
        .intermediates = .none,
        .loops = &.{
            .{ .impl = .halide, .schedule = .scalar, .parallel = .data_parallel, .variant = .none },
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .branchy },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "loop1 yes (math); loop2 no (RNG-order); loop3 n/a",
    };

    /// Cap the Halide runtime pool so the `-par` kernel honors `--threads`
    /// (issue #4): the kernel's `f.parallel(i)` schedule is still baked at build
    /// time, but the runtime pool that executes it is now capped to
    /// `sim.threads`. The Strategy harness sets `sim.threads` from `desc.threads`
    /// before this runs. Idempotent + cheap, so the per-N re-init in the bench
    /// sweep just re-sets the same value.
    pub fn initExtra(sim: anytype, desc: fw.Desc) !void {
        _ = desc;
        halide.setThreads(sim.threads);
    }

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // loop 1: Halide math (integrate pos/vel/age; no decide).
        halide.run(data, dt);
        // loop 2: Zig decide + respawn (branchy, RNG-order).
        for (data.particles, 0..) |*p, i| {
            if (config.isDead(p.age, &sim.kill_rng)) data.spawn(&sim.rng, i);
        }
        // loop 3: r0 splat pass.
        for (data.particles) |p| {
            r0.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);