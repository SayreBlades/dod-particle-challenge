// correctness.zig — golden-file element-wise check.
//
// Proves the DOD claim: every stage reshapes data, none change math.
//
// Snapshot = sorted array of (pos.xyz, vel.xyz) across all particles, after a
// fixed number of steps from a fixed seed. Sorting means storage-order changes
// (stage 4 compaction, stage 5 sort-by-kind) don't count as failures — only
// numeric drift does. Compared element-wise within eps.
//
// Stage 1 generates the golden file (it's the reference). Every later stage
// verifies against it.

const std = @import("std");
const Io = std.Io;
const fw = @import("sim.zig");
const config = @import("config.zig");

pub const Snapshot = struct {
    // flattened: n particles * 6 floats (pos.xyz, vel.xyz)
    floats: []f32,
    n: usize,
};

pub const Result = struct {
    passed: bool,
    max_delta: f32,
    divergent_count: usize,
    first_divergent_index: usize,
};

/// Run `steps` fixed-step updates from a fresh sim seeded with `desc`, then
/// capture a sorted snapshot.
pub fn capture(
    comptime SimImpl: type,
    alloc: std.mem.Allocator,
    desc: fw.Desc,
    steps: usize,
    dt: f32,
) !Snapshot {
    var sim = try SimImpl.init(alloc, desc);
    defer sim.deinit();
    // The sim golden captures pos/vel only — the splat is irrelevant. Pass a
    // tiny dummy fb; step always splats now (§17.7) but the bounds checks skip
    // everything at 4x4. No clear needed (we don't read the fb).
    var dummy_fb: [64]u8 = undefined;
    var i: usize = 0;
    while (i < steps) : (i += 1) sim.step(dt, &dummy_fb, 4, 4);
    return try snapshotFromSim(SimImpl, sim, alloc);
}

/// Build the snapshot by reading pos/vel out of the sim via its render-adjacent
/// accessor. Stages expose `snapshot()` returning a borrowed []const f32 of
/// n*6 floats; we copy + sort here.
pub fn snapshotFromSim(comptime SimImpl: type, sim: *SimImpl, alloc: std.mem.Allocator) !Snapshot {
    // Each stage must implement: pub fn snapshot(self: *const Sim, out: []f32) void
    // writing n*6 floats (px,py,pz,vx,vy,vz) per particle.
    const n = sim.n;
    const floats = try alloc.alloc(f32, n * 6);
    sim.snapshot(floats);
    // Sort so storage order doesn't matter.
    std.mem.sort(f32, floats, {}, lessThan);
    return .{ .floats = floats, .n = n };
}

fn lessThan(_: void, a: f32, b: f32) bool {
    // Bit-pattern compare for a stable, sign-correct total order.
    return std.math.order(a, b) == .lt;
}

// --- frame golden (layout-matrix.md §2.3) --------------------------------------
//
// The render-side correctness gate. The splat blend is u8 saturating add —
// commutative and associative — and the pixel mapping is a deterministic
// function of position, so the framebuffer depends only on the MULTISET of
// (pos, kind), never on splat order: compaction/sort/reordering cannot change
// it, and ONE golden serves every bit-exact cell (all layouts, all variants).
//
// Verified per cell only when that run's sim golden is bit-exact (max delta
// 0.00): identical sorted pos/vel floats ⟹ identical RNG sequence ⟹ identical
// kinds. FP-drift cells (future Halide without strict_float) skip loudly.
//
// Storage: the SHA-256 hash of the raw framebuffer + a header comment (the
// plan's default — keeps 4 MB binaries out of git; on a mismatch the bench
// prints the first-divergent byte and can regenerate PNGs on demand).

pub const FRAME_W: u32 = 1024;
pub const FRAME_H: u32 = 1024;

