#!/usr/bin/env python3
"""PMC (performance monitor counter) collection wrapper.

Runs the bench under xctrace's "CPU Counters" template (CPU Bottlenecks
guided mode) and exports per-process cycle-saturation data to CSV. This is
the cycle-side context instrument that complements the bench's bandwidth-side
view: together they tell you whether an algorithm is bandwidth-bound (near the
streaming ceiling) or compute/overhead-bound (well below it, and *why* —
frontend stalls, backend stalls, or branch mispredictions).

Optional, macOS + Xcode only. The unified sweep (scripts/collect.py) does
timing + hardware everywhere; this is the separate opt-in for the
cycle-attribution view on one machine.

Usage:
    scripts/pmc_collect.py <algo> <N> <iters> <trial>
    scripts/pmc_collect.py ML1.AF1.LP1-autovec.LP2-simple 1000000 500 1

Output: .scratch/pmc/<algo>_n<N>_t<trial>.csv
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

XCTRACE_CANDIDATES = [
    "/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace",
]


def find_xctrace() -> str | None:
    for c in XCTRACE_CANDIDATES:
        if os.path.exists(c):
            return c
    return shutil.which("xctrace")


def split_algo(algo: str) -> tuple[str, str]:
    if "." not in algo:
        sys.exit(f"error: '{algo}' is not an algorithm name (expected ML<mem_layout>.<algo>)")
    mem_layout, algo_part = algo.split(".", 1)
    return mem_layout, algo_part


def build(algo: str) -> str:
    """Build the bench binary for `algo` into out/ and return its path."""
    mem_layout, algo_part = split_algo(algo)
    bin_path = os.path.join(ROOT, "out", "bin", f"{algo}.bench")
    if not os.path.exists(bin_path):
        print(f"building {algo}...", file=sys.stderr)
        subprocess.run(
            ["zig", "build", "-p", "out", f"-Dmem_layout={mem_layout}",
             f"-Dalgo={algo_part}", "-Dmode=bench", "-Doptimize=ReleaseFast"],
            cwd=ROOT, capture_output=True, timeout=180,
        )
    if not os.path.exists(bin_path):
        sys.exit(f"error: {bin_path} not found after build.")
    return bin_path


def parse_counters(trace_xml: str) -> tuple[int, int, int, int]:
    """Sum the 4 CPU-bottleneck counters across precise (1ms) rows."""
    tree = ET.parse(trace_xml)
    root = tree.getroot()
    bool_by_id = {}
    for el in root.iter("boolean"):
        if "id" in el.attrib and el.text is not None:
            bool_by_id[el.attrib["id"]] = el.text.strip()
    totals = [0, 0, 0, 0]  # useful, processing, delivery, discarded
    for row in root.iter("row"):
        precise = row.find("boolean")
        if precise is None:
            continue
        if precise.text is not None:
            val = precise.text.strip()
        elif "ref" in precise.attrib:
            val = bool_by_id.get(precise.attrib["ref"], "")
        else:
            continue
        if val != "1":
            continue
        arr = row.find("uint64-array")
        if arr is None or arr.text is None:
            continue
        vals = arr.text.split()
        if len(vals) != 4:
            continue
        for i, v in enumerate(vals):
            totals[i] += int(v, 0)
    return totals[0], totals[1], totals[2], totals[3]


def main() -> int:
    if len(sys.argv) != 5:
        sys.exit("usage: pmc_collect.py <algo> <N> <iters> <trial>")
    algo, n, iters, trial = sys.argv[1:5]

    xctrace = find_xctrace()
    if not xctrace:
        sys.exit("error: xctrace not found. Install Xcode or set XCTRACE path.\n"
                 "  fallback: powermetrics --show-process-ipc (sudo, IPC only)")

    bin_path = build(algo)
    tag = algo.replace(".", "_")
    outdir = os.path.join(ROOT, ".scratch", "pmc")
    os.makedirs(outdir, exist_ok=True)
    trace = os.path.join(outdir, f"{tag}_n{n}_t{trial}.trace")
    csv_path = os.path.join(outdir, f"{tag}_n{n}_t{trial}.csv")

    # xctrace ignores --output when launching a process (known quirk); it writes
    # to Launch_<name>_<timestamp>.trace in CWD. Launch from a temp dir and move.
    print(f"recording: xctrace CPU Counters over algo={algo} N={n} "
          f"iters={iters} trial={trial}", file=sys.stderr)
    with tempfile.TemporaryDirectory(prefix="pmc_") as tmp:
        subprocess.run(
            [xctrace, "record", "--template", "CPU Counters", "--launch", "--",
             bin_path, "--n", n, "--iters", iters, "--time-limit", "60s"],
            cwd=tmp, capture_output=True, timeout=90,
        )
        import glob
        found = glob.glob(os.path.join(tmp, "Launch_*.trace"))
        if not found:
            sys.exit("error: xctrace did not produce a trace file")
        shutil.move(found[0], trace)

    trace_xml = trace + ".xml"
    with open(trace_xml, "wb") as f:
        subprocess.run([xctrace, "export", "--input", trace,
                        "--xpath", '//trace-toc/run[@number=1]/data/'
                                   'table[@schema="CounterMetricAggregatedForProcess"]'],
                       cwd=ROOT, stdout=f, stderr=subprocess.PIPE)

    useful, processing, delivery, discarded = parse_counters(trace_xml)
    cycles = useful + processing + delivery + discarded
    with open(csv_path, "w") as f:
        f.write("algo,N,iters,trial,cycles,useful,processing_bottleneck,"
                "delivery_bottleneck,discarded_bottleneck\n")
        f.write(f"{algo},{n},{iters},{trial},{cycles},{useful},"
                f"{processing},{delivery},{discarded}\n")
    pct = lambda x: 100.0 * x / cycles if cycles else 0
    print(f"  cycles={cycles} useful={useful} ({pct(useful):.1f}%) "
          f"processing={processing} ({pct(processing):.1f}%) "
          f"delivery={delivery} ({pct(delivery):.1f}%) "
          f"discarded={discarded} ({pct(discarded):.1f}%)", file=sys.stderr)
    print(f"wrote {csv_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
