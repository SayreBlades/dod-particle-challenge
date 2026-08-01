// Cell L1.B2.w1-autovec.w2-simple — B2 (math | decide+respawn | render),
// walk 1 autovec math, walk 2 autovec decide+respawn (branchy), walk 3 r0 splat.
//
// Golden: bit-exact. The "natural seam": math is separable from decide+respawn,
// so walk 1 reads {pos, vel, age} and writes {pos, vel, age}; walk 2 re-reads
// age across the seam to decide death + respawn. The cost B3's mask was
// invented to kill: walk 2 re-reads `age` (a second pass over the field).
// Diff vs B1.w1-autovec.w2-simple: the math/decide seam (isolates fusion).
//
// Self-contained (§8 rule 2): both walks inlined; the splat calls r0.

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const config = @import("../../../framework/config.zig");
const layout = @import("../data.zig");
const r0 = @import("../../common/render_simple.zig");

const Data = layout.Data;
const Particle = layout.Particle;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B2,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .none },
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .branchy },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "walk1 yes (math); walk2 no (RNG-order decide+respawn); walk3 n/a",
    };

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // walk 1: math only (integrate + forces + age; no decide, no respawn).
        for (data.particles) |*p| {
            p.pos = p.pos.add(p.vel.scale(dt));
            const v = p.vel;
            p.vel = .{
                .x = v.x + (config.gravity.x + config.drag * v.x) * dt,
                .y = v.y + (config.gravity.y + config.drag * v.y) * dt,
                .z = v.z + (config.gravity.z + config.drag * v.z) * dt,
            };
            p.age += dt;
        }
        // walk 2: decide + respawn (branchy). Re-reads age across the seam.
        for (data.particles, 0..) |*p, i| {
            if (config.isDead(p.age, &sim.kill_rng)) {
                data.spawn(&sim.rng, i);
            }
        }
        // walk 3: r0 splat pass (no clear — the driver owns it).
        r0.pass(fb, w, h, data.particles);
    }
};

pub const Sim = fw.Strategy(Data, H);