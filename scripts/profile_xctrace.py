#!/usr/bin/env python3
"""profile_xctrace.py — macOS xctrace backend for the profile atomic.

Runs the bench binary under xctrace's "CPU Counters" template (CPU Bottlenecks
guided mode) over one (algo, N, q, threads, trial) point and returns the four
cycle buckets normalized to the platform-neutral schema:

    xctrace          common bucket
    ---------------  ----------------
    useful           compute          (retire-ready cycles)
    processing       backend_stall    (data hazards / cache misses)
    delivery         frontend_stall   (instruction-fetch starvation)
    discarded        branch_flush     (pipeline flushes / mispredicts)

The buckets sum to `cycles`. macOS + Xcode only. The bulky `.trace` + `.xml` are
deleted after extraction (10s–100s of MB each); only the numbers survive.
"""
from __future__ import annotations
import glob, os, shutil, subprocess, tempfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
XCTRACE_CANDIDATES = ["/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace"]


def find_xctrace():
    for c in XCTRACE_CANDIDATES:
        if os.path.exists(c):
            return c
    return shutil.which("xctrace")


def parse_counters(trace_xml):
    """Sum the 4 CPU-bottleneck counters across the precise (1ms) rows.
    Returns (useful, processing, delivery, discarded)."""
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


def measure(algo, n, q, threads, iters, trial, bin_path):
    """Run xctrace over one point; return {cycles, compute, backend_stall,
    frontend_stall, branch_flush}. Raises on failure."""
    xctrace = find_xctrace()
    if not xctrace:
        raise RuntimeError("xctrace not found (macOS + Xcode required)")
    outdir = os.path.join(ROOT, ".scratch", "profile")
    os.makedirs(outdir, exist_ok=True)
    tag = algo.replace(".", "_")
    trace = os.path.join(outdir, f"{tag}_n{n}_q{q}_T{threads}_t{trial}.trace")

    # xctrace ignores --output when launching (known quirk): launch from a temp
    # dir (it writes Launch_*.trace to CWD) and move the result.
    with tempfile.TemporaryDirectory(prefix="profile_") as tmp:
        subprocess.run(
            [xctrace, "record", "--template", "CPU Counters", "--launch", "--",
             bin_path, "--n", str(n), "--q", str(q), "--threads", str(threads),
             "--iters", str(iters), "--trial", str(trial)],
            cwd=tmp, capture_output=True, timeout=120,
        )
        found = glob.glob(os.path.join(tmp, "Launch_*.trace"))
        if not found:
            raise RuntimeError("xctrace produced no trace")
        shutil.move(found[0], trace)

    trace_xml = trace + ".xml"
    try:
        with open(trace_xml, "wb") as f:
            subprocess.run([xctrace, "export", "--input", trace,
                            "--xpath", "//trace-toc/run[@number=1]/data/"
                                       'table[@schema="CounterMetricAggregatedForProcess"]'],
                           cwd=ROOT, stdout=f, stderr=subprocess.PIPE)
        useful, processing, delivery, discarded = parse_counters(trace_xml)
    finally:
        # delete the bulky artifacts; keep only the numbers
        for p in (trace, trace_xml):
            try:
                os.remove(p)
            except OSError:
                pass

    cycles = useful + processing + delivery + discarded
    if cycles == 0:
        raise RuntimeError("xctrace reported zero cycles")
    return {
        "cycles": cycles,
        "compute": useful,
        "backend_stall": processing,
        "frontend_stall": delivery,
        "branch_flush": discarded,
    }
