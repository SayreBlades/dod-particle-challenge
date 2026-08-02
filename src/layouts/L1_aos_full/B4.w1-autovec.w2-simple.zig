// Cell L1.B4.w1-autovec.w2-simple — B4 (math+decide→list | respawn-dead-only | render),
// walk 1 autovec, walk 2 autovec ordered, walk 3 r0 splat. SERIAL.
//
// Golden: bit-exact. The dead-list variant: walk 1 does math + decide → a
// compact list of dead indices (variable length, ~N·p dead); walk 2 walks
// ONLY the dead list, respawning each from the shared spawn RNG in list
// order (= index order = serial RNG order). Wins when death is rare (walk 2
// is ~N·p work, not N); loses when death is common (list is long + append
// overhead). The list is the declared intermediate (compact idx[]).
// Diff vs B3: list vs mask (isolates the intermediate axis).
//
// The list is built by a branchy append in walk 1 (irregular — not
// Halide-expressible, §5). Self-contained (§8 rule 2).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");
const r0 = @import("../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B4,
        .ordering = .identity,
        .intermediates = .list,
        .walks = &.{
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
        // walk 1: math + decide → compact dead list (append in index order).
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
        // walk 2: respawn only the dead, in list order (= index order = bit-exact).
        var k: usize = 0;
        while (k < ndead) : (k += 1) {
            data.spawn(&sim.rng, dead[k]);
        }
        // walk 3: r0 splat pass.
        r0.pass(fb, w, h, data.particles);
    }
};

pub const Sim = fw.Strategy(Data, H);