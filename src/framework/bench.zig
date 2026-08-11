// bench driver: headless, no window, no raylib. A single-point timing primitive
// — it measures ONE (N, q, threads, trial) and emits one JSONL row. Python
// (collect.py / bench.py) owns the grid; this binary does no sweeping and has
// no default grid. Required timing args have no defaults on purpose, so a bare
// invocation errors instead of silently running some hidden sweep.
//
// Also serves three non-timing modes (each early-outs):
//   --check      the invariant suite (PASS/FAIL) at one (q, threads)
//   --bandwidth  the single-core streaming-BW microbench (the report ceiling)
//   --record <d> headless fixed-step render → ffmpeg
//
// Timing model (one point):
//   - warmup: WARMUP_DEFAULT (or --warmup) steps to prime caches/predictors/DVFS.
//   - timed region: --iters steps, timed with Io.Timestamp (.awake).
//   - one row: ns_frame = elapsed/iters, ns_particle = ns_frame/N.
// Repeated trials are the caller's job (pass --trial to label each row); the
// report takes the min per (q, N, threads) at load time.

const std = @import("std");
const Io = std.Io;
const fw = @import("sim.zig");
const config = @import("config.zig");
const hardware = @import("hardware.zig");
const correctness = @import("correctness.zig");

const WARMUP_DEFAULT: usize = 5;
const GOLDEN_STEPS: usize = 600;
const GOLDEN_N: usize = 1024;
const EPS: f32 = 1e-4;
const GOLDEN_PATH = "experiments/golden/stage1.bin";
// The framebuffer dimensions used by the bench timing + record mode.
const RENDER_W: u32 = 1024;
const RENDER_H: u32 = 1024;
const RENDER_SETTLE_STEPS: usize = 120; // 2s = kill_age -> steady-state spread
const FRAME_GOLDEN_PATH = "experiments/golden/frame.sha256";

