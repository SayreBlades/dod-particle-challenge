// Cell L1.B1.w1-blend-par.w2-simple — B1 (math+decide+respawn | render),
// walk 1 Zig branchless blend (data-parallel), walk 2 r0 splat (serial).
//
// Golden: statistical. The blend is per-particle independent (hash RNG over
// (i, frame) — no shared state), so walk 1 parallelizes trivially with no
// coordination: each worker blends its chunk, the result is identical to
// the serial blend at any worker count. Walk 2 (splat) is serial r0. Diff
// vs B1.w1-blend.w2-simple: walk-1 parallel = data_parallel.
//
// (A fully-parallel variant with render-reduce walk 2 would be a separate
// schedule variant; this cell's name encodes w2-simple = serial splat.)

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const config = @import("../../../framework/config.zig");
const pool_mod = @import("../../../framework/pool.zig");
const layout = @import("../data.zig");
const hash = @import("../hash_rng.zig");
const r0 = @import("../../common/render_simple.zig");

const Data = layout.Data;
const CHUNK_ALIGN: usize = 32;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B1,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .data_parallel, .variant = .blend },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .statistical,
        .halide_expressible = "walk1 yes; walk2 n/a",
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
        // walk 1: parallel branchless blend (per-particle independent).
        if (sim.extra.pool) |p| {
            p.run(sim, phase1Task);
        } else {
            phase1Range(sim, 0, sim.data.n);
        }
        // walk 2: serial r0 splat pass.
        r0.pass(fb, w, h, sim.data.particles);
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
        const frame = sim.frame;
        const q = config.q;
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
            const age_new = p.age + dt;
            p.age = age_new;
            var dead: bool = age_new >= config.kill_age;
            if (q > 0.0) {
                if (age_new < config.kill_age) {
                    dead = dead or (hash.killFloat(i, frame) < q);
                }
            }
            const r = hash.respawn(i, frame);
            const imp = config.impulse[r.kind];
            const col = layout.kindColor(@enumFromInt(r.kind));
            if (dead) {
                p.pos = .{ .x = 0, .y = 0, .z = 0 };
                p.vel = .{ .x = imp.x + r.jx, .y = imp.y + r.jy, .z = imp.z };
                p.age = r.age * config.kill_age;
                p.kind = @enumFromInt(r.kind);
                p.color = col;
                p.life = config.kill_age;
                p.seed = @intCast(i);
            }
        }
    }
};

pub const Sim = fw.Strategy(Data, H);