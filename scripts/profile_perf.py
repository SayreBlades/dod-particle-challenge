#!/usr/bin/env python3
"""profile_perf.py — Linux `perf` backend for the profile atomic.

Runs the bench binary under `perf stat` over one (algo, N, q, threads, trial)
point and returns the four cycle buckets normalized to the common schema:

    perf (AMD Zen 2)                            common bucket
    ------------------------------------------  ----------------
    cycles − (stalls + flush)                   compute          (retire-ready)
    de_dis_dispatch_token_stalls* (memory)      backend_stall    (data hazards / cache misses)
    ic_fetch_stall.ic_stall_any                 frontend_stall   (instruction-fetch starvation)
    ex_ret_brn_resync × penalty                 branch_flush     (pipeline flushes / mispredicts)

The buckets sum to `cycles` (compute is the remainder, with a rescale safety net
for the rare case the stall proxies over-count).

EVENT SET: AMD Zen 2 (Family 17h, Model 71h — e.g. Ryzen 9 3900X). Six events,
which fits the 6 general-purpose PMCs per core → no multiplexing → every counter
is 100%-counted → cycle-accurate attribution. On other µarches these named
events may be unsupported; `measure()` raises and collect.py logs PROFILE FAIL
(graceful — the row is simply not written).

CAVEAT: on Zen 2, `ic_fetch_stall.ic_stall_any` counts cycles the front end did
not supply ops, INCLUDING cycles where the back end was not consuming — so the
frontend bucket may be over-attributed for back-end-bound code. Tune EVENTS (and
add Intel/other-AMD maps) for tighter attribution; the schema is unchanged.
Penalty constants are documented approximations from the AMD 17h PPR.
"""
from __future__ import annotations
import os, shutil, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# AMD Zen 2 (17h/71h). 6 events → 6 GP PMCs → no multiplexing.
EVENTS = [
    "cycles",
    "ic_fetch_stall.ic_stall_any",                                   # frontend (IC-pipe stall)
    "ex_ret_brn_resync",                                             # branch flush (resync COUNT)
    "de_dis_dispatch_token_stalls1.load_queue_token_stall",          # backend: memory (loads)
    "de_dis_dispatch_token_stalls1.store_queue_token_stall",         # backend: memory (stores)
    "de_dis_dispatch_token_stalls1.fp_sch_rsrc_stall",               # backend: FP scheduler
]
# AMD 17h PPR, approx: a branch resync flushes this many frontend cycles.
RESYNC_PENALTY_CYCLES = 16


def find_perf():
    return shutil.which("perf")


def _parse_perf_csv(stderr_text):
    """Parse `perf stat -x,` stderr into {event: count}. perf appends ':u'."""
    counts = {}
    for line in stderr_text.splitlines():
        f = line.split(",")
        if len(f) < 3:
            continue
        val, ev = f[0].strip(), f[2].strip()
        if not ev or ev.startswith("<"):  # <not counted> / <not supported>
            continue
        try:
            counts[ev] = int(val)
        except ValueError:
            continue  # bench binary's own stderr lines don't match
    return counts


def measure(algo, n, q, threads, iters, trial, bin_path):
    """Run perf stat over one point; return {cycles, compute, backend_stall,
    frontend_stall, branch_flush}. Raises on failure."""
    perf = find_perf()
    if not perf:
        raise RuntimeError("perf not found (apt install linux-tools-generic)")

    r = subprocess.run(
        [perf, "stat", "-x,", "-e", ",".join(EVENTS), "--",
         bin_path, "--n", str(n), "--q", str(q), "--threads", str(threads),
         "--iters", str(iters), "--trial", str(trial)],
        cwd=ROOT, capture_output=True, text=True, timeout=120,
    )
    # perf stat writes counts to stderr; rc is nonzero only on tool error.
    counts = _parse_perf_csv(r.stderr)

    def get(name):
        return counts.get(name) or counts.get(name + ":u") or 0

    cycles = get("cycles")
    if cycles == 0:
        raise RuntimeError(f"perf reported zero cycles (rc={r.returncode}): "
                           f"{r.stderr.strip()[:300]}")

    frontend_stall = get("ic_fetch_stall.ic_stall_any")
    resyncs = get("ex_ret_brn_resync")
    backend_stall = (get("de_dis_dispatch_token_stalls1.load_queue_token_stall")
                     + get("de_dis_dispatch_token_stalls1.store_queue_token_stall")
                     + get("de_dis_dispatch_token_stalls1.fp_sch_rsrc_stall"))
    branch_flush = resyncs * RESYNC_PENALTY_CYCLES

    # Partition: compute is the remainder. If the stall proxies over-count
    # (compute would go negative), clamp then rescale so the 4 buckets still
    # sum to exactly `cycles`.
    compute = cycles - (frontend_stall + backend_stall + branch_flush)
    if compute < 0:
        compute = 0
        total = frontend_stall + backend_stall + branch_flush
        if total > 0:
            f = cycles / total
            frontend_stall = int(frontend_stall * f)
            backend_stall = int(backend_stall * f)
            branch_flush = cycles - compute - frontend_stall - backend_stall
    return {
        "cycles": cycles,
        "compute": compute,
        "backend_stall": backend_stall,
        "frontend_stall": frontend_stall,
        "branch_flush": branch_flush,
    }
