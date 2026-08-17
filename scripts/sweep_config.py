#!/usr/bin/env python3
"""sweep_config — the single source of truth for the collection grid.

The N/q/T axes + per-N iters/warmup schedules live here as constants, and the
algorithm roster is parsed from build.zig's `algo_labels` registry (what can
build = what gets swept). collect.py, bench.py and analyze_algo.py all import
this. Env-overridable where it matters (NS, TRIALS, DEATH_RATES).

(The legacy experiments/sweeps/ config files were retired: `death_rates.txt`
and the per-layout `<ML>.algos` rosters duplicated this module / build.zig.
Sweeping a subset is a CLI concern — pass targets to collect.py.)
"""
from __future__ import annotations
import os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The FALLBACK N grid - decadal (10^4..10^7), machine-agnostic, used when no
# hardware.json exists yet. The real grid is machine-aware: n_grid(hw) brackets
# this machine's cache transitions (report-v2.md section 2) so knees are
# visible. Override per-run with NS= env.
N_GRID = [10000, 100000, 1000000, 10000000]

# The PROFILE N grid - FROZEN at the coarse decades (decision: dense-N is a
# bench-only change; profile collection stays 4 points x 4 q per algo).
PROFILE_N_GRID = [10000, 100000, 1000000, 10000000]


def _round_n(n: int) -> int:
    """1-2 significant figures, human-round."""
    if n >= 1e6: return int(round(n, -5))
    if n >= 1e5: return int(round(n, -4))
    if n >= 1e4: return int(round(n, -3))
    if n >= 1e3: return int(round(n, -2))
    return int(round(n, -1))


def n_grid(hw: dict, bpp: int = 68) -> list[int]:
    """Machine-aware bench grid: the decades plus 5 points bracketing each
    cache transition (N_t = size/bpp), deduped with a >=1.15x log-spacing
    floor, clamped to [300, 1e7]. M4 (bpp 68): 13 points bracketing 964 and
    61680; Ryzen ~17 (482, 7710, 246724)."""
    pts = [10 ** k for k in range(4, 8)]
    for key in ("l1dcachesize", "l2cachesize", "l3cachesize"):
        sz = hw.get(key) or 0
        if not sz:
            continue
        t = sz / bpp
        for mult in (1 / 2.5, 1 / 1.5, 1.0, 1.5, 2.5):
            n = _round_n(int(t * mult))
            if 300 <= n <= 10_000_000:
                pts.append(n)
    out = []
    for n in sorted(set(pts)):
        if not out or n >= out[-1] * 1.15:
            out.append(n)
    return out


_GRID_CACHE: dict[str, list[int]] = {}


def machine_grid(machine_id: str) -> list[int]:
    """n_grid for a measured machine (from its data/<id>/hardware.json); the
    fallback decades when absent."""
    if machine_id in _GRID_CACHE:
        return list(_GRID_CACHE[machine_id])
    p = os.path.join(ROOT, "experiments", "data", machine_id, "hardware.json")
    try:
        import json
        grid = n_grid(json.load(open(p)))
    except (OSError, ValueError):
        grid = list(N_GRID)
    _GRID_CACHE[machine_id] = grid
    return list(grid)


# Timed frames per N (report takes min over trials). COMPUTED (was a fixed
# table): enough frames for a >=~18ms timed region at every N assuming a
# conservative ~8 ns/particle floor - clamped [10, 4000].
def iters_for(n: int) -> int:
    return max(10, min(4000, -(-18_000_000 // (8 * n))))


# Warmup frames per N (prime caches/predictors/DVFS before the timed region).
def warmup_for(n: int) -> int:
    return max(2, min(400, iters_for(n) // 10))


# The death-rate (q) axis. Drops 0.05 from the legacy set — the best-interpolated
# value (linear interp 0.01↔0.10 is within ≤0.5pp on branch_flush); keeps both
# extremes (0.01 near-natural, 0.50 max churn) AND brackets the steepest signal
# gradient (branch_flush jumps 15→27pp across 0.10→0.25). Override with
# DEATH_RATES="q1 q2 ..." (space- or comma-list).
DEATH_RATES = [0.01, 0.10, 0.25, 0.50]

BUILD_ZIG = os.path.join(ROOT, "build.zig")


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
