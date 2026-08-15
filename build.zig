const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- build options ---
    // -Dselect (multi-build): "all" | ML<layout> | <full algo name>. When set,
    //   build every matching algorithm in ONE configure (zig's DAG runner
    //   compiles them in parallel). When absent, fall back to -Dmem_layout /
    //   -Dalgo (single-algo, backward compat for the python callers + ad-hoc).
    //   (Named -Dselect, not -Dtarget: zig reserves -Dtarget for the build
    //   target triple — see b.standardTargetOptions above.)
    const select_opt = b.option([]const u8, "select", "all | ML<layout> | <full algo name> (multi-build). Overrides -Dmem_layout/-Dalgo.");
    const mem_layout_opt = b.option([]const u8, "mem_layout", "memory-layout id, e.g. ML01 (needs -Dalgo; single-algo unless -Dtarget is set)");
    const algo_opt = b.option([]const u8, "algo", "algorithm name, e.g. AF02.LP1-autovec.LP2-simple (single-algo unless -Dtarget is set)");
    const halide_variant_opt = b.option([]const u8, "halide_variant", "Halide sweep candidate id (links a pre-generated out/halide/<algo>_<id>.a)");
    const halide_prefix_opt = b.option([]const u8, "halide_prefix", "Halide generator output base dir (default out/halide; per-worker when collect.py parallelizes)") orelse "out/halide";
    const mode_str = b.option([]const u8, "mode", "play | bench | audit") orelse "play";
    // Death model (optimization-framework.md §7): competing risks. `-Ddeath`
    // is the per-frame accident rate q (a float, default 0 = natural). The
    // old `natural | half | alternating` enum is retired; natural ≡ q=0
    // comptime-prunes to the plain age test, half is now q≈0.5 of the
    // competing-risks family, alternating is gone (the hybrid's high-q end
    // covers it).
    const death_q = b.option(f64, "death", "per-frame accident rate q (natural = 0; e.g. 0.5)") orelse 0.0;
    if (!std.math.isFinite(death_q) or death_q < 0.0 or death_q >= 1.0)
        std.debug.panic("invalid -Ddeath={d} (expect 0 <= q < 1)", .{death_q});

    // --- provenance build options ---
    // git_sha/git_branch computed at configure time via `git` and baked (cheap,
    // stable per commit). source_hash/machine_id/host are NOT build options —
    // the bench binary takes them as runtime flags (--source-hash/--machine-id/
    // --host) from collect/bench.py, so `make build` stays pure-zig (no python
    // provenance computation in the build path).
    const git_sha = blk: {
        const out = b.run(&.{ "git", "rev-parse", "--short", "HEAD" });
        break :blk std.mem.trim(u8, out, &std.ascii.whitespace);
    };
    const git_branch = blk: {
        const out = b.run(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });
        break :blk std.mem.trim(u8, out, &std.ascii.whitespace);
    };
    // (run_id / ts_utc are RUNTIME flags now — --run-id / --ts-utc, stamped on
    // each JSONL row. They were build options, which invalidated zig's cache
    // every collect (the timestamp changed) and forced a full recompile.)
    const keep_debug = b.option(bool, "keep-debug", "keep debug info (strip=false; same ReleaseFast codegen — for godbolt source↔asm attribution)") orelse false;

    const mode: Mode = blk: {
        if (std.mem.eql(u8, mode_str, "play")) break :blk .play;
        if (std.mem.eql(u8, mode_str, "bench")) break :blk .bench;
        if (std.mem.eql(u8, mode_str, "audit")) break :blk .audit;
        if (std.mem.eql(u8, mode_str, "manifest")) break :blk .manifest;
        std.debug.panic("invalid -Dmode='{s}' (play|bench|audit|manifest)", .{mode_str});
    };
    const mode_enum: Mode = mode;
    // raylib (GUI) is needed only for play. bench/audit/manifest are headless —
    // linking no GUI library makes them portable (no Cocoa/OpenGL) and smaller.
    const link_raylib = (mode == .play);

    // --- selection: which (mem_layout, algo) pairs to build ---
    const sel = resolveSelection(b.allocator, select_opt, mem_layout_opt, algo_opt);

    // scope banner (D12): one line up front so `make build` states its scope.
    // zig's native std.Progress renders the live step bar during the run.
    const scope = if (select_opt) |t| t else "default";
    std.debug.print("build: {d} algorithm(s) [{s}] -> out/bin (.{s})\n", .{ sel.len, scope, mode_str });

    // --- build one exe per selection (parallel via zig's DAG runner) ---
    var first_exe: ?*std.Build.Step.Compile = null;
    for (sel) |s| {
        const exe = addAlgoExe(b, target, optimize, s.mem_layout, s.algo, mode_str, mode_enum, link_raylib, death_q, git_sha, git_branch, keep_debug, halide_variant_opt, halide_prefix_opt);
        if (first_exe == null) first_exe = exe;
    }

    // `run` step: convenience for single-algo builds (runs the first/only exe).
    // For multi-build, run the installed binaries directly (./out/bin/<algo>.<mode>).
    const run = b.addRunArtifact(first_exe.?);
    const run_step = b.step("run", "Run the app (single-algo; for multi-build use ./out/bin/<algo>.<mode>)");
    run_step.dependOn(&run.step);

    // --- unit tests (render_opt's rasterizer byte-equivalence proof) ---
    // The test needs a valid options struct (death pattern); use the reference
    // algo's opts regardless of the selection.
    const test_opts = makeOpts(b, "ML01", "AF02.LP1-autovec.LP2-simple", mode_enum, link_raylib, death_q, git_sha, git_branch);
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addOptions("options", test_opts); // config.zig imports options (death pattern)
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests (render_opt rasterizer equivalence)");
    test_step.dependOn(&run_tests.step);

    // --- manifest diagnostic (reporting-and-analysis.md §9.5) ---
    // The declaration blocks in algorithm files are the single source of truth;
    // `zig build manifests` prints the registered roster to stdout as a
    // diagnostic (what's in sim_map). There is no checked-in manifest file;
    // run this to inspect the registry after editing any algo_meta.
    const manifest_exe = b.addExecutable(.{
        .name = "dod-manifest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // Manifest mode: build with -Dmode=manifest and a default sim
    // (ML01.AF02.LP1-autovec.LP2-simple);
    // main.zig iterates the whole sim_map regardless of the selected sim.
    const manifest_opts = b.addOptions();
    manifest_opts.addOption([]const u8, "name", "ML01.AF02.LP1-autovec.LP2-simple");
    manifest_opts.addOption([]const u8, "label", "manifest");
    manifest_opts.addOption(bool, "is_reference", false);
    manifest_opts.addOption(f64, "death", 0.0);
    manifest_opts.addOption(Mode, "mode", .manifest);
    manifest_opts.addOption(bool, "link_raylib", false); // manifest is headless
    manifest_exe.root_module.addOptions("options", manifest_opts);
    // No raylib: main.zig gates the play/raylib import behind (mode == .play),
    // so manifest mode compiles with no GUI library at all.
    const run_manifest = b.addRunArtifact(manifest_exe);
    const manifest_step = b.step("manifests", "Print the registered algorithm roster to stdout (diagnostic)");
    manifest_step.dependOn(&run_manifest.step);
}

pub const Mode = enum { play, bench, audit, manifest };

const AlgoEntry = struct { mem_layout: []const u8, algo: []const u8, label: []const u8 };
const Selection = struct { mem_layout: []const u8, algo: []const u8 };

/// The algorithm registry (mem-layout-verticals.md §9): every buildable
/// (mem_layout, algo) and its HUD label. main.zig's comptime map must have an
/// arm for each. Memory layouts land one vertical at a time.
const algo_labels = [_]AlgoEntry{
    // --- AF01 (Integrate+Decide+Respawn+Render — fully fused) ---
    .{ .mem_layout = "ML01", .algo = "AF01.LP1-fused", .label = "ML01.AF01.LP1-fused (AF01: fused math+decide+respawn+render; FRAMEBUFFER-ONLY)" },
    // --- AF02 (Integrate+Decide+Respawn | Render — the reference family) ---
    .{ .mem_layout = "ML01", .algo = "AF02.LP1-autovec.LP2-simple", .label = "ML01.AF02.LP1-autovec.LP2-simple (AF02: autovec branchy step + r0 render; reference sim)" },
    .{ .mem_layout = "ML01", .algo = "AF02.LP1-autovec.LP2-opt", .label = "ML01.AF02.LP1-autovec.LP2-opt (AF02: autovec branchy step + optimized r1 render)" },
    .{ .mem_layout = "ML01", .algo = "AF02.LP1-scalar.LP2-simple", .label = "ML01.AF02.LP1-scalar.LP2-simple (AF02: scalar-forced step + r0 render; de-vec control)" },
    .{ .mem_layout = "ML01", .algo = "AF02.LP1-unroll.LP2-simple", .label = "ML01.AF02.LP1-unroll.LP2-simple (AF02: unroll-by-4 branchy step + r0 render; isolates the unroll knob)" },
    .{ .mem_layout = "ML01", .algo = "AF02.LP1-autovec-par.LP2-simple", .label = "ML01.AF02.LP1-autovec-par.LP2-simple (AF02: parallel branchy math+decide | serial respawn | r0 render)" },
    .{ .mem_layout = "ML01", .algo = "AF02.LP1-blend.LP2-simple", .label = "ML01.AF02.LP1-blend.LP2-simple (AF02: Zig branchless blend + r0 render; STATISTICAL)" },
    .{ .mem_layout = "ML01", .algo = "AF02.LP1-blend-par.LP2-simple", .label = "ML01.AF02.LP1-blend-par.LP2-simple (AF02: parallel Zig blend + r0 render; STATISTICAL)" },
    .{ .mem_layout = "ML01", .algo = "AF02.LP1-halide.LP2-simple", .label = "ML01.AF02.LP1-halide.LP2-simple (AF02: Halide branchless blend + r0 render; STATISTICAL)" },
    .{ .mem_layout = "ML01", .algo = "AF02.LP1-halide.LP2-opt", .label = "ML01.AF02.LP1-halide.LP2-opt (AF02: Halide branchless blend + optimized r1 render; STATISTICAL)" },
    .{ .mem_layout = "ML01", .algo = "AF02.LP1-halide-par.LP2-simple", .label = "ML01.AF02.LP1-halide-par.LP2-simple (AF02: parallel Halide blend + r0 render; STATISTICAL; PREDICTED DRAM CHAMPION)" },
    // --- AF03 (Integrate+Decide | Respawn+Render) ---
    .{ .mem_layout = "ML01", .algo = "AF03.LP1-autovec.LP2-fused", .label = "ML01.AF03.LP1-autovec.LP2-fused (AF03: math+decide→mask | fused scan+respawn+render; FRAMEBUFFER-ONLY)" },
    // --- AF04 (Integrate | Decide+Respawn+Render) ---
    .{ .mem_layout = "ML01", .algo = "AF04.LP1-autovec.LP2-fused", .label = "ML01.AF04.LP1-autovec.LP2-fused (AF04: math | fused decide+respawn+render; FRAMEBUFFER-ONLY)" },
    // --- AF05 (Integrate | Decide+Respawn | Render — the natural seam) ---
    .{ .mem_layout = "ML01", .algo = "AF05.LP1-autovec.LP2-simple", .label = "ML01.AF05.LP1-autovec.LP2-simple (AF05: math | decide+respawn | r0 render)" },
    .{ .mem_layout = "ML01", .algo = "AF05.LP1-autovec-par.LP2-simple", .label = "ML01.AF05.LP1-autovec-par.LP2-simple (AF05: parallel math | decide+respawn | r0 render)" },
    .{ .mem_layout = "ML01", .algo = "AF05.LP1-halide.LP2-simple", .label = "ML01.AF05.LP1-halide.LP2-simple (AF05: Halide math | decide+respawn | r0 render)" },
    .{ .mem_layout = "ML01", .algo = "AF05.LP1-halide-par.LP2-simple", .label = "ML01.AF05.LP1-halide-par.LP2-simple (AF05: parallel Halide math | decide+respawn | r0 render)" },
    // --- AF06 (Integrate+Decide | Respawn | Render — mask/list/partition impl choice) ---
    .{ .mem_layout = "ML01", .algo = "AF06.LP1-autovec.LP2-mask", .label = "ML01.AF06.LP1-autovec.LP2-mask (AF06: math+decide→mask | scan+respawn | r0 render)" },
    .{ .mem_layout = "ML01", .algo = "AF06.LP1-autovec-par.LP2-mask-rmerge", .label = "ML01.AF06.LP1-autovec-par.LP2-mask-rmerge (AF06: parallel math+decide→mask | serial respawn | r0 render; DE-RISK)" },
    .{ .mem_layout = "ML01", .algo = "AF06.LP1-halide.LP2-mask", .label = "ML01.AF06.LP1-halide.LP2-mask (AF06: Halide math+decide→mask | scan+respawn | r0 render)" },
    .{ .mem_layout = "ML01", .algo = "AF06.LP1-autovec.LP2-list", .label = "ML01.AF06.LP1-autovec.LP2-list (AF06: math+decide→list | respawn-dead | r0 render)" },
    .{ .mem_layout = "ML01", .algo = "AF06.LP1-autovec-par.LP2-list-rmerge", .label = "ML01.AF06.LP1-autovec-par.LP2-list-rmerge (AF06: parallel math+decide→list | ranked-merge respawn | r0 render)" },
    .{ .mem_layout = "ML01", .algo = "AF06.LP1-autovec.LP2-list-fused", .label = "ML01.AF06.LP1-autovec.LP2-list-fused (AF06: math+decide→list | fused respawn+render(dead) | render(live); FRAMEBUFFER-ONLY)" },
};

/// Resolve the build selection into a list of (mem_layout, algo) pairs.
/// - selection = "all"        → every entry in algo_labels.
/// - selection = ML<layout>   → every entry of that layout.
/// - selection = <full algo>  → the one (validated against algo_labels).
/// - selection unset          → single-algo from -Dmem_layout/-Dalgo (defaults
///                              ML01 / AF02.LP1-autovec.LP2-simple), backward compat.
/// Uses the in-build.zig algo_labels registry — no configure-time file I/O,
/// stays self-contained (sweep_config.py parses the same registry for the
/// collection roster). Allocated via b.allocator (lives for the build).
fn resolveSelection(
    allocator: std.mem.Allocator,
    selection: ?[]const u8,
    mem_layout_opt: ?[]const u8,
    algo_opt: ?[]const u8,
) []const Selection {
    if (selection) |t| {
        if (std.mem.eql(u8, t, "all")) {
            const out = allocator.alloc(Selection, algo_labels.len) catch unreachable;
            for (algo_labels, 0..) |e, i| out[i] = .{ .mem_layout = e.mem_layout, .algo = e.algo };
            return out;
        }
        // ML<layout>? (any entry matches this mem_layout)
        var is_layout = false;
        for (algo_labels) |e| {
            if (std.mem.eql(u8, e.mem_layout, t)) {
                is_layout = true;
                break;
            }
        }
        if (is_layout) {
            var count: usize = 0;
            for (algo_labels) |e| {
                if (std.mem.eql(u8, e.mem_layout, t)) count += 1;
            }
            const out = allocator.alloc(Selection, count) catch unreachable;
            var i: usize = 0;
            for (algo_labels) |e| {
                if (std.mem.eql(u8, e.mem_layout, t)) {
                    out[i] = .{ .mem_layout = e.mem_layout, .algo = e.algo };
                    i += 1;
                }
            }
            return out;
        }
        // Else: a full algo name "ML<layout>.<algo>". Split on the first dot.
        const dot = std.mem.indexOfScalar(u8, t, '.') orelse
            std.debug.panic("-Dselect='{s}' is not 'all', a layout (MLxx), or a full algo name (MLxx.<algo>)", .{t});
        const ml = t[0..dot];
        const algo = t[dot + 1 ..];
        if (algoLabel(ml, algo) == null)
            std.debug.panic("-Dselect='{s}': not a registered algorithm (see algo_labels in build.zig)", .{t});
        const out = allocator.alloc(Selection, 1) catch unreachable;
        out[0] = .{ .mem_layout = ml, .algo = algo };
        return out;
    }
    // No -Dselect: single-algo path (backward compat for -Dmem_layout/-Dalgo).
    const ml = mem_layout_opt orelse "ML01";
    const algo = algo_opt orelse "AF02.LP1-autovec.LP2-simple";
    if (algoLabel(ml, algo) == null) {
        // Collect the valid algorithm names for the error message.
        var valid = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
        for (algo_labels) |s| {
            if (std.mem.eql(u8, s.mem_layout, ml)) {
                valid.appendSlice(allocator, s.algo) catch unreachable;
                valid.appendSlice(allocator, ", ") catch unreachable;
            }
        }
        if (valid.items.len == 0)
            std.debug.panic("unknown mem_layout '{s}' (no algorithms registered; see algo_labels in build.zig)", .{ml});
        std.debug.panic("invalid -Dalgo='{s}' for mem_layout {s} — valid: {s}", .{ algo, ml, valid.items[0 .. valid.items.len - 2] });
    }
    const out = allocator.alloc(Selection, 1) catch unreachable;
    out[0] = .{ .mem_layout = ml, .algo = algo };
    return out;
}

/// Build the per-algo options struct (name/label/is_reference + the shared
/// build config: death, mode, link_raylib, provenance). Shared by addAlgoExe
/// and the test step.
fn makeOpts(
    b: *std.Build,
    mem_layout: []const u8,
    algo: []const u8,
    mode: Mode,
    link_raylib: bool,
    death_q: f64,
    git_sha: []const u8,
    git_branch: []const u8,
) *std.Build.Step.Options {
    const name = b.fmt("{s}.{s}", .{ mem_layout, algo });
    const label = algoLabel(mem_layout, algo) orelse
        std.debug.panic("makeOpts: unknown algorithm {s}.{s}", .{ mem_layout, algo });
    const opts = b.addOptions();
    opts.addOption([]const u8, "name", name);
    opts.addOption([]const u8, "label", label);
    // The golden files are generated by the reference sim only:
    // ML01.AF02.LP1-autovec.LP2-simple (= arc stage 1's step, scavenged).
    opts.addOption(bool, "is_reference", std.mem.eql(u8, name, "ML01.AF02.LP1-autovec.LP2-simple"));
    opts.addOption(f64, "death", death_q);
    opts.addOption(Mode, "mode", mode);
    opts.addOption(bool, "link_raylib", link_raylib);
    // Provenance (refactor §6.6): stamped on every JSONL bench row so a row
    // pins the exact code + machine that produced it.
    opts.addOption([]const u8, "git_sha", git_sha);
    opts.addOption([]const u8, "git_branch", git_branch);
    return opts;
}

/// Create + install ONE algorithm's executable (opts + exe + halide gen + raylib
/// link). Called once per selection entry. Returns the exe for the run step.
fn addAlgoExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mem_layout: []const u8,
    algo: []const u8,
    mode_str: []const u8,
    mode: Mode,
    link_raylib: bool,
    death_q: f64,
    git_sha: []const u8,
    git_branch: []const u8,
    keep_debug: bool,
    halide_variant_opt: ?[]const u8,
    halide_prefix: []const u8,
) *std.Build.Step.Compile {
    const opts = makeOpts(b, mem_layout, algo, mode, link_raylib, death_q, git_sha, git_branch);

    // --- raylib C library (compiled directly; raylib-zig build is broken on 0.17-dev) ---
    // Only built for play (bench/audit/manifest are headless — no GUI link).
    const raylib_lib: ?*std.Build.Step.Compile = if (link_raylib) addRaylib(b, target, optimize) else null;

    // --- main exe ---
    // Flat name: <mem_layout>.<algo>.<mode>  →  out/bin/ML01.AF03.LP1-halide.LP2-simple.bench
    // One binary per (algorithm, mode); behavior (q, N, …) is runtime config.
    const name = b.fmt("{s}.{s}", .{ mem_layout, algo });
    const exe_name = b.fmt("{s}.{s}", .{ name, mode_str });
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = if (keep_debug) false else null,
            .link_libc = true,
        }),
    });

    // --- Halide path: ONLY for algorithms whose loop 1 is halide (the LP1-halide
    // loop). Fully gated: Zig algorithms never touch python/Halide. The
    // generator (Python bindings) emits out/halide/<base>[_<variant>].{h,a}
    // with the runtime bundled; the exe links the static .a. No libHalide at
    // runtime.
    if (halideGenBase(algo)) |base| {
        // If this python is missing, the generator step fails loudly at
        // build time; set HALIDE_PYTHON or create the env:
        //   uv sync
        const python = b.graph.environ_map.get("HALIDE_PYTHON") orelse ".venv/bin/python";
        // Derive the Halide schedule from the algo name: an algo containing
        // "-par" gets {"parallel":true}; the plain algo gets the default.
        // NOTE: the `parallel(i)` SCHEDULE is still baked into the kernel
        // at build time, but the -par cell's `initExtra` now caps the
        // Halide runtime pool via `halide_set_num_threads(sim.threads)`
        // (issue #4) — so `--threads T` governs actual CPU use. The serial
        // `halide` kernel has no parallel loop and needs no cap.
        // (-Dhalide_variant still works for ad-hoc sweep variants; it adds
        // a suffix to the stem and is expected to be pre-generated.)
        const sched_json: []const u8 = if (std.mem.indexOf(u8, algo, "-par") != null)
            "{\"parallel\":true}"
        else
            "{}";
        // The stem: the base name, plus an optional explicit variant suffix.
        // For a "-par" algo we bake "_par" into the stem so the parallel .a
        // doesn't collide with the scalar .a (same generator, different schedule).
        const stem_par = if (std.mem.indexOf(u8, algo, "-par") != null) "_par" else "";
        const stem = if (halide_variant_opt) |v| b.fmt("{s}_{s}", .{ base, v }) else b.fmt("{s}{s}", .{ base, stem_par });
        const out_prefix = b.fmt("{s}/{s}", .{ halide_prefix, stem });
        // Always run the generator for the derived schedule (no more
        // "pre-generated variant" expectation). A sweep can override the
        // schedule via -Dhalide_variant=<suffix> (pre-generated) if needed.
        const gen_dir = b.fmt("src/layouts/{s}/{s}_gen.py", .{ mem_layout, base });
        const gen = b.addSystemCommand(&.{
            python,
            gen_dir,
            out_prefix,
            sched_json,
            // q is now a runtime Halide Param (the Zig wrapper passes config.q
            // to the kernel), so the generator no longer takes it on argv.
        });
        exe.step.dependOn(&gen.step);
        exe.root_module.addObjectFile(b.path(b.fmt("{s}.a", .{out_prefix})));
    }

    exe.root_module.addOptions("options", opts);
    // raylib binding + link ONLY when link_raylib (play). bench/audit/manifest
    // builds skip this entirely — no raylib module, no GUI frameworks linked.
    if (raylib_lib) |rl| {
        exe.root_module.addImport("raylib", raylib_module: {
            const rl_mod = b.createModule(.{
                .root_source_file = b.path("src/bindings/raylib.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            rl_mod.linkLibrary(rl);
            break :raylib_module rl_mod;
        });
    }

    b.installArtifact(exe);
    return exe;
}

/// Returns the generator base name for a Halide algorithm, or null if the
/// algorithm is not Halide. Used both to gate the generator step and to find the .a.
/// Any algorithm containing "LP1-halide" maps to "LP1-halide" (the loop-1 Halide
/// pipeline generator, in loops/).
fn halideGenBase(algo: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, algo, "LP1-halide") != null) {
        // Map the algorithm's family prefix: AF02.LP1-halide / AF05.LP1-halide / AF06.LP1-halide.
        // Each has its own generator + FFI binding at the mem_layout root.
        if (std.mem.startsWith(u8, algo, "AF05.")) return "AF05.LP1-halide";
        if (std.mem.startsWith(u8, algo, "AF06.")) return "AF06.LP1-halide";
        return "AF02.LP1-halide";
    }
    return null;
}

