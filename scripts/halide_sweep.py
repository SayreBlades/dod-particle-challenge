#!/usr/bin/env python3
# scripts/halide_sweep.py — the per-layout Halide schedule-space sweep
# (layout-verticals.md §6.2 step 4; halide-exploration.md §4.2).
#
# Enumerates schedule candidates for the layout's Halide strategy, AOT-
# compiles each to zig-out/halide/<strat>_<id>.a, links it via
# `zig build -Dhalide_variant=<id>`, benches at a fixed N, and writes
# .scratch/halide/<layout>.csv + a landscape chart overlaying the layout's
# best Zig strategy. An occasionally-run context instrument (like
# pmc_sweep.sh), not part of the hot build.
#
# Run with the Halide env's python:
#   .venv-halide/bin/python scripts/halide_sweep.py [--layout L1] [--n 1000000] [--iters 200]

import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = {"L1": "src/layouts/L1_aos_full/halide_a_gen.py"}
STRAT = {"L1": "halide_a"}
# The Zig control rows (measured fresh by this script): the layout's naive
# baseline and its best known serial strategy.
ZIG_CONTROLS = {"L1": ["naive", "par"]}

MANUAL_GRID = [
    {"vector_width": vw, "parallel": par}
    for vw in (1, 2, 4, 8)
    for par in (False, True)
]
AUTOSCHEDULERS = ["Mullapudi2016", "Adams2019", "Li2018"]
# Anderson2021 is GPU-only ("target does not support GPU" on arm-64-osx CPU) —
# excluded by design; noted in the layout README.


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, **kw)


def bench_ns_per_particle(binary_args):
    r = run(["./zig-out/bin/dod-particles"] + binary_args)
    # table row: N | bytes/p | mem | ns/particle(min) | ...
    # (Zig's std.debug.print writes to stderr — parse stdout+stderr)
    for line in (r.stdout + r.stderr).splitlines():
        cols = [c.strip() for c in line.split("|")]
        if len(cols) >= 4 and cols[0].isdigit():
            return float(cols[3])
    raise RuntimeError(f"could not parse bench output:\n{r.stdout}\n{r.stderr}")


def build_and_bench(strat, variant, n, iters, extra_args=None):
    args = ["zig", "build", "-Dlayout=L1", f"-Dstrat={strat}", "-Dmode=bench", "-Doptimize=ReleaseFast"]
    if variant:
        args.append(f"-Dhalide_variant={variant}")
    r = run(args)
    if r.returncode != 0:
        raise RuntimeError(f"zig build failed:\n{r.stdout}\n{r.stderr}")
    return bench_ns_per_particle((extra_args or []) + ["--n", str(n), "--iters", str(iters)])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--layout", default="L1")
    ap.add_argument("--n", type=int, default=1_000_000)
    ap.add_argument("--iters", type=int, default=200)
    ap.add_argument("--python", default=os.environ.get("HALIDE_PYTHON", ".venv-halide/bin/python"))
    args = ap.parse_args()

    layout = args.layout
    strat = STRAT[layout]
    os.makedirs(f"{ROOT}/.scratch/halide", exist_ok=True)
    csv_path = f"{ROOT}/.scratch/halide/{layout}.csv"
    rows = []

    # --- Zig controls (fresh, same machine/session) ---
    for z in ZIG_CONTROLS[layout]:
        print(f"[zig] {z} ...", flush=True)
        ns = build_and_bench(z, None, args.n, args.iters)
        rows.append(("zig", z, "-", "-", ns))
        print(f"  ns/p = {ns:.3f}")

    # --- manual schedule grid ---
    for sched in MANUAL_GRID:
        cid = f"vw{sched['vector_width']}" + ("p" if sched["parallel"] else "")
        print(f"[halide] {cid} {sched} ...", flush=True)
        r = run([args.python, GEN[layout], f"zig-out/halide/{strat}_{cid}", json.dumps(sched)])
        if r.returncode != 0:
            print(f"  GENERATE FAILED: {r.stdout}{r.stderr}")
            continue
        ns = build_and_bench(strat, cid, args.n, args.iters)
        rows.append(("halide", cid, sched["vector_width"], sched["parallel"], ns))
        print(f"  ns/p = {ns:.3f}")

    # --- autoschedulers ---
    for name in AUTOSCHEDULERS:
        cid = f"as_{name.lower()}"
        print(f"[halide] {cid} ...", flush=True)
        r = run([args.python, GEN[layout], f"zig-out/halide/{strat}_{cid}", json.dumps({"autoscheduler": name})])
        if r.returncode != 0:
            print(f"  GENERATE FAILED: {r.stdout}{r.stderr}")
            continue
        ns = build_and_bench(strat, cid, args.n, args.iters)
        rows.append(("halide", cid, name, "-", ns))
        print(f"  ns/p = {ns:.3f}")

    with open(csv_path, "w") as f:
        f.write("kind,candidate,vw_or_sched,parallel,ns_particle\n")
        for row in rows:
            f.write(",".join(str(x) for x in row) + "\n")
    print(f"wrote {csv_path}")

    # --- the landscape chart (the deliverable) ---
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(9, 5))
    halide_rows = [r for r in rows if r[0] == "halide"]
    labels = [r[1] for r in halide_rows]
    vals = [r[4] for r in halide_rows]
    colors = ["#4c72b0" if not str(r[1]).startswith("as_") else "#dd8452" for r in halide_rows]
    ax.bar(labels, vals, color=colors)
    for r in rows:
        if r[0] == "zig":
            ax.axhline(r[4], linestyle="--", label=f"zig {r[1]} ({r[4]:.3f} ns/p)")
    ax.set_ylabel("ns/particle @ N={:,} (min of trials, step-only)".format(args.n))
    ax.set_title(f"{layout} Halide schedule sweep — AoS strided gather (blue=manual grid, orange=autoschedulers)")
    ax.legend()
    ax.set_ylim(bottom=0)
    plt.xticks(rotation=45, ha="right")
    fig.tight_layout()
    png = f"{ROOT}/.scratch/halide/{layout}_landscape.png"
    fig.savefig(png, dpi=140)
    print(f"wrote {png}")


if __name__ == "__main__":
    main()
