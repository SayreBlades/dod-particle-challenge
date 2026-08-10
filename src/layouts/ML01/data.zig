// Layout ML01 — AoS full-field (the strawman data model, frozen).
//
//   topology:   one AoS array — []Particle, every field of every particle
//               interleaved at 68 B stride
//   field set:  FULL (11 fields — pos, vel, life, age, color, size, rotation,
//               mass, flags, kind, seed). The full set IS ML01's identity: it
//               is the OOP object as first written, carrying every dead field
//               the audit later indicts. Dropping fields is a different
//               layout (L2), not a knob (layout-verticals.md §1.1, decision B).
//   allocation: plain alloc, natural alignment (4 B), exact length
//   bytes/p:    68 (@sizeOf(Particle))
//   fingerprint (audit): 11 AoS-strided blobs — the baseline density picture
//
// This file is the ONLY definition of ML01's data model. It owns the canonical
// state (the particle array — exactly what snapshot/dumpFields dump), the
// spawn discipline (the golden-critical RNG draw sequence), and the
// storage-determined Sim methods shared by every ML01 algorithm. Strategies
// (naive.zig, par.zig, ...) are pure schedules over this storage: they may
// not change what is stored or how it is allocated.

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const config = @import("../../framework/config.zig");

pub const Particle = struct {
    pos: fw.Vec3,
    vel: fw.Vec3,
    life: f32,
    age: f32,
    color: fw.Vec4,
    size: f32,
    rotation: f32,
    mass: f32,
    flags: u8,
    kind: fw.ParticleKind,
    seed: u32,
};

pub const Data = struct {
    particles: []Particle,
    n: usize,

    /// Allocate + spawn all N particles. Draws the initial spawns from *rng
    /// (the sim's shared stream — algorithms draw respawns from the same
    /// stream, reproducing the arc's single-RNG sequence exactly).
    pub fn init(alloc: std.mem.Allocator, rng: *std.Random.DefaultPrng, desc: fw.Desc) !Data {
        const ps = try alloc.alloc(Particle, desc.n);
        errdefer alloc.free(ps);
        var data: Data = .{ .particles = ps, .n = desc.n };
        var i: usize = 0;
        while (i < desc.n) : (i += 1) data.spawn(rng, i);
        return data;
    }

    pub fn deinit(self: *Data, alloc: std.mem.Allocator) void {
        alloc.free(self.particles);
    }

    /// Spawn (or respawn) particle i. Draws 4 values in the arc's exact order
    /// (kind, jitter_x, jitter_y, age) — the golden file depends on this
    /// sequence, so every ML01 algorithm must respawn through this function.
    pub fn spawn(self: *Data, rng: *std.Random.DefaultPrng, i: usize) void {
        const r = rng.random();
        const kind: fw.ParticleKind = @enumFromInt(r.intRangeAtMost(u8, 0, 2));
        const imp = config.impulse[@intFromEnum(kind)];
        const jitter_x = (r.float(f32) - 0.5) * 0.1;
        const jitter_y = (r.float(f32) - 0.5) * 0.1;
        const col = kindColor(kind);
        self.particles[i] = .{
            .pos = .{ .x = 0, .y = 0, .z = 0 },
            .vel = .{
                .x = imp.x + jitter_x,
                .y = imp.y + jitter_y,
                .z = imp.z,
            },
            .life = config.kill_age,
            .age = r.float(f32) * config.kill_age, // staggered spawn ages
            .color = col,
            .size = 1.0,
            .rotation = 0,
            .mass = 1.0,
            .flags = 0,
            .kind = kind,
            .seed = @intCast(i),
        };
    }

    /// Write n*6 floats (px,py,pz,vx,vy,vz) per particle for the golden check.
    pub fn snapshot(self: *const Data, out: []f32) void {
        for (self.particles, 0..) |p, i| {
            out[i * 6 + 0] = p.pos.x;
            out[i * 6 + 1] = p.pos.y;
            out[i * 6 + 2] = p.pos.z;
            out[i * 6 + 3] = p.vel.x;
            out[i * 6 + 4] = p.vel.y;
            out[i * 6 + 5] = p.vel.z;
        }
    }

    /// Bytes per particle that a full loop touches (the working-set cost).
    pub fn bytesPerParticle(self: *const Data) usize {
        _ = self;
        return @sizeOf(Particle);
    }

    /// Dump each field's raw bytes across the particle array (AoS-strided)
    /// for the data-density audit — 11 blobs, the ML01 fingerprint.
    pub fn dumpFields(self: *const Data, alloc: std.mem.Allocator) ![]fw.FieldDump {
        const ps = self.particles;
        const out = try alloc.alloc(fw.FieldDump, 11);
        out[0] = .{ .name = "pos", .bytes = try extractField("pos", ps, alloc) };
        out[1] = .{ .name = "vel", .bytes = try extractField("vel", ps, alloc) };
        out[2] = .{ .name = "life", .bytes = try extractField("life", ps, alloc) };
        out[3] = .{ .name = "age", .bytes = try extractField("age", ps, alloc) };
        out[4] = .{ .name = "color", .bytes = try extractField("color", ps, alloc) };
        out[5] = .{ .name = "size", .bytes = try extractField("size", ps, alloc) };
        out[6] = .{ .name = "rotation", .bytes = try extractField("rotation", ps, alloc) };
        out[7] = .{ .name = "mass", .bytes = try extractField("mass", ps, alloc) };
        out[8] = .{ .name = "flags", .bytes = try extractField("flags", ps, alloc) };
        out[9] = .{ .name = "kind", .bytes = try extractField("kind", ps, alloc) };
        out[10] = .{ .name = "seed", .bytes = try extractField("seed", ps, alloc) };
        return out;
    }

    // r0 render primitives in layouts/common/render_simple.zig (splat/passKind).
    // The cell's `step` calls the splat pass; the clear is the driver's job.
};

pub fn kindColor(k: fw.ParticleKind) fw.Vec4 {
    return switch (k) {
        .smoke => .{ .x = 120, .y = 120, .z = 120, .w = 1 }, // gray
        .spark => .{ .x = 255, .y = 180, .z = 60, .w = 1 }, // orange
        .debris => .{ .x = 100, .y = 200, .z = 255, .w = 1 }, // blue
    };
}

/// Extract one field's bytes from the AoS array (AoS-strided: the natural
/// memory layout of that field as the hot loop reads it).
fn extractField(comptime field: []const u8, ps: []const Particle, alloc: std.mem.Allocator) ![]u8 {
    const FT = @TypeOf(@field(ps[0], field));
    const sz = @sizeOf(FT);
    const out = try alloc.alloc(u8, ps.len * sz);
    for (ps, 0..) |_, i| {
        const ptr = &@field(ps[i], field);
        @memcpy(out[i * sz ..][0..sz], std.mem.asBytes(ptr));
    }
    return out;
}
