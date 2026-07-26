# Generator for L1.halide_b1 — the FULLY Halide step: math + branchless
# respawn in one pipeline (halide-exploration.md §2.3 variant B1).
#
# THE GOLDEN TENSION (read first): naive.zig draws respawn RNG only for dead
# particles, in death order — the golden's trajectories depend on that exact
# sequence. A branchless blend needs respawn values for EVERY particle, so
# no death-order stream can feed it. B1's answer: per-particle hash RNG
# (splitmix64 over (i, frame, draw)) — deterministic, vectorizable, but a
# DIFFERENT RNG model. Physics and respawn DISTRIBUTIONS are identical;
# trajectories diverge from stage1.bin by design. This strategy declares
# golden_class = .statistical (wrapper-side); the bench skips both goldens
# loudly.
#
# The pipeline (per particle, branchless — no kill branch anywhere):
#   age'  = age + dt;  dead = kill_test()
#   pos'  = select(dead, 0,                 pos + vel*dt)
#   vel'  = select(dead, impulse[k']+jitter, vel + (g + drag*vel)*dt)
#   age'' = select(dead, h_age*kill_age,     age')
#   kind' = select(dead, h_kind,             kind)
# kill_test is death-pattern-dependent (build-time, argv[3]):
#   natural     → age' >= kill_age
#   half        → dedicated kill hash < 0.5 (separate stream from spawn hash)
#   alternating → (i + frame) % 2 == 0
#
# kind is u8 inside the 68 B struct (byte offset 65) — not addressable in
# the f32 buffer view, so it travels as a second, u8-typed 1-D buffer
# (stride 68) over the same memory.
#
# Default schedule SCALAR (stride-17 gather tax applies as ever).
#
# Usage: python halide_b1_gen.py <out_prefix> [schedule_json] [death]

import halide as hl
import json
import sys

out = sys.argv[1]
import os
os.makedirs(os.path.dirname(out) or ".", exist_ok=True)

sched = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
death = sys.argv[3] if len(sys.argv) > 3 else "natural"
vw = int(sched.get("vector_width", 1))
par = bool(sched.get("parallel", False))

data = hl.ImageParam(hl.Float(32), 2, "data")          # f32 view: 17 comps
data.dim(0).set_stride(1)
data.dim(1).set_stride(17)
kind_in = hl.ImageParam(hl.UInt(8), 1, "kind_in")      # u8 view: kind byte
kind_in.dim(0).set_stride(68)

dt = hl.Param(hl.Float(32), "dt")
gx = hl.Param(hl.Float(32), "gx")
gy = hl.Param(hl.Float(32), "gy")
gz = hl.Param(hl.Float(32), "gz")
drag = hl.Param(hl.Float(32), "drag")
kill_age = hl.Param(hl.Float(32), "kill_age")
frame = hl.Param(hl.UInt(64), "frame")

i = hl.Var("i")
U64 = hl.UInt(64)

# --- per-particle hash RNG (splitmix64; deterministic per (i, frame, draw)) ---
def splitmix64(x):
    x = x + hl.u64(0x9E3779B97F4A7C15)
    z = x
    z = (z ^ (z >> 30)) * hl.u64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> 27)) * hl.u64(0x94D049BB133111EB)
    return z ^ (z >> 31)

SEED = hl.u64(0xC0FFEE)

# ONE splitmix64 draw per particle, bit-sliced into all four respawn fields
# (the hash was the b1.v1 bottleneck: 4 full draws/particle, ~30 integer
# ops — the measured 2.83 ns/p flat). 64 bits = 16 kind (Lemire, exactly
# uniform over 2^16, same algorithm as Zig's intRangeAtMost) + 16 jx + 16
# jy + 16 age. 16-bit resolution: jitter step ~1.5e-6, age step ~3e-5 s —
# finer than f32's effective precision at these scales; distributions match
# naive's 24-bit draws in shape (statistical class by design regardless).
h = splitmix64(SEED ^ (frame * hl.u64(0x100000001B3)) ^ (hl.cast(U64, i) * hl.u64(0x9E3779B1)))

