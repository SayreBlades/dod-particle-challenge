const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- build options: -Dmem_layout=ML1 -Dalgo=name (the mem_layout verticals) ---
    // The arc (src/stages/) is retired as a build target — relocated to
    // .scratch/orig/ as reference history (optimization-framework §11/§16.1).
    // -Dstage is gone; its algorithms are scavenged where useful
    // (ML1.AF1.LP1-autovec.LP2-simple == arc stage 1's step).
    const mem_layout_opt = b.option([]const u8, "mem_layout", "memory-layout id, e.g. ML1 (needs -Dalgo)");
    const algo_opt = b.option([]const u8, "algo", "algorithm name, e.g. AF1.LP1-autovec.LP2-simple");
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

    // --- provenance build options (refactor §6.6) ---
    // git_sha/git_branch computed at configure time via `git`; source_hash
    // /machine_id/host passed by collect.py (computed from algo_hash.py /
    // hardware_json.py). Defaults to empty/"unknown" for ad-hoc builds.
    const git_sha = blk: {
        const out = b.run(&.{ "git", "rev-parse", "--short", "HEAD" });
        break :blk std.mem.trim(u8, out, &std.ascii.whitespace);
    };
    const git_branch = blk: {
        const out = b.run(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });
        break :blk std.mem.trim(u8, out, &std.ascii.whitespace);
    };
    const source_hash = b.option([]const u8, "source_hash", "algorithm import-closure hash (from scripts/algo_hash.py)") orelse "";
    const machine_id = b.option([]const u8, "machine_id", "host machine id (from hardware_json.py)") orelse "";
    const host = b.option([]const u8, "host", "hostname") orelse "";
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

    // Resolve the selection to a canonical sim name + display label.
    // Names are "ML<mem_layout>.<algo>"; main.zig's comptime registry must have
    // an arm for each.
    var name: []const u8 = undefined;
    var label: []const u8 = undefined;
    var mem_layout_sel: ?[]const u8 = null;
    var algo_sel: ?[]const u8 = null;
    {
        const mem_layout = mem_layout_opt orelse "ML1";
        const algo = algo_opt orelse "AF1.LP1-autovec.LP2-simple";
        mem_layout_sel = mem_layout;
        algo_sel = algo;
        name = b.fmt("{s}.{s}", .{ mem_layout, algo });
        label = algoLabel(mem_layout, algo) orelse {
            // Collect the valid algorithm names for the error message.
            var valid = std.ArrayList(u8).initCapacity(b.allocator, 128) catch unreachable;
            for (algo_labels) |s| {
                if (std.mem.eql(u8, s.mem_layout, mem_layout)) {
                    valid.appendSlice(b.allocator, s.algo) catch unreachable;
                    valid.appendSlice(b.allocator, ", ") catch unreachable;
                }
            }
            if (valid.items.len == 0)
                std.debug.panic("unknown mem_layout '{s}' (no algorithms registered; see algo_labels in build.zig)", .{mem_layout});
            std.debug.panic("invalid -Dalgo='{s}' for mem_layout {s} — valid: {s}", .{ algo, mem_layout, valid.items[0 .. valid.items.len - 2] });
        };
    }

    const opts = b.addOptions();
    opts.addOption([]const u8, "name", name);
    opts.addOption([]const u8, "label", label);
    // The golden files are generated by the reference sim only:
    // ML1.AF1.LP1-autovec.LP2-simple
    // (= arc stage 1's step, scavenged). The arc itself is no longer a build
    // target (relocated to .scratch/orig/).
    opts.addOption(bool, "is_reference", std.mem.eql(u8, name, "ML1.AF1.LP1-autovec.LP2-simple"));
    opts.addOption(f64, "death", death_q);
    opts.addOption(Mode, "mode", mode_enum);
    opts.addOption(bool, "link_raylib", link_raylib);
    // Provenance (refactor §6.6): stamped on every JSONL bench row so a row
    // pins the exact code + machine that produced it.
    opts.addOption([]const u8, "git_sha", git_sha);
    opts.addOption([]const u8, "git_branch", git_branch);
    opts.addOption([]const u8, "source_hash", source_hash);
    opts.addOption([]const u8, "machine_id", machine_id);
    opts.addOption([]const u8, "host", host);
    // (run_id / ts_utc moved to runtime --run-id / --ts-utc — see above.)

    // --- raylib C library (compiled directly; raylib-zig build is broken on 0.17-dev) ---
    // Only built for play (bench/audit/manifest are headless — no GUI link).
    const raylib_lib: ?*std.Build.Step.Compile = if (link_raylib) addRaylib(b, target, optimize) else null;

    // --- main exe ---
    // Flat name: <mem_layout>.<algo>.<mode>  →  out/bin/ML1.AF3.LP1-halide.LP2-simple.bench
    // One binary per (algorithm, mode); behavior (q, N, …) is runtime config.
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
    if (algo_sel) |algo| {
        if (halideGenBase(algo)) |base| {
            const mem_layout = mem_layout_sel.?;
            // If this python is missing, the generator step fails loudly at
            // build time; set HALIDE_PYTHON or create the env:
            //   uv sync
            const python = b.graph.environ_map.get("HALIDE_PYTHON") orelse ".venv/bin/python";
            // Derive the Halide schedule from the algo name: an algo containing
            // "-par" gets {"parallel":true}; the plain algo gets the default.
            // NOTE: this BAKES parallelism into the kernel at build time — the
            // runtime --threads flag does NOT govern it (Halide's runtime pool
            // defaults to all cores). Making it a runtime variant is tracked in
            // https://github.com/SayreBlades/dod-particle-challenge/issues/4
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
            const out_prefix = b.fmt("{s}/{s}", .{ halide_prefix_opt, stem });
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

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run.step);

    // --- unit tests (render_opt's rasterizer byte-equivalence proof) ---
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addOptions("options", opts); // config.zig imports options (death pattern)
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests (render_opt rasterizer equivalence)");
    test_step.dependOn(&run_tests.step);

    // --- manifest diagnostic (reporting-and-analysis.md §9.5) ---
    // The declaration blocks in algorithm files are the single source of truth;
    // `zig build manifests` prints the registered roster to stdout as a
    // diagnostic (what's in sim_map). There is no checked-in manifest file
    // (experiments/cells/ was retired); run this to inspect the registry
    // after editing any algo_meta.
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
    // (ML1.AF1.LP1-autovec.LP2-simple);
    // main.zig iterates the whole sim_map regardless of the selected sim.
    const manifest_opts = b.addOptions();
    manifest_opts.addOption([]const u8, "name", "ML1.AF1.LP1-autovec.LP2-simple");
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

/// The algorithm registry (mem-layout-verticals.md §9): every buildable
/// (mem_layout, algo) and its HUD label. main.zig's comptime map must have an
/// arm for each. Memory layouts land one vertical at a time.
const algo_labels = [_]AlgoEntry{
    .{ .mem_layout = "ML1", .algo = "AF1.LP1-autovec.LP2-simple", .label = "ML1.AF1.LP1-autovec.LP2-simple (AF1: autovec branchy step + r0 render; reference sim)" },
    .{ .mem_layout = "ML1", .algo = "AF1.LP1-autovec.LP2-opt", .label = "ML1.AF1.LP1-autovec.LP2-opt (AF1: autovec branchy step + optimized r1 render)" },
    .{ .mem_layout = "ML1", .algo = "AF1.LP1-scalar.LP2-simple", .label = "ML1.AF1.LP1-scalar.LP2-simple (AF1: scalar-forced step + r0 render; de-vec control)" },
    .{ .mem_layout = "ML1", .algo = "AF1.LP1-unroll.LP2-simple", .label = "ML1.AF1.LP1-unroll.LP2-simple (AF1: unroll-by-4 branchy step + r0 render; isolates the unroll knob)" },
    .{ .mem_layout = "ML1", .algo = "AF1.LP1-autovec-par.LP2-simple", .label = "ML1.AF1.LP1-autovec-par.LP2-simple (AF1: parallel branchy math+decide | serial respawn | r0 render)" },
    .{ .mem_layout = "ML1", .algo = "AF1.LP1-blend.LP2-simple", .label = "ML1.AF1.LP1-blend.LP2-simple (AF1: Zig branchless blend + r0 render; STATISTICAL)" },
    .{ .mem_layout = "ML1", .algo = "AF1.LP1-blend-par.LP2-simple", .label = "ML1.AF1.LP1-blend-par.LP2-simple (AF1: parallel Zig blend + r0 render; STATISTICAL)" },
    .{ .mem_layout = "ML1", .algo = "AF1.LP1-halide.LP2-simple", .label = "ML1.AF1.LP1-halide.LP2-simple (AF1: Halide branchless blend + r0 render; STATISTICAL)" },
    .{ .mem_layout = "ML1", .algo = "AF1.LP1-halide.LP2-opt", .label = "ML1.AF1.LP1-halide.LP2-opt (AF1: Halide branchless blend + optimized r1 render; STATISTICAL)" },
    .{ .mem_layout = "ML1", .algo = "AF1.LP1-halide-par.LP2-simple", .label = "ML1.AF1.LP1-halide-par.LP2-simple (AF1: parallel Halide blend + r0 render; STATISTICAL; PREDICTED DRAM CHAMPION)" },
    .{ .mem_layout = "ML1", .algo = "AF2.LP1-autovec.LP2-simple", .label = "ML1.AF2.LP1-autovec.LP2-simple (AF2: math | decide+respawn | r0 render)" },
    .{ .mem_layout = "ML1", .algo = "AF2.LP1-autovec-par.LP2-simple", .label = "ML1.AF2.LP1-autovec-par.LP2-simple (AF2: parallel math | decide+respawn | r0 render)" },
    .{ .mem_layout = "ML1", .algo = "AF2.LP1-halide.LP2-simple", .label = "ML1.AF2.LP1-halide.LP2-simple (AF2: Halide math | decide+respawn | r0 render)" },
    .{ .mem_layout = "ML1", .algo = "AF2.LP1-halide-par.LP2-simple", .label = "ML1.AF2.LP1-halide-par.LP2-simple (AF2: parallel Halide math | decide+respawn | r0 render)" },
    .{ .mem_layout = "ML1", .algo = "AF3.LP1-halide.LP2-simple", .label = "ML1.AF3.LP1-halide.LP2-simple (AF3: Halide math+decide→mask | scan+respawn | r0 render)" },
    .{ .mem_layout = "ML1", .algo = "AF3.LP1-autovec.LP2-simple", .label = "ML1.AF3.LP1-autovec.LP2-simple (AF3: math+decide→mask | scan+respawn | r0 render)" },
    .{ .mem_layout = "ML1", .algo = "AF3.LP1-autovec-par.LP2-rmerge", .label = "ML1.AF3.LP1-autovec-par.LP2-rmerge (AF3: parallel math+decide→mask | serial respawn | r0 render; DE-RISK)" },
    .{ .mem_layout = "ML1", .algo = "AF4.LP1-autovec.LP2-simple", .label = "ML1.AF4.LP1-autovec.LP2-simple (AF4: math+decide→list | respawn-dead | r0 render)" },
    .{ .mem_layout = "ML1", .algo = "AF4.LP1-autovec-par.LP2-rmerge", .label = "ML1.AF4.LP1-autovec-par.LP2-rmerge (AF4: parallel math+decide→list | ranked-merge respawn | r0 render)" },
    .{ .mem_layout = "ML1", .algo = "AF5.LP1-fused", .label = "ML1.AF5.LP1-fused (AF5: fused math+decide+respawn+render; FRAMEBUFFER-ONLY)" },
    .{ .mem_layout = "ML1", .algo = "AF6.LP1-autovec.LP2-fused", .label = "ML1.AF6.LP1-autovec.LP2-fused (AF6: math | fused decide+respawn+render; FRAMEBUFFER-ONLY)" },
    .{ .mem_layout = "ML1", .algo = "AF7.LP1-autovec.LP2-fused", .label = "ML1.AF7.LP1-autovec.LP2-fused (AF7: math+decide→mask | fused scan+respawn+render; FRAMEBUFFER-ONLY)" },
    .{ .mem_layout = "ML1", .algo = "AF8.LP1-autovec.LP2-fused", .label = "ML1.AF8.LP1-autovec.LP2-fused (AF8: math+decide→list | fused respawn+render(dead) | render(live); FRAMEBUFFER-ONLY)" },
};

/// Returns the generator base name for a Halide algorithm, or null if the
/// algorithm is not Halide. Used both to gate the generator step and to find the .a.
/// Any algorithm containing "LP1-halide" maps to "LP1-halide" (the loop-1 Halide
/// pipeline generator, in loops/).
fn halideGenBase(algo: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, algo, "LP1-halide") != null) {
        // Map the algorithm's family prefix: AF1.LP1-halide / AF2.LP1-halide / AF3.LP1-halide.
        // Each has its own generator + FFI binding at the mem_layout root.
        if (std.mem.startsWith(u8, algo, "AF2.")) return "AF2.LP1-halide";
        if (std.mem.startsWith(u8, algo, "AF3.")) return "AF3.LP1-halide";
        return "AF1.LP1-halide";
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