pub fn run(comptime SimImpl: type, init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    // --- arg parse (no defaults for the timing grid; caller supplies everything) ---
    var n_opt: ?usize = null;
    var q_opt: ?f64 = null;
    var threads_opt: ?usize = null;
    var iters_opt: ?usize = null;
    var trial_opt: ?usize = null;
    var warmup: usize = WARMUP_DEFAULT;
    var run_id: []const u8 = "";
    var ts_utc: []const u8 = "";
    var json_mode = false;
    var check_mode = false;
    var bandwidth_mode = false;
    var record_dir: ?[]const u8 = null;
    var show_help = false;
    {
        var it_opt: ?std.process.Args.Iterator = std.process.Args.Iterator.initAllocator(init.minimal.args, alloc) catch null;
        if (it_opt) |*it| {
            defer it.deinit();
            _ = it.next(); // skip program name
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--n") or std.mem.eql(u8, arg, "-N")) {
                    if (it.next()) |val| n_opt = std.fmt.parseInt(usize, val, 10) catch null;
                } else if (std.mem.eql(u8, arg, "--q") or std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--death")) {
                    if (it.next()) |val| q_opt = std.fmt.parseFloat(f64, val) catch null;
                } else if (std.mem.eql(u8, arg, "--threads")) {
                    if (it.next()) |val| threads_opt = std.fmt.parseInt(usize, val, 10) catch null;
                } else if (std.mem.eql(u8, arg, "--iters")) {
                    if (it.next()) |val| iters_opt = std.fmt.parseInt(usize, val, 10) catch null;
                } else if (std.mem.eql(u8, arg, "--trial")) {
                    if (it.next()) |val| trial_opt = std.fmt.parseInt(usize, val, 10) catch null;
                } else if (std.mem.eql(u8, arg, "--warmup")) {
                    if (it.next()) |val| warmup = std.fmt.parseInt(usize, val, 10) catch WARMUP_DEFAULT;
                } else if (std.mem.eql(u8, arg, "--run-id")) {
                    if (it.next()) |val| run_id = val;
                } else if (std.mem.eql(u8, arg, "--ts-utc")) {
                    if (it.next()) |val| ts_utc = val;
                } else if (std.mem.eql(u8, arg, "--json")) {
                    // One JSONL row for the one timed point, prefixed `json,`.
                    // collect.py / bench.py grep `^json,` and strip the prefix.
                    json_mode = true;
                } else if (std.mem.eql(u8, arg, "--check")) {
                    check_mode = true;
                } else if (std.mem.eql(u8, arg, "--bandwidth")) {
                    // Streaming-bandwidth microbench (refactor §6.4): a tight
                    // single-threaded streaming-write loop over a buffer > LLC,
                    // timed. Prints `streaming_bw_gbs=<GB/s>` to stdout and exits.
                    // hardware_json.py reads this — the real ceiling, not an estimate.
                    bandwidth_mode = true;
                } else if (std.mem.eql(u8, arg, "--record")) {
                    // `--record <dir>` exports a headless video; default out/record.
                    record_dir = it.next() orelse "out/record";
                } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    show_help = true;
                }
                // Unknown args are ignored (transition tolerance); the caller
                // owns the grid, so stray flags are silently dropped.
            }
        }
    }

    if (show_help) {
        printUsage(SimImpl);
        return;
    }

    // --- hardware block (cheap: in-process sysctlbyname, no subprocess) ---
    const facts = hardware.detect();
    hardware.print(facts);

    // --- algorithm meta (§8): print every axis on every run, never silent ---
    const manifest = @import("manifest.zig");
    if (SimImpl.algo_meta) |cd| {
        manifest.printAlgoHeader(@import("options").name, cd);
    } else {
        std.debug.print("=== Algorithm ===\n\n  name: {s}\n  (pending — algo_meta not declared)\n\n", .{@import("options").name});
    }

    // --- streaming-bandwidth microbench (--bandwidth): early-out, no sim ---
    if (bandwidth_mode) {
        try runBandwidthMicrobench(io, alloc);
        return;
    }

    // --- invariant suite (--check): early-out (requires q + threads) ---
    if (check_mode) {
        const qv = q_opt orelse {
            printUsage(SimImpl);
            std.debug.print("\nerror: --check requires --q\n", .{});
            return error.MissingArgument;
        };
        const threads = threads_opt orelse {
            printUsage(SimImpl);
            std.debug.print("\nerror: --check requires --threads\n", .{});
            return error.MissingArgument;
        };
        try applyDeath(qv);
        const death_q = config.q;
        std.debug.print("=== Invariant suite (--check, q={d:.2}) ===\n\n", .{death_q});
        var inv = correctness.checkInvariants(SimImpl, alloc, .{ .n = 1024, .seed = config.spawn_seed, .threads = threads }, 600, config.dt, death_q) catch |e| {
            std.debug.print("  ERROR: invariant suite failed to run: {t}\n", .{e});
            return e;
        };
        defer inv.deinit();
        if (inv.passed) {
            std.debug.print("  PASS (checked {d} particles, {d} deaths this frame)\n", .{ inv.n_checked, inv.deaths });
        } else {
            std.debug.print("  FAIL ({d} failures):\n", .{inv.failures.len});
            for (inv.failures[0..@min(inv.failures.len, 10)]) |f| {
                std.debug.print("    [{d}] {s}\n", .{ f.index, f.check });
            }
        }
        std.debug.print("checked={s}\n", .{if (inv.passed) "PASS" else "FAIL"});
        return;
    }

    // --- timing or record path: both need q + threads ---
    const qv = q_opt orelse {
        printUsage(SimImpl);
        std.debug.print("\nerror: --q is required\n", .{});
        return error.MissingArgument;
    };
    const threads = threads_opt orelse {
        printUsage(SimImpl);
        std.debug.print("\nerror: --threads is required\n", .{});
        return error.MissingArgument;
    };
    try applyDeath(qv);
    const death_q = config.q;

    // --- correctness / golden gate (dev-time; only at q=0 natural death) ---
    // q=0 is outside the report sweep (EXCLUDE_DEATH_Q), so this fires only on a
    // manual `--q 0` invocation. Preserved from the pre-refactor binary.
    const is_reference = @import("options").is_reference;
    const death_natural = death_q == 0.0;
    if (!death_natural) {
        std.debug.print("=== Correctness: SKIPPED (death q={d} — churn regime, golden N/A; invariants via --check) ===\n\n", .{death_q});
        std.debug.print("=== Frame golden: SKIPPED (death q={d}) ===\n\n", .{death_q});
    }
    if (death_natural) {
        if (is_reference) {
            std.debug.print("=== Correctness: generating golden file ===\n", .{});
            const snap = try correctness.capture(SimImpl, alloc, .{ .n = GOLDEN_N, .seed = config.spawn_seed, .threads = threads }, GOLDEN_STEPS, config.dt);
            defer alloc.free(snap.floats);
            try correctness.writeGolden(GOLDEN_PATH, snap, io);
            std.debug.print("  wrote {s} (n={d}, steps={d})\n\n", .{ GOLDEN_PATH, snap.n, GOLDEN_STEPS });
        }

        // Golden class (§8.2): statistical-class cells diverge from
        // stage1.bin by design — skipped loudly, never silently.
        const golden_statistical = comptime @hasDecl(SimImpl, "golden_class") and
            SimImpl.golden_class == .statistical;
        if (golden_statistical) {
            std.debug.print("=== Correctness: SKIPPED (statistical golden class — different RNG model by design; distributional, not trajectory, equivalence) ===\n\n", .{});
        }
        // verify (every cell, including the reference self-check after generating)
        var sim_bit_exact = false;
        if (!golden_statistical) {
            const golden = try correctness.loadGolden(GOLDEN_PATH, alloc, io);
            defer alloc.free(golden.floats);
            const cand = try correctness.capture(SimImpl, alloc, .{ .n = GOLDEN_N, .seed = config.spawn_seed, .threads = threads }, GOLDEN_STEPS, config.dt);
            defer alloc.free(cand.floats);
            const r = correctness.compare(golden, cand, EPS);
            sim_bit_exact = (r.max_delta == 0);
            if (r.passed) {
                std.debug.print("=== Correctness: PASS (max delta = {d:.2}) ===\n\n", .{r.max_delta});
            } else {
                std.debug.print("=== Correctness: FAIL ===\n", .{});
                std.debug.print("  {d} floats diverge (max delta = {d:.2}, first at index {d})\n\n", .{ r.divergent_count, r.max_delta, r.first_divergent_index });
            }
        }

        // --- frame golden (layout-matrix.md §2.3): the render-side gate. One
        // golden serves every bit-exact cell (splat order-independence, proof
        // in correctness.zig). Verified only when the sim golden was bit-exact
        // this run; FP-drift cells skip loudly, never silently.
        {
            const fb = try correctness.captureFrame(SimImpl, alloc, .{ .n = GOLDEN_N, .seed = config.spawn_seed, .threads = threads }, GOLDEN_STEPS, config.dt, correctness.FRAME_W, correctness.FRAME_H);
            defer alloc.free(fb);
            const h = correctness.hashFrame(fb);
            const hex = std.fmt.bytesToHex(h, .lower);
            // Render-semantics class (matrix §2.3): cells whose stored color
            // is write-once diverge from the reference's current-kind color
            // by design (arc-documented cosmetic optimization). Skipped
            // loudly, never silently.
            const stale_cold = comptime @hasDecl(SimImpl, "render_color_semantics") and
                SimImpl.render_color_semantics == .stale_cold;
            if (is_reference) {
                try correctness.writeFrameGolden(FRAME_GOLDEN_PATH, h, io);
                std.debug.print("=== Frame golden: generated {s} (sha256 {s}) ===\n\n", .{ FRAME_GOLDEN_PATH, hex });
            }
            if (golden_statistical) {
                std.debug.print("=== Frame golden: SKIPPED (statistical golden class) ===\n\n", .{});
            } else if (stale_cold) {
                std.debug.print("=== Frame golden: SKIPPED (stale-cold render semantics — respawn keeps the previous life's color; arc-documented cosmetic divergence the sim golden can't see) ===\n\n", .{});
            } else if (!sim_bit_exact) {
                std.debug.print("=== Frame golden: SKIPPED (sim golden not bit-exact this run — FP-drift class) ===\n\n", .{});
            } else {
                const want = try correctness.loadFrameGolden(FRAME_GOLDEN_PATH, io);
                if (std.mem.eql(u8, &h, &want)) {
                    std.debug.print("=== Frame golden: PASS (framebuffer identical) ===\n\n", .{});
                } else {
                    std.debug.print("=== Frame golden: FAIL ===\n", .{});
                    std.debug.print("  got  {s}\n  want {s}\n\n", .{ hex, std.fmt.bytesToHex(want, .lower) });
                }
            }
        }
    }

    // --- record mode (--record <dir>): headless fixed-step render -> ffmpeg.
    // Runs AFTER the golden check above: the math is proven before the video.
    if (record_dir) |dir| {
        try recordVideo(SimImpl, alloc, io, dir, threads);
        return;
    }

    // --- benchmark: ONE point. Remaining required args (no defaults). ---
    const n = n_opt orelse {
        printUsage(SimImpl);
        std.debug.print("\nerror: --n is required\n", .{});
        return error.MissingArgument;
    };
    const iters = iters_opt orelse {
        printUsage(SimImpl);
        std.debug.print("\nerror: --iters is required\n", .{});
        return error.MissingArgument;
    };
    const trial = trial_opt orelse {
        printUsage(SimImpl);
        std.debug.print("\nerror: --trial is required\n", .{});
        return error.MissingArgument;
    };

    const fb = try alloc.alloc(u8, @as(usize, RENDER_W) * RENDER_H * 4);
    defer alloc.free(fb);
    var sim = SimImpl.init(alloc, .{ .n = n, .seed = config.spawn_seed, .threads = threads }) catch |e| {
        std.debug.print("  init failed: {t}\n", .{e});
        return e;
    };
    defer sim.deinit();
    const bytes_per_p = sim.bytesPerParticle();

    // warmup (step always splats; clear so the fb doesn't saturate).
    @memset(fb, 0);
    var w: usize = 0;
    while (w < warmup) : (w += 1) sim.step(config.dt, fb, RENDER_W, RENDER_H);

    // timed region: ITERS steps, timed with .awake (wall + CPU). The clear is
    // ONCE before the timed loop so the region is purely math + splat.
    @memset(fb, 0);
    const t0 = Io.Timestamp.now(io, .awake);
    var it: usize = 0;
    while (it < iters) : (it += 1) sim.step(config.dt, fb, RENDER_W, RENDER_H);
    const t1 = Io.Timestamp.now(io, .awake);
    const trial_ns: f64 = @floatFromInt(t0.durationTo(t1).nanoseconds);
    const ns_frame: f64 = trial_ns / @as(f64, @floatFromInt(iters));
    const ns_particle: f64 = ns_frame / @as(f64, @floatFromInt(n));
    // bytes/ns = GB/s directly (1 GB = 1e9 B, 1 s = 1e9 ns, the 1e9 cancels).
    const achieved_bw_gbs: f64 = @as(f64, @floatFromInt(bytes_per_p * n)) / ns_frame;

    const working_set_mb: f64 = @as(f64, @floatFromInt(@as(u64, n) * bytes_per_p)) / (1024.0 * 1024.0);
    std.debug.print("=== Benchmark (single point) ===\n", .{});
    std.debug.print("  N={d}  bytes/p={d}  mem={d:.1} MB  q={d}  threads={d}  trial={d}  iters={d}  warmup={d}\n", .{ n, bytes_per_p, working_set_mb, death_q, threads, trial, iters, warmup });
    std.debug.print("  ns/frame={d:.1}  ns/particle={d:.4}  achieved={d:.2} GB/s\n", .{ ns_frame, ns_particle, achieved_bw_gbs });

    if (json_mode) {
        emitJsonRow(SimImpl, .{
            .n = n,
            .threads = threads,
            .trial = trial,
            .iters = iters,
            .warmup = warmup,
            .bytes_per_p = bytes_per_p,
            .ns_frame = ns_frame,
            .ns_particle = ns_particle,
            .trial_ns = trial_ns,
        }, run_id, ts_utc);
    }
}

