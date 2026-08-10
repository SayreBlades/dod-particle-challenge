// Algorithm ML01.AF06.LP1-autovec.LP2-fused — AF06 (math | decide+respawn+render fused),
// loop 1 math, loop 2 fused decide+respawn+splat.
//
// Golden: framebuffer_only. Loop 1 is pure math (separable); loop 2 fuses
// decide+respawn+render so the splat reads post-respawn pos from a register.
// Diff vs AF05: the math/decide seam (isolates whether fusing just the
// decide+respawn+render, without fusing math, still wins).

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
        .intermediates = .none,
        .loops = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .none },
            .{ .impl = .zig, .schedule = .fused, .parallel = .none, .variant = .branchy },
        },
        .golden = .framebuffer_only,
        .halide_expressible = "loop1 yes; loop2 no (fused scatter)",
    };

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // loop 1: math only.
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
        // loop 2: fused decide + respawn + splat (reads post-respawn pos).
        for (data.particles, 0..) |*p, i| {
            if (config.isDead(p.age, &sim.kill_rng)) {
                data.spawn(&sim.rng, i);
            }
            rast.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);