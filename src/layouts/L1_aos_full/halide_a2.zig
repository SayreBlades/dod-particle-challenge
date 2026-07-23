// Strategy L1.halide_a2 — the dead-mask variant: Halide computes naive.zig's
// complete branch-free loop body (pos/vel/age) in ONE fused scalar nest AND
// writes the kill decision to a 1 B/p dead mask; Zig does the par-style
// block scan + serial index-ordered respawn.
//
// Why this should TIE naive at DRAM-bound N (README §5a): the natural seam's
// cost was never Halide's codegen, it was the SECOND walk — halide_a's Zig
// kill pass re-walks the whole 68 B struct (2 × 68 = 136 B/p, both walks at
// the ~47 GB/s ceiling). Here the Zig side walks 1 B/p instead: traffic
// ≈ 68 + 1 + 1 = 70 B/p ≈ naive's 68. The prediction is parity at DRAM;
// cache-resident keeps the scalar-Halide loop-overhead delta (selects,
// per-row bounds clamps) as the only honest gap.
//
// Golden: bit-exact. The kill test is the same >= on the same StrictFloat
// age' value, computed pipeline-side; respawn draws remain in index-death
// order from the shared spawn RNG (same discipline as par.zig's phase 2).
// bytes/p: 68 + 1 mask = 69 (scratch reported).

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

extern fn halide_a2(
    data: *halide_buffer_t,
    dt: f32,
    gx: f32,
    gy: f32,
    gz: f32,
    drag: f32,
    kill_age: f32,
    pos_x_out: *halide_buffer_t,
    vel_x_out: *halide_buffer_t,
    pos_y_out: *halide_buffer_t,
    vel_y_out: *halide_buffer_t,
    pos_z_out: *halide_buffer_t,
    vel_z_out: *halide_buffer_t,
    age_out: *halide_buffer_t,
    dead_out: *halide_buffer_t,
) c_int;

/// A 1-D strided output descriptor (one component stream of the AoS array).
fn out1d(host: [*]u8, n: usize, stride_floats: i32, t: halide_type_t, lanes_dim: *[1]halide_dimension_t) halide_buffer_t {
    lanes_dim[0] = .{ .min = 0, .extent = @intCast(n), .stride = stride_floats, .flags = 0 };
    return .{ .host = host, .type = t, .dimensions = 1, .dim = lanes_dim };
}

const FLOAT32: halide_type_t = .{ .code = 2, .bits = 32, .lanes = 1 }; // halide_type_float
const UINT8: halide_type_t = .{ .code = 1, .bits = 8, .lanes = 1 }; // halide_type_uint (int=0, uint=1, float=2)

const H = struct {
    pub const Extra = struct {
        dead: []u8, // pipeline-written kill flags; +1 B/p (see scratchBytes)
    };

    pub fn initExtra(sim: *Sim, desc: fw.Desc) !void {
        const dead = try sim.alloc.alloc(u8, desc.n);
        errdefer sim.alloc.free(dead);
        sim.extra = .{ .dead = dead };
    }

    pub fn deinitExtra(sim: *Sim) void {
        sim.alloc.free(sim.extra.dead);
    }

    pub fn scratchBytes(sim: *const Sim) usize {
        _ = sim;
        return 1; // the dead mask, 1 B/p
    }

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
        var buf_in: halide_buffer_t = .{ .host = base, .type = FLOAT32, .dimensions = 2, .dim = &in_dims };
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
        var buf_dead = out1d(sim.extra.dead.ptr, n, 1, UINT8, &ddd);

        // 1+2+3+kill-flag: the fused scalar Halide nest (one 68 B walk) +
        // the 1 B/p mask write. Nine single-component streams, one i-loop.
        const rc = halide_a2(&buf_in, dt, config.gravity.x, config.gravity.y, config.gravity.z, config.drag, config.kill_age, &buf_px, &buf_vx, &buf_py, &buf_vy, &buf_pz, &buf_vz, &buf_age, &buf_dead);
        std.debug.assert(rc == 0);

        // 4. Respawn — the par-style SERIAL scan in index order (block-wise
        // zero-skip: death is sparse at natural churn), so the spawn RNG draw
        // sequence matches L1.naive exactly. 1 B/p walk.
        const dead = sim.extra.dead;
        const B = 32;
        var i: usize = 0;
        while (i + B <= n) : (i += B) {
            const block: @Vector(B, u8) = dead[i..][0..B].*;
            if (@reduce(.Or, block) == 0) continue;
            var j: usize = i;
            while (j < i + B) : (j += 1) {
                if (dead[j] != 0) data.spawn(&sim.rng, j);
            }
        }
        while (i < n) : (i += 1) {
            if (dead[i] != 0) data.spawn(&sim.rng, i);
        }
    }
};

pub const Sim = fw.Strategy(Data, H);
