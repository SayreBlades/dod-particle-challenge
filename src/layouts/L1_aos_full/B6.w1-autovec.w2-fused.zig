// Cell L1.B6.w1-autovec.w2-fused — B6 (math | decide+respawn+render fused),
// walk 1 math, walk 2 fused decide+respawn+splat.
//
// Golden: framebuffer_only. Walk 1 is pure math (separable); walk 2 fuses
// decide+respawn+render so the splat reads post-respawn pos from a register.
// Diff vs B5: the math/decide seam (isolates whether fusing just the
// decide+respawn+render, without fusing math, still wins).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const rast = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B6,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .none },
            .{ .impl = .zig, .schedule = .fused, .parallel = .none, .variant = .branchy },
        },
        .golden = .framebuffer_only,
        .halide_expressible = "walk1 yes; walk2 no (fused scatter)",
    };

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // walk 1: math only.
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
        // walk 2: fused decide + respawn + splat (reads post-respawn pos).
        for (data.particles, 0..) |*p, i| {
            if (config.isDead(p.age, &sim.kill_rng)) {
                data.spawn(&sim.rng, i);
            }
            rast.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);