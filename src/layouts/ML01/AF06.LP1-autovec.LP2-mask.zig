// Algorithm ML01.AF06.LP1-autovec.LP2-mask — AF06 (math+decide→mask | mask-scan+respawn | render),
// loop 1 autovec, loop 2 autovec ordered, loop 3 r0 splat. SERIAL.
//
// Golden: bit-exact. The dead-mask variant: loop 1 does math + decide → a 1 B/p
// dead mask (no spawn RNG); loop 2 scans the mask in index order, respawning
// from the shared spawn RNG (rank order = serial RNG order). The mask makes
// loop 2 parallelizable (via ranked-merge — see AF06.LP1-autovec-par.LP2-mask-rmerge);
// this serial cell is the baseline. Diff vs AF02: the mask intermediate + the
// two-loop split (isolates the intermediate axis at T=1).
//
// Self-contained (§8 rule 2). The mask is the declared intermediate (1 B/p).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML01",
        .algo_fam = .AF06,
        .ordering = .identity,
        .intermediates = .mask,
        .loops = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .none },
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
        return 1; // the dead mask
    }

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        const dead = sim.extra.dead;
        // loop 1: math + decide → dead mask (no spawn RNG).
        for (data.particles, 0..) |*p, i| {
            p.pos = p.pos.add(p.vel.scale(dt));
            const v = p.vel;
            p.vel = .{
                .x = v.x + (config.gravity.x + config.drag * v.x) * dt,
                .y = v.y + (config.gravity.y + config.drag * v.y) * dt,
                .z = v.z + (config.gravity.z + config.drag * v.z) * dt,
            };
            p.age += dt;
            dead[i] = @intFromBool(config.isDead(p.age, &sim.kill_rng));
        }
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