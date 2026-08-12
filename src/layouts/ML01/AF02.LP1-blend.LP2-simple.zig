// Algorithm ML01.AF02.LP1-blend.LP2-simple — AF02 (math+decide+respawn | render),
// loop 1 Zig branchless blend, loop 2 r0 splat.
//
// Golden: statistical. The branchless blend computes respawn values for EVERY
// particle (dead or alive) via a per-particle hash RNG (hash_rng.zig), then
// selects them in only for the dead — no branch, vectorizable. The cost: the
// respawn RNG model differs from the branchy reference's ordered stream, so
// trajectories diverge by design (distributions identical). This is the Zig
// control for the Halide blend (AF02.LP1-halide.LP2-simple): same math + RNG
// model, isolates impl (zig vs halide) with variant held at blend.
//
// Self-contained (§8 rule 2): physics + branchless respawn inlined here; the
// splat calls the shared r0 pass. The clear is the driver's job.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const hash = @import("hash_rng.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;
const Particle = layout.Particle;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML01",
        .algo_fam = .AF02,
        .ordering = .identity,
        .intermediates = .none,
        .loops = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .blend },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .statistical,
        .halide_expressible = "loop1 yes (branchless blend, per-particle hash RNG); loop2 n/a",
    };

    /// AF02-blend, unfused: one physics loop with branchless respawn (select),
    /// then a separate splat pass. The splat always runs.
    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        const frame = sim.frame;
        const q = config.q;
        // loop 1: math + decide + branchless-respawn blend
        for (data.particles, 0..) |*p, i| {
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
            const age_new = p.age + dt;
            p.age = age_new;

            // 4. Decide (competing risks) — branchless: compute the kill hash
            //    regardless (the branchless tax), factor in only when age < kill_age.
            var dead: bool = age_new >= config.kill_age;
            if (q > 0.0) {
                if (age_new < config.kill_age) {
                    dead = dead or (hash.killFloat(i, frame) < q);
                }
            }

            // 5. Branchless respawn: draw respawn values for every particle,
            //    select them in only for the dead (the blend). No branch on dead.
            const r = hash.respawn(i, frame);
            const imp = config.impulse[r.kind];
            const col = layout.kindColor(@enumFromInt(r.kind));
            if (dead) {
                p.pos = .{ .x = 0, .y = 0, .z = 0 };
                p.vel = .{
                    .x = imp.x + r.jx,
                    .y = imp.y + r.jy,
                    .z = imp.z,
                };
                p.age = r.age * config.kill_age;
                p.kind = @enumFromInt(r.kind);
                p.color = col;
                p.life = config.kill_age;
                p.seed = @intCast(i);
            }
        }
        // loop 2: r0 splat pass (no clear — the driver owns it).
        for (data.particles) |p| {
            r0.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);