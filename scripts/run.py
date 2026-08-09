#!/usr/bin/env python3
"""Thin build/bench/play/profile dispatcher used by the Makefile.

Resolves a target — a full cell name (L1.B1.w1-autovec.w2-simple), a layout
(L1), or `all`/empty — into the list of cells to act on, then runs the
requested action for each. (Bare strats are rejected: strat names recur
across layouts, so they're ambiguous.)

    scripts/run.py build  [target]   zig build into out/ (one prefix, overwritten)
    scripts/run.py bench  [target]   build + run bench (table to stderr; no data append)
    scripts/run.py play   [target]   build + open the raylib window (one cell)
    scripts/run.py profile [target]  PMC cycle-attribution for one cell (macOS+Xcode)

`build`/`bench` accept `all`/a layout/a cell; `play`/`profile` need a single
cell (default: the L1 reference, L1.B1.w1-autovec.w2-simple).

Used by the Makefile's positional-target convention, e.g.:
    make build              # -> run.py build all
    make build L1           # -> run.py build L1
    make bench L1.B1.w1-autovec.w2-simple
    make play L1.B1.w1-autovec.w2-simple
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_CELL = "L1.B1.w1-autovec.w2-simple"


def layout_ids() -> list[str]:
    """Layout ids = the L<digits> directories under src/layouts/. The folder
    name IS the layout id, so there's no id->folder mapping to maintain."""
    import re
    base = os.path.join(ROOT, "src", "layouts")
    return sorted(d for d in os.listdir(base)
                  if re.fullmatch(r"L\d+", d) and os.path.isdir(os.path.join(base, d)))


def read_cells(layout: str) -> list[str]:
    path = os.path.join(ROOT, "experiments", "sweeps", f"{layout}.cells")
    return [l.strip() for l in open(path)
            if l.strip() and not l.strip().startswith("#")]


def resolve(target: str) -> list[str]:
    """target -> list of full cell names."""
    known = layout_ids()
    if not target or target == "all":
        cells = []
        for layout in known:
            cells.extend(read_cells(layout))
        return cells
    if target in known:
        return read_cells(target)
    if "." in target:
        layout = target.split(".", 1)[0]
        if layout not in known:
            sys.exit(f"error: unknown layout '{layout}' in cell '{target}'")
        return [target]
    sys.exit(f"error: '{target}' is not a layout or a full cell name "
            f"(expected L<layout>.<strat>, e.g. {DEFAULT_CELL})")


def zig_build(cell: str, mode: str, prefix: str = "out") -> bool:
    layout, strat = cell.split(".", 1)
    r = subprocess.run(
        ["zig", "build", "-p", prefix, f"-Dlayout={layout}",
         f"-Dstrat={strat}", f"-Dmode={mode}", "-Doptimize=ReleaseFast"],
        cwd=ROOT)
    return r.returncode == 0


def bin_path(cell: str, mode: str) -> str:
    """Flat-name binary: out/bin/<layout>.<strat>.<mode>"""
    return os.path.join(ROOT, "out", "bin", f"{cell}.{mode}")


def cmd_build(cells: list[str]) -> int:
    for c in cells:
        print(f"  build {c}...", file=sys.stderr)
        if not zig_build(c, "bench"):
            print(f"    BUILD FAILED — {c}", file=sys.stderr)
    return 0


def cmd_bench(cells: list[str]) -> int:
    for c in cells:
        print(f"=== bench {c} ===", file=sys.stderr)
        if not zig_build(c, "bench"):
            print(f"    BUILD FAILED — {c}", file=sys.stderr)
            continue
        bin_path = bin_path(c, "bench")
        subprocess.run([bin_path], cwd=ROOT)
    return 0


def cmd_play(cells: list[str]) -> int:
    if len(cells) != 1:
        sys.exit("error: play needs exactly one cell (got: " + " ".join(cells) + ")")
    c = cells[0]
    print(f"=== play {c} ===", file=sys.stderr)
    if not zig_build(c, "play"):
        sys.exit(f"BUILD FAILED — {c}")
    return subprocess.run([bin_path(c, "play")], cwd=ROOT).returncode


def cmd_profile(cells: list[str]) -> int:
    if len(cells) != 1:
        sys.exit("error: profile needs exactly one cell (got: " + " ".join(cells) + ")")
    c = cells[0]
    # PMC needs a single (N, iters, trial); pick a large-N sample for stable counters.
    return subprocess.run([sys.executable,
                           os.path.join(ROOT, "scripts", "pmc_collect.py"),
                           c, "1000000", "100", "1"]).returncode


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["build", "bench", "play", "profile"])
    ap.add_argument("target", nargs="?", default="all",
                    help="layout (L1), full cell name (L1.B1.w1-autovec.w2-simple), or all (default: all)")
    args = ap.parse_args()

    if args.action in ("play", "profile"):
        cells = resolve(args.target)
        if len(cells) != 1 and args.target not in ("", "all") and "." not in args.target:
            # layout/all -> pick default; a full cell resolved to one already
            cells = [DEFAULT_CELL]
        elif args.target in ("", "all") or len(cells) != 1:
            cells = [DEFAULT_CELL]
    else:
        cells = resolve(args.target)

    if not cells:
        sys.exit("error: no cells to act on.")

    return {"build": cmd_build, "bench": cmd_bench,
            "play": cmd_play, "profile": cmd_profile}[args.action](cells)


if __name__ == "__main__":
    raise SystemExit(main())
