// bench driver: headless, no window, no raylib. Sweeps N, times Sim.step()
// only, runs the golden-file correctness check. Prints a results table.
//
// Timing model:
//   - warmup: 10 steps (prime caches/branch predictors/battery clock).
//   - trial: ITERS steps, timed with Io.Timestamp (.awake = wall + CPU).
//   - trials per N: TRIALS, keep the MIN ns/frame (the cleanest sample — least
//     perturbed by interrupts, scheduling, DVFS transients). Max is also printed
//     so drift/noise is visible at a glance; if min≈max the number is stable.
//
// Columns:
//   N          particle count
//   bytes/p    hot-loop bytes touched per particle (sim.bytesPerParticle)
//   mem(MB)    N * bytes/p  — the per-frame working set
//   ns/particle (min)       cleanest per-particle cost
//   ns/frame (min)          cleanest per-frame cost
//   frames/sec (min)        1e9 / ns/frame
//   GB/s eff   N*bytes/p / ns/frame — effective hot-loop bandwidth. Compare to
//              the DRAM ceiling to see whether a stage is bandwidth-bound
//              (near ceiling) or compute/latency-bound (well below).
//   runtime(ms) (total)    TRIALS*ITERS + warmup wall time spent at this N
//
// The final TOTAL row sums the runtime(ms) column = the wall time of the whole
// sweep (correctness + bench), so you can see what the bench *cost*.

const std = @import("std");
const Io = std.Io;
const fw = @import("sim.zig");
const config = @import("config.zig");
const hardware = @import("hardware.zig");
const correctness = @import("correctness.zig");

const SWEEP = [_]usize{ 4_000, 16_000, 65_000, 262_000, 1_000_000, 4_000_000, 16_000_000, 64_000_000 };
const ITERS: usize = 200;
const WARMUP: usize = 10;
const TRIALS: usize = 3;
const GOLDEN_STEPS: usize = 600;
const GOLDEN_N: usize = 1024;
const EPS: f32 = 1e-4;
const GOLDEN_PATH = "golden/stage1.bin";
const FRAME_GOLDEN_PATH = "golden/frame.sha256";
// CSV death column (build option -Ddeath=<q>, optimization-framework §7).
const DEATH_COL = @import("options").death;

