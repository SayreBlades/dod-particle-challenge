#!/usr/bin/env bash
# scripts/collect.sh — unified data-collection sweep for one layout.
#
# Runs every cell (or a subset) in a layout across the N-sweep in step + frame
# + render modes, capturing per-trial CSV rows into a run directory under
# experiments/data/<layout>/<run-id>/, with a hardware.json sidecar and a
# meta.json (git sha, zig version, sweep config). Hardware is a dimension:
# machine_id is stamped on every CSV row; the full facts live in hardware.json.
#
# Run this on each machine you want to compare. The analysis notebook globs
# every experiments/data/*/*/runs.csv and groups by machine_id.
#
# Usage:
#   scripts/collect.sh L1                                  # all L1 cells, default sweep
#   scripts/collect.sh L1 "B1.w1-naive.w2-naive"           # one cell
#   scripts/collect.sh L1 "" "step frame"                  # modes (default: step frame render)
#   NS="4000,65000,1000000" TRIALS=5 scripts/collect.sh L1 # override N-sweep / trials
#   DEATH_RATES="0 0.5" scripts/collect.sh L1             # competing-risks sweep
#   THREADS=8 scripts/collect.sh L1 "B1.w1-halide.w2-naive"  # parallel cells
#
# Output: experiments/data/<layout>/<timestamp>-<machine_id>-<short-sha>/
#           runs.csv       — one row per (cell, mode, death, N, trial)
#           hardware.json  — machine facts sidecar (the machine_id dimension)
#           meta.json      — run provenance (git sha, zig ver, sweep config)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LAYOUT="${1:?usage: collect.sh <layout> [cells] [modes]}"
CELLS_ARG="${2:-}"
MODES="${3:-frame}"
# Death rates: default to the probe set; --full-rates swaps to the champion set.
RATES_FILE="experiments/sweeps/death_rates.txt"
# Parse --full-rates from args (before the positional layout arg)
for arg in "$@"; do
    if [ "$arg" = "--full-rates" ]; then RATES_FILE="experiments/sweeps/death_rates_full.txt"; fi
done
if [ -n "${DEATH_RATES:-}" ]; then
    : # explicit override wins
elif [ -f "$RATES_FILE" ]; then
    DEATH_RATES="$(grep -vE '^[[:space:]]*(#|$)' "$RATES_FILE" | tr '\n' ' ')"
else
    DEATH_RATES="0.01 0.05 0.25"
fi
NS="${NS:-}"           # comma-list passed to bench --ns (empty = default SWEEP)
TRIALS="${TRIALS:-3}"
THREADS="${THREADS:-1}"
# Halide cells need the python env; default to the project venv if it exists.
if [ -z "${HALIDE_PYTHON:-}" ] && [ -x ".venv/bin/python" ]; then
    export HALIDE_PYTHON=".venv/bin/python"
fi

# Default cell list for the layout (one per line; # comments allowed).
CELLS_FILE="experiments/sweeps/${LAYOUT}.cells"
if [ -n "$CELLS_ARG" ]; then
    CELLS="$CELLS_ARG"
elif [ -f "$CELLS_FILE" ]; then
    CELLS="$(grep -vE '^[[:space:]]*(#|$)' "$CELLS_FILE" | tr '\n' ' ')"
else
    echo "error: no cell list. Pass a cells arg or create $CELLS_FILE." >&2
    exit 1
fi
[ -z "$CELLS" ] && { echo "error: no cells to run for $LAYOUT." >&2; exit 1; }

# --- provenance + run directory ---
SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo nogit)"
ZIG_VERSION="$(zig version 2>/dev/null || echo unknown)"
TS_UTC="$(date -u +%Y%m%dT%H%M%SZ)"
HARDWARE_JSON="$(python3 scripts/hardware_json.py)"
MACHINE_ID="$(printf '%s' "$HARDWARE_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["machine_id"])')"
RUN_ID="${TS_UTC}-${MACHINE_ID}-${SHORT_SHA}"
RUN_DIR="experiments/data/${LAYOUT}/${RUN_ID}"
mkdir -p "$RUN_DIR"

