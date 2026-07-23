// Strategy L1.naive_novec — L1.naive with auto-vectorization disabled.
//
// WHY this control exists: naive.zig's compiled step is secretly good code —
// LLVM SLP-vectorized the Vec3 math across components (one fmul.4s/fadd.4s
// for pos, 2-wide for vel). That muddies the halide_a comparison: is naive's
// edge "scalar is enough on AoS" or "LLVM vectorized the only way AoS
// allows"? This strategy pins every scalar intermediate behind a
// doNotOptimizeAway barrier, breaking SLP's pattern match, so the loop is
// TRULY scalar. Verified by disassembly (no q-register math in the loop —
// see README §5c), not assumed.
//
// The prediction this tests (README §5b): at DRAM-bound N, de-vectorized
// naive still beats halide_a — the gap there is two walks vs one
// (bandwidth), not vector width. The cache-resident band is where scalar
// should hurt.
//
// Golden: bit-exact. NEON fmul.s and fmul.4s lanes are both IEEE single —
// same ops, same order, same rounding; only the packing changes.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");

const Data = layout.Data;
const Particle = layout.Particle;

/// An OPAQUE identity: the value emerges from an asm output operand, so
/// the optimizer cannot prove it equals the input — SLP can't pack
/// producer or consumer chains across the box. (The naive
/// `doNotOptimizeAway(&x); return x;` form is input-only: dataflow stays
/// transparent and LLVM re-packs AFTER the barrier — measured: vel.x/y
/// still became fmul.2s before this fix.)
inline fn box(x: f32) f32 {
    return asm volatile (""
        : [ret] "=w" (-> f32)
        : [in] "w" (x)
    );
}

pub const H = struct {
    pub fn step(sim: *Sim, dt: f32) void {
        const data = &sim.data;
        for (data.particles, 0..) |*p, i| {
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
            if (config.isDead(p.age, i, sim.frame, &sim.kill_rng)) {
                data.spawn(&sim.rng, @intCast(p.seed % data.particles.len));
            }

            // Same nominal schedule as naive (DCE'd there, DCE'd here).
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
};

pub const Sim = fw.Strategy(Data, H);

fn smokeNudge(p: *Particle) void {
    _ = p;
}
fn sparkNudge(p: *Particle) void {
    _ = p;
}
fn debrisNudge(p: *Particle) void {
    _ = p;
}
