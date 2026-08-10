// Algorithm ML1.AF1.LP1-autovec.LP2-simple — AF1 (math+decide+respawn | render),
// loop 1 autovec branchy, loop 2 r0 splat.
//
// The reference sim (generates experiments/golden/stage1.bin + experiments/golden/frame.sha256).
// Golden: bit-exact. Same algorithm family as the other AF1 cells; differs only in
// loop attributes (read the declaration diff for the attribution).
//
// Self-contained (§8 rule 2): the physics is inlined here, not aliased from
// a loop file. The splat calls the shared r0 pass in layouts/common/.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;
const Particle = layout.Particle;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML1",
        .algo_fam = .AF1,
        .ordering = .identity,
        .intermediates = .none,
        .loops = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .branchy },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "loop1 no (branchy respawn — select is branchless); loop2 n/a (render)",
    };

    /// AF1, unfused: physics loop, then a separate splat pass. The splat always
    /// runs (the driver provided a real fb and cleared it).
    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // loop 1: math + decide + respawn (branchy)
        for (data.particles) |*p| {
            // 1. Integrate: pos += vel * dt
            p.pos = p.pos.add(p.vel.scale(dt));

            // 2. Forces: vel += (gravity + drag*vel) * dt
            const v = p.vel;
            p.vel = .{
                .x = v.x + (config.gravity.x + config.drag * v.x) * dt,
                .y = v.y + (config.gravity.y + config.drag * v.y) * dt,
                .z = v.z + (config.gravity.z + config.drag * v.z) * dt,
            };

            // 3. Age
            p.age += dt;

            // 4. Kill → respawn (in place; seed % len == i by construction)
            if (config.isDead(p.age, &sim.kill_rng)) {
                data.spawn(&sim.rng, @intCast(p.seed % data.particles.len));
            }
        }
        // loop 2: r0 splat pass (no clear — the driver owns it).
        for (data.particles) |p| {
            r0.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);
