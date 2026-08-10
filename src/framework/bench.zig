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

// N-sweep: ~×4 geometric, chosen to straddle this machine's cache knees
// (L1d @ N≈963, L2 @ N≈61_680 for bpp=68). 65k sits ON the L2 transition;
// 262k/1M resolve the post-knee RAM ramp; 16M is the clean out-of-cache
// asymptote (proves bandwidth-bound). 4k is the L2-resident baseline.
// (commit 97f2541 trimmed this to a 4-point sparse grid for speed; the
// cache-curve shape — what analyze_cell's cache_transitions overlay reads —
// is the study's payoff, so the resolution was restored.)
const SWEEP = [_]usize{ 4_000, 65_000, 262_000, 1_000_000, 16_000_000 };
// Timed frames per trial, per N (min over TRIALS is reported). NON-UNIFORM by
// design: small N is cheap + noisy (wants many samples); large N is expensive
// + stable. But the bias isn't uniform — it concentrates at MID-N (1M/262k run
// too short a trial to settle), so those get bumped above the pure ×4 curve
// (100/60 instead of 50/30): ~halves their drift for +1s. 16M stays at 20 —
// it's the cost giant and its only job is asymptote confirmation. Override
// uniformly with `--iters K`; custom `--ns` falls back to the _DEFAULT consts.
const ITERS_PER_N = [_]usize{ 200, 100, 100, 60, 20 }; // parallel to SWEEP
const WARMUP_PER_N = [_]usize{ 20, 10, 5, 3, 2 }; // parallel to SWEEP
const ITERS_DEFAULT: usize = 50;
const WARMUP_DEFAULT: usize = 5;

/// Timed frames for N: the --iters override if set, else the per-N schedule
/// (lookup by N value so a custom --ns still resolves), else ITERS_DEFAULT.
fn itersForN(n: usize, override: ?usize) usize {
    if (override) |i| return i;
    for (SWEEP, ITERS_PER_N) |sn, it| if (n == sn) return it;
    return ITERS_DEFAULT;
}
/// Warmup frames for N (per-N schedule; WARMUP_DEFAULT for custom N).
fn warmupForN(n: usize) usize {
    for (SWEEP, WARMUP_PER_N) |sn, w| if (n == sn) return w;
    return WARMUP_DEFAULT;
}
const TRIALS: usize = 3;
const GOLDEN_STEPS: usize = 600;
const GOLDEN_N: usize = 1024;
const EPS: f32 = 1e-4;
const GOLDEN_PATH = "experiments/golden/stage1.bin";
// The framebuffer dimensions used by the bench sweep + record mode.
const RENDER_W: u32 = 1024;
const RENDER_H: u32 = 1024;
const RENDER_SETTLE_STEPS: usize = 120; // 2s = kill_age -> steady-state spread
const FRAME_GOLDEN_PATH = "experiments/golden/frame.sha256";
// (death is runtime now — config.q, set via --death or the -Ddeath default.
// The CSV + JSONL rows read config.q directly.)

