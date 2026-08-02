// Cell L1.B5.w1-fused — B5 (math+decide+respawn+render, fully fused),
// single walk, splat inlined into the physics loop.
//
// Golden: framebuffer_only. The sim golden passes trivially (respawn RNG
// order unchanged from B1.w1-autovec — the splat reads pos after respawn,
// doesn't perturb it); the FRAME golden is the fusion-relevant check (does
// the interleaved splat still produce a byte-identical frame?).
//
// The fusion win: the splat reads post-respawn pos from a register before
// eviction. Layout- and regime-dependent — wins on lean layouts at
// cache-resident N (saves a pos re-read); loses on fat layouts at DRAM (the
// state stream already saturates; interleaved scatter only hurts). This cell
// IS the measurement of that hypothesis on L1.
//
// Self-contained (§8 rule 2): one loop, physics + splat interleaved.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const rast = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1",
        .blueprint = .B5,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{
            .{ .impl = .zig, .schedule = .fused, .parallel = .none, .variant = .branchy },
        },
        .golden = .framebuffer_only,
        .halide_expressible = "no (scatter reduction — fused render is not Halide-expressible)",
    };

    /// B5: one fused loop — math + decide + respawn, then splat the (possibly
    /// respawned) particle in the same iteration. The splat reads post-respawn
    /// pos from a register before the next iteration evicts it.
    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        for (data.particles, 0..) |*p, i| {
            // math
            p.pos = p.pos.add(p.vel.scale(dt));
            const v = p.vel;
            p.vel = .{
                .x = v.x + (config.gravity.x + config.drag * v.x) * dt,
                .y = v.y + (config.gravity.y + config.drag * v.y) * dt,
                .z = v.z + (config.gravity.z + config.drag * v.z) * dt,
            };
            p.age += dt;
            // decide + respawn (branchy, in place)
            if (config.isDead(p.age, &sim.kill_rng)) {
                data.spawn(&sim.rng, i);
            }
            // splat (inlined — reads post-respawn pos). Uses stored color
            // (matches the r0 splat; spawn sets color = kindColor(kind)).
            rast.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);