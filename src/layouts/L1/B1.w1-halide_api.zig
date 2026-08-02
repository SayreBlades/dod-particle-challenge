// B1.w1-halide_api.zig — the Halide FFI binding for the B1 branchless-blend
// step (shared by the B1 halide cells). Extern decl + buffer marshaling;
// the generator (B1.w1-halide_gen.py) emits out/halide/w1-halide.{h,a}.
//
// This is shared *infrastructure* (§8 rule 3): cells call `run()` like
// calling memcpy — not imported as a walk. The cell's `step` owns the
// blueprint; this file owns the FFI plumbing.
//
// THE GOLDEN TENSION (read first): naive draws respawn RNG only for dead
// particles, in death order — the golden's trajectories depend on that exact
// sequence. A branchless blend needs respawn values for EVERY particle, so
// no death-order stream can feed it. B1's answer: per-particle hash RNG
// (splitmix64 over (i, frame, draw)) — deterministic, vectorizable, but a
// DIFFERENT RNG model. Physics and respawn DISTRIBUTIONS are identical;
// trajectories diverge from stage1.bin by design. The cell declares
// golden_class = .statistical.

const std = @import("std");
const config = @import("../../framework/config.zig");
const layout = @import("data.zig");

pub const Data = layout.Data;
pub const Particle = layout.Particle;

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
    color_r_out: *halide_buffer_t,
    color_g_out: *halide_buffer_t,
    color_b_out: *halide_buffer_t,
) c_int;

const FLOAT32: halide_type_t = .{ .code = 2, .bits = 32, .lanes = 1 };
const UINT8: halide_type_t = .{ .code = 1, .bits = 8, .lanes = 1 };

fn out1d(host: [*]u8, n: usize, stride: i32, t: halide_type_t, d: *[1]halide_dimension_t) halide_buffer_t {
    d[0] = .{ .min = 0, .extent = @intCast(n), .stride = stride, .flags = 0 };
    return .{ .host = host, .type = t, .dimensions = 1, .dim = d };
}

/// Run the Halide B1 branchless-blend step over the whole particle array
/// in place. `frame` is the sim's frame counter (the per-particle hash RNG
/// uses it). Competing-risks death (config.q) is baked into the emitted .a.
pub fn run(data: *Data, dt: f32, frame: u64) void {
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
    var dcr: [1]halide_dimension_t = undefined;
    var dcg: [1]halide_dimension_t = undefined;
    var dcb: [1]halide_dimension_t = undefined;
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
    const color_off = @offsetOf(Particle, "color");
    var buf_cr = out1d(base + color_off + 0, n, stride_floats, FLOAT32, &dcr);
    var buf_cg = out1d(base + color_off + 4, n, stride_floats, FLOAT32, &dcg);
    var buf_cb = out1d(base + color_off + 8, n, stride_floats, FLOAT32, &dcb);

    const rc = halide_b1(&buf_in, &buf_kind_in, dt, config.gravity.x, config.gravity.y, config.gravity.z, config.drag, config.kill_age, frame, &buf_px, &buf_vx, &buf_py, &buf_vy, &buf_pz, &buf_vz, &buf_age, &buf_kind, &buf_cr, &buf_cg, &buf_cb);
    std.debug.assert(rc == 0);
}