printf '%s\n' "$HARDWARE_JSON" > "$RUN_DIR/hardware.json"
python3 - "$RUN_DIR/meta.json" "$RUN_ID" "$MACHINE_ID" "$LAYOUT" "$SHORT_SHA" \
    "$GIT_BRANCH" "$ZIG_VERSION" "$TS_UTC" "$MODES" "$DEATH_RATES" "$TRIALS" \
    "$NS" "$CELLS" << 'PYEOF'
import sys, json
out, run_id, mid, layout, sha, branch, zig, ts, modes, dr, tr, ns, cells = sys.argv[1:]
json.dump({
    "run_id": run_id, "machine_id": mid, "layout": layout,
    "git_sha": sha, "git_branch": branch, "zig_version": zig, "timestamp_utc": ts,
    "sweep": {"modes": modes.split(), "death_rates": dr.split(),
              "trials": int(tr), "ns_override": ns or None,
              "threads": 1, "cells": cells.split()},
}, open(out, "w"), indent=2)
print("  wrote", out)
PYEOF

# runs.csv header. collect.sh prefixes run_id,machine_id onto every bench row.
HDR="run_id,machine_id,cell,mode,death_q,threads,N,bytes_per_particle,trial,ns_frame,ns_particle,,,"
printf '%s\n' "$HDR" > "$RUN_DIR/runs.csv"
printf 'run_id,machine_id,cell,death_q,checked\n' > "$RUN_DIR/checks.csv"

NS_ARG=""
[ -n "$NS" ] && NS_ARG="--ns $NS"

echo "=== collect: layout=$LAYOUT  run=$RUN_ID ===" >&2
echo "  cells:   $CELLS" >&2
echo "  modes:   $MODES" >&2
echo "  death:   $DEATH_RATES" >&2
echo "  ns:      ${NS:-<default SWEEP>}  trials=$TRIALS  threads=$THREADS" >&2
echo "  -> $RUN_DIR" >&2

for cell in $CELLS; do
    # cell is "L<layout>.<strat>"; split on the first dot.
    layout="${cell%%.*}"
    strat="${cell#*.}"
    for q in $DEATH_RATES; do
        echo "  build $cell (q=$q)..." >&2
        if ! zig build -Dlayout="$layout" -Dstrat="$strat" -Ddeath="$q" \
                -Dmode=bench -Doptimize=ReleaseFast >&2 2>&1; then
            echo "    BUILD FAILED — skipping $cell (q=$q)." >&2
            echo "    (halide cells need: uv sync --extra halide)" >&2
            continue
        fi
        for mode in $MODES; do
            case "$mode" in
                frame)  flag="" ;;
                *) echo "    unknown mode '$mode' (only 'frame' is supported) — skipping" >&2; continue ;;
            esac
            echo "    $cell  $mode (q=$q)..." >&2
            # bench prints csv rows to stderr; merge, filter, prefix, append.
            ./zig-out/bin/dod-particles $flag $NS_ARG --trials "$TRIALS" \
                --csv --threads "$THREADS" 2>&1 \
                | grep '^csv,' \
                | sed "s/^csv,/${RUN_ID},${MACHINE_ID},/" \
                >> "$RUN_DIR/runs.csv" || true
        done
        # Invariant suite (--check): separate run, no timed-region overhead.
        echo "    $cell  --check (q=$q)..." >&2
        check_result=$(./zig-out/bin/dod-particles --check 2>&1 | grep '^checked=' || echo 'checked=ERROR')
        printf '%s,%s,%s,%s,%s\n' "$RUN_ID" "$MACHINE_ID" "$cell" "$q" "$check_result" >> "$RUN_DIR/checks.csv"
    done
done

ROWS=$(( $(wc -l < "$RUN_DIR/runs.csv") - 1 ))
echo "=== done: $ROWS data rows -> $RUN_DIR/runs.csv ===" >&2
echo "  analyze: .venv/bin/jupyter nbconvert --execute --to notebook experiments/results/analyze.ipynb" >&2
