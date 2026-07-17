// Stage 8: allocators & streaming — double-buffered compaction.
//
// P9: the allocator is part of the data pipeline.
//
// Stages 1–7 preallocate their particle storage once at init and reuse slots
// forever — the per-frame spawn/recycle path never touches the allocator. That
// is the right call for a fixed-N sim, but it hides the allocator: real systems
// have spawn churn (uneven births/deaths, variable alive counts), and a naive
// `allocator.alloc` per spawn destroys cache locality and adds lock/contention
// overhead. Stage 8 makes the allocator *visible* by restructuring the frame
// pipeline around it.
//
// The DOD transformation: **double-buffered streaming compaction.** Two SoA
// buffer sets (`a`, `b`); each frame reads from `front` and writes the
// compacted+spawned result to `back`, then swaps. The write to `back` is a
// *frame-local arena*: a preallocated region written sequentially (bump
// discipline — `write` only advances), "reset" by the swap. This is P9 read
// literally — the allocator (the bump-write discipline into `back`) is part of
// the data pipeline, not a separate concern bolted on afterward.
//
//   frame:  math(front)  →  age+alive(front)  →  compact front→back  →  spawn into back  →  swap
//
// Why the double-buffer is the "arena" winner (and not naive/freelist):
//   - **naive** (`alloc/free` per spawn): each spawn hits the general heap —
//     lock contention, cache pollution, O(log n) or worse. Catastrophic under
//     churn. Not implemented (it's the anti-pattern); the README documents it.
//   - **freelist** (dead slots reused by respawn): what stages 1–7 effectively
//     do (respawn in place). O(1) per spawn, cache-local. But it can't compact
//     — live particles stay scattered, and the branchy kill returns (stage 4's
//     target). Good for low churn; loses compaction's streaming density.
//   - **arena** (bump-allocate frame spawns, reset at frame end): O(1) per
//     spawn, cache-linear, no contention. The double-buffer IS this — `back`
//     is the arena, the swap is the reset, and compaction falls out for free
//     (live particles stream into the front of `back`, spawns fill the tail).
//   - **double-buffer** (= arena + compaction): the implemented strategy. The
//     compaction is a streaming copy `front→back` — a pure write stream into
//     `back` (no read-for-ownership: the cache line need not be loaded before
//     being written, because nothing reads `back` this frame). This is the
//     stage-4 compaction lesson, but with the RFO cost removed by writing to a
//     separate buffer. P5 (branchless) is preserved: `write += alive[i]`,
//     zero `if` in the compaction loop.
//
// BUILDS ON STAGE 7 (aligned SoA + @Vector(4) + padded). The math pass is
// unchanged (vectorized over the padded `front` length, no tail branch). The
// only structural change is the kill path: stage 7's branchy in-place respawn
// → stage 8's branchless streaming compaction into `back` + spawn + swap.
//
// HONEST OUTCOME (same pattern as stages 4/5 — a technique that lands
// structurally but isn't a time win at natural churn). The compaction pass is
// O(n) every frame: it reads all 8 hot streams from `front` and writes them to
// `back`, even though only ~1/120 of particles die per frame (the natural
// death rate at kill_age=2.0, dt=1/60). Stage 7's branchy respawn touches only
// the ~0.83% of dead particles. So stage 8 does MORE memory traffic than
// stage 7 (front read + back write ≈ 2× the hot-stream bytes) and is slower at
// large N (bandwidth-bound — the extra back-write stream saturates the memory
// bus). The win the double-buffer promises is under HIGH churn (50% die/frame):
// there, stage 7's branchy kill mispredicts heavily AND the freelist scatters
// live particles across a fragmented array, while the double-buffer's streaming
// compaction keeps `back` dense and branchless. The plan's 50%-churn regime
// requires a non-golden-checked adversarial mode (changing the death model
// breaks the golden file); the README documents this. At natural churn, the
// technique lands (compaction = streaming copy, no RFO; arena discipline) and
// is the prerequisite for stage 9's synthesis. The time win is deferred to the
// high-churn regime, exactly as P9 predicts.
//
// GOLDEN CHECK. The RNG draw sequence is preserved: compaction reads `front`
// in index order (no RNG), then spawn fills `back[live_count..n]` in slot
// order (RNG drawn in order). This is the same sequence as stage 4 — dead
// particles processed in index order, same count, same RNG draws. The spawned
// (kind, jitter, age) values are identical; only their slot assignment differs
// (compacted to the tail vs in-place). The sorted golden check tolerates the
// reordering. Golden PASS (max delta = 0.00).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const rast = @import("../../framework/render.zig");

