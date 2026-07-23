# Generator for L1.halide_a2 — the dead-mask variant, LEAN formulation.
#
# Same fused math as halide_a (naive.zig's complete branch-free loop body)
# + a 1 B/p dead mask, but expressed as NINE single-component 1-D Funcs
# (pos_x..vel_z, age, dead) instead of three 2-D (c,i) Funcs. Why: the
# (c,i) formulation makes gravity a runtime select on c (6 fcsel/particle)
# and makes Halide emit per-row bounds clamps and strided address arithmetic
# — measured 179 cmp + 27 csel + 6 fcsel vs 23 fmul/fadd in the a2 v1
# disassembly, an issue-bound loop at 26 GB/s (NOT the ~47 ceiling).
# Single-component Funcs make gravity a hoisted scalar constant per stream
# and each access a simple strided walk — the closest Halide gets to
# naive.zig's codegen. compute_with fuses all nine into ONE i-loop.
#
# Golden: bit-exact (same StrictFloat discipline as halide_a; mask from the
# same age' expression; respawn order preserved wrapper-side).
#
# Default schedule SCALAR (vw=1) — the honest AoS schedule on NEON (§5c).
#
# Usage: python halide_a2_gen.py <out_prefix> [schedule_json]

import halide as hl
import json
import sys

out = sys.argv[1]
import os
os.makedirs(os.path.dirname(out) or ".", exist_ok=True)

sched = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
vw = int(sched.get("vector_width", 1))
par = bool(sched.get("parallel", False))

data = hl.ImageParam(hl.Float(32), 2, "data")
data.dim(0).set_stride(1)
data.dim(1).set_stride(17)

dt = hl.Param(hl.Float(32), "dt")
gx = hl.Param(hl.Float(32), "gx")
gy = hl.Param(hl.Float(32), "gy")
gz = hl.Param(hl.Float(32), "gz")
drag = hl.Param(hl.Float(32), "drag")
kill_age = hl.Param(hl.Float(32), "kill_age")

i = hl.Var("i")

# Nine single-component outputs. pos.c = data(c,i), vel.c = data(3+c,i),
# age = data(7,i). Gravity is a hoisted scalar per stream — no selects.
outs = []
pos_f = []
vel_f = []
for ci, comp in enumerate("xyz"):
    g = {"x": gx, "y": gy, "z": gz}[comp]
    pf = hl.Func(f"pos_{comp}_out")
    vf = hl.Func(f"vel_{comp}_out")
    pf[i] = data[ci, i] + data[ci + 3, i] * dt
    vf[i] = data[ci + 3, i] + (g + drag * data[ci + 3, i]) * dt
    pf.output_buffer().dim(0).set_stride(17)
    vf.output_buffer().dim(0).set_stride(17)
    pos_f.append(pf)
    vel_f.append(vf)
    outs += [pf, vf]

age_out = hl.Func("age_out")
age_out[i] = data[7, i] + dt
age_out.output_buffer().dim(0).set_stride(17)

dead_out = hl.Func("dead_out")
# age' recomputed from data (a Func reading a sibling it's fused with makes
# the realization order cyclic — same expression, same rounding).
dead_out[i] = hl.cast(hl.UInt(8), hl.select(data[7, i] + dt >= kill_age, 1, 0))
dead_out.output_buffer().dim(0).set_stride(1)  # unit-stride mask
outs += [age_out, dead_out]

autosched = sched.get("autoscheduler")
target = hl.get_host_target()
target = target.with_feature(hl.TargetFeature.StrictFloat)  # the FP gate

if not autosched:
    for f in outs[1:]:
        f.compute_with(outs[0], i)  # ONE fused i-loop over all nine
    if vw > 1:
        for f in outs:
            f.vectorize(i, vw)
    if par:
        for f in outs:
            f.parallel(i)

pipeline = hl.Pipeline(outs)
if autosched:
    hl.load_plugin(
        os.path.join(hl.install_dir(), "lib", f"libautoschedule_{autosched.lower()}.so")
    )
    N_EST = 1_000_000
    for f in outs:
        f.set_estimates([hl.Range(0, N_EST)])
    data.set_estimates([[0, 17], [0, N_EST]])
    dt.set_estimate(1.0 / 60.0)
    gx.set_estimate(0.0)
    gy.set_estimate(-1.0)
    gz.set_estimate(0.0)
    drag.set_estimate(0.02)
    kill_age.set_estimate(2.0)
    pipeline.apply_autoscheduler(target, hl.AutoschedulerParams(autosched))

pipeline.compile_to_static_library(
    out,
    [data, dt, gx, gy, gz, drag, kill_age],
    "halide_a2",
    target,
)
print(f"emitted {out}.h {out}.a (vw={vw} parallel={par} autoscheduler={autosched}, lean 9-func)")
