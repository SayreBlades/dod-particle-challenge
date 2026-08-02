// Cell L1.B2.w1-autovec-par.w2-simple — B2 (math | decide+respawn | render),
// walk 1 data-parallel math, walk 2 serial decide+respawn, walk 3 r0 splat.
//
// Golden: bit-exact. Walk 1 (math) is per-particle independent → parallel with
// no coordination; walk 2 (decide+respawn) is serial (RNG-order). The seam
// re-read is still here (walk 2 re-reads age), just walk 1 is parallel.
// Diff vs B2.w1-autovec.w2-simple: walk-1 parallel = data_parallel.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const pool_mod = @import("../../framework/pool.zig");
const layout = @import("data.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;
const CHUNK_ALIGN: usize = 32;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1",
        .blueprint = .B2,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .data_parallel, .variant = .none },
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .branchy },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "walk1 yes; walk2 no (RNG-order); walk3 n/a",
    };

    pub const Extra = struct {
        pool: ?*pool_mod.Pool,
        cur_dt: f32,
    };

    pub fn initExtra(sim: anytype, _: fw.Desc) !void {
        sim.extra = .{
            .pool = if (sim.threads > 1) try pool_mod.Pool.create(sim.alloc, sim.threads) else null,
            .cur_dt = config.dt,
        };
    }

    pub fn deinitExtra(sim: anytype) void {
        if (sim.extra.pool) |p| p.destroy(sim.alloc);
    }

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        sim.extra.cur_dt = dt;
        // walk 1: parallel math (per-particle independent).
        if (sim.extra.pool) |p| {
            p.run(sim, phase1Task);
        } else {
            phase1Range(sim, 0, sim.data.n);
        }
        // walk 2: serial decide + respawn (RNG-order).
        for (sim.data.particles, 0..) |*p, i| {
            if (config.isDead(p.age, &sim.kill_rng)) sim.data.spawn(&sim.rng, i);
        }
        // walk 3: r0 splat pass.
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
        phase1Range(sim, lo, @min(n, lo + chunk));
    }

    fn phase1Range(sim: anytype, lo: usize, hi: usize) void {
        const data = &sim.data;
        const dt = sim.extra.cur_dt;
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
        }
    }
};

pub const Sim = fw.Strategy(Data, H);