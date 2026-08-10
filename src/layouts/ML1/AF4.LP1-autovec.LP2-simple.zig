// Algorithm ML1.AF4.LP1-autovec.LP2-simple — AF4 (math+decide→list | respawn-dead-only | render),
// loop 1 autovec, loop 2 autovec ordered, loop 3 r0 splat. SERIAL.
//
// Golden: bit-exact. The dead-list variant: loop 1 does math + decide → a
// compact list of dead indices (variable length, ~N·p dead); loop 2 loops
// ONLY the dead list, respawning each from the shared spawn RNG in list
// order (= index order = serial RNG order). Wins when death is rare (loop 2
// is ~N·p work, not N); loses when death is common (list is long + append
// overhead). The list is the declared intermediate (compact idx[]).
// Diff vs AF3: list vs mask (isolates the intermediate axis).
//
// The list is built by a branchy append in loop 1 (irregular — not
// Halide-expressible, §5). Self-contained (§8 rule 2).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const algo_meta: fw.AlgorithmMeta = .{
        .mem_layout = "ML1",
        .algo_fam = .AF4,
        .ordering = .identity,
        .intermediates = .list,
        .loops = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .none },
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .ordered },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "no (irregular append — the list intermediate is not Halide-expressible)",
    };

    pub const Extra = struct {
        dead: []u32, // compact dead-index list (the declared intermediate; cap N)
        dead_count: usize = 0,
    };

    pub fn initExtra(sim: anytype, desc: fw.Desc) !void {
        sim.extra = .{ .dead = try sim.alloc.alloc(u32, desc.n) };
    }

    pub fn deinitExtra(sim: anytype) void {
        sim.alloc.free(sim.extra.dead);
    }

    pub fn scratchBytes(sim: *const Sim) usize {
        _ = sim;
        return 4; // the dead list, 4 B/p worst case (compact, variable)
    }

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        const dead = sim.extra.dead;
        var ndead: usize = 0;
        // loop 1: math + decide → compact dead list (append in index order).
        for (data.particles, 0..) |*p, i| {
            p.pos = p.pos.add(p.vel.scale(dt));
            const v = p.vel;
            p.vel = .{
                .x = v.x + (config.gravity.x + config.drag * v.x) * dt,
                .y = v.y + (config.gravity.y + config.drag * v.y) * dt,
                .z = v.z + (config.gravity.z + config.drag * v.z) * dt,
            };
            p.age += dt;
            if (config.isDead(p.age, &sim.kill_rng)) {
                dead[ndead] = @intCast(i);
                ndead += 1;
            }
        }
        sim.extra.dead_count = ndead;
        // loop 2: respawn only the dead, in list order (= index order = bit-exact).
        var k: usize = 0;
        while (k < ndead) : (k += 1) {
            data.spawn(&sim.rng, dead[k]);
        }
        // loop 3: r0 splat pass.
        for (data.particles) |p| {
            r0.splat(fb, w, h, p.pos.x, p.pos.y, p.color.x, p.color.y, p.color.z);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);