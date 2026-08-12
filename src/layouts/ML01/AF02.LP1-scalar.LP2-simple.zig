// Algorithm ML01.AF02.LP1-scalar.LP2-simple — AF02 (math+decide+respawn | render),
// loop 1 scalar branchy, loop 2 r0 splat.
//
// Golden: bit-exact. Same algorithm as LP2-simple but every scalar intermediate
// is boxed behind an opaque asm barrier, breaking LLVM SLP's pattern match so
// the loop is TRULY scalar (no q-register math). The de-vectorization control:
// isolates the schedule axis (auto → scalar) from the algorithm family axis.
// (NEON fmul.s and fmul.4s lanes are both IEEE single — same ops, same order.)

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const r0 = @import("../common/render_simple.zig");
const devec = @import("../common/devec.zig");

const Data = layout.Data;
// Scalar de-vec barrier (opaque identity through a SIMD register), shared from
// layouts/common/devec.zig. Aliased locally so the dense math in step() stays
// readable — `box(x)` is a no-op at runtime, purely an optimization barrier.
const box = devec.box;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML01",
        .algo_fam = .AF02,
        .ordering = .identity,
        .intermediates = .none,
        .loops = &.{
            .{ .impl = .zig, .schedule = .scalar, .parallel = .none, .variant = .branchy },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "loop1 no (branchy respawn, de-vec control); loop2 n/a",
    };

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // loop 1: math + decide + respawn (branchy, scalar-forced)
        for (data.particles) |*p| {
            // 1. Integrate: pos += vel * dt — inputs AND results boxed.
            p.pos.x = box(box(p.pos.x) + box(p.vel.x) * dt);
            p.pos.y = box(box(p.pos.y) + box(p.vel.y) * dt);
            p.pos.z = box(box(p.pos.z) + box(p.vel.z) * dt);

            // 2. Forces: vel += (gravity + drag*vel) * dt
            const vx = box(p.vel.x);
            const vy = box(p.vel.y);
            const vz = box(p.vel.z);
            p.vel.x = box(vx + (config.gravity.x + config.drag * vx) * dt);
            p.vel.y = box(vy + (config.gravity.y + config.drag * vy) * dt);
            p.vel.z = box(vz + (config.gravity.z + config.drag * vz) * dt);

            // 3. Age
            p.age = box(p.age) + dt;

            // 4. Kill → respawn (identical to autovec)
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
