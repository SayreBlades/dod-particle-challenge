// Algorithm ML01.AF06.LP1-autovec-par.LP2-list-rmerge — AF06 (math+decide→list | respawn-dead-only | render),
// loop 1 data-parallel, loop 2 ranked-merge, loop 3 r0 splat.
//
// Golden: bit-exact. Parallel AF06: loop 1 (math + decide → per-chunk dead
// lists) is data-parallel; loop 2 is a ranked-merge — concatenate the
// per-chunk lists in chunk order (rank order = serial index order = serial
// RNG order), then respawn each. The list intermediate makes loop 2
// O(dead) work, parallelizable across chunks. Zig-only (irregular append,
// §5). Diff vs AF06.LP1-autovec-par.LP2-mask-rmerge: list vs mask.
//
// Self-contained (§8 rule 2). Scavenges the pool discipline.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const pool_mod = @import("../../framework/pool.zig");
const layout = @import("data.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;
const CHUNK_ALIGN: usize = 32;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML01",
        .algo_fam = .AF06,
        .ordering = .identity,
        .intermediates = .list,
        .loops = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .data_parallel, .variant = .none },
            .{ .impl = .zig, .schedule = .auto, .parallel = .ranked_merge, .variant = .ordered },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "no (irregular append)",
    };

    pub const Extra = struct {
        dead: []u32, // flattened per-chunk dead lists (cap N)
        // per-worker (lo, count) into `dead`; the ranked-merge concatenates in worker order.
        wlo: [64]usize = undefined,
        wcnt: [64]usize = undefined,
        pool: ?*pool_mod.Pool,
        kill_seed: u64,
        cur_dt: f32,
    };

    pub fn initExtra(sim: anytype, desc: fw.Desc) !void {
        sim.extra = .{
            .dead = try sim.alloc.alloc(u32, desc.n),
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
        return 4; // the dead list, 4 B/p worst case
    }

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        sim.extra.cur_dt = dt;
        // loop 1 (parallel): math + decide → per-chunk dead lists into `dead`,
        // each worker writing into dead[lo..lo+count) (disjoint regions keyed
        // by chunk-lo; dead is cap N so regions never overlap).
        if (sim.extra.pool) |p| {
            p.run(sim, phase1Task);
        } else {
            sim.extra.wlo[0] = 0;
            sim.extra.wcnt[0] = phase1Range(sim, 0, sim.data.n, 0);
        }
        const nw: usize = if (sim.extra.pool != null) sim.threads else 1;
        // loop 2: ranked-merge respawn — loop the per-chunk lists in worker
        // order (worker 0..nw-1 = index order), reading dead[wlo[w]..wlo[w]+wcnt[w]).
        // Worker order = index order = serial RNG order (bit-exact).
        var wi: usize = 0;
        while (wi < nw) : (wi += 1) {
            const lo = sim.extra.wlo[wi];
            const cnt = sim.extra.wcnt[wi];
            var k: usize = 0;
            while (k < cnt) : (k += 1) {
                sim.data.spawn(&sim.rng, sim.extra.dead[lo + k]);
            }
        }
        // loop 3: r0 splat pass.
        for (sim.data.particles) |p| {
            r0.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }

    fn phase1Task(ctx: *anyopaque, worker: usize, n_workers: usize) void {
        const sim: *Sim = @ptrCast(@alignCast(ctx));
        const n = sim.data.n;
        const chunk = std.mem.alignForward(usize, n / n_workers, CHUNK_ALIGN);
        const lo = worker * chunk;
        if (lo >= n) {
            sim.extra.wlo[worker] = lo;
            sim.extra.wcnt[worker] = 0;
            return;
        }
        const hi = @min(n, lo + chunk);
        sim.extra.wlo[worker] = lo;
        sim.extra.wcnt[worker] = phase1Range(sim, lo, hi, lo);
    }

    /// Returns the dead count for this range; writes dead indices into
    /// dead[base..base+count). Uses base = lo so each worker's region is
    /// disjoint (dead is cap N, and lo partitions [0,n)).
    fn phase1Range(sim: anytype, lo: usize, hi: usize, base: usize) usize {
        const data = &sim.data;
        const dead = sim.extra.dead;
        const dt = sim.extra.cur_dt;
        var kr = std.Random.DefaultPrng.init(sim.extra.kill_seed ^ @as(u64, lo));
        var k: usize = 0;
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
            if (config.isDead(p.age, &kr)) {
                dead[base + k] = @intCast(i);
                k += 1;
            }
        }
        return k;
    }
};

pub const Sim = fw.Strategy(Data, H);