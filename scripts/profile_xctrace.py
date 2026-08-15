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


def _record_export_parse(xctrace, bin_path, trace, trace_xml, n, q, threads, iters, trial):
    """One record + export + parse attempt. Returns (useful, processing, delivery,
    discarded) or raises. Cleans up the bulky trace artifacts in finally (on both
    success and failure)."""
    try:
        # xctrace ignores --output when launching (known quirk): launch from a
        # temp dir (it writes Launch_*.trace to CWD) and move the result.
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

        with open(trace_xml, "wb") as f:
            subprocess.run([xctrace, "export", "--input", trace,
                            "--xpath", "//trace-toc/run[@number=1]/data/"
                                       'table[@schema="CounterMetricAggregatedForProcess"]'],
                           cwd=ROOT, stdout=f, stderr=subprocess.PIPE)
        if os.path.getsize(trace_xml) == 0:
            raise RuntimeError("xctrace export produced empty xml (malformed trace)")
        useful, processing, delivery, discarded = parse_counters(trace_xml)
        if useful + processing + delivery + discarded == 0:
            raise RuntimeError("xctrace reported zero cycles")
        return useful, processing, delivery, discarded
    finally:
        # delete the bulky artifacts; keep only the numbers. The `.trace` is a
        # directory bundle — `os.remove` raises IsADirectoryError (an OSError),
        # which the old `except OSError: pass` silently swallowed, leaking every
        # trace (6.7GB / 579 dirs had accumulated). rmtree removes the bundle.
        shutil.rmtree(trace, ignore_errors=True)
        try:
            os.remove(trace_xml)
        except OSError:
            pass


def measure(algo, n, q, threads, iters, trial, bin_path):
    """Run xctrace over one point; return {cycles, compute, backend_stall,
    frontend_stall, branch_flush}. Raises on failure after retries."""
    xctrace = find_xctrace()
    if not xctrace:
        raise RuntimeError("xctrace not found (macOS + Xcode required)")
    outdir = os.path.join(ROOT, ".scratch", "profile")
    os.makedirs(outdir, exist_ok=True)
    tag = algo.replace(".", "_")
    trace = os.path.join(outdir, f"{tag}_n{n}_q{q}_T{threads}_t{trial}.trace")
    trace_xml = trace + ".xml"

    # xctrace intermittently emits an empty/malformed trace — under contention,
    # and occasionally even idle. Without a retry that point is silently dropped
    # (collect.py logs PROFILE FAIL, no row written, the radar lacks that cell).
    # Retry the whole record+export+parse a couple of times before giving up.
    last_err = None
    for _attempt in range(3):  # 1 initial + 2 retries
        try:
            useful, processing, delivery, discarded = _record_export_parse(
                xctrace, bin_path, trace, trace_xml, n, q, threads, iters, trial)
            return {
                "cycles": useful + processing + delivery + discarded,
                "compute": useful,
                "backend_stall": processing,
                "frontend_stall": delivery,
                "branch_flush": discarded,
            }
        except (RuntimeError, ET.ParseError) as e:
            last_err = e
    raise RuntimeError(f"xctrace failed after 3 attempts: {last_err}")