u16 = lambda shift: hl.cast(hl.UInt(32), (h >> shift) & 0xFFFF)
h_kind = hl.cast(hl.UInt(8), (u16(48) * 3) >> 16)                    # Lemire
h_jx = (hl.cast(hl.Float(32), u16(32)) * (1.0 / 65536.0) - hl.f32(0.5)) * hl.f32(0.1)
h_jy = (hl.cast(hl.Float(32), u16(16)) * (1.0 / 65536.0) - hl.f32(0.5)) * hl.f32(0.1)
h_age = hl.cast(hl.Float(32), u16(0)) * (1.0 / 65536.0) * kill_age
if death == "half":
    # dedicated kill stream (drawn only in half builds — spawn-hash work
    # stays comparable across regimes)
    h_kill = splitmix64(SEED ^ hl.u64(0xDEAD) ^ (frame * hl.u64(0x100000001B3)) ^ (hl.cast(U64, i) * hl.u64(0x9E3779B1)))
    h_kill_f = hl.cast(hl.Float(32), h_kill >> 40) * (1.0 / 16777216.0)

# --- kill test (death pattern is build-time) ---
age_new = data[7, i] + dt
if death == "natural":
    dead = age_new >= kill_age
elif death == "half":
    dead = h_kill_f < hl.f32(0.5)
elif death == "alternating":
    dead = ((hl.cast(U64, i) + frame) % 2) == 0
else:
    raise ValueError(f"unknown death pattern {death}")

# --- impulse LUT (config.impulse) as select chains on the drawn kind ---
def impulse(comp):
    # kinds: 0=smoke, 1=spark, 2=debris
    f = hl.f32
    table = {
        "x": (f(0.0), f(1.0), f(0.4)),
        "y": (f(0.8), f(1.2), f(0.6)),
        "z": (f(0.0), f(0.0), f(0.2)),
    }[comp]
    return hl.select(h_kind == 1, table[1], hl.select(h_kind == 2, table[2], table[0]))

outs = []
for ci, comp in enumerate("xyz"):
    g = {"x": gx, "y": gy, "z": gz}[comp]
    pf = hl.Func(f"pos_{comp}_out")
    vf = hl.Func(f"vel_{comp}_out")
    jit = {"x": h_jx, "y": h_jy}.get(comp, 0.0)   # spawn: no jitter on z
    pf[i] = hl.select(dead, 0.0, data[ci, i] + data[ci + 3, i] * dt)
    vf[i] = hl.select(dead, impulse(comp) + jit,
                      data[ci + 3, i] + (g + drag * data[ci + 3, i]) * dt)
    pf.output_buffer().dim(0).set_stride(17)
    vf.output_buffer().dim(0).set_stride(17)
    outs += [pf, vf]

age_out = hl.Func("age_out")
age_out[i] = hl.select(dead, h_age, age_new)
age_out.output_buffer().dim(0).set_stride(17)

kind_now = hl.select(dead, h_kind, kind_in[i])
kind_out = hl.Func("kind_out")
kind_out[i] = kind_now
kind_out.output_buffer().dim(0).set_stride(68)
outs += [age_out, kind_out]

# Color: the stored field must stay color ≡ kindColor(kind) — v1 omitted
# these writes, so respawned particles kept their previous life's color
# (the stale-cold bug, caught VISUALLY: mixed streams in the b1 video).
# data.spawn writes color at spawn; the blend must too. Written
# unconditionally from kind_now (no old-color loads needed).
for ci, comp in enumerate(("r", "g", "b")):
    f = hl.f32
    table = {"r": (f(120.0), f(255.0), f(100.0)),
             "g": (f(120.0), f(180.0), f(200.0)),
             "b": (f(120.0), f(60.0), f(255.0))}[comp]
    cf = hl.Func(f"color_{comp}_out")
    cf[i] = hl.select(kind_now == 1, table[1], hl.select(kind_now == 2, table[2], table[0]))
    cf.output_buffer().dim(0).set_stride(17)
    outs.append(cf)

target = hl.get_host_target()
target = target.with_feature(hl.TargetFeature.StrictFloat)  # math identical

for f in outs[1:]:
    f.compute_with(outs[0], i)  # ONE fused i-loop
if vw > 1:
    for f in outs:
        f.vectorize(i, vw)
if par:
    for f in outs:
        f.parallel(i)

hl.Pipeline(outs).compile_to_static_library(
    out,
    [data, kind_in, dt, gx, gy, gz, drag, kill_age, frame],
    "halide_b1",
    target,
)
print(f"emitted {out}.h {out}.a (vw={vw} parallel={par} death={death} branchless-B1)")