pub fn run(comptime SimImpl: type, init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    // Parse runtime args: --n <N> and --iters <K>. When --n is present, run
    // a single N only (no sweep, no golden check) — this is the PMC mode:
    // the whole process is a clean step() region for xctrace to wrap.
    var single_n: ?usize = null;
    var single_iters: ?usize = null;
    var render_mode = false;
    var frame_mode = false;
    var csv_mode = false;
    var record_dir: ?[]const u8 = null;
    var threads: usize = 1;
    {
        var it_opt: ?std.process.Args.Iterator = std.process.Args.Iterator.initAllocator(init.minimal.args, alloc) catch null;
        if (it_opt) |*it| {
            defer it.deinit();
            _ = it.next(); // skip program name
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--n")) {
                    if (it.next()) |val| single_n = std.fmt.parseInt(usize, val, 10) catch null;
                } else if (std.mem.eql(u8, arg, "--iters")) {
                    if (it.next()) |val| single_iters = std.fmt.parseInt(usize, val, 10) catch null;
                } else if (std.mem.eql(u8, arg, "--render")) {
                    render_mode = true;
                } else if (std.mem.eql(u8, arg, "--frame")) {
                    frame_mode = true;
                } else if (std.mem.eql(u8, arg, "--csv")) {
                    csv_mode = true;
                } else if (std.mem.eql(u8, arg, "--threads")) {
                    if (it.next()) |val| threads = std.fmt.parseInt(usize, val, 10) catch 1;
                } else if (std.mem.eql(u8, arg, "--record")) {
                    if (it.next()) |val| record_dir = val;
                }
            }
        }
    }
    const pmc_mode = single_n != null;

    // --- hardware block ---
    const facts = hardware.detect();
    hardware.print(facts);

    // --- cell declaration (§8): print every axis on every run, never silent ---
    const manifest = @import("manifest.zig");
    if (SimImpl.cell_decl) |cd| {
        manifest.printCellHeader(@import("options").name, cd);
    } else {
        std.debug.print("=== Cell ===\n  name: {s}\n  (pending — cell_decl not declared)\n\n", .{@import("options").name});
    }

    // --- correctness: generate (reference cell L1.naive) or verify ---
    const is_reference = @import("options").is_reference;

    // Golden checks are defined only for the natural death pattern
    // (optimization-framework.md §7: competing risks, q=0 = natural).
    // q>0 is a different sim — goldens skipped loudly; the invariant suite
    // (§10.6, Phase 1) is the correctness floor at q>0.
    const death_q = @import("options").death;
    const death_natural = comptime death_q == 0.0;
    if (!pmc_mode and !death_natural) {
        std.debug.print("=== Correctness: SKIPPED (death q={d} — churn regime, golden N/A; invariants: Phase 1) ===\n\n", .{death_q});
        std.debug.print("=== Frame golden: SKIPPED (death q={d}) ===\n\n", .{death_q});
    }
    if (!pmc_mode and death_natural) {
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

    // --- record mode (--record <dir>): headless fixed-step render -> PNG ->
    // ffmpeg. Runs AFTER the golden check above: the math is proven before the
    // video is exported. Available on EVERY cell since matrix M0 (was the
    // stage-11 special case in the arc).
    if (record_dir) |dir| {
        try recordVideo(SimImpl, alloc, io, dir, threads);
        return;
    }

    // --- render benchmark (--render): times Sim.render() separately from step() ---
    if (render_mode) {
        try renderBench(SimImpl, alloc, io, csv_mode, threads);
        return;
    }

    // --- frame benchmark (--frame): times { step() + render() } as one CPU frame ---
    if (frame_mode) {
        try frameBench(SimImpl, alloc, io, csv_mode, threads);
        return;
    }

    // --- benchmark sweep ---
    const sweep_t0 = Io.Timestamp.now(io, .awake);
    const iters = if (single_iters) |i| i else ITERS;
    const sweep_list: []const usize = if (single_n) |n| &.{n} else &SWEEP;
    std.debug.print("=== Benchmark (iters={d}, warmup={d}, trials={d} per N; reporting min){s}\n", .{ iters, WARMUP, TRIALS, if (pmc_mode) " [PMC mode]" else "" });
    std.debug.print("  {s:>10} | {s:>7} | {s:>9} | {s:>14} | {s:>14} | {s:>11} | {s:>8} | {s:>11}\n", .{
        "N", "bytes/p", "mem(MB)", "ns/particle(min)", "ns/frame(min)", "frames/sec", "GB/s eff", "runtime(ms)",
    });
    std.debug.print("  {s:-<10}-+-{s:-<7}-+-{s:-<9}-+-{s:-<14}-+-{s:-<14}-+-{s:-<11}-+-{s:-<8}-+-{s:-<11}\n", .{
        "", "", "", "", "", "", "", "",
    });

    var total_runtime_ms: f64 = 0;
    var total_frames: u64 = 0;

    for (sweep_list) |n| {
        var sim = SimImpl.init(alloc, .{ .n = n, .seed = config.spawn_seed, .threads = threads }) catch |e| {
            std.debug.print("  {d:>10} | (init failed: {t})\n", .{ n, e });
            continue;
        };
        defer sim.deinit();

        const bytes_per_p = sim.bytesPerParticle();
        const working_set_bytes: u64 = @as(u64, n) * bytes_per_p;
        const working_set_mb: f64 = @as(f64, @floatFromInt(working_set_bytes)) / (1024.0 * 1024.0);

        // Time TRIALS independent runs of (warmup + ITERS), keep min ns/frame.
        // Each run includes its own warmup so the min reflects a fully-primed
        // cache state; runtime(ms) sums all trials (the real bench cost).
        var min_ns_frame: f64 = std.math.inf(f64);
        var max_ns_frame: f64 = 0;
        var trial_runtime_ns: f64 = 0;

        var trial: usize = 0;
        while (trial < TRIALS) : (trial += 1) {
            // warmup
            var w: usize = 0;
            while (w < WARMUP) : (w += 1) sim.step(config.dt);

            const t0 = Io.Timestamp.now(io, .awake);
            var it: usize = 0;
            while (it < iters) : (it += 1) sim.step(config.dt);
            const t1 = Io.Timestamp.now(io, .awake);
            const ns: f64 = @floatFromInt(t0.durationTo(t1).nanoseconds);
            trial_runtime_ns += ns;
            const ns_frame: f64 = ns / @as(f64, @floatFromInt(iters));
            if (ns_frame < min_ns_frame) min_ns_frame = ns_frame;
            if (ns_frame > max_ns_frame) max_ns_frame = ns_frame;
        }

        const ns_per_particle = min_ns_frame / @as(f64, @floatFromInt(n));
        const frames_sec = 1e9 / min_ns_frame;
        // effective hot-loop bandwidth = bytes touched per frame / time per frame.
        // 1 byte/ns == 1e9 bytes/s == 1 GB/s, so bytes/ns is GB/s directly.
        const gbs_eff: f64 = @as(f64, @floatFromInt(working_set_bytes)) / min_ns_frame;
        const runtime_ms: f64 = trial_runtime_ns / 1e6;
        total_runtime_ms += runtime_ms;
        total_frames += @as(u64, n) * iters * TRIALS;

        std.debug.print("  {d:>10} | {d:>7} | {d:>9.1} | {d:>14.3} | {d:>14.1} | {d:>11.1} | {d:>8.2} | {d:>11.1}\n", .{
            n, bytes_per_p, working_set_mb, ns_per_particle, min_ns_frame, frames_sec, gbs_eff, runtime_ms,
        });
        if (csv_mode) std.debug.print("csv,{s},step,{d},{d},{d},{d},{d:.1},{d:.4},{d:.2}\n", .{
            @import("options").name, DEATH_COL, threads, n, bytes_per_p, min_ns_frame, ns_per_particle, gbs_eff,
        });
    }

    const sweep_t1 = Io.Timestamp.now(io, .awake);
    const sweep_wall_ms: f64 = @as(f64, @floatFromInt(sweep_t0.durationTo(sweep_t1).nanoseconds)) / 1e6;

    std.debug.print("  {s:-<10}-+-{s:-<7}-+-{s:-<9}-+-{s:-<14}-+-{s:-<14}-+-{s:-<11}-+-{s:-<8}-+-{s:-<11}\n", .{
        "", "", "", "", "", "", "", "",
    });
    std.debug.print("  {s:>10} | {s:>7} | {s:>9} | {s:>14} | {s:>14} | {s:>11} | {s:>8} | {d:>11.1}\n", .{
        "TOTAL", "", "", "", "", "", "sweep(ms):", total_runtime_ms,
    });
    std.debug.print("  {s:>10} | {s:>7} | {s:>9} | {s:>14} | {s:>14} | {s:>11} | {s:>8} | {d:>11.1}\n", .{
        "", "", "", "", "", "", "wall(ms):", sweep_wall_ms,
    });
    std.debug.print("\n  total particles-frames simulated: {d}\n", .{total_frames});
}

