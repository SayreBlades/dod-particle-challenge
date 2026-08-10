// Algorithm ML01.AF01.LP1-unroll.LP2-simple — AF01 (math+decide+respawn | render),
// loop 1 unroll-by-4 branchy, loop 2 r0 splat.
//
// Fills the `unroll` schedule knob (declared in LoopSchedule but, until this
// cell, instantiated nowhere in ML01). Manual loop unrolling: the physics body
// is replicated 4× via `inline for`, so four particles are advanced per loop
// iteration. That amortizes branch/loop overhead and exposes four independent
// particle bodies to the out-of-order core (ILP) — the classic unrolling win.
//
// What it isolates. The per-particle math is byte-identical to the autovec
// cell (same ops, same FP order → bit-exact golden). The ONLY change from
// autovec is the loop structure: autovec lets LLVM pick the unroll factor
// (and vectorize); this cell commits to a source-level unroll of 4. So:
//   auto   → unroll   = does FORCING the unroll beat LLVM's chosen one?
//   scalar → unroll   = boxed-no-unroll-scalar vs forced-unroll (+ autovec).
// (Vectorization is left to the compiler here, exactly as in `auto` — the
//  orthogonal, boxed "unroll with the vectorizer pinned off" comparison is a
//  separate cell if we ever want that axis split; see the README note.)
//
// Golden: bit-exact. The respawn branch is per-particle and the loop preserves
// index order (i, i+1, i+2, i+3), so the shared spawn/kill RNG stream is
// consumed identically to autovec.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML01",
        .algo_fam = .AF01,
        .ordering = .identity,
        .intermediates = .none,
        .loops = &.{
            .{ .impl = .zig, .schedule = .unroll, .parallel = .none, .variant = .branchy },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "loop1 no (branchy respawn); loop2 n/a (render)",
    };

    /// Unroll factor. 4 mirrors the vw4 vector-width neighbor — "four-wide,
    /// either by scalar ILP (this cell) or by NEON lanes (vw4)."
    pub const UNROLL: usize = 4;

    /// One particle's math+decide+respawn (identical to the autovec body).
    /// Hoisted so the unrolled copy and the tail stay provably in sync.
    inline fn advanceOne(data: *Data, sim: anytype, i: usize, dt: f32) void {
        const p = &data.particles[i];
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
    }

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        const ps = data.particles;
        const n = ps.len;

        // loop 1: math + decide + respawn (branchy), unrolled by UNROLL.
        // `inline for` is the comptime unroll: the body is replicated UNROLL
        // times, advancing i, i+1, …, i+UNROLL-1 per iteration. Index order is
        // preserved, so the RNG stream matches autovec exactly.
        var i: usize = 0;
        const main = n - (n % UNROLL);
        while (i < main) : (i += UNROLL) {
            inline for (0..UNROLL) |k| {
                advanceOne(data, sim, i + k, dt);
            }
        }
        // tail: the final (n % UNROLL) particles, one at a time.
        while (i < n) : (i += 1) {
            advanceOne(data, sim, i, dt);
        }

        // loop 2: r0 splat pass (no clear — the driver owns it).
        for (ps) |p| {
            r0.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);
