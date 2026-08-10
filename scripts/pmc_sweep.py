#!/usr/bin/env python3
"""PMC collection across all algorithms of a memory layout x N.

Runs scripts/pmc_collect.py for every (algorithm, N, trial) combo, producing
one CSV per trial in .scratch/pmc/ and a rollup .scratch/pmc/pmc_rollup.csv
(min per (algorithm, N) across trials + derived percentages).

Optional, macOS + Xcode only (the separate cycle-attribution layer; the
unified sweep is scripts/collect.py). Iter counts are scaled by N so each
trial runs ~1-3s of step() work (enough for stable counters, not so long the
sweep takes hours).

Usage:
    scripts/pmc_sweep.py [mem_layout] [trials] [--algos "<list>"] [--run-dir <dir>"]
    mem_layout defaults to ML1 (reads experiments/sweeps/<mem_layout>.algos)
    trials defaults to 3
"""
from __future__ import annotations

import argparse
import csv
import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# N -> iters pairs. Smaller N gets more iters (each step is cheap); larger N
# gets fewer (each step is already slow).
N_ITERS = [
    (4000, 2000), (16000, 1000), (65000, 500), (262000, 200),
    (1000000, 100), (4000000, 50), (16000000, 20), (64000000, 10),
]


def read_algos(mem_layout: str) -> list[str]:
    path = os.path.join(ROOT, "experiments", "sweeps", f"{mem_layout}.algos")
    if not os.path.exists(path):
        sys.exit(f"error: {path} not found.")
    out = [l.strip() for l in open(path) if l.strip() and not l.strip().startswith("#")]
    if not out:
        sys.exit(f"error: no algorithms in {path}.")
    return out


def collect_one(algo: str, n: int, iters: int, trial: int) -> bool:
    r = subprocess.run([sys.executable,
                        os.path.join(ROOT, "scripts", "pmc_collect.py"),
                        algo, str(n), str(iters), str(trial)],
                       capture_output=True, text=True)
    line = next((l for l in (r.stderr + r.stdout).splitlines() if "cycles=" in l), "      FAILED")
    print(f"      {line}", file=sys.stderr)
    return r.returncode == 0


def build_rollup(outdir: str, rollout_dir: str) -> None:
    rows: dict[tuple[str, int], list[dict]] = {}
    for path in sorted(glob.glob(os.path.join(outdir, "*_n*_t*.csv"))):
        with open(path) as f:
            for r in csv.DictReader(f):
                key = (r["algo"], int(r["N"]))
                rows.setdefault(key, []).append({
                    "cycles": int(r["cycles"]), "useful": int(r["useful"]),
                    "processing": int(r["processing_bottleneck"]),
                    "delivery": int(r["delivery_bottleneck"]),
                    "discarded": int(r["discarded_bottleneck"]),
                    "iters": int(r["iters"]), "trial": int(r["trial"]),
                })
    rollup = os.path.join(rollout_dir, "pmc_rollup.csv")
    os.makedirs(rollout_dir, exist_ok=True)
    with open(rollup, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["algo", "N", "iters", "trial", "cycles", "useful",
                    "processing_bottleneck", "delivery_bottleneck",
                    "discarded_bottleneck", "pct_useful", "pct_processing",
                    "pct_delivery", "pct_discarded"])
        for key in sorted(rows):
            best = min(rows[key], key=lambda t: t["cycles"])
            c = best["cycles"]
            p = lambda x: f"{100.0 * x / c:.1f}" if c else "0.0"
            w.writerow([key[0], key[1], best["iters"], best["trial"], c,
                        best["useful"], best["processing"], best["delivery"],
                        best["discarded"], p(best["useful"]), p(best["processing"]),
                        p(best["delivery"]), p(best["discarded"])])
    print(f"\n  {'algo':>36} {'N':>10} {'cycles':>10} {'%useful':>8} "
          f"{'%proc':>7} {'%deliv':>7} {'%disc':>7}")
    print(f"  {'-' * 36} {'-' * 10} {'-' * 10} {'-' * 8} {'-' * 7} {'-' * 7} {'-' * 7}")
    with open(rollup) as f:
        for r in sorted(csv.DictReader(f), key=lambda x: (x["algo"], int(x["N"]))):
            print(f"  {r['algo']:>36} {r['N']:>10} {r['cycles']:>10} "
                  f"{r['pct_useful']:>7}% {r['pct_processing']:>6}% "
                  f"{r['pct_delivery']:>6}% {r['pct_discarded']:>6}%")
    print(f"\n  wrote {rollup}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mem_layout", nargs="?", default="ML1")
    ap.add_argument("trials", nargs="?", type=int, default=3)
    ap.add_argument("--algos", default="", help="space-separated algorithm list (default: <mem_layout>.algos)")
    ap.add_argument("--run-dir", default=None, help="where to write the rollup (default: .scratch/pmc/)")
    args = ap.parse_args()

    algos = args.algos.split() if args.algos else read_algos(args.mem_layout)
    outdir = os.path.join(ROOT, ".scratch", "pmc")
    rollout_dir = args.run_dir or outdir
    os.makedirs(outdir, exist_ok=True)
    os.makedirs(rollout_dir, exist_ok=True)

    total = len(N_ITERS) * len(algos) * args.trials
    ns = ", ".join(str(n) for n, _ in N_ITERS)
    print(f"=== PMC sweep: mem_layout={args.mem_layout} trials={args.trials} ===", file=sys.stderr)
    print(f"    algos: {' '.join(algos)}", file=sys.stderr)
    print(f"    Ns: {ns}", file=sys.stderr)
    print(f"    ~{total} xctrace launches (each ~2-5s + overhead)", file=sys.stderr)
    print(file=sys.stderr)

    i = 0
    for algo in algos:
        for n, iters in N_ITERS:
            for t in range(1, args.trials + 1):
                i += 1
                print(f"[{i}/{total}] algo={algo} N={n} iters={iters} trial={t}",
                      file=sys.stderr)
                if not collect_one(algo, n, iters, t):
                    print("      FAILED", file=sys.stderr)

    print("\n=== building rollup (min per algo/N across trials) ===", file=sys.stderr)
    build_rollup(outdir, rollout_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
