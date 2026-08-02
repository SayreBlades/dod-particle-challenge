#!/usr/bin/env bash
# scripts/collect.sh — unified data-collection sweep for one layout.
#
# Runs every cell (or a subset) in a layout across the N-sweep, emitting one
# JSONL row per (cell, death_q, threads, N, trial) into the host's
# runs.jsonl, plus a checks.jsonl row per (cell, death_q) from the invariant
# suite. Parallel cells are swept across the THREADS set; serial cells run
# T=1 only (no duplicate rows). Data is host-partitioned + append-only (§6.5):
#
#   experiments/data/<machine_id>/{runs.jsonl, checks.jsonl, hardware.json}
#
# Every run row is fully self-describing: the bench binary (--json) carries
# build-time provenance (git_sha, source_hash, machine_id, host, run_id,
# ts_utc) + the cell_decl axes + measurements, so collect.sh just greps
# `^json,` and appends. Hardware is a host-level dimension written once
# (hardware.json); the report joins on machine_id.
#
# Append-only by design: re-runs duplicate rows; dedup/filtering is a
# loader/report concern (the jsonl is a historical audit of every run).
#
# Usage:
#   scripts/collect.sh L1                                  # all L1 cells, single rate set
#   scripts/collect.sh L1 "B1.w1-autovec.w2-simple"        # one cell
#   NS="4000,65000,1000000" TRIALS=5 scripts/collect.sh L1
#   DEATH_RATES="0 0.5" scripts/collect.sh L1
#   THREADS="1 4 10" scripts/collect.sh L1                 # parallel cells sweep T (default)
#   THREADS=8 scripts/collect.sh L1 "B1.w1-halide.w2-simple"  # single T override

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Death rates: the single rate set (§17.5 — one-pass workflow; the champion
# pass was retired). DEATH_RATES overrides the file.
RATES_FILE="experiments/sweeps/death_rates.txt"
LAYOUT="${1:?usage: collect.sh <layout> [cells]}"
CELLS_ARG="${2:-}"
if [ -n "${DEATH_RATES:-}" ]; then
    :
elif [ -f "$RATES_FILE" ]; then
    DEATH_RATES="$(grep -vE '^[[:space:]]*(#|$)' "$RATES_FILE" | tr '\n' ' ')"
else
    DEATH_RATES="0.01 0.05 0.25"
fi
NS="${NS:-}"
TRIALS="${TRIALS:-3}"
# THREADS is a space-separated list, swept for parallel cells only; serial
# cells always run T=1 (a serial cell ignores --threads, so looping it would
# just emit duplicate rows). Default: the regime thread set {1, 4, 10}.
THREADS="${THREADS:-1 4 10}"
REFRESH_HW="${REFRESH_HW:-0}"
if [ -z "${HALIDE_PYTHON:-}" ] && [ -x ".venv/bin/python" ]; then
    export HALIDE_PYTHON=".venv/bin/python"
fi

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

# --- provenance + host data directory (§6.5) ---
SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo nogit)"
HOST="$(python3 -c 'import platform,sys;print(platform.node().split(".")[0])')"
# hardware.json: one per host. Write it if missing or if REFRESH_HW=1.
HARDWARE_JSON_OUT="$(python3 scripts/hardware_json.py)"
MACHINE_ID="$(printf '%s' "$HARDWARE_JSON_OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["machine_id"])')"
HOST_DIR="experiments/data/${MACHINE_ID}"
mkdir -p "$HOST_DIR"
HW_PATH="$HOST_DIR/hardware.json"
if [ ! -f "$HW_PATH" ] || [ "$REFRESH_HW" = "1" ]; then
    printf '%s\n' "$HARDWARE_JSON_OUT" > "$HW_PATH"
    echo "  wrote $HW_PATH" >&2
fi
TS_UTC="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="${TS_UTC}-${MACHINE_ID}-${SHORT_SHA}"

NS_ARG=""
[ -n "$NS" ] && NS_ARG="--ns $NS"

