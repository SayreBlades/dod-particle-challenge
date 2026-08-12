// Algorithm ML01.AF06.LP1-autovec.LP2-list-fused — AF06 (math+decide→list | respawn+render(dead) fused | render(live)),
// loop 1 math+decide→list, loop 2 fused respawn+render(dead only), loop 3 render(live, mask-tested).
//
// Golden: framebuffer_only. The most complex algorithm family: the list intermediate
// + a dead/live render split. Loop 2 renders ONLY the dead (just respawned —
// reads post-respawn pos from a register); loop 3 renders the live (those not
// in the dead list). The dead/live split needs a live test — AF06 carries the
// mask AND the list (declared intermediates: list + mask). Loop 3 splats a
// live particle only if its mask bit is clear (not respawned this frame).
//
// The dead/live render split is the fusion win for the list family: loop 2
// touches only the dead (O(dead) splats reading fresh pos), loop 3 touches
// the live (O(live) splats). Total splats = N, but the dead ones read
// register-resident post-respawn pos.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const rast = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML01",
        .algo_fam = .AF06,
        .ordering = .identity,
        .intermediates = .mask_and_list,
        .loops = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .none },
            .{ .impl = .zig, .schedule = .fused, .parallel = .none, .variant = .ordered },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .framebuffer_only,
        .halide_expressible = "no",
    };

    pub const Extra = struct {
        dead: []u32, // compact dead-index list
        was_dead: []u8, // 1 B/p mask: was this particle respawned this frame?
        dead_count: usize = 0,
    };

    pub fn initExtra(sim: anytype, desc: fw.Desc) !void {
        sim.extra = .{
            .dead = try sim.alloc.alloc(u32, desc.n),
            .was_dead = try sim.alloc.alloc(u8, desc.n),
        };
    }

    pub fn deinitExtra(sim: anytype) void {
        sim.alloc.free(sim.extra.dead);
        sim.alloc.free(sim.extra.was_dead);
    }

    pub fn scratchBytes(sim: *const Sim) usize {
        _ = sim;
        return 5; // list (4 B/p) + mask (1 B/p)
    }

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        const dead = sim.extra.dead;
        const was_dead = sim.extra.was_dead;
        @memset(was_dead, 0);
        var ndead: usize = 0;
        // loop 1: math + decide → dead list + was_dead mask.
        for (data.particles, 0..) |*p, i| {
            p.pos = p.pos.add(p.vel.scale(dt));
            const v = p.vel;
            p.vel = .{
                .x = v.x + (config.gravity.x + config.drag * v.x) * dt,
                .y = v.y + (config.gravity.y + config.drag * v.y) * dt,
                .z = v.z + (config.gravity.z + config.drag * v.z) * dt,
            };
            p.age += dt;
            if (config.isDead(p.age, &sim.kill_rng)) {
                dead[ndead] = @intCast(i);
                ndead += 1;
                was_dead[i] = 1;
            }
        }
        sim.extra.dead_count = ndead;
        // loop 2: fused respawn + render(dead only). Respawns in list order
        // (= index order = bit-exact RNG); splats each just-respawned particle
        // reading post-respawn pos from a register.
        var k: usize = 0;
        while (k < ndead) : (k += 1) {
            const i = dead[k];
            data.spawn(&sim.rng, i);
            const p = &data.particles[i];
            rast.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
        // loop 3: render(live) — splat every particle whose was_dead bit is clear.
        for (data.particles, 0..) |*p, i| {
            if (was_dead[i] == 0) {
                rast.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
            }
        }
    }
};

pub const Sim = fw.Strategy(Data, H);