// Stage 9: synthesis — the full DOD composition.
//
// P10: every move is independent and measurable; the final ratio is their
// product (aspirational — see the honest outcome below).
//
// Stage 9 composes the *time winners* from stages 2–8 into one Sim, and
// honestly documents where the plan's synthesis spec was followed, where the
// measured outcomes of the detour stages revise it, and why the detour
// techniques are excluded from the time-optimal composition.
//
// WHAT COMPOSES (the implemented synthesis — the time-optimal layout):
//   - Hot/cold split + per-component SoA streams (stages 2, 3). Only the hot
//     fields the update touches are stored per-particle; cold/render fields are
//     gone (color → kindColor lookup; size/rotation/mass/flags/seed removed).
//   - `life` removed from storage entirely (stage 4's lesson — it was a
//     constant, density 0.013; the kill check compares `age` against
//     `config.kill_age` directly).
//   - 128 B-aligned, padded-to-W SoA streams (stage 7). Every `@Vector(4)`
//     load starts on a cache-line boundary; the vectorized math pass is a
//     single tight loop with no scalar tail branch.
//   - @Vector(4, f32) math (stage 6). 128-bit NEON, the M4's native lane count
//     (stage 6's width sweep confirmed W=4 is the minimum; the plan's W=8 was
//     revised — wider vectors don't help because the backend can't retire
//     >128 bits/cycle). One NEON fma per step retires 4× the math of a scalar
//     fma. This is the throughput reward the SoA layout unlocked (P7).
//   - **Per-particle `switch(kind)` DELETED** (stage 5's lesson, without the
//     sort). Stage 5 measured that the switch was already compiler-optimized
//     away (empty cases — stage 4's PMC showed % Discarded ~0.5% *with* the
//     switch), and the sort's own 3-way branch was *worse* (stage 5's %
//     Discarded rose to 2–4.7%). Stage 9 achieves P6's de-virtualization by
//     simply deleting the dead branch — the free cleanup the structure wanted,
//     without the sort's O(n) overhead. (Stage 5's per-kind *streams* variant
//     (5b) was infeasible at N=64M — 3× memory blowup.)
//   - Branchy in-place respawn (the stage 7 / stages 1–3 kill model). At the
//     natural death rate (~1/120 per frame ≈ 0.83%), this touches only the
//     ~0.83% of dead particles — the time-optimal kill model for low churn.
//
// WHAT IS EXCLUDED (and why — the honest revision):
//   - **Stage 4's compaction, stage 5's sort, stage 8's double-buffer are
//     EXCLUDED from the time-optimal synthesis.** Each is an O(n) per-frame
//     pass (compaction reads+writes all 8 hot streams; sort does up to n
//     8-field swaps; double-buffer copies front→back). At the natural death
//     rate, stage 7's branchy respawn touches only the ~0.83% of dead
//     particles — vastly cheaper than an O(n) compaction. The plan's synthesis
//     spec lists "branchless double-buffer compaction (4+8)"; the measured
//     reality (documented in stage 8's README and reproduced below) is that the
//     double-buffer doubles the resident working set (front+back = 59 B/p vs
//     stage 7's 29 B/p) and is ~4–5× SLOWER than stage 7 at natural churn
//     (3.98 vs 0.88 ns/p at 1M). The compaction/sort/double-buffer techniques
//     are pedagogically essential (they teach P5, P6, P9) and their
//     *structural* transformations land (the audit proves the density changes),
//     but they are not time-win *compositions* at natural churn — they pay off
//     under high churn (50% die/frame), which the golden-checked natural-churn
//     sim doesn't exercise. Stage 9 composes the time winners; the README
//     records the full-composition experiment (stage 8's double-buffer) as a
//     measured regression for completeness.
//
// THE HONEST SYNTHESIS OUTCOME. The plan expected ~8–15× vs stage 1 at N=1M.
// The measured reality is ~1.6× at 1M, for two honest reasons:
//
//   1. **The bandwidth ceiling.** At N≥1M the sim is memory-bandwidth-bound
//      (stage 1's README established this: ~54 GB/s ceiling, flat ns/particle
//      from 1M→64M). Stage 9's hot loop walks 29 B/particle (same as stage 7 —
//      no compaction, so no front+back doubling). The bandwidth floor is
//      29 B/p ÷ 54 GB/s ≈ 0.54 ns/particle at large N. Stage 1 walks 68 B/p →
//      floor ~1.26 ns/p. So the *bandwidth-limited* speedup ceiling at large N
//      is 68/29 ≈ 2.3× — and stage 1's measured 1.46 ns/p at 1M is already
//      below its 68 B/p floor (cache effects lift it above the pure-bandwidth
//      floor), so the real large-N ratio is ~1.6×. The plan's 8–15× is
//      physically unreachable at 1M: 8× would be 0.18 ns/p = 161 B/p of
//      equivalent bandwidth at 29 B/p — ~3× the memory ceiling. The large-N
//      win was always going to be the byte-reduction ratio (68→29 ≈ 2.3×), not
//      8–15×.
//   2. **The detour stages don't compose into time wins** (see EXCLUDED above).
//      The product-of-ratios the plan predicted is ill-defined because stages
//      6/7 didn't build on 4/5 (they went back to stage 3's clean SoA), and
//      dominated by the <1 ratios of the detour stages (3, 4, 5, 8). The time
//      winners that DO compose (2, 3, 6, 7 + the switch/life cleanups) multiply
//      to the measured ~1.6× at 1M and ~1.2–1.6× across the sweep.
//
// WHAT STAGE 9 PROVES (the real synthesis lesson). The layout transformations
// that compose into a *time* win are the ones that cut bytes-per-particle or
// raise throughput without adding a per-frame O(n) pass: hot/cold split (2),
// SoA (3), SIMD (6), alignment (7), + the cleanup removals (life, switch).
// Stage 9 = those — it converges to stage 7's layout (the time-optimal
// composition) with the dead switch and dead `life` field removed. The
// compaction/sort/double-buffer techniques are structurally valuable (P5, P6,
// P9) but are regime-conditional (high churn), not unconditional time-win
// compositions. The cumulative speedup vs stage 1 is real and measurable
// (~1.6× at 1M, ~1.2–1.6× across the sweep); the plan's 8–15× was aspirational
// and bounded above by the memory bandwidth ceiling, which the honest analysis
// records. The synthesis's pedagogical value is showing which moves compose
// (byte-reduction + throughput) and which are regime-conditional detours
// (compaction/sort/allocator) — the data decides what's a winner.
//
// GOLDEN CHECK. Same as stage 6/7: the vectorized math is bit-identical for
// [0..n] (same FP ops, same per-particle order — W at a time). The guard region
// [n..n_padded] is processed by the vectorized passes but never observed
// (snapshot/age/kill/render iterate [0..n]). The RNG sequence is identical
// (branchy kill, same draw order as stages 1–3/6/7). The switch is deleted (it
// was a no-op — no effect on state or RNG). Golden PASS.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const rast = @import("../../framework/render.zig");