/// Validate + apply the runtime death rate. Errors on out-of-range q.
fn applyDeath(qv: f64) !void {
    if (!std.math.isFinite(qv) or qv < 0.0 or qv >= 1.0) {
        std.debug.print("error: invalid --q={d} (expect 0 <= q < 1)\n", .{qv});
        return error.InvalidArgument;
    }
    config.setDeathRate(@floatCast(qv));
}

fn printUsage(comptime SimImpl: type) void {
    const manifest = @import("manifest.zig");
    std.debug.print("Usage: {s} <mode> --q <q> --threads <T> [timing args]\n\n", .{@import("options").name});
    if (SimImpl.algo_meta) |cd|
        manifest.printAlgoHeader(@import("options").name, cd);
    std.debug.print(
        \\Measures ONE point — there is no default sweep; the caller owns the grid.
        \\
        \\Required for timing: --n, --q, --threads, --iters, --trial.
        \\Required for --check / --record: --q, --threads. (--bandwidth: none.)
        \\
        \\Options:
        \\  -q, --death <q>     per-frame accident rate (0 = natural/golden)
        \\  -N, --n <N>         particle count (timing)
        \\      --iters <K>     timed frames (timing)
        \\      --trial <T>     trial index — labels the JSONL row (timing)
        \\      --warmup <K>    warmup frames (default 5; timing)
        \\      --threads <T>   worker count
        \\      --json          emit one JSONL timing row (prefix `json,`)
        \\      --check         invariant suite only (PASS/FAIL), then exit
        \\      --bandwidth     streaming-BW microbench, then exit
        \\      --record <dir>  headless render -> ffmpeg
        \\  -h, --help          this message
        \\
    , .{});
}

