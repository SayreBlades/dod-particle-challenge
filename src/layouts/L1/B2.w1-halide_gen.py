# B2.w1-halide_gen.py — the B2 Halide math walk (walk 1 only).
#
# B2 is the "natural seam": Halide does math (integrate pos/vel/age), Zig
# keeps decide+respawn (RNG-order, not Halide-expressible). So this generator
# emits ONLY the math: pos/vel/age updated, no decide, no respawn, no kind/color.
# The cell's `step` calls this for walk 1, then runs the Zig decide+respawn
# walk 2, then the Zig splat walk 3.
#
# The math is a subset of the B1 generator (everything except decide/respawn):
#   pos' = pos + vel*dt
#   vel' = vel + (gravity + drag*vel)*dt
#   age' = age + dt
# Same StrictFloat target so the math is bit-identical to the Zig cells.
#
# Usage: python B2.w1-halide_gen.py <out_prefix> [schedule_json] [q]

import halide as hl
import json, sys, os

out = sys.argv[1]
os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
sched = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
# q is unused (no decide here) but accepted for argv compatibility.
vw = int(sched.get("vector_width", 1))
par = bool(sched.get("parallel", False))

data = hl.ImageParam(hl.Float(32), 2, "data")  # f32 view: 17 components × N
data.dim(0).set_stride(1)
data.dim(1).set_stride(17)  # 68 B / 4 B = 17 floats per particle

i = hl.Var("i")

gx, gy, gz = hl.f32(0.0), hl.f32(-1.0), hl.f32(0.0)  # gravity (config.zig)
drag = hl.f32(0.02)
dt = hl.Param(hl.Float(32), "dt")

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
age_out[i] = data[7, i] + dt  # age at component index 7
age_out.output_buffer().dim(0).set_stride(17)
outs += [age_out]

target = hl.get_host_target().with_feature(hl.TargetFeature.StrictFloat)
for f in outs[1:]:
    f.compute_with(outs[0], i)
if vw > 1:
    for f in outs:
        f.vectorize(i, vw)
if par:
    for f in outs:
        f.parallel(i)

# extern fn name "halide_b2_math"; the FFI binding calls this.
hl.Pipeline(outs).compile_to_static_library(
    out, [data, dt], "halide_b2_math", target)
print(f"emitted {out}.h {out}.a (vw={vw} parallel={par} B2-math)")