pub fn run(comptime SimImpl: type, init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    // Parse runtime args: --n <N> and --iters <K>. When --n is present, run
    // a single N only (no sweep, no golden check) — this is the PMC mode:
    // the whole process is a clean step() region for xctrace to wrap.
    var single_n: ?usize = null;
    var single_iters: ?usize = null;
    var csv_mode = false;
    var runtime_death: ?f64 = null;
    var runtime_run_id: []const u8 = "";
    var runtime_ts_utc: []const u8 = "";
    var json_mode = false;
    var record_dir: ?[]const u8 = null;
    var check_mode = false;
    var bandwidth_mode = false;
    var show_help = false;
    var threads: usize = 1;
    var trials_arg: ?usize = null;
    var ns_buf: [32]usize = undefined;
    var ns_count: usize = 0;
    {
        var it_opt: ?std.process.Args.Iterator = std.process.Args.Iterator.initAllocator(init.minimal.args, alloc) catch null;
        if (it_opt) |*it| {
            defer it.deinit();
            _ = it.next(); // skip program name
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--n") or std.mem.eql(u8, arg, "-N")) {
                    if (it.next()) |val| single_n = std.fmt.parseInt(usize, val, 10) catch null;
                } else if (std.mem.eql(u8, arg, "--iters")) {
                    if (it.next()) |val| single_iters = std.fmt.parseInt(usize, val, 10) catch null;
                } else if (std.mem.eql(u8, arg, "--death") or std.mem.eql(u8, arg, "-q")) {
                    if (it.next()) |val| runtime_death = std.fmt.parseFloat(f64, val) catch null;
                } else if (std.mem.eql(u8, arg, "--run-id")) {
                    if (it.next()) |val| runtime_run_id = val;
                } else if (std.mem.eql(u8, arg, "--ts-utc")) {
                    if (it.next()) |val| runtime_ts_utc = val;
                } else if (std.mem.eql(u8, arg, "--csv")) {
                    csv_mode = true;
                } else if (std.mem.eql(u8, arg, "--json")) {
                    // JSONL output (refactor §6.6): one JSON object per trial to
                    // stdout, carrying full provenance (git_sha, source_hash,
                    // machine_id, algo_meta axes) + measurements. collect.py
                    // appends stdout directly into runs.jsonl. Replaces --csv.
                    json_mode = true;
                } else if (std.mem.eql(u8, arg, "--threads")) {
                    if (it.next()) |val| threads = std.fmt.parseInt(usize, val, 10) catch 1;
                } else if (std.mem.eql(u8, arg, "--trials")) {
                    if (it.next()) |val| trials_arg = std.fmt.parseInt(usize, val, 10) catch null;
                } else if (std.mem.eql(u8, arg, "--ns")) {
                    // Comma-separated N list, overriding the default SWEEP.
                    if (it.next()) |val| {
                        var sit = std.mem.splitScalar(u8, val, ',');
                        while (sit.next()) |tok| {
                            if (ns_count >= ns_buf.len) break;
                            ns_buf[ns_count] = std.fmt.parseInt(usize, std.mem.trim(u8, tok, " "), 10) catch continue;
                            ns_count += 1;
                        }
                    }
                } else if (std.mem.eql(u8, arg, "--record")) {
                    // `--record <dir>` exports a headless video; if no dir
                    // follows, default to the build-output record dir ("out/record"),
                    // which lives under the single `out/` prefix (refactor §2).
                    record_dir = it.next() orelse "out/record";
                } else if (std.mem.eql(u8, arg, "--check")) {
                    check_mode = true;
                } else if (std.mem.eql(u8, arg, "--bandwidth")) {
                    // Streaming-bandwidth microbench (refactor §6.4): a tight
                    // single-threaded streaming-write loop over a buffer > LLC,
                    // timed. Prints `streaming_bw_gbs=<GB/s>` to stdout and exits.
                    // This is the real hardware ceiling that hardware_json.py reads
                    // (replaces the Python-interpreter-bound estimate).
                    bandwidth_mode = true;
                } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    show_help = true;
                }
            }
        }
    }
    // -h/--help: print usage + this cell's declaration, then exit.
    if (show_help) {
        const manifest = @import("manifest.zig");
        std.debug.print("Usage: {s} [options]\n\n", .{@import("options").name});
        if (SimImpl.algo_meta) |cd|
            manifest.printAlgoHeader(@import("options").name, cd);
        std.debug.print(
            \\Options:
            \\  -q, --death <q>     per-frame accident rate (0 = natural/golden)
            \\  -N, --n <N>         single particle count (PMC mode: no sweep)
            \\      --ns <a,b,c>    comma-list of N (overrides the default sweep)
            \\      --iters <K>     timed frames per trial (default: per-N schedule)
            \\      --trials <T>    trials per N (min reported)
            \\      --threads <T>   worker count (parallel cells)
            \\      --check         invariant suite only (PASS/FAIL), then exit
            \\      --json          JSONL provenance rows to stdout (collect.py)
            \\      --csv           legacy CSV table
            \\      --record <dir>  headless render → PNG → ffmpeg
            \\      --bandwidth     streaming-BW microbench, then exit
            \\  -h, --help          this message
            \\
        , .{});
        return;
    }
    // Apply runtime --death override (before any golden/invariant use of config.q).
    if (runtime_death) |qv| {
        if (!std.math.isFinite(qv) or qv < 0.0 or qv >= 1.0)
            std.debug.panic("invalid --death={d} (expect 0 <= q < 1)", .{qv});
        config.setDeathRate(@floatCast(qv));
    }
    const pmc_mode = single_n != null;
    const trials: usize = trials_arg orelse TRIALS;
    // The N-sweep: --ns <list> overrides; --n <one> is single-N PMC mode;
    // otherwise the default SWEEP. Passed to every bench mode so --ns applies
    // uniformly (collect.py uses it for quick subset runs).
    const sweep_list: []const usize = if (ns_count > 0)
        ns_buf[0..ns_count]
    else if (single_n) |n| blk: {
        ns_buf[0] = n;
        break :blk ns_buf[0..1];
    } else &SWEEP;

    // --- hardware block ---
    const facts = hardware.detect();
    hardware.print(facts);

    // --- algorithm meta (§8): print every axis on every run, never silent ---
    const manifest = @import("manifest.zig");
    if (SimImpl.algo_meta) |cd| {
        manifest.printAlgoHeader(@import("options").name, cd);
    } else {
        std.debug.print("=== Algorithm ===\n\n  name: {s}\n  (pending — algo_meta not declared)\n\n", .{@import("options").name});
    }

    // --- invariant suite (--check): separate invocation, no timed-region overhead ---
    if (check_mode) {
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

    // --- streaming-bandwidth microbench (--bandwidth): early-out, no sim ---
    // Measures the machine's single-core streaming-write bandwidth (the
    // bandwidth-attribution ceiling, §17.7/§6.4). hardware_json.py shells out
    // to this so the ceiling is measured in real hardware bandwidth, not a
    // Python interpreter loop. Output: one line `streaming_bw_gbs=<value>` on
    // stdout (machine-parseable); a human block on stderr.
    if (bandwidth_mode) {
        try runBandwidthMicrobench(io, alloc);
        return;
    }

    // --- correctness: generate (reference cell L1.naive) or verify ---
    const is_reference = @import("options").is_reference;

    // Golden checks are defined only for the natural death pattern
    // (optimization-framework.md §7: competing risks, q=0 = natural).
    // q>0 is a different sim — goldens skipped loudly; the invariant suite
    // (§10.6, Phase 1) is the correctness floor at q>0.
    const death_q = config.q;
    const death_natural = death_q == 0.0;
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

    // --- render/frame modes retired (§17.7): one workload, the frame ---
    // (math + splat, always). --render/--frame are gone; the sweep below
    // times step(dt, fb, w, h) directly.

    // --- benchmark sweep ---
    const sweep_t0 = Io.Timestamp.now(io, .awake);
    // The framebuffer the splat writes into (RAM-only; no GPU in bench mode).
    const fb = try alloc.alloc(u8, @as(usize, RENDER_W) * RENDER_H * 4);
    defer alloc.free(fb);
    std.debug.print("=== Benchmark (iters/warmup per-N schedule; trials={d} per N; reporting min){s}\n\n", .{ trials, if (pmc_mode) " [PMC mode]" else "" });
    std.debug.print("  {s:>10} | {s:>7} | {s:>9} | {s:>14} | {s:>14} | {s:>11} | {s:>11}\n", .{
        "N", "bytes/p", "mem(MB)", "ns/particle(min)", "ns/frame(min)", "frames/sec", "runtime(ms)",
    });
    std.debug.print("  {s:-<10}-+-{s:-<7}-+-{s:-<9}-+-{s:-<14}-+-{s:-<14}-+-{s:-<11}-+-{s:-<11}\n", .{
        "", "", "", "", "", "", "",
    });

    var total_runtime_ms: f64 = 0;
    var sweep_total_frames: u64 = 0;
    var sweep_total_particles: u64 = 0;
    // Buffer per-trial records so run-level totals (sweep wall time, total
    // frames/particles, end timestamp) can be denormalized onto every JSONL
    // row (refactor §6.2): the row is emitted once, at sweep end, carrying
    // both the per-trial measurement and the whole-run summary.
    var trial_recs: std.ArrayList(TrialRec) = .empty;
    defer trial_recs.deinit(alloc);

    for (sweep_list) |n| {
        const iters = itersForN(n, single_iters);
        const warmup = warmupForN(n);
        var sim = SimImpl.init(alloc, .{ .n = n, .seed = config.spawn_seed, .threads = threads }) catch |e| {
            std.debug.print("  {d:>10} | (init failed: {t})\n", .{ n, e });
            continue;
        };
        defer sim.deinit();

        const bytes_per_p = sim.bytesPerParticle();
        const working_set_bytes: u64 = @as(u64, n) * bytes_per_p;
        const working_set_mb: f64 = @as(f64, @floatFromInt(working_set_bytes)) / (1024.0 * 1024.0);

        // Time TRIALS independent runs of (warmup + ITERS), keep min ns/frame.
        // The clear is ONCE before the timed loop (S17.7: the clear is a
        // driver concern; the timed region is purely math + splat).
        var min_ns_frame: f64 = std.math.inf(f64);
        var trial_runtime_ns: f64 = 0;

        var trial: usize = 0;
        while (trial < trials) : (trial += 1) {
            // warmup (step always splats; clear so the fb doesn't saturate).
            @memset(fb, 0);
            var w: usize = 0;
            while (w < warmup) : (w += 1) sim.step(config.dt, fb, RENDER_W, RENDER_H);

            // clear once before the timed loop.
            @memset(fb, 0);
            const t0 = Io.Timestamp.now(io, .awake);
            var it: usize = 0;
            while (it < iters) : (it += 1) sim.step(config.dt, fb, RENDER_W, RENDER_H);
            const t1 = Io.Timestamp.now(io, .awake);
            const ns: f64 = @floatFromInt(t0.durationTo(t1).nanoseconds);
            trial_runtime_ns += ns;
            const ns_frame: f64 = ns / @as(f64, @floatFromInt(iters));
            if (ns_frame < min_ns_frame) min_ns_frame = ns_frame;
            // Per-trial output (refactor §6.6):
            //   --csv: legacy CSV row to stderr (collect.py greps + prefixes)
            //   --json: one JSONL row to stderr (collect.py greps '^json,' + strips)
            // The JSON row is fully self-describing: it carries build-time
            // provenance (git_sha, source_hash, machine_id, host, run_id, ts_utc)
            // + the algo_meta axes (blueprint, ordering, intermediates, golden,
            // halide_expressible) + measurements. No collect.py prefixing needed.
            if (csv_mode) {
                const ns_p: f64 = ns_frame / @as(f64, @floatFromInt(n));
                std.debug.print("csv,{s},frame,{d},{d},{d},{d},{d},{d:.1},{d:.4}\n", .{
                    @import("options").name, config.q, threads, n, bytes_per_p, trial, ns_frame, ns_p,
                });
            }
            if (json_mode) {
                const ns_p: f64 = ns_frame / @as(f64, @floatFromInt(n));
                // Buffer; emitted at sweep end once run-level totals are known.
                trial_recs.append(alloc, .{
                    .n = n,
                    .bytes_per_p = bytes_per_p,
                    .trial = trial,
                    .ns_frame = ns_frame,
                    .ns_particle = ns_p,
                    .trial_ns = ns,
                    .frames = iters,
                    .particles_processed = @as(u64, n) * iters,
                }) catch {};
            }
        }

        const ns_per_particle = min_ns_frame / @as(f64, @floatFromInt(n));
        const frames_sec = 1e9 / min_ns_frame;
        const runtime_ms: f64 = trial_runtime_ns / 1e6;
        total_runtime_ms += runtime_ms;
        sweep_total_frames += @as(u64, iters) * trials;
        sweep_total_particles += @as(u64, n) * iters * trials;

        std.debug.print("  {d:>10} | {d:>7} | {d:>9.1} | {d:>14.3} | {d:>14.1} | {d:>11.1} | {d:>11.1}\n", .{
            n, bytes_per_p, working_set_mb, ns_per_particle, min_ns_frame, frames_sec, runtime_ms,
        });
    }

    const sweep_t1 = Io.Timestamp.now(io, .awake);
    const sweep_wall_ms: f64 = @as(f64, @floatFromInt(sweep_t0.durationTo(sweep_t1).nanoseconds)) / 1e6;

    // --- JSONL emission (refactor §6.6): one row per trial, denormalized ---
    // with the whole-run summary so duckdb GROUP BY needs no joins. Emitted at
    // sweep end (not per-trial) so run-level totals + end timestamp are known.
    // collect.py greps `^json,` off stderr and strips the prefix.
    if (json_mode and trial_recs.items.len > 0) {
        // .real = wall clock (Unix epoch seconds); format to match ts_utc's
        // YYYYMMDDTHHMMSSZ so a loader can diff start vs end directly.
        const end_ts = Io.Timestamp.now(io, .real);
        const ts_end_utc = formatUtc(@intCast(end_ts.toSeconds()));
        const summary = RunSummary{
            .threads = threads,
            .iters = single_iters orelse ITERS_DEFAULT,
            .warmup = WARMUP_DEFAULT,
            .trials_per_n = trials,
            .sweep_wall_ms = sweep_wall_ms,
            .sweep_total_frames = sweep_total_frames,
            .sweep_total_particles = sweep_total_particles,
            .ts_end_utc = ts_end_utc,
            .run_id = runtime_run_id,
            .ts_utc = runtime_ts_utc,
        };
        for (trial_recs.items) |rec| emitJsonRow(SimImpl, rec, summary);
    }

    std.debug.print("  {s:-<10}-+-{s:-<7}-+-{s:-<9}-+-{s:-<14}-+-{s:-<14}-+-{s:-<11}-+-{s:-<11}\n", .{
        "", "", "", "", "", "", "",
    });
    std.debug.print("  {s:>10} | {s:>7} | {s:>9} | {s:>14} | {s:>14} | {s:>11} | {d:>11.1}\n", .{
        "TOTAL", "", "", "", "", "sweep(ms):", total_runtime_ms,
    });
    std.debug.print("  {s:>10} | {s:>7} | {s:>9} | {s:>14} | {s:>14} | {s:>11} | {d:>11.1}\n", .{
        "", "", "", "", "", "wall(ms):", sweep_wall_ms,
    });
    std.debug.print("\n  total frames: {d}  particles-frames simulated: {d}\n", .{ sweep_total_frames, sweep_total_particles });
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

// --- JSONL row emission (refactor §6.6) ----------------------------------------
// Emits one JSON object per trial to stderr, prefixed `json,`. collect.py
// greps `^json,` and strips the prefix, appending the bare JSON to runs.jsonl.
// The row is fully self-describing: build-time provenance (git_sha,
// source_hash, machine_id, host, run_id, ts_utc from build options) + the
// algo_meta static axes (algo_fam, ordering, intermediates, golden_class,
// halide_expressible) + the per-trial measurements + the whole-run summary
// (iters, warmup, trials_per_n, sweep wall time, total frames/particles, end
// timestamp). Denormalized per §6.2 so duckdb GROUP BY works without joins.

/// One measured trial. Buffered during the sweep, emitted once at sweep end.
const TrialRec = struct {
    n: usize,
    bytes_per_p: usize,
    trial: usize,
    ns_frame: f64,
    ns_particle: f64,
    /// Elapsed nanoseconds of this trial's timed region (raw, = ns_frame*iters).
    trial_ns: f64,
    /// Frames simulated in this trial's timed region (= iters).
    frames: usize,
    /// Particle-frames this trial (= n * iters).
    particles_processed: u64,
};

/// Whole-run summary, constant across every trial row of one bench invocation.
/// Denormalized onto every emitted row.
const RunSummary = struct {
    threads: usize,
    iters: usize,
    warmup: usize,
    trials_per_n: usize,
    /// Wall time of the entire sweep (all N, all trials, including warmup).
    sweep_wall_ms: f64,
    /// Total frames simulated across the whole sweep (timed region only).
    sweep_total_frames: u64,
    /// Total particle-frames across the whole sweep (timed region only).
    sweep_total_particles: u64,
    /// Wall-clock end time of the sweep, YYYYMMDDTHHMMSSZ (same format as ts_utc).
    ts_end_utc: [16]u8,
    /// Collect run identity + start timestamp (runtime --run-id / --ts-utc),
    /// denormalized onto every JSONL row. NOT a build option — a build-time
    /// timestamp would invalidate zig's cache every collect.
    run_id: []const u8,
    ts_utc: []const u8,
};

/// Format Unix epoch seconds (UTC) as YYYYMMDDTHHMMSSZ — the same shape as the
/// build-time `ts_utc` — so a loader can compute run duration as end - start.
fn formatUtc(unix_secs: u64) [16]u8 {
    const epoch = std.time.epoch;
    const es = epoch.EpochSeconds{ .secs = unix_secs };
    const ed = es.getEpochDay();
    const ds = es.getDaySeconds();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        @as(u32, yd.year),
        @as(u32, md.month.numeric()),
        @as(u32, md.day_index) + 1,
        @as(u32, ds.getHoursIntoDay()),
        @as(u32, ds.getMinutesIntoHour()),
        @as(u32, ds.getSecondsIntoMinute()),
    }) catch unreachable;
    return buf;
}