// --- record mode (stage 11, --record <dir>) ----------------------------------------

const RECORD_N: usize = 65_000; // play mode's DEFAULT_N — visual parity
const RECORD_STEPS: usize = 600; // fixed steps, fixed dt -> deterministic replay
const RECORD_FPS: u32 = 30; // capture every 2nd step: 300 frames = 10 s

/// Headless video export (P12: determinism enables replay). Runs the sim for
/// RECORD_STEPS fixed steps, renders every 2nd step into an RGBA framebuffer,
/// and pipes the raw frames straight into ffmpeg's stdin to encode
/// <dir>/video.mp4 (30 fps x 300 frames = 10 s at 1024^2 -- the acceptance
/// spec). No image library: raw RGBA over a pipe is ffmpeg's native input.
/// Deterministic: same seed + same dt => byte-identical frames => byte-identical
/// video across runs.
fn recordVideo(comptime SimImpl: type, alloc: std.mem.Allocator, io: Io, out_dir: []const u8, threads: usize) !void {
    const video_path = try std.fmt.allocPrint(alloc, "{s}/video.mp4", .{out_dir});
    defer alloc.free(video_path);

    var dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, out_dir);

    std.debug.print("=== Record: {s} ===\n", .{@import("options").label});
    std.debug.print("  sim: N={d}, seed=0x{X}, {d} steps @ dt={d:.6}\n", .{ RECORD_N, config.spawn_seed, RECORD_STEPS, config.dt });
    std.debug.print("  capture: every 2nd step -> {d} frames @ {d} fps = {d:.1} s at {d}x{d} (raw RGBA -> ffmpeg)\n\n", .{
        RECORD_STEPS / 2, RECORD_FPS, @as(f64, RECORD_STEPS / 2) / @as(f64, RECORD_FPS), RENDER_W, RENDER_H,
    });

    var sim = try SimImpl.init(alloc, .{ .n = RECORD_N, .seed = config.spawn_seed, .threads = threads });
    defer sim.deinit();

    const fb = try alloc.alloc(u8, @as(usize, RENDER_W) * RENDER_H * 4);
    defer alloc.free(fb);

    // ffmpeg reads raw RGBA frames from stdin. yuv420p for player compatibility
    // (1024x1024 is even -- valid for 4:2:0). crf 18 = visually lossless.
    // +faststart for web playback. stderr -> /dev/null (progress spam);
    // failures surface via the exit code + output-file check.
    const size_arg = try std.fmt.allocPrint(alloc, "{d}x{d}", .{ RENDER_W, RENDER_H });
    defer alloc.free(size_arg);
    var child = std.process.spawn(io, .{
        .argv = &.{
            "ffmpeg", "-y",
            "-f", "rawvideo",
            "-pixel_format", "rgba",
            "-video_size", size_arg,
            "-framerate", "30",
            "-i", "-",
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-crf", "18",
            "-movflags", "+faststart",
            video_path,
        },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| {
        std.debug.print("  ERROR: failed to spawn ffmpeg ({t}). Is ffmpeg on PATH?\n", .{e});
        return e;
    };
    defer child.kill(io);
    const stdin_file = child.stdin orelse return error.NoStdinPipe;

    // Settle to steady state before capturing: init places every particle at
    // the origin (maximally overlapped, unrepresentative). Running
    // RENDER_SETTLE_STEPS (2s = kill_age) reaches the developed fountain spread
    // before the first recorded frame. Determinism is preserved (settle steps
    // are deterministic too) — same seed+dt still yields byte-identical video.
    var su: usize = 0;
    while (su < RENDER_SETTLE_STEPS) : (su += 1) sim.step(config.dt, fb, RENDER_W, RENDER_H);

    const record_t0 = Io.Timestamp.now(io, .awake);
    var frame: usize = 0;
    var step_i: usize = 0;
    while (step_i < RECORD_STEPS) : (step_i += 1) {
        // Clear before each step so each captured frame shows exactly this
        // step's splat on a clean fb (step always splats now, §17.7).
        @memset(fb, 0);
        sim.step(config.dt, fb, RENDER_W, RENDER_H);
        if (step_i % 2 != 0) continue;
        // Stream the captured frame to ffmpeg.
        stdin_file.writeStreamingAll(io, fb) catch |e| {
            std.debug.print("  ERROR: ffmpeg stdin write failed ({t}) -- encoder likely exited early\n", .{e});
            return e;
        };
        frame += 1;
        if (frame % 60 == 0) std.debug.print("  streamed {d}/{d} frames...\n", .{ frame, RECORD_STEPS / 2 });
    }
    // Close stdin (EOF) so ffmpeg flushes and exits, then wait for it.
    stdin_file.close(io);
    child.stdin = null;
    const record_t1 = Io.Timestamp.now(io, .awake);
    std.debug.print("  streamed {d} frames in {d:.1} ms; waiting for ffmpeg...\n", .{
        frame, @as(f64, @floatFromInt(record_t0.durationTo(record_t1).nanoseconds)) / 1e6,
    });

    const term = child.wait(io) catch |e| {
        std.debug.print("  ERROR: ffmpeg wait failed ({t})\n", .{e});
        return e;
    };
    if (switch (term) { .exited => |c| c != 0, else => true }) {
        std.debug.print("  ERROR: ffmpeg exited nonzero ({t}). Run it manually to see stderr:\n", .{term});
        std.debug.print("    ffmpeg -y -f rawvideo -pixel_format rgba -video_size {s} -framerate 30 -i - -c:v libx264 -pix_fmt yuv420p -crf 18 {s}\n", .{ size_arg, video_path });
        return error.FfmpegFailed;
    }

    const stat = try dir.statFile(io, video_path, .{});
    std.debug.print("  wrote {s} ({d:.2} MB, {d} frames @ {d} fps = {d:.1} s)\n", .{
        video_path,
        @as(f64, @floatFromInt(stat.size)) / (1024.0 * 1024.0),
        frame,
        RECORD_FPS,
        @as(f64, @floatFromInt(frame)) / @as(f64, RECORD_FPS),
    });
}

// --- streaming-bandwidth microbench (--bandwidth) -------------------------------
// Measures single-core streaming-write bandwidth over a buffer larger than LLC,
// single-threaded, timed for a fixed wall budget. This is the bandwidth-
// attribution ceiling (§17.7/§6.4): hardware_json.py shells out to this so the
// ceiling is real hardware bandwidth, not a Python interpreter loop.
//
// Method: allocate a buffer > LLC, run a tight `@memset`-style loop touching
// every cache line, for a fixed ~0.7s wall budget, count bytes written, divide.
// Single-threaded (no parallelism) so the number is the per-core streaming
// ceiling the bandwidth plot compares `achieved_bw` against.
const BW_BUDGET_NS: u64 = 700 * std.time.ns_per_ms; // ~0.7s
const BW_MIN_BYTES: usize = 256 * 1024 * 1024; // 256 MB floor (> typical LLC)

fn runBandwidthMicrobench(io: Io, alloc: std.mem.Allocator) !void {
    const facts = hardware.detect();
    // Size the buffer > LLC so we measure DRAM streaming, not cache. M4 reports
    // l3=0 (unified memory); fall back to 4x L2, floored at 256 MB.
    const l3 = facts.l3cachesize;
    const l2 = facts.l2cachesize;
    const cache_ref: u64 = if (l3 > 0) l3 else (if (l2 > 0) l2 else 64 * 1024 * 1024);
    const buf_bytes: usize = @max(@as(usize, @intCast(cache_ref * 4)), BW_MIN_BYTES);

    const buf = try alloc.alloc(u8, buf_bytes);
    defer alloc.free(buf);

    // Warmup: touch the buffer once so initial faults/page-table setup don't
    // land in the timed region.
    @memset(buf, 0);

    // Timed loop: streaming writes, cache-line stride. Count whole passes until
    // the wall budget elapses; the final partial pass is counted by bytes.
    const stride: usize = if (facts.cachelinesize > 0) @intCast(facts.cachelinesize) else 64;
    var total_bytes: u64 = 0;
    var passes: u64 = 0;
    const t0 = Io.Timestamp.now(io, .awake);
    while (true) {
        var i: usize = 0;
        while (i < buf_bytes) : (i += stride) buf[i] = @truncate(passes + i);
        total_bytes += @intCast(buf_bytes);
        passes += 1;
        const now = Io.Timestamp.now(io, .awake);
        if (t0.durationTo(now).nanoseconds >= BW_BUDGET_NS) break;
    }
    const t1 = Io.Timestamp.now(io, .awake);
    const elapsed_ns: f64 = @floatFromInt(t0.durationTo(t1).nanoseconds);
    // bytes/ns = GB/s directly (1 GB = 1e9 bytes, 1 s = 1e9 ns, the 1e9 cancels).
    const gbs = @as(f64, @floatFromInt(total_bytes)) / elapsed_ns;

    // stdout: machine-parseable (hardware_json.py reads this).
    std.debug.print("streaming_bw_gbs={d:.2}\n", .{gbs});
    // stderr: human context.
    std.debug.print("=== Streaming-bandwidth microbench ===\n", .{});
    std.debug.print("  buffer: {d} MB ({d}x LLC/L2 ref, {s})\n", .{
        buf_bytes / (1024 * 1024),
        buf_bytes / @max(@as(usize, @intCast(cache_ref)), 1),
        if (l3 > 0) "L3-based" else "L2-based (L3 reported 0)",
    });
    std.debug.print("  passes: {d}, stride: {d} B\n", .{ passes, stride });
    std.debug.print("  elapsed: {d:.3} s, bytes: {d}\n", .{ elapsed_ns / 1e9, total_bytes });
    std.debug.print("  streaming_bw_gbs = {d:.2} GB/s (single-core)\n", .{gbs});
}

// --- JSONL row emission ---------------------------------------------------------
// Emits ONE JSON object for the single timed point to stderr, prefixed `json,`.
// collect.py / bench.py grep `^json,` and strip the prefix, appending the bare
// JSON to <algo>.runs.jsonl. The row is fully self-describing: build-time
// provenance (git_sha, source_hash, machine_id, host, run_id, ts_utc) + the
// algo_meta static axes + the point's measurements. No sweep summary — it's one
// point (denormalized per §6.2 so duckdb GROUP BY needs no joins).

const Measure = struct {
    n: usize,
    threads: usize,
    trial: usize,
    iters: usize,
    warmup: usize,
    bytes_per_p: usize,
    ns_frame: f64,
    ns_particle: f64,
    /// Elapsed nanoseconds of the timed region (raw, = ns_frame * iters).
    trial_ns: f64,
};

fn emitJsonRow(comptime SimImpl: type, m: Measure, run_id: []const u8, ts_utc: []const u8) void {
    const o = @import("options");
    // algo_meta axes (static per algorithm; denormalized onto every row).
    var algo_fam: []const u8 = "";
    var ordering: []const u8 = "";
    var intermediates: []const u8 = "";
    var golden_class: []const u8 = "";
    var halide_expressible: []const u8 = "";
    if (SimImpl.algo_meta) |cd| {
        algo_fam = @tagName(cd.algo_fam);
        ordering = @tagName(cd.ordering);
        intermediates = @tagName(cd.intermediates);
        golden_class = @tagName(cd.golden);
        halide_expressible = cd.halide_expressible;
    }
    // Manual JSON formatting (flat object, known types). Quotes strings,
    // escapes nothing (all our strings are identifier-like: no quotes/backslashes).
    std.debug.print("json,{{", .{});
    std.debug.print("\"run_id\":\"{s}\",", .{run_id});
    std.debug.print("\"ts_utc\":\"{s}\",", .{ts_utc});
    std.debug.print("\"kind\":\"timing\",", .{});
    std.debug.print("\"host\":\"{s}\",", .{o.host});
    std.debug.print("\"machine_id\":\"{s}\",", .{o.machine_id});
    std.debug.print("\"mem_layout\":\"{s}\",", .{if (SimImpl.algo_meta) |cd| cd.mem_layout else ""});
    std.debug.print("\"algo\":\"{s}\",", .{o.name});
    std.debug.print("\"source_hash\":\"{s}\",", .{o.source_hash});
    std.debug.print("\"git_sha\":\"{s}\",", .{o.git_sha});
    std.debug.print("\"git_branch\":\"{s}\",", .{o.git_branch});
    std.debug.print("\"zig_version\":\"{s}\",", .{@import("builtin").zig_version_string});
    std.debug.print("\"death_q\":{d},", .{config.q});
    std.debug.print("\"threads\":{d},", .{m.threads});
    std.debug.print("\"N\":{d},", .{m.n});
    std.debug.print("\"bytes_per_particle\":{d},", .{m.bytes_per_p});
    std.debug.print("\"trial\":{d},", .{m.trial});
    std.debug.print("\"iters\":{d},", .{m.iters});
    std.debug.print("\"warmup\":{d},", .{m.warmup});
    std.debug.print("\"ns_frame\":{d:.1},", .{m.ns_frame});
    std.debug.print("\"ns_particle\":{d:.4},", .{m.ns_particle});
    std.debug.print("\"trial_ns\":{d:.0},", .{m.trial_ns});
    std.debug.print("\"algo_fam\":\"{s}\",", .{algo_fam});
    std.debug.print("\"ordering\":\"{s}\",", .{ordering});
    std.debug.print("\"intermediates\":\"{s}\",", .{intermediates});
    std.debug.print("\"golden_class\":\"{s}\",", .{golden_class});
    // halide_expressible is prose (may contain spaces/parens) — quote, no escape.
    std.debug.print("\"halide_expressible\":\"{s}\"", .{halide_expressible});
    std.debug.print("}}\n", .{});
}
