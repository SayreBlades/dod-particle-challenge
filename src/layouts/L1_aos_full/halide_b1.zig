// Strategy L1.halide_b1 — the ENTIRE step in Halide: math + branchless
// respawn, one pipeline, zero Zig passes (halide-exploration §2.3 B1).
//
// GOLDEN CLASS: **statistical** — declared, printed, never silent. The
// branchless blend needs respawn values for every particle, which no
// death-order RNG stream can feed (§2.3's fundamental tension); this
// strategy uses a per-particle hash RNG (splitmix64 over (i, frame, draw)).
// The PHYSICS and the respawn DISTRIBUTIONS are identical to naive
// (kind ~ uniform 3, jitter ~ ±0.05 x/y, age ~ U[0,kill_age), same
// impulses); the trajectories are not. The bench skips both goldens
// loudly; distribution checks live in the README (audit-density
// comparison).
//
// Performance shape: one 68 B walk, no Zig pass, no branch anywhere — the
// blend computes respawn values for ALL N every frame (~99% wasted at
// natural churn: the branchless tax), plus ~4 splitmix64 draws/particle
// (integer-heavy). The payoff regime is adversarial churn (-Ddeath=half):
// a2's serial Zig respawn eats 50% of N there; this strategy's cost is
// death-rate-INVARIANT.
//
// The generator takes the death pattern at BUILD time (build.zig passes
// -Ddeath through), so the kill test matches the Zig strategies' regimes:
// natural = age' >= kill_age; half = dedicated kill-hash < 0.5 (separate
// hash stream from the spawn draws); alternating = (i+frame) % 2 == 0.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");

const Data = layout.Data;
const Particle = layout.Particle;

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

extern fn halide_b1(
    data: *halide_buffer_t,
    kind_in: *halide_buffer_t,
    dt: f32,
    gx: f32,
    gy: f32,
    gz: f32,
    drag: f32,
    kill_age: f32,
    frame: u64,
    pos_x_out: *halide_buffer_t,
    vel_x_out: *halide_buffer_t,
    pos_y_out: *halide_buffer_t,
    vel_y_out: *halide_buffer_t,
    pos_z_out: *halide_buffer_t,
    vel_z_out: *halide_buffer_t,
    age_out: *halide_buffer_t,
    kind_out: *halide_buffer_t,
) c_int;

const FLOAT32: halide_type_t = .{ .code = 2, .bits = 32, .lanes = 1 };
const UINT8: halide_type_t = .{ .code = 1, .bits = 8, .lanes = 1 };

fn out1d(host: [*]u8, n: usize, stride: i32, t: halide_type_t, d: *[1]halide_dimension_t) halide_buffer_t {
    d[0] = .{ .min = 0, .extent = @intCast(n), .stride = stride, .flags = 0 };
    return .{ .host = host, .type = t, .dimensions = 1, .dim = d };
}

const H = struct {
    // The lab's honesty contract: different RNG model by DESIGN (see
    // header). Physics identical; trajectories diverge from stage1.bin.
    pub const golden_class: fw.GoldenClass = .statistical;

    pub fn step(sim: *Sim, dt: f32) void {
        const data = &sim.data;
        const n = data.n;
        const base: [*]u8 = @ptrCast(&data.particles[0]);
        const stride_floats: i32 = @intCast(@sizeOf(Particle) / 4);
        const stride_bytes: i32 = @intCast(@sizeOf(Particle));

        var in_dims = [2]halide_dimension_t{
            .{ .min = 0, .extent = 17, .stride = 1, .flags = 0 },
            .{ .min = 0, .extent = @intCast(n), .stride = stride_floats, .flags = 0 },
        };
        var buf_in: halide_buffer_t = .{ .host = base, .type = FLOAT32, .dimensions = 2, .dim = &in_dims };
        var kind_dim = [1]halide_dimension_t{
            .{ .min = 0, .extent = @intCast(n), .stride = stride_bytes, .flags = 0 },
        };
        var buf_kind_in: halide_buffer_t = .{ .host = base + @offsetOf(Particle, "kind"), .type = UINT8, .dimensions = 1, .dim = &kind_dim };

        var dpx: [1]halide_dimension_t = undefined;
        var dvx: [1]halide_dimension_t = undefined;
        var dpy: [1]halide_dimension_t = undefined;
        var dvy: [1]halide_dimension_t = undefined;
        var dpz: [1]halide_dimension_t = undefined;
        var dvz: [1]halide_dimension_t = undefined;
        var dag: [1]halide_dimension_t = undefined;
        var dkd: [1]halide_dimension_t = undefined;
        const pos_off = @offsetOf(Particle, "pos");
        const vel_off = @offsetOf(Particle, "vel");
        var buf_px = out1d(base + pos_off + 0, n, stride_floats, FLOAT32, &dpx);
        var buf_vx = out1d(base + vel_off + 0, n, stride_floats, FLOAT32, &dvx);
        var buf_py = out1d(base + pos_off + 4, n, stride_floats, FLOAT32, &dpy);
        var buf_vy = out1d(base + vel_off + 4, n, stride_floats, FLOAT32, &dvy);
        var buf_pz = out1d(base + pos_off + 8, n, stride_floats, FLOAT32, &dpz);
        var buf_vz = out1d(base + vel_off + 8, n, stride_floats, FLOAT32, &dvz);
        var buf_age = out1d(base + @offsetOf(Particle, "age"), n, stride_floats, FLOAT32, &dag);
        var buf_kind = out1d(base + @offsetOf(Particle, "kind"), n, stride_bytes, UINT8, &dkd);

        const rc = halide_b1(&buf_in, &buf_kind_in, dt, config.gravity.x, config.gravity.y, config.gravity.z, config.drag, config.kill_age, sim.frame, &buf_px, &buf_vx, &buf_py, &buf_vy, &buf_pz, &buf_vz, &buf_age, &buf_kind);
        std.debug.assert(rc == 0);
    }
};

pub const Sim = fw.Strategy(Data, H);