fn algoLabel(mem_layout: []const u8, algo: []const u8) ?[]const u8 {
    for (algo_labels) |s|
        if (std.mem.eql(u8, s.mem_layout, mem_layout) and std.mem.eql(u8, s.algo, algo)) return s.label;
    return null;
}

fn addRaylib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const c_flags = &.{
        "-std=c11",
        "-DPLATFORM_DESKTOP",
        "-DGRAPHICS_API_OPENGL_33",
        // Disable raylib's image-export helpers (ExportImage* — unused by us;
        // --record pipes raw RGBA straight into ffmpeg, no image lib). Keeps
        // raylib lean and avoids bundling stb_image_write inside rtextures.c.
        "-DSUPPORT_IMAGE_EXPORT=0",
        "-ObjC",
    };

    const sources = [_][]const u8{
        "rcore.c",
        "rglfw.c",
        "rshapes.c",
        "rtextures.c",
        "rtext.c",
        "rmodels.c",
    };

    const lib = b.addLibrary(.{
        .name = "raylib",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });
    inline for (sources) |s| {
        lib.root_module.addCSourceFile(.{
            .file = b.path("vendor/raylib/src/" ++ s),
            .flags = c_flags,
        });
    }
    lib.root_module.addIncludePath(b.path("vendor/raylib/src"));
    lib.root_module.addIncludePath(b.path("vendor/raylib/src/external/glfw/include"));

    lib.root_module.linkFramework("Cocoa", .{});
    lib.root_module.linkFramework("IOKit", .{});
    lib.root_module.linkFramework("CoreVideo", .{});
    lib.root_module.linkFramework("CoreFoundation", .{});
    lib.root_module.linkFramework("OpenGL", .{});

    // raylib is statically linked into the exe via linkLibrary (above) — do NOT
    // installArtifact(lib). The installed libraylib.a is never read at runtime
    // (the exe already linked it), and installing it would copy the identical
    // 4.8 MB .a into EVERY -p prefix (out/lib, out/{algo}/lib, ...) — pure
    // duplication across algorithms. Build it + link it, but don't stage the .a.
    return lib;
}
