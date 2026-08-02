// Cell L1.B1.w1-autovec.w2-opt — B1 (math+decide+respawn | render),
// walk 1 autovec branchy, walk 2 optimized r1 splat.
//
// Golden: bit-exact. r1 splat (comptime color LUT + NEON uqadd) on the
// reference physics; byte-identical output to w2-simple (proven by
// `zig build test`).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const r1 = @import("../common/render_opt.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B1,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .branchy },
            .{ .impl = .zig, .schedule = .r1, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "walk1 no (branchy respawn); walk2 n/a (render)",
    };

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // walk 1: math + decide + respawn (branchy) — identical to w2-simple.
        for (data.particles) |*p| {
            p.pos = p.pos.add(p.vel.scale(dt));
            const v = p.vel;
            p.vel = .{
                .x = v.x + (config.gravity.x + config.drag * v.x) * dt,
                .y = v.y + (config.gravity.y + config.drag * v.y) * dt,
                .z = v.z + (config.gravity.z + config.drag * v.z) * dt,
            };
            p.age += dt;
            if (config.isDead(p.age, &sim.kill_rng)) {
                data.spawn(&sim.rng, @intCast(p.seed % data.particles.len));
            }
        }
        // walk 2: r1 splat pass (no clear — the driver owns it).
        for (data.particles) |p| {
            r1.splatFast(fb, w, h, p.pos.x, p.pos.y, r1.lut[@intFromEnum(p.kind)]);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);