fn emitJsonRow(comptime SimImpl: type, rec: TrialRec, summary: RunSummary) void {
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
    std.debug.print("\"run_id\":\"{s}\",", .{summary.run_id});
    std.debug.print("\"ts_utc\":\"{s}\",", .{summary.ts_utc});
    std.debug.print("\"host\":\"{s}\",", .{o.host});
    std.debug.print("\"machine_id\":\"{s}\",", .{o.machine_id});
    std.debug.print("\"mem_layout\":\"{s}\",", .{if (SimImpl.algo_meta) |cd| cd.mem_layout else ""});
    std.debug.print("\"algo\":\"{s}\",", .{o.name});
    std.debug.print("\"source_hash\":\"{s}\",", .{o.source_hash});
    std.debug.print("\"git_sha\":\"{s}\",", .{o.git_sha});
    std.debug.print("\"git_branch\":\"{s}\",", .{o.git_branch});
    std.debug.print("\"zig_version\":\"{s}\",", .{@import("builtin").zig_version_string});
    std.debug.print("\"death_q\":{d},", .{config.q});
    std.debug.print("\"threads\":{d},", .{summary.threads});
    std.debug.print("\"N\":{d},", .{rec.n});
    std.debug.print("\"bytes_per_particle\":{d},", .{rec.bytes_per_p});
    std.debug.print("\"trial\":{d},", .{rec.trial});
    std.debug.print("\"ns_frame\":{d:.1},", .{rec.ns_frame});
    std.debug.print("\"ns_particle\":{d:.4},", .{rec.ns_particle});
    // Per-trial workload + raw timing (so totals are derivable per row).
    std.debug.print("\"iters\":{d},", .{summary.iters});
    std.debug.print("\"warmup\":{d},", .{summary.warmup});
    std.debug.print("\"trial_ns\":{d:.0},", .{rec.trial_ns});
    std.debug.print("\"frames\":{d},", .{rec.frames});
    std.debug.print("\"particles_processed\":{d},", .{rec.particles_processed});
    std.debug.print("\"algo_fam\":\"{s}\",", .{algo_fam});
    std.debug.print("\"ordering\":\"{s}\",", .{ordering});
    std.debug.print("\"intermediates\":\"{s}\",", .{intermediates});
    std.debug.print("\"golden_class\":\"{s}\",", .{golden_class});
    // halide_expressible is prose (may contain spaces/parens) — quote + escape.
    std.debug.print("\"halide_expressible\":\"{s}\",", .{halide_expressible});
    // Whole-run summary (constant across every row of this bench invocation).
    std.debug.print("\"trials_per_n\":{d},", .{summary.trials_per_n});
    std.debug.print("\"sweep_wall_ms\":{d:.1},", .{summary.sweep_wall_ms});
    std.debug.print("\"sweep_total_frames\":{d},", .{summary.sweep_total_frames});
    std.debug.print("\"sweep_total_particles\":{d},", .{summary.sweep_total_particles});
    std.debug.print("\"ts_end_utc\":\"{s}\"", .{summary.ts_end_utc});
    std.debug.print("}}\n", .{});
}