// --- render benchmark (--render) --------------------------------------------------

const RENDER_W: u32 = 1024;
const RENDER_H: u32 = 1024;
const RENDER_SETTLE_STEPS: usize = 120; // 2s = kill_age -> steady-state spread

/// Render-time benchmark (stage 10's instrument, P11): times Sim.render()
/// exactly the way the step sweep times Sim.step() — warmup, TRIALS runs,
/// keep min ns/frame. The step bench is firewalled from rendering; this flag
/// is the render-side counterpart, so the rasterizer's cost is measurable
/// separately from the sim's cost. Iters scale ~1/N so every N costs roughly
/// the same wall time (render is O(N) splats + a fixed 4 MB clear).
fn renderBench(comptime SimImpl: type, alloc: std.mem.Allocator, io: Io, csv: bool, threads: usize) !void {
    const fb = try alloc.alloc(u8, @as(usize, RENDER_W) * RENDER_H * 4);
    defer alloc.free(fb);

    std.debug.print("=== Render benchmark (framebuffer {d}x{d}, trials={d} per N; reporting min) ===\n", .{ RENDER_W, RENDER_H, TRIALS });
    std.debug.print("  render() timed end-to-end (clear + splat) after {d} settle steps.\n\n", .{RENDER_SETTLE_STEPS});
    std.debug.print("  {s:>10} | {s:>6} | {s:>14} | {s:>14} | {s:>11}\n", .{ "N", "iters", "ns/frame(min)", "ns/particle", "frames/sec" });
    std.debug.print("  {s:-<10}-+-{s:-<6}-+-{s:-<14}-+-{s:-<14}-+-{s:-<11}\n", .{ "", "", "", "", "" });

    for (SWEEP) |n| {
        var sim = SimImpl.init(alloc, .{ .n = n, .seed = config.spawn_seed, .threads = threads }) catch |e| {
            std.debug.print("  {d:>10} | (init failed: {t})\n", .{ n, e });
            continue;
        };
        defer sim.deinit();

        // Settle to a steady-state spatial distribution (init places every
        // particle at the origin — maximally overlapped, unrepresentative).
        var s: usize = 0;
        while (s < RENDER_SETTLE_STEPS) : (s += 1) sim.step(config.dt);

        const iters: usize = @max(10, @min(200, 13_000_000 / @max(n, 1)));

        var wu: usize = 0;
        while (wu < 2) : (wu += 1) sim.render(fb, RENDER_W, RENDER_H);

        var min_ns_frame: f64 = std.math.inf(f64);
        var trial: usize = 0;
        while (trial < TRIALS) : (trial += 1) {
            const t0 = Io.Timestamp.now(io, .awake);
            var it: usize = 0;
            while (it < iters) : (it += 1) sim.render(fb, RENDER_W, RENDER_H);
            const t1 = Io.Timestamp.now(io, .awake);
            const ns_frame = @as(f64, @floatFromInt(t0.durationTo(t1).nanoseconds)) / @as(f64, @floatFromInt(iters));
            if (ns_frame < min_ns_frame) min_ns_frame = ns_frame;
        }

        std.debug.print("  {d:>10} | {d:>6} | {d:>14.1} | {d:>14.4} | {d:>11.1}\n", .{
            n, iters, min_ns_frame, min_ns_frame / @as(f64, @floatFromInt(n)), 1e9 / min_ns_frame,
        });
        if (csv) std.debug.print("csv,{s},render,{d},{d},{d},,{d:.1},{d:.4},\n", .{
            @import("options").name, DEATH_COL, threads, n, min_ns_frame, min_ns_frame / @as(f64, @floatFromInt(n)),
        });
    }
    std.debug.print("\n", .{});
}

