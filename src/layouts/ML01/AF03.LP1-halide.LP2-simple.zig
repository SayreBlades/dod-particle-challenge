// Algorithm ML01.AF03.LP1-halide.LP2-simple — AF03 (math+decide→mask | mask-scan+respawn | render),
// loop 1 Halide math+decide→mask, loop 2 Zig scan+respawn, loop 3 r0 splat. SERIAL.
//
// Golden: bit-exact. Halide does math + decide → the dead mask (StrictFloat,
// bit-identical math); Zig scans the mask in index order, respawning from the
// shared spawn RNG (rank order = serial RNG order). The mask makes the scan
// parallelizable (via ranked-merge — the AF03-par cell); this serial cell is the
// Halide baseline. Diff vs AF03.LP1-autovec.LP2-simple: loop-1 impl zig → halide.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const halide = @import("AF03.LP1-halide_api.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML01",
        .algo_fam = .AF03,
        .ordering = .identity,
        .intermediates = .mask,
        .loops = &.{
            .{ .impl = .halide, .schedule = .scalar, .parallel = .none, .variant = .none },
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .ordered },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "loop1 yes (math+decide→mask); loop2 no (host scan); loop3 n/a",
    };

    pub const Extra = struct {
        dead: []u8, // 1 B/p mask (the declared intermediate)
    };

    pub fn initExtra(sim: anytype, desc: fw.Desc) !void {
        sim.extra = .{ .dead = try sim.alloc.alloc(u8, desc.n) };
    }

    pub fn deinitExtra(sim: anytype) void {
        sim.alloc.free(sim.extra.dead);
    }

    pub fn scratchBytes(sim: *const Sim) usize {
        _ = sim;
        return 1;
    }

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        const dead = sim.extra.dead;
        // loop 1: Halide math + decide → dead mask.
        halide.run(data, dt, dead);
        // loop 2: mask-scan + respawn in index order (bit-exact). Block skip.
        phase2Respawn(sim);
        // loop 3: r0 splat pass.
        for (data.particles) |p| {
            r0.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }

    fn phase2Respawn(sim: anytype) void {
        const dead = sim.extra.dead;
        const n = sim.data.n;
        const B = 32;
        var i: usize = 0;
        while (i + B <= n) : (i += B) {
            const block: @Vector(B, u8) = dead[i..][0..B].*;
            if (@reduce(.Or, block) == 0) continue;
            var j: usize = i;
            while (j < i + B) : (j += 1) {
                if (dead[j] != 0) sim.data.spawn(&sim.rng, j);
            }
        }
        while (i < n) : (i += 1) {
            if (dead[i] != 0) sim.data.spawn(&sim.rng, i);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);