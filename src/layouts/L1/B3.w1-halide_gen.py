# B3.w1-halide_gen.py — the B3 Halide math+decide walk (walk 1 only).
#
# B3's walk 1 is math + decide → dead mask (no respawn; respawn is the Zig
# walk 2). This generator emits the math (integrate pos/vel/age) AND the
# decide (competing-risks death test) → a dead-mask output buffer (u8, 1 per
# particle). The cell's `step` calls this for walk 1, then runs the Zig
# mask-scan+respawn walk 2 + the Zig splat walk 3.
#
# The decide uses the per-chunk kill-RNG discipline (splitmix64) so the parallel
# variant is deterministic per (T, chunk). q=0 prunes to age-only (no kill hash).
#
# Usage: python B3.w1-halide_gen.py <out_prefix> [schedule_json] [q]

import halide as hl
import json, sys, os

out = sys.argv[1]
os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
sched = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
q = hl.Param(hl.Float(32), "q")  # runtime scalar param (Zig wrapper passes config.q)
vw = int(sched.get("vector_width", 1))
par = bool(sched.get("parallel", False))

data = hl.ImageParam(hl.Float(32), 2, "data")  # f32 view: 17 components × N
data.dim(0).set_stride(1)
data.dim(1).set_stride(17)

i = hl.Var("i")

gx, gy, gz = hl.f32(0.0), hl.f32(-1.0), hl.f32(0.0)
drag = hl.f32(0.02)
dt = hl.Param(hl.Float(32), "dt")
kill_age = hl.Param(hl.Float(32), "kill_age")
SEED = hl.u64(0xC0FFEE)
U64 = hl.UInt(64)

def splitmix64(x):
    x = x + hl.u64(0x9E3779B97F4A7C15)
    z = x
    z = (z ^ (z >> 30)) * hl.u64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> 27)) * hl.u64(0x94D049BB133111EB)
    return z ^ (z >> 31)

# --- math: integrate pos/vel/age ---
outs = []
for ci, comp in enumerate("xyz"):
    g = {"x": gx, "y": gy, "z": gz}[comp]
    pf = hl.Func(f"pos_{comp}_out")
    vf = hl.Func(f"vel_{comp}_out")
    pf[i] = data[ci, i] + data[ci + 3, i] * dt
    vf[i] = data[ci + 3, i] + (g + drag * data[ci + 3, i]) * dt
    pf.output_buffer().dim(0).set_stride(17)
    vf.output_buffer().dim(0).set_stride(17)
    outs += [pf, vf]

age_out = hl.Func("age_out")
age_new = data[7, i] + dt  # age at component index 7
age_out[i] = age_new
age_out.output_buffer().dim(0).set_stride(17)
outs += [age_out]

# --- decide → dead mask (competing risks) ---
dead = age_new >= kill_age
# kill hash always computed; at runtime q=0 it's a no-op (h_kill_f >= 0, so
# `h_kill_f < 0` never holds — dead unchanged).
h_kill = splitmix64(SEED ^ hl.u64(0xDEAD) ^ (hl.cast(U64, i) * hl.u64(0x9E3779B1)))
h_kill_f = hl.cast(hl.Float(32), h_kill >> 40) * (1.0 / 16777216.0)
dead = dead | (h_kill_f < q)

dead_out = hl.Func("dead_out")
dead_out[i] = hl.cast(hl.UInt(8), hl.select(dead, 1, 0))
dead_out.output_buffer().dim(0).set_stride(1)  # 1 B/p mask, tightly packed
outs += [dead_out]

# --- schedule ---
target = hl.get_host_target().with_feature(hl.TargetFeature.StrictFloat)
for f in outs[1:]:
    f.compute_with(outs[0], i)
if vw > 1:
    for f in outs:
        f.vectorize(i, vw)
if par:
    for f in outs:
        f.parallel(i)

hl.Pipeline(outs).compile_to_static_library(
    out, [data, dt, kill_age, q], "halide_b3_mask", target)
print(f"emitted {out}.h {out}.a (vw={vw} parallel={par} q=runtime B3-math+mask)")
