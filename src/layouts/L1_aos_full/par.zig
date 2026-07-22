// Strategy L1.par — range-partitioned multicore on L1 storage
// (layout-verticals.md §4.3), base schedule = L1.naive.
//
// The two-phase golden discipline (the part that makes or breaks honesty):
//
//   Phase 1 (PARALLEL over ranges): integrate + forces + age + dead-flag +
//     the naive schedule's kind-switch and cold touches. No spawn RNG is
//     drawn here → bit-exact under any partition.
//   Phase 2 (SERIAL respawn): scan the dead mask in index order, respawning
//     from the single shared spawn RNG in exactly the serial strategy's
//     order. O(dead) ≈ 0.83% of N at natural churn (Amdahl is kind); under
//     -Ddeath=half it's 50% and the win must be re-read (that IS the
//     adversarial experiment).
//
// Golden claim: bit-exact at ANY worker count (respawn sequence identical to
// L1.naive). The bench runs the golden check at whatever --threads says —
// PASS at T=10 vs the T=1-generated golden IS the proof of this discipline.
//
// Chunking: ranges snap to 32 particles (32 × 68 B = 2176 B = exactly 17
// cache lines), so no line is split across workers (false sharing is a
// self-own). The dead mask adds 1 B/p (bytes/p 68 → 69) — the structural
// cost of two-phase, isolated by the T=1 row against plain L1.naive (the
// pool-overhead check).
//
// -Ddeath=half under parallel: each chunk draws kill decisions from a
// chunk-local RNG (kill_seed ^ chunk_lo) — deterministic per (T, chunk),
// independent of scheduling. Golden is skipped in that regime anyway.
//
// Hypothesis (old H-note): L1 has the highest serial ns/p of any layout, so
// its parallel crossover N should be the earliest — measured by the T-sweep.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const pool_mod = @import("../../framework/pool.zig");
const layout = @import("data.zig");

const Data = layout.Data;
const CHUNK_ALIGN: usize = 32; // chunk starts snap to 32 particles (17 lines)

const H = struct {
    pub const Extra = struct {
        dead: []u8, // parallel-phase kill flags; +1 B/p (see scratchBytes)
        pool: ?*pool_mod.Pool,
        kill_seed: u64, // base seed for per-chunk kill RNGs (-Ddeath=half)
        cur_dt: f32, // dt of the in-flight step, read by pool tasks
    };

    pub fn initExtra(sim: *Sim, desc: fw.Desc) !void {
        const dead = try sim.alloc.alloc(u8, desc.n);
        errdefer sim.alloc.free(dead);
        sim.extra = .{
            .dead = dead,
            .pool = if (sim.threads > 1) try pool_mod.Pool.create(sim.alloc, sim.threads) else null,
            .kill_seed = desc.seed ^ 0xDEAD_BEEF,
            .cur_dt = config.dt,
        };
    }

    pub fn deinitExtra(sim: *Sim) void {
        if (sim.extra.pool) |p| p.destroy(sim.alloc);
        sim.alloc.free(sim.extra.dead);
    }

    pub fn scratchBytes(sim: *const Sim) usize {
        _ = sim;
        return 1; // the dead mask, 1 B/p
    }

    pub fn step(sim: *Sim, dt: f32) void {
        sim.extra.cur_dt = dt;
        if (sim.extra.pool) |p| {
            p.run(sim, phase1Task);
        } else {
            phase1Range(sim, 0, sim.data.n);
        }
        phase2Respawn(sim);
    }

    /// Pool task: compute this worker's chunk and run phase 1 on it.
    fn phase1Task(ctx: *anyopaque, worker: usize, n_workers: usize) void {
        const sim: *Sim = @ptrCast(@alignCast(ctx));
        const n = sim.data.n;
        const chunk = std.mem.alignForward(usize, n / n_workers, CHUNK_ALIGN);
        const lo = worker * chunk;
        if (lo >= n) return; // more workers than chunks (tiny N)
        const hi = @min(n, lo + chunk);
        phase1Range(sim, lo, hi);
    }

    /// Phase 1 (PARALLEL): the naive schedule's per-particle work over
    /// [lo..hi), plus the dead flag. No spawn RNG drawn → bit-exact under
    /// any partition. The math expressions are L1.naive's verbatim (same
    /// order, same rounding).
    fn phase1Range(sim: *Sim, lo: usize, hi: usize) void {
        const data = &sim.data;
        const dead = sim.extra.dead;
        const dt = sim.extra.cur_dt;
        // Chunk-local kill RNG for -Ddeath=half: deterministic per (T, chunk),
        // independent of scheduling order. Never drawn in natural builds.
        var kr = std.Random.DefaultPrng.init(sim.extra.kill_seed ^ @as(u64, lo));

        var i: usize = lo;
        while (i < hi) : (i += 1) {
            const p = &data.particles[i];
            p.pos = p.pos.add(p.vel.scale(dt));
            const v = p.vel;
            p.vel = .{
                .x = v.x + (config.gravity.x + config.drag * v.x) * dt,
                .y = v.y + (config.gravity.y + config.drag * v.y) * dt,
                .z = v.z + (config.gravity.z + config.drag * v.z) * dt,
            };
            p.age += dt;
            dead[i] = @intFromBool(config.isDead(p.age, i, sim.frame, &kr));
            _ = switch (p.kind) {
                .smoke => {},
                .spark => {},
                .debris => {},
            };
            _ = p.mass;
            _ = p.flags;
            _ = p.seed;
        }
    }

    /// Phase 2 (SERIAL): respawn dead particles in INDEX ORDER — the spawn
    /// RNG draw sequence is identical to L1.naive's, so the sim is bit-exact
    /// at any worker count. The mask scan is BLOCK-WISE (32 B zero-skip):
    /// death is sparse at natural churn, so nearly every block reduces to
    /// zero and is skipped at vector speed; order is preserved exactly.
    fn phase2Respawn(sim: *Sim) void {
        const dead = sim.extra.dead;
        const n = sim.data.n;
        const B = 32;
        var i: usize = 0;
        while (i + B <= n) : (i += B) {
            const block: @Vector(B, u8) = dead[i..][0..B].*;
            if (@reduce(.Or, block) == 0) continue;
            var j: usize = i;
            while (j < i + B) : (j += 1) {
                if (dead[j] != 0) sim.data.spawn(&sim.rng, j);
            }
        }
        while (i < n) : (i += 1) {
            if (dead[i] != 0) sim.data.spawn(&sim.rng, i);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);