echo "=== collect: layout=$LAYOUT  run=$RUN_ID ===" >&2
echo "  host_dir: $HOST_DIR" >&2
echo "  cells:   $CELLS" >&2
echo "  death:   $DEATH_RATES" >&2
echo "  ns:      ${NS:-<default SWEEP>}  trials=$TRIALS  threads=$THREADS (parallel only)" >&2
echo "  -> runs.jsonl (append)" >&2

RUNS_JSONL="$HOST_DIR/runs.jsonl"
CHECKS_JSONL="$HOST_DIR/checks.jsonl"
# Ensure the append targets exist (so wc -l works even if every cell fails).
touch "$RUNS_JSONL" "$CHECKS_JSONL"

for cell in $CELLS; do
    layout="${cell%%.*}"
    strat="${cell#*.}"
    # Parallel cells (strat name carries -par / rmerge) sweep the THREADS set;
    # serial cells run T=1 only (no duplicate rows).
    case "$strat" in
        *-par*|*rmerge*) cell_threads="$THREADS" ;;
        *) cell_threads="1" ;;
    esac
    check_t="${cell_threads##* }"   # max T — exercise the parallel path under --check
    # source_hash: the cell's @import closure (refactor §5). One per cell.
    SOURCE_HASH="$(python3 scripts/cell_hash.py "$cell" 2>/dev/null || echo '')"
    for q in $DEATH_RATES; do
        echo "  build $cell (q=$q)..." >&2
        if ! zig build -p out -Dlayout="$layout" -Dstrat="$strat" -Ddeath="$q" \
                -Dmode=bench -Doptimize=ReleaseFast \
                -Dsource_hash="$SOURCE_HASH" -Dmachine_id="$MACHINE_ID" \
                -Dhost="$HOST" -Drun_id="$RUN_ID" -Dts_utc="$TS_UTC" \
                >&2 2>&1; then
            echo "    BUILD FAILED — skipping $cell (q=$q)." >&2
            echo "    (halide cells need: uv sync --extra halide)" >&2
            continue
        fi
        for t in $cell_threads; do
            echo "    $cell  bench (q=$q, T=$t)..." >&2
            # bench --json emits one `json,{...}` row per trial to stderr; grep + strip + append.
            ./out/bin/dod-particles $NS_ARG --trials "$TRIALS" \
                --json --threads "$t" 2>&1 \
                | grep '^json,' \
                | sed 's/^json,//' \
                >> "$RUNS_JSONL" || true
        done
        # Invariant suite (--check): separate run, no timed-region overhead.
        echo "    $cell  --check (q=$q, T=$check_t)..." >&2
        check_result=$(./out/bin/dod-particles --check --threads "$check_t" 2>&1 | grep '^checked=' || echo 'checked=ERROR')
        python3 - "$CHECKS_JSONL" "$RUN_ID" "$TS_UTC" "$MACHINE_ID" "$LAYOUT" \
            "$cell" "$q" "$SOURCE_HASH" "$SHORT_SHA" "$check_result" << 'PYEOF'
import sys, json
out, run_id, ts, mid, layout, cell, q, sh, sha, checked = sys.argv[1:11]
row = {"run_id": run_id, "ts_utc": ts, "machine_id": mid, "layout": layout,
       "cell": cell, "death_q": float(q) if q not in ("", "n/a") else None,
       "source_hash": sh or None, "git_sha": sha,
       "checked": "PASS" if "PASS" in checked else "FAIL"}
with open(out, "a") as f:
    f.write(json.dumps(row) + "\n")
PYEOF
    done
done

RUNS=$(( $(wc -l < "$RUNS_JSONL" 2>/dev/null || echo 0) ))
CHECKS=$(( $(wc -l < "$CHECKS_JSONL" 2>/dev/null || echo 0) ))
echo "=== done: $RUNS run rows -> $RUNS_JSONL ===" >&2
echo "         $CHECKS check rows -> $CHECKS_JSONL" >&2
echo "  report: scripts/build_report.py  (then serve experiments/report/)" >&2
