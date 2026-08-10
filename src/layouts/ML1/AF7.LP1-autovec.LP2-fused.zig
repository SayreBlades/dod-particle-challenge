// Algorithm ML1.AF7.LP1-autovec.LP2-fused — AF7 (math+decide→mask | mask-scan+respawn+render fused),
// loop 1 math+decide→mask, loop 2 fused mask-scan+respawn+splat.
//
// Golden: framebuffer_only. The mask variant with fused render: loop 1
// produces the dead mask; loop 2 scans it, respawns, and splats — the splat
// reads post-respawn pos from a register. Diff vs AF5: the mask intermediate
// (does the two-phase structure change the fusion win?).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const rast = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML1",
        .algo_fam = .AF7,
        .ordering = .identity,
        .intermediates = .mask,
        .loops = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .none },
            .{ .impl = .zig, .schedule = .fused, .parallel = .none, .variant = .ordered },
        },
        .golden = .framebuffer_only,
        .halide_expressible = "loop1 yes; loop2 no (fused scatter)",
    };

    pub const Extra = struct {
        dead: []u8,
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
        // loop 1: math + decide → dead mask.
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
        // loop 2: fused mask-scan + respawn + splat. Respawns in index order
        // (bit-exact RNG); splats every particle (reads post-respawn pos for
        // the dead, current pos for the live).
        for (data.particles, 0..) |*p, i| {
            if (dead[i] != 0) data.spawn(&sim.rng, i);
            rast.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);