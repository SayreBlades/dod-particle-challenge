#!/usr/bin/env python3
"""sweep_config — the single source of truth for the collection grid.

Replaces the bench binary's old hardcoded SWEEP/ITERS_PER_N/WARMUP_PER_N consts
(now removed). collect.py and bench.py both import this so the grid is defined
once. Env-overridable where it matters (NS, TRIALS, THREADS).
"""
from __future__ import annotations
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The N grid (matches experiments/analysis/<id>/grid.json n_values). ~×4 geometric,
# straddling this machine's cache knees. Override per-run with NS= env.
N_GRID = [4000, 65000, 262000, 1000000, 4000000]

# Timed frames per N (min over trials is taken at load time). Small N is cheap +
# noisy (wants more samples); large N is expensive + stable.
ITERS = {4000: 200, 65000: 100, 262000: 100, 1000000: 60, 4000000: 20}
ITERS_DEFAULT = 50

# Warmup frames per N (prime caches/predictors/DVFS before the timed region).
WARMUP = {4000: 20, 65000: 10, 262000: 5, 1000000: 3, 4000000: 2}
WARMUP_DEFAULT = 5

# Parallel algorithms sweep this set; serial algorithms run T=1 only.
THREADS_DEFAULT = "1 2 4 8"

RATES_FILE = os.path.join(ROOT, "experiments", "sweeps", "death_rates.txt")


def iters_for(n: int) -> int:
    return ITERS.get(n, ITERS_DEFAULT)


def warmup_for(n: int) -> int:
    return WARMUP.get(n, WARMUP_DEFAULT)


def death_rates() -> list[float]:
    if not os.path.exists(RATES_FILE):
        return [0.01, 0.05, 0.1, 0.25, 0.5]
    return [float(l.strip()) for l in open(RATES_FILE)
            if l.strip() and not l.strip().startswith("#")]
