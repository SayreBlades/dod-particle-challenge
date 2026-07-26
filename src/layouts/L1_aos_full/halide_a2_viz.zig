// Strategy L1.halide_a2_viz — pipeline visualization render for halide_a2
// (the lab's HalideTraceViz analogue). The SIM is halide_a2 exactly
// (bit-exact); render() is replaced with a three-panel instrument view of
// the two-phase step, so `--record` produces a video of the pipeline
// PROCESSING, not just the particles:
//
//   rows   0–767 : the fountain (normal splat, LUT colors)
//   rows 768–895 : the DEAD MASK — one pixel per particle (512×128 grid),
//                  white = killed this frame by the Halide nest
//   rows 896–1023: RESPAWNS this frame — same grid, kind-colored, flashed by
//                  the Zig serial scan (phase 2)
//
// (Real HalideTraceViz works on JIT pipelines with trace_stores over 2-D
// images; our AOT strided-1-D pipelines don't fit it. This is the same
// idea — watch data move through the phases — built on the lab's own
// instruments. Viz-only: used with --record; step is unchanged a2.)

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");
const rast = @import("../../framework/render.zig");
const opt = @import("../../framework/render_opt.zig");
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

const FLOAT32: halide_type_t = .{ .code = 2, .bits = 32, .lanes = 1 };
const UINT8: halide_type_t = .{ .code = 1, .bits = 8, .lanes = 1 };

fn out1d(host: [*]u8, n: usize, stride: i32, t: halide_type_t, d: *[1]halide_dimension_t) halide_buffer_t {
    d[0] = .{ .min = 0, .extent = @intCast(n), .stride = stride, .flags = 0 };
    return .{ .host = host, .type = t, .dimensions = 1, .dim = d };
}

const H = struct {
    pub const Extra = struct {
        dead: []u8,
        respawned: []u8, // slots respawned this step (viz panel 3)
    };

    pub fn initExtra(sim: *Sim, desc: fw.Desc) !void {
        const dead = try sim.alloc.alloc(u8, desc.n);
        errdefer sim.alloc.free(dead);
        const respawned = try sim.alloc.alloc(u8, desc.n);
        errdefer sim.alloc.free(respawned);
        sim.extra = .{ .dead = dead, .respawned = respawned };
    }

    pub fn deinitExtra(sim: *Sim) void {
        sim.alloc.free(sim.extra.dead);
        sim.alloc.free(sim.extra.respawned);
    }

    pub fn scratchBytes(sim: *const Sim) usize {
        _ = sim;
        return 2;
    }

    pub fn step(sim: *Sim, dt: f32) void {
        const data = &sim.data;
        const n = data.n;
        const base: [*]u8 = @ptrCast(&data.particles[0]);
        const stride_floats: i32 = @intCast(@sizeOf(Particle) / 4);
        const pos_off = @offsetOf(Particle, "pos");
        const vel_off = @offsetOf(Particle, "vel");

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

        const rc = halide_a2(&buf_in, dt, config.gravity.x, config.gravity.y, config.gravity.z, config.drag, config.kill_age, &buf_px, &buf_vx, &buf_py, &buf_vy, &buf_pz, &buf_vz, &buf_age, &buf_dead);
        std.debug.assert(rc == 0);

        // Phase 2 (serial, index order) — same as a2, plus respawned[] marks
        // for the viz. respawned is 1 only at slots respawned THIS step.
        const dead = sim.extra.dead;
        const respawned = sim.extra.respawned;
        @memset(respawned, 0);
        const B = 32;
        var i: usize = 0;
        while (i + B <= n) : (i += B) {
            const block: @Vector(B, u8) = dead[i..][0..B].*;
            if (@reduce(.Or, block) == 0) continue;
            var j: usize = i;
            while (j < i + B) : (j += 1) {
                if (dead[j] != 0) {
                    data.spawn(&sim.rng, j);
                    respawned[j] = 1;
                }
            }
        }
        while (i < n) : (i += 1) {
            if (dead[i] != 0) {
                data.spawn(&sim.rng, i);
                respawned[i] = 1;
            }
        }
    }

    pub fn render(sim: *const Sim, fb: []u8, w: u32, h: u32) void {
        _ = h;
        const n = sim.data.n;
        rast.clear(fb);

        // Panel 1 (rows 0..768): the fountain, LUT colors.
        const fh: u32 = 768;
        for (sim.data.particles) |p| {
            opt.splatFast(fb, w, fh, p.pos.x, p.pos.y, opt.lut[@intFromEnum(p.kind)]);
        }

        // Panel 2 (rows 768..896): dead mask, one pixel per particle.
        // Panel 3 (rows 896..1024): respawns this frame, kind-colored.
        // Grid: 512 wide; particle i -> (i % 512, i / 512).
        const dead = sim.extra.dead;
        const respawned = sim.extra.respawned;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const gx: usize = i % 512;
            const gy: usize = i / 512;
            if (gy >= 128) break; // grid capacity 512×128 = 65536
            if (dead[i] != 0) {
                const px = (768 + gy) * 1024 + gx;
                fb[px * 4 + 0] = 255;
                fb[px * 4 + 1] = 255;
                fb[px * 4 + 2] = 255;
                fb[px * 4 + 3] = 255;
            }
            if (respawned[i] != 0) {
                const c = kindRgb(sim.data.particles[i].kind);
                const px = (896 + gy) * 1024 + gx;
                fb[px * 4 + 0] = c[0];
                fb[px * 4 + 1] = c[1];
                fb[px * 4 + 2] = c[2];
                fb[px * 4 + 3] = 255;
            }
        }
    }
};

fn kindRgb(k: fw.ParticleKind) [3]u8 {
    return switch (k) {
        .smoke => .{ 120, 120, 120 },
        .spark => .{ 255, 180, 60 },
        .debris => .{ 100, 200, 255 },
    };
}

pub const Sim = fw.Strategy(Data, H);