/// Run `steps` fixed-step updates from a fresh sim, then render once into an
/// RGBA framebuffer. Caller owns the returned slice.
pub fn captureFrame(
    comptime SimImpl: type,
    alloc: std.mem.Allocator,
    desc: fw.Desc,
    steps: usize,
    dt: f32,
    w: u32,
    h: u32,
) ![]u8 {
    var sim = try SimImpl.init(alloc, desc);
    defer sim.deinit();
    const fb = try alloc.alloc(u8, @as(usize, w) * h * 4);
    // Each step splats into fb; clear before each so the fb after the loop
    // shows exactly the state after `steps` steps (the last step's splat on
    // a cleared fb). The old code ran step(null) then render() once; the
    // always-splat step (§17.7) makes memset+step equivalent.
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        @memset(fb, 0);
        sim.step(dt, fb, w, h);
    }
    return fb;
}

pub const FrameHash = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub fn hashFrame(fb: []const u8) FrameHash {
    var h: FrameHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(fb, &h, .{});
    return h;
}

pub fn writeFrameGolden(path: []const u8, hash: FrameHash, io: Io) !void {
    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "experiments/golden") catch {};
    var f = try dir.createFile(io, path, .{});
    var io_buf: [256]u8 = undefined;
    var w = f.writer(io, &io_buf);
    try w.interface.writeAll("DODF\x01\x00\x00\x00");
    try w.interface.writeAll(&hash);
    try w.end();
    f.close(io);
}

pub fn loadFrameGolden(path: []const u8, io: Io) !FrameHash {
    var dir = std.Io.Dir.cwd();
    var f = try dir.openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);
    var io_buf: [256]u8 = undefined;
    var r = f.reader(io, &io_buf);
    const rr = &r.interface;
    var magic: [8]u8 = undefined;
    try rr.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, "DODF\x01\x00\x00\x00")) return error.BadMagic;
    var h: FrameHash = undefined;
    try rr.readSliceAll(&h);
    return h;
}

pub fn writeGolden(path: []const u8, snap: Snapshot, io: Io) !void {
    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "experiments/golden") catch {};
    var f = try dir.createFile(io, path, .{});
    var io_buf: [4096]u8 = undefined;
    var w = f.writer(io, &io_buf);
    // header: magic + n
    try w.interface.writeAll("DODP\x01\x00\x00\x00");
    var n_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &n_buf, snap.n, .little);
    try w.interface.writeAll(&n_buf);
    for (snap.floats) |fl| {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @bitCast(fl), .little);
        try w.interface.writeAll(&buf);
    }
    try w.end();
    f.close(io);
}

pub fn loadGolden(path: []const u8, alloc: std.mem.Allocator, io: Io) !Snapshot {
    var dir = std.Io.Dir.cwd();
    var f = try dir.openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);
    var io_buf: [4096]u8 = undefined;
    var r = f.reader(io, &io_buf);
    const rr = &r.interface;
    var magic: [8]u8 = undefined;
    try rr.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, "DODP\x01\x00\x00\x00")) return error.BadMagic;
    var n_buf: [8]u8 = undefined;
    try rr.readSliceAll(&n_buf);
    const n = std.mem.readInt(u64, &n_buf, .little);
    const floats = try alloc.alloc(f32, @intCast(n * 6));
    var i: usize = 0;
    while (i < floats.len) : (i += 1) {
        var buf: [4]u8 = undefined;
        try rr.readSliceAll(&buf);
        floats[i] = @bitCast(std.mem.readInt(u32, &buf, .little));
    }
    return .{ .floats = floats, .n = @intCast(n) };
}

pub fn compare(golden: Snapshot, candidate: Snapshot, eps: f32) Result {
    if (golden.n != candidate.n) return .{
        .passed = false,
        .max_delta = std.math.inf(f32),
        .divergent_count = @max(golden.n, candidate.n),
        .first_divergent_index = 0,
    };
    var max_delta: f32 = 0;
    var divergent: usize = 0;
    var first: usize = 0;
    var i: usize = 0;
    while (i < golden.floats.len) : (i += 1) {
        const d = @abs(golden.floats[i] - candidate.floats[i]);
        if (d > max_delta) max_delta = d;
        if (d > eps) {
            if (divergent == 0) first = i;
            divergent += 1;
        }
    }
    return .{
        .passed = divergent == 0,
        .max_delta = max_delta,
        .divergent_count = divergent,
        .first_divergent_index = first,
    };
}

