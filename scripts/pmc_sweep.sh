#!/usr/bin/env bash
# scripts/pmc_sweep.sh — PMC collection across all cells of a layout x N.
#
# Runs scripts/pmc_collect.sh for every (cell, N, trial) combo, producing
# one CSV per trial in .scratch/pmc/ and a rollup .scratch/pmc/pmc_rollup.csv
# (min per (cell, N) across trials + derived percentages).
#
# Optional, macOS+Xcode only (the separate cycle-attribution layer; the
# unified sweep is scripts/collect.sh). Iter counts are scaled by N so each
# trial runs ~1-3s of step() work (enough for stable counters, not so long
# the sweep takes hours).
#
# Usage: scripts/pmc_sweep.sh [layout] [trials]
#   layout defaults to L1 (reads experiments/sweeps/<layout>.cells)
#   trials defaults to 3

set -euo pipefail

LAYOUT="${1:-L1}"
TRIALS="${2:-3}"
CELLS_FILE="experiments/sweeps/${LAYOUT}.cells"

if [ ! -f "$CELLS_FILE" ]; then
    echo "error: $CELLS_FILE not found (create it or pass a layout with one)." >&2
    exit 1
fi
CELLS="$(grep -vE '^[[:space:]]*(#|$)' "$CELLS_FILE" | tr '\n' ' ')"
[ -z "$CELLS" ] && { echo "error: no cells in $CELLS_FILE." >&2; exit 1; }

# N -> iters pairs. Smaller N gets more iters (each step is cheap); larger N
# gets fewer (each step is already slow).
N_ITERS_LIST="
4000:2000
16000:1000
65000:500
262000:200
1000000:100
4000000:50
16000000:20
64000000:10
"

OUTDIR="$(cd "$(dirname "$0")/.." && pwd)/.scratch/pmc"
ROLLOUT_DIR="$OUTDIR"  # default: local .scratch/
# Parse --run-dir from args
prev=""
for arg in "$@"; do
    if [ "$prev" = "--run-dir" ]; then ROLLOUT_DIR="$arg"; fi
    prev="$arg"
done
mkdir -p "$OUTDIR"
mkdir -p "$ROLLOUT_DIR"

# Count total launches for progress.
total=0
for entry in $N_ITERS_LIST; do
    for c in $CELLS; do
        total=$((total + TRIALS))
    done
done

echo "=== PMC sweep: layout=$LAYOUT trials=$TRIALS ===" >&2
echo "    cells: $CELLS" >&2
echo "    Ns: $(echo "$N_ITERS_LIST" | tr -d ' ' | tr '\n' ' ' | sed 's/:[0-9]*//g')" >&2
echo "    ~$total xctrace launches (each ~2-5s + overhead)" >&2
echo

i=0
for cell in $CELLS; do
    for entry in $N_ITERS_LIST; do
        n="${entry%%:*}"
        iters="${entry##*:}"
        for t in $(seq 1 "$TRIALS"); do
            i=$((i + 1))
            echo "[$i/$total] cell=$cell N=$n iters=$iters trial=$t" >&2
            scripts/pmc_collect.sh "$cell" "$n" "$iters" "$t" 2>&1 | grep "cycles=" | sed "s/^/      /" >&2 || {
                echo "      FAILED" >&2
            }
        done
    done
done

echo
echo "=== building rollup (min per cell/N across trials) ===" >&2
python3 - "$OUTDIR" "$ROLLOUT_DIR" << 'PYEOF'
import sys, csv, os, glob

outdir = sys.argv[1]
rollout_dir = sys.argv[2]

# Collect all trial CSVs.
rows = {}  # (cell, N) -> list of trial dicts
for path in sorted(glob.glob(os.path.join(outdir, "*_n*_t*.csv"))):
    with open(path) as f:
        reader = csv.DictReader(f)
        for r in reader:
            key = (r["cell"], int(r["N"]))
            rows.setdefault(key, []).append({
                "cycles": int(r["cycles"]),
                "useful": int(r["useful"]),
                "processing": int(r["processing_bottleneck"]),
                "delivery": int(r["delivery_bottleneck"]),
                "discarded": int(r["discarded_bottleneck"]),
                "iters": int(r["iters"]),
                "trial": int(r["trial"]),
            })

# For each (cell, N), pick the trial with min cycles (cleanest sample).
rollup_path = os.path.join(rollout_dir, "pmc_rollup.csv")
with open(rollup_path, "w") as f:
    w = csv.writer(f)
    w.writerow(["cell", "N", "iters", "trial",
                "cycles", "useful", "processing_bottleneck",
                "delivery_bottleneck", "discarded_bottleneck",
                "pct_useful", "pct_processing", "pct_delivery", "pct_discarded"])
    for key in sorted(rows.keys()):
        trials = rows[key]
        best = min(trials, key=lambda t: t["cycles"])
        c = best["cycles"]
        def pct(x): return f"{100.0*x/c:.1f}" if c else "0.0"
        w.writerow([key[0], key[1], best["iters"], best["trial"],
                    c, best["useful"], best["processing"],
                    best["delivery"], best["discarded"],
                    pct(best["useful"]), pct(best["processing"]),
                    pct(best["delivery"]), pct(best["discarded"])])

# Print a readable table.
print(f"\n  {'cell':>28} {'N':>10} {'cycles':>10} {'%useful':>8} {'%proc':>7} {'%deliv':>7} {'%disc':>7}")
print(f"  {'-'*28} {'-'*10} {'-'*10} {'-'*8} {'-'*7} {'-'*7} {'-'*7}")
with open(rollup_path) as f:
    reader = csv.DictReader(f)
    for r in sorted(reader, key=lambda x: (x["cell"], int(x["N"]))):
        print(f"  {r['cell']:>28} {r['N']:>10} {r['cycles']:>10} "
              f"{r['pct_useful']:>7}% {r['pct_processing']:>6}% "
              f"{r['pct_delivery']:>6}% {r['pct_discarded']:>6}%")
print(f"\n  wrote {rollup_path}", file=sys.stderr)
PYEOF
