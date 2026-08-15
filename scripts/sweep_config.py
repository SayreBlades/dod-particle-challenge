#!/usr/bin/env python3
"""sweep_config — the single source of truth for the collection grid.

The N/q/T axes + per-N iters/warmup schedules live here as constants, and the
algorithm roster is parsed from build.zig's `algo_labels` registry (what can
build = what gets swept). collect.py, bench.py and analyze_algo.py all import
this. Env-overridable where it matters (NS, TRIALS, THREADS, DEATH_RATES).

(The legacy experiments/sweeps/ config files were retired: `death_rates.txt`
and the per-layout `<ML>.algos` rosters duplicated this module / build.zig.
Sweeping a subset is a CLI concern — pass targets to collect.py.)
"""
from __future__ import annotations
import os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The N grid — decadal (10^4..10^7), machine-agnostic. Each decade brackets a
# regime: 10k=L2-resident, 100k=just-past-L2 (the 4MB≈59k-particle knee falls
# between 10k and 100k), 1M=memory-bound, 10M=deep-memory saturation. Override
# per-run with NS= env. (Validated 2026-08: 10k/100k/1M CV≤1.1%; 10M feasible
# at 680MB working set, ~96ms/frame.)
N_GRID = [10000, 100000, 1000000, 10000000]

# Timed frames per N (report takes min over trials). Sized for a ≥18ms timed
# region at every N (timer-granularity/scheduler-jitter floor); large N is
# intrinsically stable so fewer frames suffice. Regions: 18/92/564/960 ms.
ITERS = {10000: 200, 100000: 100, 1000000: 60, 10000000: 10}
ITERS_DEFAULT = 50

# Warmup frames per N (prime caches/predictors/DVFS before the timed region).
WARMUP = {10000: 20, 100000: 10, 1000000: 3, 10000000: 2}
WARMUP_DEFAULT = 5

# Thread set — shared by bench AND profile. Parallel algorithms sweep it; serial
# algorithms run T=1 only. {1,4,8} = baseline / mid / saturation (T=2 dropped:
# 1→2 is near-linear/predictable, and the radar stays fully populated at every T
# only if bench and profile share one set).
THREADS_DEFAULT = "1 4 8"

# The death-rate (q) axis. Drops 0.05 from the legacy set — the best-interpolated
# value (linear interp 0.01↔0.10 is within ≤0.5pp on branch_flush); keeps both
# extremes (0.01 near-natural, 0.50 max churn) AND brackets the steepest signal
# gradient (branch_flush jumps 15→27pp across 0.10→0.25). Override with
# DEATH_RATES="q1 q2 ..." (space- or comma-list).
DEATH_RATES = [0.01, 0.10, 0.25, 0.50]

BUILD_ZIG = os.path.join(ROOT, "build.zig")


def iters_for(n: int) -> int:
    return ITERS.get(n, ITERS_DEFAULT)


def warmup_for(n: int) -> int:
    return WARMUP.get(n, WARMUP_DEFAULT)


def death_rates() -> list[float]:
    env = os.environ.get("DEATH_RATES", "").replace(",", " ")
    if env.strip():
        return [float(x) for x in env.split()]
    return list(DEATH_RATES)


def algo_roster() -> list[str]:
    """Full algo names ('ML01.<algo>') parsed from build.zig's `algo_labels`
    registry — the single source of truth for what can build (and therefore be
    swept). Raises loudly (not empty-silent) if the registry format changes."""
    src = open(BUILD_ZIG, encoding="utf-8").read()
    entries = re.findall(
        r'\.\{\s*\.mem_layout\s*=\s*"(ML\d+)"\s*,\s*\.algo\s*=\s*"([^"]+)"', src)
    if not entries:
        raise RuntimeError(
            "no algo_labels entries parsed from build.zig — did the registry "
            "format change? (expected .{ .mem_layout = \"MLnn\", .algo = \"...\" })")
    return [f"{ml}.{algo}" for ml, algo in entries]


def mem_layout_algos(mem_layout: str) -> list[str]:
    """The roster filtered to one memory layout (e.g. 'ML01')."""
    prefix = mem_layout + "."
    return [a for a in algo_roster() if a.startswith(prefix)]
