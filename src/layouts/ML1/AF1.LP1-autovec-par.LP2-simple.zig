// Algorithm ML1.AF1.LP1-autovec-par.LP2-simple — AF1 (math+decide+respawn | render),
// loop 1 data-parallel, loop 2 r0 splat (serial).
//
// Golden: bit-exact. AF1 fuses math+decide+respawn into one loop, but
// parallelism splits it into two phases (the structural cost of parallel
// AF1): phase 1 (parallel) does math + decide → dead mask, NO spawn RNG
// drawn; phase 2 (serial) scans the dead mask in index order, respawning
// from the shared spawn RNG in exactly the serial algorithm's order —
// bit-exact at any worker count. The mask is parallel-scratch (1 B/p),
// not a declared intermediate (the algorithm family is still AF1, intermediates =
// none); the declaration's loop-1 parallel = data_parallel is what carries
// the two-phase structure. Diff vs AF3.LP1-autovec-par.LP2-rmerge: AF3's mask
// IS the declared intermediate (the algorithm family makes it first-class); here
// it's an implementation detail of parallelizing a fused loop.
//
// Self-contained (§8 rule 2). Scavenges the AF3-par pool discipline.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const pool_mod = @import("../../framework/pool.zig");
const layout = @import("data.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;
const CHUNK_ALIGN: usize = 32; // chunk starts snap to 32 particles (17 lines)

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML1",
        .algo_fam = .AF1,
        .ordering = .identity,
        .intermediates = .none,
        .loops = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .data_parallel, .variant = .branchy },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "loop1 no (branchy respawn); loop2 n/a",
    };

    pub const Extra = struct {
        dead: []u8, // parallel-phase kill flags (parallel-scratch, not a declared intermediate)
        pool: ?*pool_mod.Pool,
        kill_seed: u64,
        cur_dt: f32,
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
        return 1; // the dead mask, 1 B/p (parallel-scratch)
    }

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        sim.extra.cur_dt = dt;
        // loop 1 (parallel): math + decide → dead mask (no spawn RNG).
        if (sim.extra.pool) |p| {
            p.run(sim, phase1Task);
        } else {
            phase1Range(sim, 0, sim.data.n);
        }
        // loop 1 (serial tail): mask-scan + respawn in index order (bit-exact).
        phase2Respawn(sim);
        // loop 2: r0 splat pass (no clear — the driver owns it).
        for (sim.data.particles) |p| {
            r0.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }

    fn phase1Task(ctx: *anyopaque, worker: usize, n_workers: usize) void {
        const sim: *Sim = @ptrCast(@alignCast(ctx));
        const n = sim.data.n;
        const chunk = std.mem.alignForward(usize, n / n_workers, CHUNK_ALIGN);
        const lo = worker * chunk;
        if (lo >= n) return;
        const hi = @min(n, lo + chunk);
        phase1Range(sim, lo, hi);
    }

    fn phase1Range(sim: anytype, lo: usize, hi: usize) void {
        const data = &sim.data;
        const dead = sim.extra.dead;
        const dt = sim.extra.cur_dt;
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
            dead[i] = @intFromBool(config.isDead(p.age, &kr));
        }
    }

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