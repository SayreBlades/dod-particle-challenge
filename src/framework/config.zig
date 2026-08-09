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

// --- death model: competing risks (optimization-framework.md §7) ---
//
// A particle dies when EITHER it ages out (age >= kill_age) OR it draws an
// accident (per-frame Bernoulli with rate q, from the dedicated kill-RNG
// stream — never the spawn RNG). Lifetime = min(kill_age, geometric(q)).
//
// `q` is a comptime build option (-Ddeath=<float>, default 0 = natural).
// natural (q=0) is the golden-checked sim: isDead prunes to exactly the
// original age test, zero cost, zero RNG perturbation. q>0 is the churn
// regime sweep (§7); goldens are skipped loudly (§10.6 — the invariant
// suite, Phase 1) and the sim is a different one by design.
//
// Draw discipline (§7): exactly one kill-RNG draw per non-aged-out particle
// per frame, in index order (short-circuit: aged-out particles consume no
// draw). Parallel cells use the per-chunk kill-RNG pattern par.zig already
// has. The sim stays deterministic given (seed, q, T).
//
// Retired: the old `natural | half | alternating` enum. `alternating` was a
// predictability regime, not a rate — the hybrid's high-q end covers the
// unpredictable-death regime it was probing. `half` (pure coin-flip,
// age-ignoring) is replaced by the competing-risks family; age stays
// load-bearing at every rate (death axis orthogonal to field-set, §7).

/// The per-frame accident rate q. natural ≡ q = 0. Runtime-settable via
/// `--death <q>` (bench.zig) so one binary sweeps the whole death axis;
/// `-Ddeath=<q>` sets the default for runs that don't pass --death. isDead
/// short-circuits before the kill-RNG draw when q==0 (no spawn-sequence
/// perturbation) — identical behavior at q=0 whether set comptime or runtime,
/// so the golden holds either way.
pub var q: f32 = @floatCast(@import("options").death);

/// Set the accident rate at runtime (call once at startup; isDead reads `q` live).
pub fn setDeathRate(qv: f32) void {
    q = qv;
}

/// The kill decision for particle `i` this frame. `kill_rng` is a DEDICATED
/// stream (never the spawn RNG); drawn only when q > 0 and the particle has
/// not aged out (short-circuit). At q==0 (natural) the kill-RNG is never
/// drawn, so the spawn sequence stays comparable across rates. Set once at
/// startup (build default or --death); the `q == 0` test is one predicted op.
pub inline fn isDead(age: f32, kill_rng: *std.Random.DefaultPrng) bool {
    if (age >= kill_age) return true;
    if (q == 0) return false; // runtime short-circuit; no kill-RNG draw at q=0
    return kill_rng.random().float(f32) < q;
}

// Per-kind initial velocity (set at spawn). Lookup, not branch.
pub const impulse: [3]vec.Vec3 = .{
    .{ .x = 0, .y = 0.8, .z = 0 }, // smoke:  gentle rise
    .{ .x = 1.0, .y = 1.2, .z = 0 }, // spark:   diagonal arc
    .{ .x = 0.4, .y = 0.6, .z = 0.2 }, // debris:  slow scatter
};
