// Walk 1 — naive branchy step (B1 walk 1, branchy variant).
//
// impl: zig, schedule: auto, parallel: none, variant: branchy
//
// The reference step: math + decide + respawn fused in one per-particle loop,
// with a branchy respawn (rarely-taken, predicted at natural churn). The
// auto-vectorization here is LLVM SLP across x/y/z components — the thing
// w1-scalar exists to disable. Golden-critical: respawns draw from the shared
// spawn RNG in index order, so the sim is bit-exact against the reference.

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const config = @import("../../../framework/config.zig");
const layout = @import("../data.zig");

const Data = layout.Data;
const Particle = layout.Particle;

pub const decl: fw.WalkDecl = .{
    .impl = .zig,
    .schedule = .auto,
    .parallel = .none,
    .variant = .branchy,
};

/// `sim: anytype` so any B1 cell can compose this walk (each
/// fw.Strategy instantiation is a distinct type; duck-typing on the fields
/// the Strategy helper guarantees: data, rng, kill_rng, frame).
pub fn step(sim: anytype, dt: f32) void {
    const data = &sim.data;
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

        // Deliberate hot branch: per-particle dispatch (a schedule sin —
        // de-virtualization strategies on richer layouts remove this).
        _ = switch (p.kind) {
            .smoke => smokeNudge(p),
            .spark => sparkNudge(p),
            .debris => debrisNudge(p),
        };

        // Cold fields touched every frame (the strawman's other sin).
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