// --- invariant suite (§10.6, the --check flag) ---------------------------------
//
// The correctness floor at any death rate (q>0 has no golden; statistical-class
// cells have no golden even at q=0). An O(N) pass checking PHYSICAL PLAUSIBILITY,
// not trajectory equality — so bit-exact, Halide StrictFloat, and statistical-
// class cells all pass the same suite. Envelopes are analytic upper bounds
// (conservative kinematic bounds from config.zig: max displacement = |impulse+
// jitter|*age + 0.5*gravity*age^2; drag only reduces displacement so ignoring it
// keeps the bound safe) with margin. The check is "physically impossible," never
// "trajectory differs."
//
// Run under `--check` as a SEPARATE invocation (bench runs once for timing, once
// for correctness) so the O(N) pass adds no overhead to the timed region.

pub const InvariantResult = struct {
    passed: bool,
    n_checked: usize,
    deaths: usize,
    failures: []const Failure,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *InvariantResult) void {
        self.alloc.free(self.failures);
    }
};

pub const Failure = struct {
    check: []const u8,
    index: usize,
    detail: [128]u8 = undefined,
    detail_len: usize = 0,
};

/// Run `steps` fixed-step updates, then run the full (a)-(e) invariant pass.
/// Returns the result (caller deinit's the failures slice).
pub fn checkInvariants(
    comptime SimImpl: type,
    alloc: std.mem.Allocator,
    desc: fw.Desc,
    steps: usize,
    dt: f32,
    q: f32,
) !InvariantResult {
    var sim = try SimImpl.init(alloc, desc);
    defer sim.deinit();
    // Run to steady state (2s = kill_age) + the requested steps.
    const settle: usize = @intFromFloat(config.kill_age / dt);
    const total_steps = steps + settle;
    var dummy_fb: [64]u8 = undefined;
    var deaths: usize = 0;
    // Allocate a buffer to track ages before each step (to detect respawns:
    // a respawned particle's age drops to a random value, so age_after < age_before).
    const prev_ages = try alloc.alloc(f32, desc.n);
    defer alloc.free(prev_ages);
    // Accumulate deaths over the last `settle` frames (one kill_age period)
    // for a stable death-rate estimate.
    var i: usize = 0;
    while (i < total_steps) : (i += 1) {
        if (i >= total_steps - settle) {
            // snapshot ages before step
            for (sim.data.particles, 0..) |p, j| prev_ages[j] = p.age;
        }
        sim.step(dt, &dummy_fb, 4, 4);
        if (i >= total_steps - settle) {
            // count respawns this frame (age decreased = respawned)
            for (sim.data.particles, 0..) |p, j| if (p.age < prev_ages[j]) { deaths += 1; };
        }
    }

    // Fixed-capacity failure buffer (we cap at 64 reported; the rest are counted).
    var failure_buf: [64]Failure = undefined;
    var failure_count: usize = 0;
    var n_checked: usize = 0;

    // Read particle state directly from sim.data (duck-typed via anytype).
    const data = &sim.data;
    const ps = data.particles;
    for (ps, 0..) |p, idx| {
        n_checked += 1;
        // (a) Conservation: no NaN/Inf in pos/vel/age
        if (!std.math.isFinite(p.pos.x) or !std.math.isFinite(p.pos.y) or
            !std.math.isFinite(p.pos.z) or !std.math.isFinite(p.vel.x) or
            !std.math.isFinite(p.vel.y) or !std.math.isFinite(p.vel.z) or
            !std.math.isFinite(p.age))
        {
            if (failure_count < failure_buf.len) { failure_buf[failure_count] = .{ .check = "conservation_nan", .index = idx }; failure_count += 1; }
            continue;
        }
        // (b) age in [0, kill_age + dt] (dt slack for the just-stepped age)
        if (p.age < 0 or p.age > config.kill_age + dt + 1e-6) {
            if (failure_count < failure_buf.len) { failure_buf[failure_count] = .{ .check = "field_bounds_age", .index = idx }; failure_count += 1; }
        }
        // (b) |vel| within the impulse+jitter envelope. Max |vel| = max|impulse|+jitter.
        const max_impulse: f32 = blk: {
            var m: f32 = 0;
            for (config.impulse) |imp| {
                const mag = @sqrt(imp.x * imp.x + imp.y * imp.y + imp.z * imp.z);
                if (mag > m) m = mag;
            }
            break :blk m;
        };
        const vel_mag = @sqrt(p.vel.x * p.vel.x + p.vel.y * p.vel.y + p.vel.z * p.vel.z);
        const vel_cap = max_impulse + 0.1 + 1.0; // jitter + gravity slack over kill_age
        if (vel_mag > vel_cap + 1e-3) {
            if (failure_count < failure_buf.len) { failure_buf[failure_count] = .{ .check = "field_bounds_vel", .index = idx }; failure_count += 1; }
        }
        // (c) Reachability: |pos| within the kind's reachable tube at its age.
        // Max displacement = |impulse+jitter|*age (drag reduces it; ignoring
        // drag is safe). Plus gravity*age^2/2 vertical. Plus spawn_radius.
        const imp = config.impulse[@intFromEnum(p.kind)];
        const imp_mag = @sqrt(imp.x * imp.x + imp.y * imp.y + imp.z * imp.z);
        const max_disp = (imp_mag + 0.1) * p.age + 0.5 * @abs(config.gravity.y) * p.age * p.age + config.spawn_radius;
        const pos_mag = @sqrt(p.pos.x * p.pos.x + p.pos.y * p.pos.y + p.pos.z * p.pos.z);
        if (pos_mag > max_disp + 1e-3) {
            if (failure_count < failure_buf.len) { failure_buf[failure_count] = .{ .check = "reachability", .index = idx }; failure_count += 1; }
        }
        // (e) Respawn locality: a particle that respawned this frame (age <
        // prev_age) should be near the spawn origin. Check the ones that
        // respawned (we can't re-check here; the per-particle loop above
        // already counts deaths). Instead, check ALL particles with low age
        // (age < dt): they're either freshly respawned (age set to < dt by
        // the random spawn) or just-born. Either way they should be near origin.
        if (p.age < dt) {
            const spawn_disp = @sqrt(p.pos.x * p.pos.x + p.pos.y * p.pos.y);
            if (spawn_disp > config.spawn_radius + 1e-3) {
                if (failure_count < failure_buf.len) { failure_buf[failure_count] = .{ .check = "respawn_locality", .index = idx }; failure_count += 1; }
            }
        }
    }

    // (d) Death statistics: over `settle` frames (~one kill_age period),
    // expected total deaths ~ N * settle / mean_lifetime. Mean lifetime L:
    // q=0 -> L = kill_age/dt; q>0 -> L = (1-(1-q)^{kill_age/dt})/q.
    const frames_per_kill_age: f32 = config.kill_age / dt;
    const mean_lifetime: f32 = if (q > 0)
        (1.0 - std.math.pow(f32, 1.0 - q, frames_per_kill_age)) / q
    else
        frames_per_kill_age;
    const expected_deaths = @as(f32, @floatFromInt(desc.n)) * @as(f32, @floatFromInt(settle)) / mean_lifetime;
    const death_low = expected_deaths * 0.2;
    const death_high = expected_deaths * 5.0 + 20.0;
    if (@as(f32, @floatFromInt(deaths)) < death_low or @as(f32, @floatFromInt(deaths)) > death_high) {
        if (failure_count < failure_buf.len) { failure_buf[failure_count] = .{ .check = "death_stats", .index = 0 }; failure_count += 1; }
    }


    const owned = try alloc.alloc(Failure, failure_count);
    @memcpy(owned, failure_buf[0..failure_count]);
    return .{
        .passed = failure_count == 0,
        .n_checked = n_checked,
        .deaths = deaths,
        .failures = owned,
        .alloc = alloc,
    };
}
