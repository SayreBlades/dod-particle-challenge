# Generator for L1.halide_a — the natural-seam Halide strategy on AoS storage
# (layout-verticals.md §6.2; halide-exploration.md §2.1/§2.6).
#
# Halide does the two MATH passes (integrate + forces); Zig keeps the branchy
# scalar age/kill/respawn (the natural seam — the golden's RNG discipline is
# untouched by construction). The input is the L1 particle array as a 2-D
# interleaved buffer: dim0 = component (stride 1), dim1 = particle
# (stride 17 floats = 68 B). Vectorizing across particles is therefore a
# STRIDED GATHER — measuring that cost, on a toolchain that vectorizes, is
# the entire point of L1's Halide section (§6.4).
#
# Usage: python halide_a_gen.py <out_prefix> [schedule_json]
# Emits <out_prefix>.h + <out_prefix>.a (runtime bundled; no libHalide needed
# at link time). schedule_json (optional, the sweep's knob):
#   {"vector_width": 4, "parallel": false}

import halide as hl
import json
import sys

out = sys.argv[1]
import os
os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
sched = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
vw = int(sched.get("vector_width", 4))
par = bool(sched.get("parallel", False))

# --- algorithm (identical math to config.zig, expressed over the AoS buffer) ---
# components: pos = c 0..2, vel = c 3..5. age (c 7) stays in Zig.
data = hl.ImageParam(hl.Float(32), 2, "data")
data.dim(0).set_stride(1)
data.dim(1).set_stride(17)

dt = hl.Param(hl.Float(32), "dt")
gx = hl.Param(hl.Float(32), "gx")
gy = hl.Param(hl.Float(32), "gy")
gz = hl.Param(hl.Float(32), "gz")
drag = hl.Param(hl.Float(32), "drag")

c = hl.Var("c")
i = hl.Var("i")

# gravity component for output lane c (c in 0..2)
g = hl.select(c == 0, gx, hl.select(c == 1, gy, gz))

pos_out = hl.Func("pos_out")
vel_out = hl.Func("vel_out")
# pos' = pos + vel*dt        (reads OLD vel — aliasing is safe: pos_out writes
# vel' = vel + (g + drag*vel)*dt   only c 0..2, reads only c 0..5 same-i)
pos_out[c, i] = data[c, i] + data[c + 3, i] * dt
vel_out[c, i] = data[c + 3, i] + (g + drag * data[c + 3, i]) * dt

# Output descriptors: same AoS stride, disjoint component ranges — aliased
# in-place into the particle array (elementwise, same-i dependence only).
for f in (pos_out, vel_out):
    f.output_buffer().dim(0).set_stride(1)
    f.output_buffer().dim(1).set_stride(17)

autosched = sched.get("autoscheduler")
target = hl.get_host_target()
target = target.with_feature(hl.TargetFeature.StrictFloat)  # the FP gate

# --- schedule (manual directives only when NOT autoscheduling — the
# autoscheduler refuses pipelines with directives already applied) ---
if not autosched:
    if vw > 1:
        pos_out.vectorize(i, vw)
        vel_out.vectorize(i, vw)
    if par:
        pos_out.parallel(i)
        vel_out.parallel(i)

pipeline = hl.Pipeline([pos_out, vel_out])
if autosched:
    # The autoscheduler replaces the manual schedule entirely. Plugins ship
    # in the pip package's lib/ but aren't auto-discovered — load explicitly.
    hl.load_plugin(
        os.path.join(hl.install_dir(), "lib", f"libautoschedule_{autosched.lower()}.so")
    )
    # Autoschedulers cost-model from estimates: outputs are (3 comps × N
    # particles), input is the full 17-float struct × N. N=1M = the sweep's
    # bench point.
    N_EST = 1_000_000
    for f in (pos_out, vel_out):
        f.set_estimates([hl.Range(0, 3), hl.Range(0, N_EST)])
    data.set_estimates([hl.Range(0, 17), hl.Range(0, N_EST)])
    dt.set_estimate(1.0 / 60.0)
    gx.set_estimate(0.0)
    gy.set_estimate(-1.0)
    gz.set_estimate(0.0)
    drag.set_estimate(0.02)
    pipeline.apply_autoscheduler(target, hl.AutoschedulerParams(autosched))

pipeline.compile_to_static_library(
    out,
    [data, dt, gx, gy, gz, drag],
    "halide_a",
    target,
)
print(f"emitted {out}.h {out}.a (vw={vw} parallel={par} autoscheduler={autosched})")
