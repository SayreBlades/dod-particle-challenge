#!/usr/bin/env python3
"""Thin build/bench/play/profile dispatcher used by the Makefile.

Resolves a target — a full algorithm name (ML01.AF05.LP1-autovec.LP2-simple), a
memory layout (ML01), or `all`/empty — into the list of algorithms to act on,
then runs the requested action for each. (Bare algos are rejected: algo names
recur across memory layouts, so they're ambiguous.)

    scripts/run.py build  [target]   zig build into out/ (one prefix, overwritten)
    scripts/run.py bench  [target]   build + run bench (table to stderr; no data append)
    scripts/run.py play   [target]   build + open the raylib window (one algorithm)
    scripts/run.py profile [target]  PMC cycle-attribution for one algorithm (macOS+Xcode)

`build`/`bench` accept `all`/a memory layout/an algorithm; `play`/`profile`
need a single algorithm (default: the ML01 reference, ML01.AF05.LP1-autovec.LP2-simple).

Used by the Makefile's positional-target convention, e.g.:
    make build              # -> run.py build all
    make build ML01          # -> run.py build ML01
    make bench ML01.AF05.LP1-autovec.LP2-simple
    make play ML01.AF05.LP1-autovec.LP2-simple
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ALGO = "ML01.AF05.LP1-autovec.LP2-simple"


def mem_layout_ids() -> list[str]:
    """Memory-layout ids = the ML<digits> directories under src/layouts/. The
    folder name IS the mem_layout id, so there's no id->folder mapping to maintain."""
    import re
    base = os.path.join(ROOT, "src", "layouts")
    return sorted(d for d in os.listdir(base)
                  if re.fullmatch(r"ML\d+", d) and os.path.isdir(os.path.join(base, d)))


def read_algos(mem_layout: str) -> list[str]:
    path = os.path.join(ROOT, "experiments", "sweeps", f"{mem_layout}.algos")
    return [l.strip() for l in open(path)
            if l.strip() and not l.strip().startswith("#")]


def resolve(target: str) -> list[str]:
    """target -> list of full algorithm names."""
    known = mem_layout_ids()
    if not target or target == "all":
        algos = []
        for mem_layout in known:
            algos.extend(read_algos(mem_layout))
        return algos
    if target in known:
        return read_algos(target)
    if "." in target:
        mem_layout = target.split(".", 1)[0]
        if mem_layout not in known:
            sys.exit(f"error: unknown mem_layout '{mem_layout}' in algorithm '{target}'")
        return [target]
    sys.exit(f"error: '{target}' is not a memory layout or a full algorithm name "
            f"(expected ML<mem_layout>.<algo>, e.g. {DEFAULT_ALGO})")


def zig_build(algo: str, mode: str, prefix: str = "out") -> bool:
    mem_layout, algo_part = algo.split(".", 1)
    r = subprocess.run(
        ["zig", "build", "-p", prefix, f"-Dmem_layout={mem_layout}",
         f"-Dalgo={algo_part}", f"-Dmode={mode}", "-Doptimize=ReleaseFast"],
        cwd=ROOT)
    return r.returncode == 0


def bin_path(algo: str, mode: str) -> str:
    """Flat-name binary: out/bin/<algo>.<mode>"""
    return os.path.join(ROOT, "out", "bin", f"{algo}.{mode}")


def cmd_build(algos: list[str]) -> int:
    for a in algos:
        print(f"  build {a}...", file=sys.stderr)
        if not zig_build(a, "bench"):
            print(f"    BUILD FAILED — {a}", file=sys.stderr)
    return 0


def cmd_bench(algos: list[str]) -> int:
    # Quick single-point smoke (no --json, so nothing is appended to data/):
    # the binary is a single-point primitive now, so `make bench` shows one point.
    for a in algos:
        print(f"=== bench {a} (N=65000 q=0.1 T=1) ===", file=sys.stderr)
        if not zig_build(a, "bench"):
            print(f"    BUILD FAILED — {a}", file=sys.stderr)
            continue
        bp = bin_path(a, "bench")
        subprocess.run([bp, "--n", "65000", "--q", "0.1", "--threads", "1",
                        "--iters", "100", "--trial", "1"], cwd=ROOT)
    return 0


def cmd_play(algos: list[str]) -> int:
    if len(algos) != 1:
        sys.exit("error: play needs exactly one algorithm (got: " + " ".join(algos) + ")")
    a = algos[0]
    print(f"=== play {a} ===", file=sys.stderr)
    if not zig_build(a, "play"):
        sys.exit(f"BUILD FAILED — {a}")
    return subprocess.run([bin_path(a, "play")], cwd=ROOT).returncode


def cmd_profile(algos: list[str]) -> int:
    if len(algos) != 1:
        sys.exit("error: profile needs exactly one algorithm (got: " + " ".join(algos) + ")")
    a = algos[0]
    # One cycle-attribution point via the platform profiler backend (xctrace on
    # macOS). Full grid: `scripts/collect.py <target> --only profile`.
    return subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "profile.py"),
                           a, "--n", "1000000", "--q", "0.1", "--threads", "1",
                           "--trial", "1"]).returncode


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["build", "bench", "play", "profile"])
    ap.add_argument("target", nargs="?", default="all",
                    help="memory layout (ML01), full algorithm name (ML01.AF05.LP1-autovec.LP2-simple), or all (default: all)")
    args = ap.parse_args()

    if args.action in ("play", "profile"):
        algos = resolve(args.target)
        if len(algos) != 1 and args.target not in ("", "all") and "." not in args.target:
            # memory layout/all -> pick default; a full algorithm resolved to one already
            algos = [DEFAULT_ALGO]
        elif args.target in ("", "all") or len(algos) != 1:
            algos = [DEFAULT_ALGO]
    else:
        algos = resolve(args.target)

    if not algos:
        sys.exit("error: no algorithms to act on.")

    return {"build": cmd_build, "bench": cmd_bench,
            "play": cmd_play, "profile": cmd_profile}[args.action](algos)


if __name__ == "__main__":
    raise SystemExit(main())
