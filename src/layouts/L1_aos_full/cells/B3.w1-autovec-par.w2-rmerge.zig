// Cell L1.B3.w1-autovec-par.w2-rmerge — B3 (math+decide→mask | mask-scan+respawn | render),
// walk 1 data-parallel, walk 2 ranked-merge (serial scan = degenerate T=1), walk 3 serial.
//
// Golden: bit-exact. The two-phase discipline: phase 1 (parallel) does math +
// decide → dead mask, no spawn RNG drawn → bit-exact under any partition.
// Phase 2 (serial respawn) scans the dead mask in index order, respawning
// from the shared spawn RNG in exactly the serial strategy's order.
//
// The DE-RISK cell (Phase 0.5.3): validates pool.zig with the current Strategy
// harness before the parallel pattern replicates across B1/B2/B4. The serial
// respawn is the bit-exact floor; true parallel ranked-merge (parallel count →
// prefix sum → parallel respawn-by-rank) is a future schedule variant that
// parallelizes the O(dead) respawn work — the mask structure already enables it.
//
// Chunking: ranges snap to 32 particles (32 × 68 B = 2176 B = exactly 17 cache
// lines), so no line is split across workers. The dead mask adds 1 B/p
// (bytes/p 68 → 69) — the structural cost of two-phase, isolated by the T=1
// row against plain B1.w1-autovec.w2-simple (the pool-overhead check).
//
// -Ddeath=q under parallel: each chunk draws kill decisions from a chunk-local
// RNG (kill_seed ^ chunk_lo) — deterministic per (T, chunk), independent of
// scheduling. The spawn RNG stays shared + serial (bit-exact).

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const config = @import("../../../framework/config.zig");
const pool_mod = @import("../../../framework/pool.zig");
const layout = @import("../data.zig");
const r0 = @import("../../common/render_simple.zig");

const Data = layout.Data;
const CHUNK_ALIGN: usize = 32; // chunk starts snap to 32 particles (17 lines)

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B3,
        .ordering = .identity,
        .intermediates = .mask,
        .walks = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .data_parallel, .variant = .none },
            .{ .impl = .zig, .schedule = .auto, .parallel = .ranked_merge, .variant = .ordered },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "walk1 yes (math+decide→mask); walk2 no (host scan); walk3 n/a",
    };

    pub const Extra = struct {
        dead: []u8, // parallel-phase kill flags; +1 B/p
        pool: ?*pool_mod.Pool,
        kill_seed: u64, // base seed for per-chunk kill RNGs
        cur_dt: f32, // dt of the in-flight step, read by pool tasks
    };

    pub fn initExtra(sim: anytype, desc: fw.Desc) !void {
        const dead = try sim.alloc.alloc(u8, desc.n);
        errdefer sim.alloc.free(dead);
        sim.extra = .{
            .dead = dead,
            .pool = if (sim.threads > 1) try pool_mod.Pool.create(sim.alloc, sim.threads) else null,
            .kill_seed = desc.seed ^ 0xDEAD_BEEF,
            .cur_dt = config.dt,
        };
    }

    pub fn deinitExtra(sim: anytype) void {
        if (sim.extra.pool) |p| p.destroy(sim.alloc);
        sim.alloc.free(sim.extra.dead);
    }

    pub fn scratchBytes(sim: *const Sim) usize {
        _ = sim;
        return 1; // the dead mask, 1 B/p
    }

    /// B3 step: walk 1 (parallel math+decide→mask), walk 2 (serial mask-scan+
    /// respawn), walk 3 (serial splat). Always splats (§17.7).
    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        sim.extra.cur_dt = dt;
        // walk 1: parallel math + decide → dead mask (no spawn RNG).
        if (sim.extra.pool) |p| {
            p.run(sim, phase1Task);
        } else {
            phase1Range(sim, 0, sim.data.n);
        }
        // walk 2: serial mask-scan + respawn (index order = serial RNG order).
        phase2Respawn(sim);
        // walk 3: r0 splat pass (no clear — the driver owns it).
        r0.pass(fb, w, h, sim.data.particles);
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

    /// Phase 1 (PARALLEL): math + decide → dead mask over [lo..hi).
    /// No spawn RNG drawn → bit-exact under any partition.
    fn phase1Range(sim: anytype, lo: usize, hi: usize) void {
        const data = &sim.data;
        const dead = sim.extra.dead;
        const dt = sim.extra.cur_dt;
        // Chunk-local kill RNG for q>0: deterministic per (T, chunk).
        var kr = std.Random.DefaultPrng.init(sim.extra.kill_seed ^ @as(u64, lo));

        var i: usize = lo;
        while (i < hi) : (i += 1) {
            const p = &data.particles[i];
            // math: integrate + forces + age (identical to B1.w1-autovec).
            p.pos = p.pos.add(p.vel.scale(dt));
            const v = p.vel;
            p.vel = .{
                .x = v.x + (config.gravity.x + config.drag * v.x) * dt,
                .y = v.y + (config.gravity.y + config.drag * v.y) * dt,
                .z = v.z + (config.gravity.z + config.drag * v.z) * dt,
            };
            p.age += dt;
            // decide → dead mask
            dead[i] = @intFromBool(config.isDead(p.age, &kr));
        }
    }

    /// Phase 2 (SERIAL): scan dead mask in index order, respawn from shared
    /// spawn RNG. The RNG draw sequence is identical to B1.w1-autovec's, so
    /// the sim is bit-exact at any worker count. Block-wise zero-skip (32 B
    /// blocks): death is sparse at natural churn, so nearly every block
    /// reduces to zero and is skipped at vector speed.
    fn phase2Respawn(sim: anytype) void {
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
