// Cell L1.B3.w1-autovec.w2-simple — B3 (math+decide→mask | mask-scan+respawn | render),
// walk 1 autovec, walk 2 autovec ordered, walk 3 r0 splat. SERIAL.
//
// Golden: bit-exact. The dead-mask variant: walk 1 does math + decide → a 1 B/p
// dead mask (no spawn RNG); walk 2 scans the mask in index order, respawning
// from the shared spawn RNG (rank order = serial RNG order). The mask makes
// walk 2 parallelizable (via ranked-merge — see B3.w1-autovec-par.w2-rmerge);
// this serial cell is the baseline. Diff vs B1: the mask intermediate + the
// two-walk split (isolates the intermediate axis at T=1).
//
// Self-contained (§8 rule 2). The mask is the declared intermediate (1 B/p).

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const config = @import("../../../framework/config.zig");
const layout = @import("../data.zig");
const r0 = @import("../../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B3,
        .ordering = .identity,
        .intermediates = .mask,
        .walks = &.{
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .none },
            .{ .impl = .zig, .schedule = .auto, .parallel = .none, .variant = .ordered },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "walk1 yes (math+decide→mask); walk2 no (host scan); walk3 n/a",
    };

    pub const Extra = struct {
        dead: []u8, // 1 B/p mask (the declared intermediate)
    };

    pub fn initExtra(sim: anytype, desc: fw.Desc) !void {
        sim.extra = .{ .dead = try sim.alloc.alloc(u8, desc.n) };
    }

    pub fn deinitExtra(sim: anytype) void {
        sim.alloc.free(sim.extra.dead);
    }

    pub fn scratchBytes(sim: *const Sim) usize {
        _ = sim;
        return 1; // the dead mask
    }

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        const dead = sim.extra.dead;
        // walk 1: math + decide → dead mask (no spawn RNG).
        for (data.particles, 0..) |*p, i| {
            p.pos = p.pos.add(p.vel.scale(dt));
            const v = p.vel;
            p.vel = .{
                .x = v.x + (config.gravity.x + config.drag * v.x) * dt,
                .y = v.y + (config.gravity.y + config.drag * v.y) * dt,
                .z = v.z + (config.gravity.z + config.drag * v.z) * dt,
            };
            p.age += dt;
            dead[i] = @intFromBool(config.isDead(p.age, &sim.kill_rng));
        }
        // walk 2: mask-scan + respawn in index order (bit-exact). Block skip.
        phase2Respawn(sim);
        // walk 3: r0 splat pass.
        r0.pass(fb, w, h, data.particles);
    }

    fn phase2Respawn(sim: anytype) void {
        const dead = sim.extra.dead;
        const n = sim.data.n;
        const B = 32;
        var i: usize = 0;
        while (i + B <= n) : (i += B) {
            const block: @Vector(B, u8) = dead[i..][0..B].*;
            if (@reduce(.Or, block) == 0) continue;
            var j: usize = i;
            while (j < i + B) : (j += 1) {
                if (dead[j] != 0) sim.data.spawn(&sim.rng, j);
            }
        }
        while (i < n) : (i += 1) {
            if (dead[i] != 0) sim.data.spawn(&sim.rng, i);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);