// SIMD width: 4×f32 = 128-bit NEON (the M4's native lane count). Same as stage 6/7.
const W: usize = 4;
const V = @Vector(W, f32);

// Cache-line alignment: 128 B (the M4's hw.cachelinesize). Same as stage 7.
const LINE: std.mem.Alignment = .fromByteUnits(128);

/// One complete set of hot SoA streams — the per-particle state. Stage 8 holds
/// two of these (`a`, `b`) and swaps them each frame: `front` is read, `back`
/// is written (the frame-local arena). `life` is gone from storage (stage 4's
/// lesson — it was a constant); the kill check compares `age` against
/// `config.kill_age` directly.
const Streams = struct {
    pos_x: []align(128) f32,
    pos_y: []align(128) f32,
    pos_z: []align(128) f32,
    vel_x: []align(128) f32,
    vel_y: []align(128) f32,
    vel_z: []align(128) f32,
    age: []align(128) f32,
    kind: []align(128) fw.ParticleKind,
};

pub const Sim = struct {
    alloc: std.mem.Allocator,

    // The double buffer: two complete SoA stream sets. `front` is the current
    // read buffer (this frame's input); `back` is the write buffer (this
    // frame's output = next frame's input, after the swap). Both are 128 B-
    // aligned and padded to a multiple of W.
    a: Streams,
    b: Streams,
    front: *Streams,
    back: *Streams,

    // Branchless-compaction scratch: the alive mask, indexed by `front`. 1
    // byte/particle. Written once (alive-marking pass), read once (compaction).
    // Transient — not in dumpFields.
    alive: []u8,

    rng: std.Random.DefaultPrng,
    n: usize, // real particle count (snapshot/age/kill/render iterate [0..n])
    n_padded: usize, // padded count (math pass iterates [0..n_padded], no tail)

    pub fn init(alloc: std.mem.Allocator, desc: fw.Desc) anyerror!*@This() {
        const self = try alloc.create(@This());
        const n = desc.n;
        const n_padded = std.mem.alignForward(usize, n, W);

        const a = try allocStreams(alloc, n_padded);
        errdefer freeStreams(alloc, a);
        const b = try allocStreams(alloc, n_padded);
        errdefer freeStreams(alloc, b);
        const alive = try alloc.alloc(u8, n);
        errdefer alloc.free(alive);

        // Zero both buffers' guard regions [n..n_padded] so the vectorized math
        // pass (which processes the full padded length) operates on 0, not
        // garbage. The guard elements are never observed (snapshot/age/kill/
        // render iterate [0..n]); 0 keeps the FPU from producing NaN/inf.
        zeroGuard(a, n, n_padded);
        zeroGuard(b, n, n_padded);

        self.* = .{
            .alloc = alloc,
            .a = a,
            .b = b,
            .front = &self.a,
            .back = &self.b,
            .alive = alive,
            .rng = std.Random.DefaultPrng.init(desc.seed),
            .n = n,
            .n_padded = n_padded,
        };
        // Spawn the initial population into `front` (buffer a) in index order —
        // same RNG sequence as stages 1–7, so the initial state matches the
        // golden reference exactly.
        var i: usize = 0;
        while (i < n) : (i += 1) self.drawHotToStreams(self.front, i);
        return self;
    }

    pub fn step(self: *@This(), dt: f32) void {
        const f = self.front;
        const b = self.back;
        const al = self.alive;
        const n = self.n;
        const n_padded = self.n_padded;

        // 1. Integrate + forces, VECTORIZED over the FULL PADDED length of
        //    `front` (same as stage 7 — no tail branch; 128 B-aligned loads).
        //    Math is bit-identical to stages 1–7 for [0..n]; the guard region
        //    [n..n_padded] is processed but never observed.
        mathPassVec(f.pos_x, f.vel_x, n_padded, dt, config.gravity.x);
        mathPassVec(f.pos_y, f.vel_y, n_padded, dt, config.gravity.y);
        mathPassVec(f.pos_z, f.vel_z, n_padded, dt, config.gravity.z);

        // 2. Age + alive marking + dispatch — SCALAR over [0..n] on `front`.
        //    `alive[i] = @intFromBool(age < kill_age)` is branchless (P5,
        //    compare-to-register). The per-particle switch is the deliberate
        //    hot branch kept for consistency with stages 1–7 (removed in
        //    stage 9's synthesis). `life` is gone — the check compares against
        //    `config.kill_age` directly.
        for (0..n) |i| {
            f.age[i] += dt;
            al[i] = @intFromBool(f.age[i] < config.kill_age);
            _ = switch (f.kind[i]) {
                .smoke => {},
                .spark => {},
                .debris => {},
            };
        }

        // 3. Streaming compaction `front → back` (BRANCHLESS, P5). Live
        //    particles stream into the front of `back`; dead particles' copies
        //    are overwritten by the next live one (write doesn't advance). The
        //    write to `back` is a PURE WRITE STREAM — nothing reads `back` this
        //    frame, so the cache line is filled without a read-for-ownership
        //    (the stage-4 RFO cost is gone because the destination is a
        //    separate buffer). `write += alive[i]` is the branchless advance;
        //    every iteration does the same 8 reads + 8 writes, no `if`.
        //
        //    The write addresses are monotonically non-decreasing (write
        //    advances by 0 or 1) — the prefetcher tracks `back` as a single
        //    forward stream. Under natural churn (~0.83% dead) the wasted
        //    rewrites (consecutive dead → same slot overwritten) are negligible.
        var write: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            b.pos_x[write] = f.pos_x[i];
            b.pos_y[write] = f.pos_y[i];
            b.pos_z[write] = f.pos_z[i];
            b.vel_x[write] = f.vel_x[i];
            b.vel_y[write] = f.vel_y[i];
            b.vel_z[write] = f.vel_z[i];
            b.age[write] = f.age[i];
            b.kind[write] = f.kind[i];
            write += al[i];
        }
        const live_count = write;

        // 4. Spawn — fill `back[live_count..n]` with new particles drawn from
        //    the RNG. RNG drawn in slot order (live_count..n), same sequence as
        //    stage 4: dead particles processed in index order → same draws.
        //    N is maintained: `back` has exactly `n` particles after this.
        //    This is the "arena" discipline: spawns bump-allocate sequentially
        //    into the tail of `back`, O(1) per spawn, no heap call.
        var j: usize = live_count;
        while (j < n) : (j += 1) {
            self.drawHotToStreams(b, j);
        }

        // 5. Swap — `back` becomes next frame's `front`. O(1) (pointer swap,
        //    no data copy). This is the arena "reset": `back` (the old front,
        //    now stale) will be overwritten next frame, so no explicit free/reset.
        const tmp = self.front;
        self.front = self.back;
        self.back = tmp;
    }

    pub fn render(self: *const @This(), fb: []u8, w: u32, h: u32) void {
        const f = self.front;
        rast.clear(fb);
        const n = self.n;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const col = kindColor(f.kind[i]);
            rast.splat(fb, w, h, f.pos_x[i], f.pos_y[i], col.x, col.y, col.z);
        }
    }

    pub fn deinit(self: *@This()) void {
        freeStreams(self.alloc, self.a);
        freeStreams(self.alloc, self.b);
        self.alloc.free(self.alive);
        self.alloc.destroy(self);
    }

    /// Write n*6 floats (px,py,pz,vx,vy,vz) per particle for the golden check.
    /// Reads from `front` (the current observable state).
    pub fn snapshot(self: *const @This(), out: []f32) void {
        const f = self.front;
        const n = self.n;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i * 6 + 0] = f.pos_x[i];
            out[i * 6 + 1] = f.pos_y[i];
            out[i * 6 + 2] = f.pos_z[i];
            out[i * 6 + 3] = f.vel_x[i];
            out[i * 6 + 4] = f.vel_y[i];
            out[i * 6 + 5] = f.vel_z[i];
        }
    }

    /// Bytes per particle that step() touches each frame (the working-set cost).
    /// Stage 8's double-buffer doubles the resident working set: `front` (read,
    /// 29 B/p) + `back` (written, 29 B/p) + `alive` (1 B/p) = 59 B/p. The math
    /// pass reads+writes `front` (shared with stage 7); the compaction pass
    /// reads `front` (cache-resident from the math pass) and writes `back`
    /// (the new cost). The `back` write is a streaming store (no RFO), so the
    /// *bandwidth* cost is ~29 B/p read + 29 B/p write for the compaction,
    /// on top of stage 7's math traffic. This is why stage 8 is slower than
    /// stage 7 at large N (bandwidth-bound) — the double-buffer's compaction
    /// traffic is the cost, and the payoff (branchless kill, dense `back`)
    /// only outweighs it under high churn.
    pub fn bytesPerParticle(self: *const @This()) usize {
        _ = self;
        return 29 + 29 + 1; // front (read) + back (write) + alive
    }

    /// Dump the hot-loop fields' raw bytes as per-component SoA streams for the
    /// data-density audit. Dumps `front` (the current observable state), [0..n].
    /// Same 8 streams as stages 3–7 (life was already gone from stage 4's dump
    /// onward). The fingerprint matches stage 7 (same SoA layout); the density
    /// reflects the same real signal. The double-buffer doesn't change the data
    /// — only the frame pipeline (compaction + swap).
    pub fn dumpFields(self: *const @This(), alloc: std.mem.Allocator) ![]fw.FieldDump {
        const f = self.front;
        const n = self.n;
        const out = try alloc.alloc(fw.FieldDump, 8);
        out[0] = .{ .name = "pos.x", .bytes = try copyStream(f.pos_x, n, alloc) };
        out[1] = .{ .name = "pos.y", .bytes = try copyStream(f.pos_y, n, alloc) };
        out[2] = .{ .name = "pos.z", .bytes = try copyStream(f.pos_z, n, alloc) };
        out[3] = .{ .name = "vel.x", .bytes = try copyStream(f.vel_x, n, alloc) };
        out[4] = .{ .name = "vel.y", .bytes = try copyStream(f.vel_y, n, alloc) };
        out[5] = .{ .name = "vel.z", .bytes = try copyStream(f.vel_z, n, alloc) };
        out[6] = .{ .name = "age", .bytes = try copyStream(f.age, n, alloc) };
        out[7] = .{ .name = "kind", .bytes = try copyStream(f.kind, n, alloc) };
        return out;
    }

    /// Draw the hot fields from the shared RNG (kind, jitter_x, jitter_y, age —
    /// same order, same methods as stages 1–7) and write them into the given
    /// buffer set at index `i`. Used by init (writes `front`) and the spawn
    /// pass (writes `back`), so the RNG sequence stays synchronized and the
    /// math matches byte-for-byte. `life` is gone — it was a constant.
    fn drawHotToStreams(self: *@This(), s: *Streams, i: usize) void {
        const r = self.rng.random();
        const kind: fw.ParticleKind = @enumFromInt(r.intRangeAtMost(u8, 0, 2));
        const imp = config.impulse[@intFromEnum(kind)];
        const jitter_x = (r.float(f32) - 0.5) * 0.1;
        const jitter_y = (r.float(f32) - 0.5) * 0.1;
        s.pos_x[i] = 0;
        s.pos_y[i] = 0;
        s.pos_z[i] = 0;
        s.vel_x[i] = imp.x + jitter_x;
        s.vel_y[i] = imp.y + jitter_y;
        s.vel_z[i] = imp.z;
        s.age[i] = r.float(f32) * config.kill_age; // staggered spawn ages
        s.kind[i] = kind;
    }
};

