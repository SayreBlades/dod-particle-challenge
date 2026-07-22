#!/usr/bin/env bash
# scripts/vertical_collect.sh — run strategies × modes, collect --csv rows
# into .scratch/verticals/<layout>.csv (layout-verticals.md §5.4 / §11).
#
# This is the vertical's batch instrument — an occasionally-run context tool,
# like pmc_sweep.sh, NOT part of the hot build. A full sweep through N=64M
# takes minutes per strategy (render dominates the frame mode); pass a
# subset when you only need a few rows.
#
# Usage:
#   scripts/vertical_collect.sh                       # default: L1 strategies × {step,frame}
#   scripts/vertical_collect.sh "L1.naive L1.par"     # subset of strategies
#   scripts/vertical_collect.sh "L1.naive" "step frame render"
#   DEATH=half scripts/vertical_collect.sh "L1.naive" # adversarial regime
#   THREADS=8 scripts/vertical_collect.sh "L1.par"    # thread-count knob
#
# Output: .scratch/verticals/<layout>.csv — rows like
#   csv,<name>,<mode>,<death>,<N>,<bytes/p>,<ns_frame>,<extra...>
#     step:   ...,bytes_p,ns_frame_min,ns_particle,gbs_eff
#     frame:  ...,bytes_p,ns_frame_min,step_ns,render_ns
#     render: ...,,(empty),ns_frame_min,ns_particle,(empty)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STRATS="${1:-L1.naive L1.naive_r1 L1.par}"
MODES="${2:-step frame}"
DEATH="${DEATH:-natural}"
THREADS="${THREADS:-1}"

for s in $STRATS; do
    layout="${s%%.*}"
    strat="${s#*.}"
    OUT=".scratch/verticals/${layout}.csv"
    mkdir -p .scratch/verticals
    echo "=== building $s (death=$DEATH threads=$THREADS) ===" >&2
    zig build -Dlayout="$layout" -Dstrat="$strat" -Dmode=bench -Ddeath="$DEATH" -Doptimize=ReleaseFast >&2 2>&1
    for mode in $MODES; do
        flag="--$mode"
        [ "$mode" = "step" ] && flag=""
        echo "  collecting $s $mode ..." >&2
        ./zig-out/bin/dod-particles $flag --csv --threads "$THREADS" 2>&1 | grep '^csv,' >> "$OUT" || true
    done
done

echo "appended to .scratch/verticals/*.csv" >&2
