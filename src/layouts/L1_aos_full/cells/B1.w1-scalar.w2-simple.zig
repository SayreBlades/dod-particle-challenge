// Cell L1.B1.w1-scalar.w2-simple — B1 (math+decide+respawn | render),
// walk 1 scalar branchy, walk 2 r0 splat.
//
// Golden: bit-exact. Same algorithm as w2-simple but every scalar intermediate
// is boxed behind an opaque asm barrier, breaking LLVM SLP's pattern match so
// the loop is TRULY scalar (no q-register math). The de-vectorization control:
// isolates the schedule axis (auto → scalar) from the blueprint axis.
// (NEON fmul.s and fmul.4s lanes are both IEEE single — same ops, same order.)

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const config = @import("../../../framework/config.zig");
const layout = @import("../data.zig");
const r0 = @import("../../common/render_simple.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B1,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{
            .{ .impl = .zig, .schedule = .scalar, .parallel = .none, .variant = .branchy },
            .{ .impl = .zig, .schedule = .r0, .parallel = .none, .variant = .none },
        },
        .golden = .bit_exact,
        .halide_expressible = "walk1 no (branchy respawn, de-vec control); walk2 n/a",
    };

    /// An OPAQUE identity: the value emerges from an asm output operand, so
    /// the optimizer cannot prove it equals the input — SLP can't pack
    /// producer or consumer chains across the box.
    inline fn box(x: f32) f32 {
        return asm volatile (""
            : [ret] "=w" (-> f32)
            : [in] "w" (x)
        );
    }

    pub fn step(sim: anytype, dt: f32, fb: []u8, w: u32, h: u32) void {
        const data = &sim.data;
        // walk 1: math + decide + respawn (branchy, scalar-forced)
        for (data.particles) |*p| {
            // 1. Integrate: pos += vel * dt — inputs AND results boxed.
            p.pos.x = box(box(p.pos.x) + box(p.vel.x) * dt);
            p.pos.y = box(box(p.pos.y) + box(p.vel.y) * dt);
            p.pos.z = box(box(p.pos.z) + box(p.vel.z) * dt);

            // 2. Forces: vel += (gravity + drag*vel) * dt
            const vx = box(p.vel.x);
            const vy = box(p.vel.y);
            const vz = box(p.vel.z);
            p.vel.x = box(vx + (config.gravity.x + config.drag * vx) * dt);
            p.vel.y = box(vy + (config.gravity.y + config.drag * vy) * dt);
            p.vel.z = box(vz + (config.gravity.z + config.drag * vz) * dt);

            // 3. Age
            p.age = box(p.age) + dt;

            // 4. Kill → respawn (identical to autovec)
            if (config.isDead(p.age, &sim.kill_rng)) {
                data.spawn(&sim.rng, @intCast(p.seed % data.particles.len));
            }
        }
        // walk 2: r0 splat pass (no clear — the driver owns it).
        r0.pass(fb, w, h, data.particles);
    }
};

pub const Sim = fw.Strategy(Data, H);