// --- frame benchmark (--frame): step+render timed as one CPU frame ------------

/// Frame benchmark (layout-matrix.md §2.2): times { step(); render() } per
/// frame — the way play mode actually pays it — with nested decomposition
/// (step ns and render ns accumulated separately inside the timed loop), so a
/// frame win is attributable to the sim side or the render side at a glance.
/// This is the primary instrument for the matrix's winner-per-regime
/// declarations. Iters scale ~1/N (same as --render: O(N) splats + a fixed
/// 4 MB clear that dominates at small N — the Amdahl note of §6.2).
fn frameBench(comptime SimImpl: type, alloc: std.mem.Allocator, io: Io, csv: bool, threads: usize) !void {
    const fb = try alloc.alloc(u8, @as(usize, RENDER_W) * RENDER_H * 4);
    defer alloc.free(fb);

    std.debug.print("=== Frame benchmark (step+render, framebuffer {d}x{d}, trials={d} per N; reporting min) ===\n", .{ RENDER_W, RENDER_H, TRIALS });
    std.debug.print("  step/render columns are per-frame averages inside the fastest trial (the 4 MB clear is inside render).\n\n", .{});
    std.debug.print("  {s:>10} | {s:>6} | {s:>12} | {s:>12} | {s:>12} | {s:>13} | {s:>11}\n", .{ "N", "iters", "step ns/f", "render ns/f", "frame ns/f", "frame ns/p", "fps" });
    std.debug.print("  {s:-<10}-+-{s:-<6}-+-{s:-<12}-+-{s:-<12}-+-{s:-<12}-+-{s:-<13}-+-{s:-<11}\n", .{ "", "", "", "", "", "", "" });

    for (SWEEP) |n| {
        var sim = SimImpl.init(alloc, .{ .n = n, .seed = config.spawn_seed, .threads = threads }) catch |e| {
            std.debug.print("  {d:>10} | (init failed: {t})\n", .{ n, e });
            continue;
        };
        defer sim.deinit();

        const iters: usize = @max(10, @min(200, 13_000_000 / @max(n, 1)));

        // Warmup: full frames (step+render) — reaches steady-state population
        // and primes caches/predictors, same role as the step sweep's warmup.
        var wu: usize = 0;
        while (wu < WARMUP) : (wu += 1) {
            sim.step(config.dt);
            sim.render(fb, RENDER_W, RENDER_H);
        }

        var min_frame_ns: f64 = std.math.inf(f64);
        var step_ns_at_min: f64 = 0;
        var render_ns_at_min: f64 = 0;
        var trial: usize = 0;
        while (trial < TRIALS) : (trial += 1) {
            var step_ns: u64 = 0;
            var render_ns: u64 = 0;
            const t0 = Io.Timestamp.now(io, .awake);
            var it: usize = 0;
            while (it < iters) : (it += 1) {
                const ts0 = Io.Timestamp.now(io, .awake);
                sim.step(config.dt);
                const ts1 = Io.Timestamp.now(io, .awake);
                sim.render(fb, RENDER_W, RENDER_H);
                const ts2 = Io.Timestamp.now(io, .awake);
                step_ns += @intCast(ts0.durationTo(ts1).nanoseconds);
                render_ns += @intCast(ts1.durationTo(ts2).nanoseconds);
            }
            const t1 = Io.Timestamp.now(io, .awake);
            const frame_ns = @as(f64, @floatFromInt(t0.durationTo(t1).nanoseconds)) / @as(f64, @floatFromInt(iters));
            if (frame_ns < min_frame_ns) {
                min_frame_ns = frame_ns;
                step_ns_at_min = @as(f64, @floatFromInt(step_ns)) / @as(f64, @floatFromInt(iters));
                render_ns_at_min = @as(f64, @floatFromInt(render_ns)) / @as(f64, @floatFromInt(iters));
            }
        }

        std.debug.print("  {d:>10} | {d:>6} | {d:>12.1} | {d:>12.1} | {d:>12.1} | {d:>13.4} | {d:>11.1}\n", .{
            n, iters, step_ns_at_min, render_ns_at_min, min_frame_ns, min_frame_ns / @as(f64, @floatFromInt(n)), 1e9 / min_frame_ns,
        });
        if (csv) std.debug.print("csv,{s},frame,{d},{d},{d},{d},{d:.1},{d:.1},{d:.1}\n", .{
            @import("options").name, DEATH_COL, threads, n, sim.bytesPerParticle(), min_frame_ns, step_ns_at_min, render_ns_at_min,
        });
    }
    std.debug.print("\n", .{});
}

