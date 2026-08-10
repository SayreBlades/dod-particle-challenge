// Algorithm ML1.AF1.LP1-halide-par.LP2-simple — AF1 (math+decide+respawn | render),
// loop 1 Halide branchless blend, loop 2 r0 splat.
//
// Golden: statistical (different RNG model by design — per-particle hash RNG
// vs the branchy variant's ordered spawn stream). Diff vs AF1.LP1-autovec.LP2-simple:
// loop-1 impl zig → halide AND variant branchy → blend (isolates the
// impl+variant axes; the statistical golden is the cost of that isolation).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const layout = @import("data.zig");
const halide = @import("AF1.LP1-halide_api.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML1",
        .algo_fam = .AF1,
        .ordering = .identity,
        .intermediates = .none,
        .loops = &.{
            .{ .impl = .halide, .schedule = .scalar, .parallel = .data_parallel, .variant = .blend },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .statistical,
        .halide_expressible = "loop1 yes (branchless blend, per-particle hash RNG); loop2 n/a (render)",
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
        // loop 1: Halide branchless blend (math + decide + respawn in one pipeline).
        halide.run(data, dt, sim.frame);
        // loop 2: r0 splat pass (no clear — the driver owns it).
        for (data.particles) |p| {
            r0.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);
