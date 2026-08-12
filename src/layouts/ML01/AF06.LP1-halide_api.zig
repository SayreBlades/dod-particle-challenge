// AF06.LP1-halide_api.zig — the Halide FFI binding for the AF06 math+decide loop
// (shared by the AF06 halide cells). Math + competing-risks decide → dead mask.
// The cell's `step` calls `run()` for loop 1 (passing the mask buffer), then
// runs the Zig mask-scan+respawn loop 2 + the Zig splat loop 3.
//
// Shared infrastructure (§8 rule 3).

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

extern fn halide_b6_mask(
    data: *halide_buffer_t,
    dt: f32,
    kill_age: f32,
    q: f32,
    pos_x_out: *halide_buffer_t,
    vel_x_out: *halide_buffer_t,
    pos_y_out: *halide_buffer_t,
    vel_y_out: *halide_buffer_t,
    pos_z_out: *halide_buffer_t,
    vel_z_out: *halide_buffer_t,
    age_out: *halide_buffer_t,
    dead_out: *halide_buffer_t,
) c_int;

const FLOAT32: halide_type_t = .{ .code = 2, .bits = 32, .lanes = 1 };
const UINT8: halide_type_t = .{ .code = 1, .bits = 8, .lanes = 1 };

fn out1d(host: [*]u8, n: usize, stride: i32, t: halide_type_t, d: *[1]halide_dimension_t) halide_buffer_t {
    d[0] = .{ .min = 0, .extent = @intCast(n), .stride = stride, .flags = 0 };
    return .{ .host = host, .type = t, .dimensions = 1, .dim = d };
}

/// Run the Halide AF06 math+decide loop over the whole particle array in place.
/// Writes updated pos/vel/age and the dead mask (1 B/p, tightly packed).
pub fn run(data: *Data, dt: f32, dead: []u8) void {
    const n = data.n;
    const base: [*]u8 = @ptrCast(&data.particles[0]);
    const stride_floats: i32 = @intCast(@sizeOf(Particle) / 4);

    var in_dims = [2]halide_dimension_t{
        .{ .min = 0, .extent = 17, .stride = 1, .flags = 0 },
        .{ .min = 0, .extent = @intCast(n), .stride = stride_floats, .flags = 0 },
    };
    var buf_in: halide_buffer_t = .{ .host = base, .type = FLOAT32, .dimensions = 2, .dim = &in_dims };

    const pos_off = @offsetOf(Particle, "pos");
    const vel_off = @offsetOf(Particle, "vel");
    var dpx: [1]halide_dimension_t = undefined;
    var dvx: [1]halide_dimension_t = undefined;
    var dpy: [1]halide_dimension_t = undefined;
    var dvy: [1]halide_dimension_t = undefined;
    var dpz: [1]halide_dimension_t = undefined;
    var dvz: [1]halide_dimension_t = undefined;
    var dag: [1]halide_dimension_t = undefined;
    var ddd: [1]halide_dimension_t = undefined;
    var buf_px = out1d(base + pos_off + 0, n, stride_floats, FLOAT32, &dpx);
    var buf_vx = out1d(base + vel_off + 0, n, stride_floats, FLOAT32, &dvx);
    var buf_py = out1d(base + pos_off + 4, n, stride_floats, FLOAT32, &dpy);
    var buf_vy = out1d(base + vel_off + 4, n, stride_floats, FLOAT32, &dvy);
    var buf_pz = out1d(base + pos_off + 8, n, stride_floats, FLOAT32, &dpz);
    var buf_vz = out1d(base + vel_off + 8, n, stride_floats, FLOAT32, &dvz);
    var buf_age = out1d(base + @offsetOf(Particle, "age"), n, stride_floats, FLOAT32, &dag);
    var buf_dead = out1d(dead.ptr, n, 1, UINT8, &ddd);

    const rc = halide_b6_mask(&buf_in, dt, config.kill_age, config.q, &buf_px, &buf_vx, &buf_py, &buf_vy, &buf_pz, &buf_vz, &buf_age, &buf_dead);
    std.debug.assert(rc == 0);
}