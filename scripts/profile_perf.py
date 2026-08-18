#!/usr/bin/env python3
"""profile_perf.py — Linux `perf` backend for the profile atomic.

Runs the bench binary under `perf stat` over one (algo, N, q, threads, trial)
point and returns the four cycle buckets normalized to the common schema:

    perf (AMD Zen 2)                            common bucket
    ------------------------------------------  ----------------
    cycles − (stalls + flush)                   compute          (retire-ready)
    l2_latency.l2_cycles_waiting_on_fills × 4   backend_stall    (data hazards / cache misses)
    ic_fetch_stall.ic_stall_dq_empty            frontend_stall   (instruction-fetch starvation)
    ex_ret_brn_misp × ~17                        branch_flush     (pipeline flushes / mispredicts)

The buckets sum to `cycles` (compute is the remainder, with a rescale safety net
for the rare case the stall proxies over-count).

EVENT SET: AMD Zen 2 (Family 17h, Model 71h — e.g. Ryzen 9 3900X). Four events
→ fits the 6 GP PMCs with headroom (no multiplexing even if the NMI watchdog
steals one). Validated live on madbits (kernel 6.12, perf 5.15) 2026-08-17:
the previous event set — `de_dis_dispatch_token_stalls1.*` + `ex_ret_brn_resync`
— was SUPPORTED but read ~0 on this µarch/workload (123 load-queue token
stalls and 45 resyncs per 1.4 BILLION cycles), collapsing the attribution to
Compute+Frontend only. The replacements, chosen from the same PMU vocabulary:

- `l2_latency.l2_cycles_waiting_on_fills` — core cycles waiting on L2 fills
  from L3/DRAM, counted ÷4 (scale factor applied) — the Zen 2 memory-latency
  proxy. An upper bound on true backend stall (a fill can be outstanding while
  independent work retires) — documented approximation.
- `ic_fetch_stall.ic_stall_dq_empty` — the HONEST frontend stall (dispatch
  queue empty = genuinely fetch-starved), unlike `ic_stall_any` which also
  counts back-pressure cycles when the backend isn't consuming (~64% here —
  it was absorbing the entire backend signal).
- `ex_ret_brn_misp` — retired mispredicted branches; `ex_ret_brn_resync`
  counts only the rare resync class (12.6M vs 57 events on the same run).

On other µarches these named events may be unsupported; `measure()` raises and
collect.py logs PROFILE FAIL (graceful — the row is simply not written).
`measure()` also raises if perf silently dropped or scaled any event (that
would otherwise collapse the buckets to a misleading all-`compute` row).

Requires: `perf` on PATH and permission to read PMCs —
`kernel.perf_event_paranoid <= 1` (or `CAP_PERFMON`).
Penalty constants are documented approximations from the AMD 17h PPR.
"""
from __future__ import annotations
import glob, os, shutil, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# AMD Zen 2 (17h/71h). 4 events → no multiplexing (headroom for the NMI watchdog).
EVENTS = [
    "cycles",
    "l2_latency.l2_cycles_waiting_on_fills",   # backend: L2 fill-wait cycles (÷4 — see EVENT_SCALE)
    "ic_fetch_stall.ic_stall_dq_empty",         # frontend: IC stall with dispatch queue EMPTY (honest fetch starvation)
    "ex_ret_brn_misp",                           # branch flush (mispredict COUNT; × penalty below)
]
# Counters that do not increment 1:1 per cycle (per the event description).
EVENT_SCALE = {"l2_latency.l2_cycles_waiting_on_fills": 4}
# AMD 17h PPR, approx: a branch mispredict flushes this many frontend cycles.
MISP_PENALTY_CYCLES = 17


def find_perf():
    """Locate `perf`. Prefers PATH; falls back to the version-specific
    linux-tools install path (common on Ubuntu/Pop, where `perf` isn't on PATH
    and the `linux-tools-generic` metapackage may point at a mismatched kernel).
    A slightly older perf binary works fine for `perf stat` on a newer kernel."""
    p = shutil.which("perf")
    if p:
        return p
    # Probe the running kernel's dir first, then newest available.
    import platform
    kver = platform.release().split("-", 1)[0]
    for cand in [f"/usr/lib/linux-tools-{kver}/perf", *sorted(glob.glob("/usr/lib/linux-tools-*/perf"), reverse=True)]:
        if os.path.exists(cand):
            return cand
    return None


def _parse_perf_csv(stderr_text):
    """Parse `perf stat -x,` stderr into {event: count}. Events are requested
    bare, but perf may render some with a trailing ':u' modifier, so get()
    accepts either the bare or the ':u'-suffixed name."""
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

    # Guard: every event must have been COUNTED. perf emits "<not Supported>"
    # (wrong µarch) or "<not counted>" (multiplexed — e.g. the NMI watchdog
    # stealing a GP PMC) on hosts that can't schedule the full set; the parser
    # drops those lines, so ABSENCE from `counts` = never counted → fail loudly
    # (a silent 0 would collapse the buckets to all-compute). Note a counted
    # event may legitimately read 0 (e.g. fp_sch_rsrc_stall on integer-only
    # short runs) — presence in `counts`, not truthiness, is the test.
    missing = [e for e in EVENTS if e not in counts and e + ":u" not in counts]
    if missing:
        raise RuntimeError(
            f"perf did not count every event on this host (unsupported µarch or "
            f"multiplexing — check kernel.perf_event_paranoid<=1 and "
            f"kernel.nmi_watchdog=0): missing={missing}; "
            f"stderr: {r.stderr.strip()[:300]}"
        )

    def get(name):
        return counts[name] if name in counts else counts.get(name + ":u", 0)

    cycles = get("cycles")
    if cycles == 0:
        raise RuntimeError(f"perf reported zero cycles (rc={r.returncode}): "
                           f"{r.stderr.strip()[:300]}")

    frontend_stall = get("ic_fetch_stall.ic_stall_dq_empty")
    misp = get("ex_ret_brn_misp")
    fills = get("l2_latency.l2_cycles_waiting_on_fills")
    backend_stall = fills * EVENT_SCALE["l2_latency.l2_cycles_waiting_on_fills"]
    branch_flush = misp * MISP_PENALTY_CYCLES

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


def _selftest():
    """Parser smoke test — run via `python scripts/profile_perf.py` (no deps).
    Covers: plain rows, the ':u' suffix, <not supported> drop, non-numeric
    value drop, and the <3-field drop."""
    sample = "\n".join([
        "1234567890,,cycles,100.00",                                  # plain
        "555,,ic_fetch_stall.ic_stall_any:u,100.00",                  # :u suffix kept
        "<not supported>,,ex_ret_brn_resync,0.00",                    # dropped (<not...>)
        "oops,,de_dis_dispatch_token_stalls1.load_queue_token_stall,100.00",  # dropped (non-int)
        "short line",                                                 # dropped (<3 fields)
        "42,,de_dis_dispatch_token_stalls1.store_queue_token_stall,100.00",
        "8,,de_dis_dispatch_token_stalls1.fp_sch_rsrc_stall,100.00",
        "",
    ])
    c = _parse_perf_csv(sample)
    assert c == {
        "cycles": 1234567890,
        "ic_fetch_stall.ic_stall_any:u": 555,
        "de_dis_dispatch_token_stalls1.store_queue_token_stall": 42,
        "de_dis_dispatch_token_stalls1.fp_sch_rsrc_stall": 8,
    }, c
    print("profile_perf._parse_perf_csv: ok")


if __name__ == "__main__":
    _selftest()
