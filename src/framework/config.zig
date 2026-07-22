// The single source of truth for physics. Imported by every stage's step().
// If two stages ever diverge on one of these, the golden-file test catches it.
//
// MODEL (locked here so every stage shares it):
//   At spawn:  vel = impulse[kind] + jitter        (impulse is INITIAL velocity)
//   Per frame: vel += (gravity + drag*vel) * dt     (no impulse in the force)
//              pos += vel * dt
//              age += dt
//              if age >= kill_age: respawn
//
// impulse is a spawn-time initial velocity, NOT a continuous force. This gives
// proper ballistic arcs (fountain) instead of monotonic acceleration. The
// per-frame force is gravity + drag only.

const std = @import("std");
const vec = @import("vec.zig");

pub const dt: f32 = 1.0 / 60.0;
pub const gravity: vec.Vec3 = .{ .x = 0, .y = -1.0, .z = 0 }; // gentle, unit-world scale
pub const drag: f32 = 0.02;
pub const kill_age: f32 = 2.0; // particle respawns at age >= 2.0s
pub const spawn_seed: u64 = 0xC0FFEE;
pub const spawn_radius: f32 = 0.05; // tight emitter around origin

// World extents: positions in [-view_half, view_half] map to the framebuffer.
pub const view_half: f32 = 2.0;

// --- death-pattern regimes (layout-matrix.md §2.5, build option -Ddeath=) ---

pub const DeathPattern = enum { natural, half, alternating };

/// The active death pattern. `natural` is the golden-checked sim; `half` and
/// `alternating` are adversarial regimes (golden compile-skipped in bench — a
/// different sim, loudly). Comptime-known, so isDead prunes to exactly the
/// original age test in natural builds: zero cost, zero RNG perturbation.
pub const death_pattern: DeathPattern = std.meta.stringToEnum(DeathPattern, @import("options").death) orelse
    @compileError("invalid -Ddeath (natural | half | alternating)");

/// The kill decision for particle `i` this frame. `kill_rng` is a DEDICATED
/// stream (never the spawn RNG — spawn draws stay comparable across patterns);
/// drawn only in .half. `frame` is used only in .alternating.
pub inline fn isDead(age: f32, i: usize, frame: usize, kill_rng: *std.Random.DefaultPrng) bool {
    return switch (death_pattern) {
        .natural => age >= kill_age,
        .half => kill_rng.random().float(f32) < 0.5,
        .alternating => (i + frame) % 2 == 0,
    };
}

// Per-kind initial velocity (set at spawn). Lookup, not branch.
pub const impulse: [3]vec.Vec3 = .{
    .{ .x = 0, .y = 0.8, .z = 0 }, // smoke:  gentle rise
    .{ .x = 1.0, .y = 1.2, .z = 0 }, // spark:   diagonal arc
    .{ .x = 0.4, .y = 0.6, .z = 0.2 }, // debris:  slow scatter
};