/// Allocate one complete Streams set (8 aligned, padded SoA streams).
fn allocStreams(alloc: std.mem.Allocator, n_padded: usize) !Streams {
    return .{
        .pos_x = try alloc.alignedAlloc(f32, LINE, n_padded),
        .pos_y = try alloc.alignedAlloc(f32, LINE, n_padded),
        .pos_z = try alloc.alignedAlloc(f32, LINE, n_padded),
        .vel_x = try alloc.alignedAlloc(f32, LINE, n_padded),
        .vel_y = try alloc.alignedAlloc(f32, LINE, n_padded),
        .vel_z = try alloc.alignedAlloc(f32, LINE, n_padded),
        .age = try alloc.alignedAlloc(f32, LINE, n_padded),
        .kind = try alloc.alignedAlloc(fw.ParticleKind, LINE, n_padded),
    };
}

/// Free one Streams set.
fn freeStreams(alloc: std.mem.Allocator, s: Streams) void {
    alloc.free(s.pos_x);
    alloc.free(s.pos_y);
    alloc.free(s.pos_z);
    alloc.free(s.vel_x);
    alloc.free(s.vel_y);
    alloc.free(s.vel_z);
    alloc.free(s.age);
    alloc.free(s.kind);
}

/// Zero the guard region [n..n_padded] of all 8 streams (so the vectorized math
/// pass operates on 0, not uninitialized bits). Same as stage 7's init.
fn zeroGuard(s: Streams, n: usize, n_padded: usize) void {
    @memset(s.pos_x[n..n_padded], 0);
    @memset(s.pos_y[n..n_padded], 0);
    @memset(s.pos_z[n..n_padded], 0);
    @memset(s.vel_x[n..n_padded], 0);
    @memset(s.vel_y[n..n_padded], 0);
    @memset(s.vel_z[n..n_padded], 0);
    @memset(s.age[n..n_padded], 0);
    @memset(s.kind[n..n_padded], .smoke);
}

