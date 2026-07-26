// Strategy L1.halide_a — the natural-seam Halide strategy (halide-exploration
// §2.1/§2.2): Halide runs the two math passes (integrate + forces) as an AOT
// pipeline over the AoS buffer; Zig keeps the branchy scalar
// age/kill/respawn (the natural seam — the golden's RNG discipline is
// untouched by construction).
//
// The input is L1's particle array as a 2-D interleaved halide_buffer_t:
// dim0 = component (stride 1), dim1 = particle (stride 17 floats = 68 B).
// Vectorizing across particles is a strided gather — the AoS vectorization
// cost this strategy exists to MEASURE (layout-verticals §6.4: prove it on a
// toolchain that vectorizes, don't assert it from Zig's scalar codegen).
//
// Golden: bit-exact IF Halide's StrictFloat codegen matches Zig's scalar
// fmul+fadd rounding — the FP gate (halide-exploration §5.1), decided for
// real here in V1. The pipeline is in-place aliased (elementwise, same-i
// dependence; pos/vel component ranges are disjoint).
//
// Loop-structure note (golden-relevant): L1.naive fuses math+age+kill into
// one per-particle loop; this strategy does math-for-all (Halide) then
// age/kill-for-all (Zig). The RNG draw SEQUENCE is unchanged (respawns still
// happen in index-death order), so the golden holds if FP rounding matches.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");

const Data = layout.Data;
const Particle = layout.Particle;

// --- the Halide AOT ABI (HalideRuntime.h, redeclared — plain C, stable) ---
const halide_type_t = extern struct { code: u8, bits: u8, lanes: u16 };
const halide_dimension_t = extern struct { min: i32, extent: i32, stride: i32, flags: u32 };
const halide_buffer_t = extern struct {
    device: u64 = 0,
    device_interface: ?*anyopaque = null,
    host: [*]u8,
    flags: u64 = 0,
    type: halide_type_t,
    dimensions: i32,
    dim: [*]halide_dimension_t,
    padding: ?*anyopaque = null,
};

extern fn halide_a(
    data: *halide_buffer_t,
    dt: f32,
    gx: f32,
    gy: f32,
    gz: f32,
    drag: f32,
    pos_out: *halide_buffer_t,
    vel_out: *halide_buffer_t,
    age_out: *halide_buffer_t,
) c_int;

const FLOAT32: halide_type_t = .{ .code = 2, .bits = 32, .lanes = 1 }; // halide_type_float

const H = struct {
    pub fn step(sim: *Sim, dt: f32) void {
        const data = &sim.data;
        const n = data.n;
        const base: [*]u8 = @ptrCast(&data.particles[0]);
        const pos_off = @offsetOf(Particle, "pos");
        const vel_off = @offsetOf(Particle, "vel");
        const stride_floats: i32 = @intCast(@sizeOf(Particle) / 4);

        var in_dims = [2]halide_dimension_t{
            .{ .min = 0, .extent = 17, .stride = 1, .flags = 0 },
            .{ .min = 0, .extent = @intCast(n), .stride = stride_floats, .flags = 0 },
        };
        var out_dims = [2]halide_dimension_t{
            .{ .min = 0, .extent = 3, .stride = 1, .flags = 0 },
            .{ .min = 0, .extent = @intCast(n), .stride = stride_floats, .flags = 0 },
        };
        var buf_in: halide_buffer_t = .{
            .host = base,
            .type = FLOAT32,
            .dimensions = 2,
            .dim = &in_dims,
        };
        var buf_pos: halide_buffer_t = .{
            .host = base + pos_off,
            .type = FLOAT32,
            .dimensions = 2,
            .dim = &out_dims,
        };
        var buf_vel: halide_buffer_t = .{
            .host = base + vel_off,
            .type = FLOAT32,
            .dimensions = 2,
            .dim = &out_dims,
        };
        var age_dim = [1]halide_dimension_t{
            .{ .min = 0, .extent = @intCast(n), .stride = stride_floats, .flags = 0 },
        };
        var buf_age: halide_buffer_t = .{
            .host = base + @offsetOf(Particle, "age"),
            .type = FLOAT32,
            .dimensions = 1,
            .dim = &age_dim,
        };

        // 1+2+3. Integrate + forces + age — the Halide pipeline, ONE fused
        // loop nest, in place. This is naive.zig's entire branch-free math.
        const rc = halide_a(&buf_in, dt, config.gravity.x, config.gravity.y, config.gravity.z, config.drag, &buf_pos, &buf_vel, &buf_age);
        std.debug.assert(rc == 0);

        // 4. Kill / respawn — Zig, branchy scalar (the natural seam), index
        // order so the RNG draw sequence matches L1.naive exactly. (Age was
        // already updated by the pipeline.)
        // 5. The naive schedule's kind-switch + cold touches stay too: the
        //    comparison is "same schedule, Halide does the math".
        for (data.particles) |*p| {
            if (config.isDead(p.age, &sim.kill_rng)) {
                data.spawn(&sim.rng, @intCast(p.seed % data.particles.len));
            }
            _ = switch (p.kind) {
                .smoke => {},
                .spark => {},
                .debris => {},
            };
            _ = p.mass;
            _ = p.flags;
            _ = p.seed;
        }
    }
};

pub const Sim = fw.Strategy(Data, H);
