// Cell L1.B3.w1-halide.w2-simple — B3 (math+decide→mask | mask-scan+respawn | render),
// walk 1 Halide math+decide→mask, walk 2 Zig scan+respawn, walk 3 r0 splat. SERIAL.
//
// Golden: bit-exact. Halide does math + decide → the dead mask (StrictFloat,
// bit-identical math); Zig scans the mask in index order, respawning from the
// shared spawn RNG (rank order = serial RNG order). The mask makes the scan
// parallelizable (via ranked-merge — the B3-par cell); this serial cell is the
// Halide baseline. Diff vs B3.w1-autovec.w2-simple: walk-1 impl zig → halide.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const halide = @import("B3.w1-halide_api.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B3,
        .ordering = .identity,
        .intermediates = .mask,
        .walks = &.{
            .{ .impl = .halide, .schedule = .scalar, .parallel = .none, .variant = .none },
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .ordered },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "walk1 yes (math+decide→mask); walk2 no (host scan); walk3 n/a",
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
        // walk 1: Halide math + decide → dead mask.
        halide.run(data, dt, dead);
        // walk 2: mask-scan + respawn in index order (bit-exact). Block skip.
        phase2Respawn(sim);
        // walk 3: r0 splat pass.
        r0.pass(fb, w, h, data.particles);
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