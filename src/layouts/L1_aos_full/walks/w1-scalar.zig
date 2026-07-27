// Walk 1 — scalar-forced step (B1 walk 1, branchy variant, de-vectorized).
//
// impl: zig, schedule: scalar, parallel: none, variant: branchy
//
// Same algorithm as w1-naive, but every scalar intermediate is boxed behind
// an opaque asm barrier, breaking LLVM SLP's pattern match so the loop is
// TRULY scalar (no q-register math). The de-vectorization control: isolates
// the schedule axis (auto → scalar) from the blueprint axis. Golden: bit-exact
// (NEON fmul.s and fmul.4s lanes are both IEEE single — same ops, same order).

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const config = @import("../../../framework/config.zig");
const layout = @import("../data.zig");

const Data = layout.Data;
const Particle = layout.Particle;

pub const decl: fw.WalkDecl = .{
    .impl = .zig,
    .schedule = .scalar,
    .parallel = .none,
    .variant = .branchy,
};

/// An OPAQUE identity: the value emerges from an asm output operand, so
/// the optimizer cannot prove it equals the input — SLP can't pack
/// producer or consumer chains across the box.
inline fn box(x: f32) f32 {
    return asm volatile (""
        : [ret] "=w" (-> f32)
        : [in] "w" (x)
    );
}

pub fn step(sim: anytype, dt: f32) void {
    const data = &sim.data;
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

        // 4. Kill → respawn (identical to naive)
        if (config.isDead(p.age, &sim.kill_rng)) {
            data.spawn(&sim.rng, @intCast(p.seed % data.particles.len));
        }

        _ = switch (p.kind) {
            .smoke => smokeNudge(p),
            .spark => sparkNudge(p),
            .debris => debrisNudge(p),
        };
        _ = p.mass;
        _ = p.flags;
        _ = p.seed;
    }
}

fn smokeNudge(p: *Particle) void {
    _ = p;
}
fn sparkNudge(p: *Particle) void {
    _ = p;
}
fn debrisNudge(p: *Particle) void {
    _ = p;
}