// SIMD width: 4×f32 = 128-bit NEON (stage 6's measured optimum; the plan's W=8
// was revised — wider vectors don't help on this backend).
const W: usize = 4;
const V = @Vector(W, f32);

// Cache-line alignment: 128 B (the M4's hw.cachelinesize). Same as stage 7/8.
const LINE: std.mem.Alignment = .fromByteUnits(128);

pub const Sim = struct {
    alloc: std.mem.Allocator,

    // Hot SoA streams — 128 B-aligned, padded to a multiple of W. `life` is
    // gone (stage 4 — it was a constant). 8 streams: pos×3, vel×3, age, kind.
    pos_x: []align(128) f32,
    pos_y: []align(128) f32,
    pos_z: []align(128) f32,
    vel_x: []align(128) f32,
    vel_y: []align(128) f32,
    vel_z: []align(128) f32,
    age: []align(128) f32,
    kind: []align(128) fw.ParticleKind,

    rng: std.Random.DefaultPrng,
    n: usize,
    n_padded: usize,

    pub fn init(alloc: std.mem.Allocator, desc: fw.Desc) anyerror!*@This() {
        const self = try alloc.create(@This());
        const n = desc.n;
        const n_padded = std.mem.alignForward(usize, n, W);

        const pos_x = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(pos_x);
        const pos_y = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(pos_y);
        const pos_z = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(pos_z);
        const vel_x = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(vel_x);
        const vel_y = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(vel_y);
        const vel_z = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(vel_z);
        const age = try alloc.alignedAlloc(f32, LINE, n_padded);
        errdefer alloc.free(age);
        const kind = try alloc.alignedAlloc(fw.ParticleKind, LINE, n_padded);
        errdefer alloc.free(kind);

        // Zero the guard region [n..n_padded] (same as stage 7).
        @memset(pos_x[n..n_padded], 0);
        @memset(pos_y[n..n_padded], 0);
        @memset(pos_z[n..n_padded], 0);
        @memset(vel_x[n..n_padded], 0);
        @memset(vel_y[n..n_padded], 0);
        @memset(vel_z[n..n_padded], 0);
        @memset(age[n..n_padded], 0);
        @memset(kind[n..n_padded], .smoke);

        self.* = .{
            .alloc = alloc,
            .pos_x = pos_x,
            .pos_y = pos_y,
            .pos_z = pos_z,
            .vel_x = vel_x,
            .vel_y = vel_y,
            .vel_z = vel_z,
            .age = age,
            .kind = kind,
            .rng = std.Random.DefaultPrng.init(desc.seed),
            .n = n,
            .n_padded = n_padded,
        };
        var i: usize = 0;
        while (i < n) : (i += 1) self.drawHotToStreams(i);
        return self;
    }

    pub fn step(self: *@This(), dt: f32) void {
        const px = self.pos_x; const py = self.pos_y; const pz = self.pos_z;
        const vx = self.vel_x; const vy = self.vel_y; const vz = self.vel_z;
        const ag = self.age;
        const n = self.n;
        const n_padded = self.n_padded;

        // 1. Integrate + forces, VECTORIZED over the full padded length (stage
        //    6/7 — no tail branch, 128 B-aligned loads). 3 per-component passes,
        //    each fusing integrate (pos += vel*dt) and forces (vel += (g+drag*vel)*dt)
        //    so `vel` is loaded once. Bit-identical math for [0..n].
        mathPassVec(px, vx, n_padded, dt, config.gravity.x);
        mathPassVec(py, vy, n_padded, dt, config.gravity.y);
        mathPassVec(pz, vz, n_padded, dt, config.gravity.z);

        // 2. Age + kill + respawn — SCALAR over [0..n]. The per-particle
        //    `switch(kind)` is DELETED (stage 5's lesson — it was a compiler-
        //    optimized-away no-op; deleting it is P6's de-virtualization without
        //    the sort's overhead). `life` is gone — compare `age` against
        //    `config.kill_age` directly (stage 4's lesson). Branchy in-place
        //    respawn: at the natural death rate (~0.83%), this touches only the
        //    dead particles — the time-optimal kill model for low churn (the
        //    regime this sim runs in). The compaction/sort/double-buffer
        //    techniques from stages 4/5/8 are excluded (they're O(n) every
        //    frame — see the README's full-composition experiment).
        var i: usize = 0;
        while (i < n) : (i += 1) {
            ag[i] += dt;
            if (ag[i] >= config.kill_age) {
                self.respawnHot(i);
            }
        }
    }

    pub fn render(self: *const @This(), fb: []u8, w: u32, h: u32) void {
        rast.clear(fb);
        const n = self.n;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const col = kindColor(self.kind[i]);
            rast.splat(fb, w, h, self.pos_x[i], self.pos_y[i], col.x, col.y, col.z);
        }
    }

    pub fn deinit(self: *@This()) void {
        self.alloc.free(self.pos_x);
        self.alloc.free(self.pos_y);
        self.alloc.free(self.pos_z);
        self.alloc.free(self.vel_x);
        self.alloc.free(self.vel_y);
        self.alloc.free(self.vel_z);
        self.alloc.free(self.age);
        self.alloc.free(self.kind);
        self.alloc.destroy(self);
    }

    /// Write n*6 floats (px,py,pz,vx,vy,vz) per particle for the golden check.
    pub fn snapshot(self: *const @This(), out: []f32) void {
        const n = self.n;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i * 6 + 0] = self.pos_x[i];
            out[i * 6 + 1] = self.pos_y[i];
            out[i * 6 + 2] = self.pos_z[i];
            out[i * 6 + 3] = self.vel_x[i];
            out[i * 6 + 4] = self.vel_y[i];
            out[i * 6 + 5] = self.vel_z[i];
        }
    }

    /// Bytes per particle that step() touches each frame. Same as stage 7
    /// (29 B/p): pos (12) + vel (12) + age (4) + kind (1). No compaction → no
    /// front+back doubling (unlike stage 8). `life` is gone (stage 4). The
    /// switch is deleted but `kind` is still stored (needed for render's color
    /// lookup) and read by render. Reported per real particle, same as stage 7.
    pub fn bytesPerParticle(self: *const @This()) usize {
        _ = self;
        return 12 + 12 + 4 + 1; // pos + vel + age + kind
    }

    /// Dump the hot-loop fields' raw bytes as per-component SoA streams for the
    /// data-density audit. Same 8 streams as stages 3–7 (life was already gone
    /// from stage 4's dump onward; the synthesis doesn't change the data, only
    /// the deleted switch). Dumps [0..n].
    pub fn dumpFields(self: *const @This(), alloc: std.mem.Allocator) ![]fw.FieldDump {
        const n = self.n;
        const out = try alloc.alloc(fw.FieldDump, 8);
        out[0] = .{ .name = "pos.x", .bytes = try copyStream(self.pos_x, n, alloc) };
        out[1] = .{ .name = "pos.y", .bytes = try copyStream(self.pos_y, n, alloc) };
        out[2] = .{ .name = "pos.z", .bytes = try copyStream(self.pos_z, n, alloc) };
        out[3] = .{ .name = "vel.x", .bytes = try copyStream(self.vel_x, n, alloc) };
        out[4] = .{ .name = "vel.y", .bytes = try copyStream(self.vel_y, n, alloc) };
        out[5] = .{ .name = "vel.z", .bytes = try copyStream(self.vel_z, n, alloc) };
        out[6] = .{ .name = "age", .bytes = try copyStream(self.age, n, alloc) };
        out[7] = .{ .name = "kind", .bytes = try copyStream(self.kind, n, alloc) };
        return out;
    }

    /// Draw the hot fields from the shared RNG and write them into the streams.
    /// Same RNG sequence as stages 1–7 → golden PASS. `life` is gone (stage 4);
    /// no cold to write (color → kindColor lookup in render).
    fn drawHotToStreams(self: *@This(), i: usize) void {
        const r = self.rng.random();
        const kind: fw.ParticleKind = @enumFromInt(r.intRangeAtMost(u8, 0, 2));
        const imp = config.impulse[@intFromEnum(kind)];
        const jitter_x = (r.float(f32) - 0.5) * 0.1;
        const jitter_y = (r.float(f32) - 0.5) * 0.1;
        self.pos_x[i] = 0;
        self.pos_y[i] = 0;
        self.pos_z[i] = 0;
        self.vel_x[i] = imp.x + jitter_x;
        self.vel_y[i] = imp.y + jitter_y;
        self.vel_z[i] = imp.z;
        self.age[i] = r.float(f32) * config.kill_age;
        self.kind[i] = kind;
    }

    fn respawnHot(self: *@This(), i: usize) void {
        self.drawHotToStreams(i);
    }
};

