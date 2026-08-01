// hash_rng.zig — the per-particle hash RNG for the blend variants (B1-blend,
// and any cell using the branchless-respawn model). splitmix64 over
// (i, frame), bit-sliced into kind/jx/jy/age — the SAME model the Halide
// B1 generator uses (B1.w1-halide_gen.py), so the Zig blend and Halide blend
// are statistical-class twins: identical physics + respawn distributions,
// trajectories diverge from the branchy reference by design.
//
// This is NOT the shared spawn-RNG stream (data.spawn draws that, in index
// order, for the bit-exact cells). It is a *different* RNG model — declared
// golden_class = .statistical. The whole point: a branchless blend needs
// respawn values for every particle, so no death-order stream can feed it.

const SEED: u64 = 0xC0FFEE;

inline fn splitmix64(x: u64) u64 {
    var z: u64 = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// One splitmix64 draw per particle, bit-sliced into the four respawn fields.
/// Returns (kind, jx, jy, age) matching the Halide generator's bit layout.
/// `frame` is the sim's frame counter (per-particle hash RNG uses it).
pub inline fn respawn(i: usize, frame: u64) struct { kind: u8, jx: f32, jy: f32, age: f32 } {
    const h = splitmix64(SEED ^ (frame *% 0x100000001B3) ^ (@as(u64, i) *% 0x9E3779B1));
    const u16_ = struct {
        fn at(v: u64, shift: u6) u32 {
            return @intCast((v >> shift) & 0xFFFF);
        }
    };
    // kind: Lemire reduction of a 16-bit value to [0,2]
    const h_kind_raw: u32 = u16_.at(h, 48);
    const kind: u8 = @intCast((h_kind_raw * 3) >> 16);
    const jx: f32 = (@as(f32, @floatFromInt(u16_.at(h, 32))) * (1.0 / 65536.0) - 0.5) * 0.1;
    const jy: f32 = (@as(f32, @floatFromInt(u16_.at(h, 16))) * (1.0 / 65536.0) - 0.5) * 0.1;
    const age: f32 = @as(f32, @floatFromInt(u16_.at(h, 0))) * (1.0 / 65536.0);
    return .{ .kind = kind, .jx = jx, .jy = jy, .age = age };
}

/// The dedicated kill-stream draw (competing-risks accident test, q>0 only).
/// Matches the Halide generator's h_kill. Returns a float in [0,1) for the
/// Bernoulli(q) test. Drawn only when q > 0 AND age < kill_age (short-circuit,
/// like the branchy path — though blend computes it branchlessly regardless).
pub inline fn killFloat(i: usize, frame: u64) f32 {
    const h = splitmix64(SEED ^ 0xDEAD ^ (frame *% 0x100000001B3) ^ (@as(u64, i) *% 0x9E3779B1));
    // h_kill_f = (h >> 40) * (1/2^24) — top 24 bits as a float in [0,1)
    return @as(f32, @floatFromInt(h >> 40)) * (1.0 / 16777216.0);
}