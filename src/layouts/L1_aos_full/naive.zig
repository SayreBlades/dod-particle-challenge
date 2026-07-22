// Strategy L1.naive — the arc stage-1 schedule on L1 storage, verbatim.
//
// Branchy in-place respawn, the deliberate per-particle switch(kind) hot
// branch, and the cold-field touches (mass/flags/seed read every frame for
// nothing). Note the separation of concerns the verticals make explicit:
// those sins are the SCHEDULE's, not the layout's — the layout (data.zig) is
// just the full-field AoS array; this file is the naive way of walking it.
//
// Golden: bit-exact. This is the reference sim itself (= arc stage 1's code):
// bench mode generates golden/stage1.bin and golden/frame.sha256 from it.
// -Ddeath support: the kill test goes through config.isDead; in natural
// builds that prunes to the plain age test, zero cost, RNG untouched.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");

const Data = layout.Data;
const Particle = layout.Particle;

pub const H = struct {
    // `anytype` so render-variant strategies (naive_r1) can re-export this
    // step — each fw.Strategy instantiation is a distinct type.
    pub fn step(sim: anytype, dt: f32) void {
        const data = &sim.data;
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
            p.age += dt;

            // 4. Kill → respawn (in place; seed % len == i by construction)
            if (config.isDead(p.age, i, sim.frame, &sim.kill_rng)) {
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
};

pub const Sim = fw.Strategy(Data, H);

// Per-kind nudges (deliberate hot-loop dispatch — see above).
fn smokeNudge(p: *Particle) void {
    _ = p;
}
fn sparkNudge(p: *Particle) void {
    _ = p;
}
fn debrisNudge(p: *Particle) void {
    _ = p;
}
