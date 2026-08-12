#!/usr/bin/env python3
"""profile.py — the cycle-attribution atomic (platform-neutral dispatcher).

Attributes cycles for ONE (algo, N, q, threads, trial) point via the host's
profiler backend (xctrace on macOS now; perf on Linux later), normalizing to the
common 4-bucket schema, and appends one row to
experiments/data/<machine_id>/<algo>.profile.jsonl.

Buckets (sum = cycles, pct sum ~100):
    compute         retire-ready cycles              -> radar Compute axis
    backend_stall   data hazards / cache misses      -> radar Latency axis
    frontend_stall  instruction-fetch starvation     -> (dropped from radar)
    branch_flush    pipeline flushes / mispredicts   -> radar Control axis

Graceful absence: where no profiler backend is available, the row is not written
(the radar degrades to a hint). collect.py loops the grid and calls
profile_point().

Usage:
    scripts/profile.py ML01.AF05.LP1-autovec.LP2-simple --n 1000000 --q 0.1 --threads 1 --trial 1
"""
from __future__ import annotations
import argparse, datetime, json, os, platform, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import bench        # build_binary, source_hash, machine_id_arg, host_of
import sweep_config

DATA = os.path.join(ROOT, "experiments", "data")

# backend module name by backend id. A future `perf` backend registers here.
BACKENDS = {"xctrace": "profile_xctrace"}


def available_backends():
    """Profiler backends usable on this host (id list). Empty where none exist."""
    out = []
    if platform.system() == "Darwin":
        try:
            import profile_xctrace
            if profile_xctrace.find_xctrace():
                out.append("xctrace")
        except ImportError:
            pass
    return out


def profile_path(algo, machine_id):
    return os.path.join(DATA, machine_id, f"{algo}.profile.jsonl")


def have_point(profile_jsonl, algo, n, q, threads, shash):
    """Is this (algo, N, q, threads) point already present at the current
    source_hash? (trial is ignored — any trial satisfies the point.)"""
    if not os.path.exists(profile_jsonl):
        return False
    for line in open(profile_jsonl):
        try:
            r = json.loads(line)
        except Exception:
            continue
        if (r.get("algo") == algo and int(r.get("N", -1)) == n
                and abs(float(r.get("death_q", -1)) - q) < 1e-12
                and int(r.get("threads", -1)) == threads
                and r.get("source_hash") == shash):
            return True
    return False


def profile_point(algo, n, q, threads, trial=1, iters=None, machine_id=None,
                  run_id=None, ts_utc=None, profiler=None, skip_done=False, verbose=True):
    """Profile one point; append a normalized row to <algo>.profile.jsonl.
    Returns the row dict, or None if no backend is available / skipped."""
    log = (lambda m: print(m, file=sys.stderr)) if verbose else (lambda m: None)
    backends = available_backends()
    chosen = profiler or (backends[0] if backends else None)
    if not chosen:
        log(f"  no profiler backend available — skip {algo} N={n} q={q}")
        return None

    machine_id = bench.machine_id_arg(machine_id)
    host = bench.host_of(machine_id)
    shash = bench.source_hash(algo)
    path = profile_path(algo, machine_id)
    if skip_done and have_point(path, algo, n, q, threads, shash):
        log(f"  skip {algo} N={n} q={q} T={threads} (current source_hash present)")
        return None

    bp = bench.build_binary(algo)
    iters = iters or sweep_config.iters_for(n)
    mod = __import__(BACKENDS[chosen])
    raw = mod.measure(algo, n, q, threads, iters, trial, bp)

    cycles = raw["cycles"]
    pct = lambda x: round(100.0 * x / cycles, 1) if cycles else 0.0
    now = datetime.datetime.now(datetime.timezone.utc)
    ts_utc = ts_utc or now.strftime("%Y%m%dT%H%M%SZ")
    run_id = run_id or f"{ts_utc}-{machine_id}-{shash[:7]}"
    row = {
        "run_id": run_id, "ts_utc": ts_utc, "host": host, "machine_id": machine_id,
        "algo": algo, "source_hash": shash,
        "N": n, "death_q": float(q), "threads": threads, "trial": trial, "iters": iters,
        "profiler": chosen, "cycles": cycles,
        "compute": raw["compute"], "backend_stall": raw["backend_stall"],
        "frontend_stall": raw["frontend_stall"], "branch_flush": raw["branch_flush"],
        "compute_pct": pct(raw["compute"]),
        "backend_stall_pct": pct(raw["backend_stall"]),
        "frontend_stall_pct": pct(raw["frontend_stall"]),
        "branch_flush_pct": pct(raw["branch_flush"]),
    }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(row) + "\n")
    log(f"  profile {algo} N={n} q={q} T={threads} [{chosen}]  "
        f"compute={row['compute_pct']}%  backend={row['backend_stall_pct']}%  "
        f"branch={row['branch_flush_pct']}%")
    return row


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("algo")
    ap.add_argument("--n", type=int, required=True)
    ap.add_argument("--q", type=float, required=True)
    ap.add_argument("--threads", type=int, required=True)
    ap.add_argument("--trial", type=int, default=1)
    ap.add_argument("--iters", type=int, default=None)
    ap.add_argument("--machine-id", default=None)
    ap.add_argument("--profiler", default=None, choices=list(BACKENDS))
    ap.add_argument("--skip-done", action="store_true")
    a = ap.parse_args()
    row = profile_point(a.algo, a.n, a.q, a.threads, trial=a.trial, iters=a.iters,
                        machine_id=a.machine_id, profiler=a.profiler, skip_done=a.skip_done)
    if row is None:
        sys.exit(1)


if __name__ == "__main__":
    main()