fn kindColor(k: fw.ParticleKind) fw.Vec4 {
    return switch (k) {
        .smoke => .{ .x = 120, .y = 120, .z = 120, .w = 1 }, // gray
        .spark => .{ .x = 255, .y = 180, .z = 60, .w = 1 }, // orange
        .debris => .{ .x = 100, .y = 200, .z = 255, .w = 1 }, // blue
    };
}

fn copyStream(stream: anytype, n: usize, alloc: std.mem.Allocator) ![]u8 {
    const T = std.meta.Elem(@TypeOf(stream));
    const sz = @sizeOf(T);
    const out = try alloc.alloc(u8, n * sz);
    @memcpy(out, std.mem.sliceAsBytes(stream[0..n]));
    return out;
}

/// One component's integrate + forces pass, VECTORIZED over the full padded
/// length (same as stage 6/7/8). Bit-identical math for [0..n].
fn mathPassVec(pos: []align(128) f32, vel: []align(128) f32, n_padded: usize, dt: f32, g: f32) void {
    const drag = config.drag;
    const vdt: V = @splat(dt);
    const vdrag: V = @splat(drag);
    const vg: V = @splat(g);

    var i: usize = 0;
    while (i < n_padded) : (i += W) {
        const pos_w: *[W]f32 = @ptrCast(&pos[i]);
        const vel_w: *[W]f32 = @ptrCast(&vel[i]);
        const o: V = vel_w.*;
        const p: V = pos_w.*;
        pos_w.* = p + o * vdt;
        vel_w.* = o + (vg + vdrag * o) * vdt;
    }
}