fn kindColor(k: fw.ParticleKind) fw.Vec4 {
    return switch (k) {
        .smoke => .{ .x = 120, .y = 120, .z = 120, .w = 1 }, // gray
        .spark => .{ .x = 255, .y = 180, .z = 60, .w = 1 }, // orange
        .debris => .{ .x = 100, .y = 200, .z = 255, .w = 1 }, // blue
    };
}

/// Copy a contiguous SoA stream's raw bytes [0..n] for the audit (same as
/// stages 3–7). Works with aligned slices (anytype).
fn copyStream(stream: anytype, n: usize, alloc: std.mem.Allocator) ![]u8 {
    const T = std.meta.Elem(@TypeOf(stream));
    const sz = @sizeOf(T);
    const out = try alloc.alloc(u8, n * sz);
    @memcpy(out, std.mem.sliceAsBytes(stream[0..n]));
    return out;
}

/// One component's integrate + forces pass, VECTORIZED over the full padded
/// length (NO scalar tail — same as stage 7). @Vector(4, f32) = 128-bit NEON;
/// each stream is 128 B-aligned, so every load starts on a cache line boundary.
///   pos[i..i+W] += vel[i..i+W] * dt                    (integrate, using OLD vel)
///   vel[i..i+W]  = old_vel + (g + drag*old_vel) * dt    (forces)
/// Math is bit-identical to stage 7 for [0..n].
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