// --- record mode (stage 11, --record <dir>) ----------------------------------------

const RECORD_N: usize = 65_000; // play mode's DEFAULT_N — visual parity
const RECORD_STEPS: usize = 600; // fixed steps, fixed dt -> deterministic replay
const RECORD_FPS: u32 = 30; // capture every 2nd step: 300 frames = 10 s

/// Headless video export (P12: determinism enables replay). Runs the sim for
/// RECORD_STEPS fixed steps, renders every 2nd step into an RGBA framebuffer,
/// writes each frame as a PNG via stb_image_write, then shells out to ffmpeg
/// to encode <dir>/video.mp4 (30 fps × 300 frames = 10 s at 1024² — the
/// acceptance spec). Deterministic: same seed + same dt ⇒ byte-identical
/// PNGs across runs.
fn recordVideo(comptime SimImpl: type, alloc: std.mem.Allocator, io: Io, out_dir: []const u8, threads: usize) !void {
    const stb = @import("../bindings/stb.zig");

    const frames_dir = try std.fmt.allocPrint(alloc, "{s}/frames", .{out_dir});
    defer alloc.free(frames_dir);
    const video_path = try std.fmt.allocPrint(alloc, "{s}/video.mp4", .{out_dir});
    defer alloc.free(video_path);

    var dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, frames_dir);

    std.debug.print("=== Record: {s} ===\n", .{@import("options").label});
    std.debug.print("  sim: N={d}, seed=0x{X}, {d} steps @ dt={d:.6}\n", .{ RECORD_N, config.spawn_seed, RECORD_STEPS, config.dt });
    std.debug.print("  capture: every 2nd step -> {d} frames @ {d} fps = {d:.1} s at {d}x{d}\n\n", .{
        RECORD_STEPS / 2, RECORD_FPS, @as(f64, RECORD_STEPS / 2) / @as(f64, RECORD_FPS), RENDER_W, RENDER_H,
    });

    var sim = try SimImpl.init(alloc, .{ .n = RECORD_N, .seed = config.spawn_seed, .threads = threads });
    defer sim.deinit();

    const fb = try alloc.alloc(u8, @as(usize, RENDER_W) * RENDER_H * 4);
    defer alloc.free(fb);

    const record_t0 = Io.Timestamp.now(io, .awake);
    var frame: usize = 0;
    var step_i: usize = 0;
    while (step_i < RECORD_STEPS) : (step_i += 1) {
        sim.step(config.dt);
        if (step_i % 2 != 0) continue;
        sim.render(fb, RENDER_W, RENDER_H);
        const path = try std.fmt.allocPrintSentinel(alloc, "{s}/frame_{d:0>4}.png", .{ frames_dir, frame }, 0);
        defer alloc.free(path);
        if (stb.stbi_write_png(path.ptr, @intCast(RENDER_W), @intCast(RENDER_H), 4, fb.ptr, @intCast(RENDER_W * 4)) == 0) {
            std.debug.print("  ERROR: stbi_write_png failed for {s}\n", .{path});
            return error.PngWriteFailed;
        }
        frame += 1;
        if (frame % 60 == 0) std.debug.print("  wrote {d}/{d} frames...\n", .{ frame, RECORD_STEPS / 2 });
    }
    const record_t1 = Io.Timestamp.now(io, .awake);
    std.debug.print("  wrote {d} frames to {s}/ in {d:.1} ms\n\n", .{
        frame, frames_dir, @as(f64, @floatFromInt(record_t0.durationTo(record_t1).nanoseconds)) / 1e6,
    });

    // Encode: 300 frames @ 30 fps = 10 s. yuv420p for player compatibility
    // (1024×1024 is even — valid for 4:2:0). crf 18 = visually lossless.
    std.debug.print("  encoding {s} via ffmpeg...\n", .{video_path});
    const pattern = try std.fmt.allocPrint(alloc, "{s}/frame_%04d.png", .{frames_dir});
    defer alloc.free(pattern);
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "ffmpeg", "-y", "-framerate", "30", "-i", pattern, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-movflags", "+faststart", video_path },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |e| {
        std.debug.print("  ERROR: failed to spawn ffmpeg ({t}). Is ffmpeg on PATH?\n", .{e});
        std.debug.print("  frames are still in {s}/ — encode manually:\n", .{frames_dir});
        std.debug.print("    ffmpeg -y -framerate 30 -i {s} -c:v libx264 -pix_fmt yuv420p -crf 18 {s}\n", .{ pattern, video_path });
        return e;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (switch (result.term) { .exited => |c| c != 0, else => true }) {
        const tail = result.stderr[result.stderr.len -| 2000 ..];
        std.debug.print("  ERROR: ffmpeg exited nonzero. stderr tail:\n{s}\n", .{tail});
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
