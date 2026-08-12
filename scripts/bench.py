#!/usr/bin/env python3
"""bench.py — the timing atomic.

Times ONE (algo, q, threads) column: every (N × trial) point via the single-point
bench binary, then one --check, appending rows into
experiments/data/<machine_id>/<algo>.runs.jsonl. Owns the N→iters/warmup
schedule (moved out of the bench binary — sweep_config). collect.py loops
algos × q × threads and calls bench_column().

Each timing row is kind:"timing"; the check row is kind:"check" — one file,
kind-discriminated (no separate checks file). Rows are append-only; --skip-done
skips a point already present at the current source_hash (resume without dupes).

Usage:
    scripts/bench.py ML01.AF02.LP1-autovec.LP2-simple --q 0.1 --threads 1
    scripts/bench.py ML01.AF02.LP1-autovec-par.LP2-simple --q 0.25 --threads 4 --trials 3 --skip-done
"""
from __future__ import annotations
import argparse, datetime, json, os, platform, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import sweep_config

DATA = os.path.join(ROOT, "experiments", "data")
OUT = os.path.join(ROOT, "out")


def split_algo(algo):
    return algo.split(".", 1)


def source_hash(algo):
    return subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "algo_hash.py"), algo],
                          capture_output=True, text=True).stdout.strip()


def machine_id_arg(arg):
    if arg:
        return arg
    ids = [d for d in os.listdir(DATA) if os.path.isdir(os.path.join(DATA, d))]
    if len(ids) != 1:
        sys.exit(f"expected one machine under {DATA}, found {ids}; pass --machine-id")
    return ids[0]


def host_of(machine_id):
    hw = os.path.join(DATA, machine_id, "hardware.json")
    if os.path.exists(hw):
        try:
            return json.load(open(hw)).get("hostname") or platform.node().split(".")[0]
        except Exception:
            pass
    return platform.node().split(".")[0]


def bin_path(algo):
    return os.path.join(OUT, "bin", f"{algo}.bench")


def build_binary(algo):
    """Ensure the bench binary exists in out/bin/. Build-if-missing via -Dselect
    (pure-zig). `make collect` relies on `make build` (the prereq) for the
    authoritative parallel multi-build; this is a fallback for standalone atom
    use. Staleness caveat: after a source edit, run `make build` (its stamp gate
    rebuilds) rather than relying on this."""
    bp = bin_path(algo)
    if os.path.exists(bp):
        return bp
    env = os.environ.copy()
    if "LP1-halide" in algo:
        env.setdefault("HALIDE_PYTHON", sys.executable)
    cmd = ["zig", "build", "-p", OUT, f"-Dselect={algo}",
           "-Dmode=bench", "-Doptimize=ReleaseFast", "-Dhalide_prefix=out/halide"]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env)
    if r.returncode != 0 or not os.path.exists(bp):
        sys.exit(f"build failed for {algo}:\n" + (r.stderr or r.stdout)[-800:])
    return bp


def runs_path(algo, machine_id):
    return os.path.join(DATA, machine_id, f"{algo}.runs.jsonl")


def have_points(runs_jsonl, algo, q, threads, shash):
    """Set of (N, trial) already present at the current source_hash for this
    (algo, q, threads). Used for --skip-done resume."""
    have = set()
    if not os.path.exists(runs_jsonl):
        return have
    for line in open(runs_jsonl):
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("algo") != algo or r.get("kind") != "timing":
            continue
        if abs(float(r.get("death_q", -1)) - q) > 1e-12:
            continue
        if int(r.get("threads", -1)) != threads:
            continue
        if r.get("source_hash") != shash:
            continue
        have.add((int(r["N"]), int(r["trial"])))
    return have


def run_point(bp, n, q, threads, iters, warmup, trial, run_id, ts_utc, machine_id, host, shash):
    """Run one timing point; return the parsed json row dict (or None)."""
    cmd = [bp, "--n", str(n), "--q", str(q), "--threads", str(threads),
           "--iters", str(iters), "--warmup", str(warmup), "--trial", str(trial),
           "--json", "--run-id", run_id, "--ts-utc", ts_utc,
           "--machine-id", machine_id, "--host", host, "--source-hash", shash]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines():
        if line.startswith("json,"):
            try:
                return json.loads(line[len("json,"):])
            except Exception:
                return None
    return None


def run_check(bp, q, threads, run_id, ts_utc, shash, algo, machine_id, host):
    """Run --check once; return a kind:"check" row dict (or None on parse failure)."""
    cmd = [bp, "--check", "--q", str(q), "--threads", str(threads)]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    checked = None
    for line in (r.stdout + r.stderr).splitlines():
        if line.startswith("checked="):
            checked = line.split("=", 1)[1].strip()
    if checked is None:
        return None
    return {"run_id": run_id, "ts_utc": ts_utc, "kind": "check", "host": host,
            "machine_id": machine_id, "mem_layout": algo.split(".", 1)[0],
            "algo": algo, "source_hash": shash,
            "death_q": float(q), "threads": threads, "checked": checked}


def append_rows(path, rows):
    if not rows:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")


def bench_column(algo, q, threads, n_list=None, trials=None, machine_id=None,
                 run_id=None, ts_utc=None, skip_done=False, verbose=True):
    """Time one (algo, q, threads) column: all (N × trial) timing rows + one
    check row, appended to <algo>.runs.jsonl. Returns the rows written."""
    machine_id = machine_id_arg(machine_id)
    host = host_of(machine_id)
    shash = source_hash(algo)
    bp = build_binary(algo)
    n_list = n_list or sweep_config.N_GRID
    trials = trials if trials is not None else 3
    now = datetime.datetime.now(datetime.timezone.utc)
    ts_utc = ts_utc or now.strftime("%Y%m%dT%H%M%SZ")
    run_id = run_id or f"{ts_utc}-{machine_id}-{shash[:7]}"
    path = runs_path(algo, machine_id)
    have = have_points(path, algo, q, threads, shash) if skip_done else set()

    log = (lambda m: print(m, file=sys.stderr)) if verbose else (lambda m: None)
    rows = []
    for n in n_list:
        iters = sweep_config.iters_for(n)
        warmup = sweep_config.warmup_for(n)
        for trial in range(1, trials + 1):
            if (n, trial) in have:
                log(f"  skip {algo} N={n} trial={trial} (current source_hash present)")
                continue
            log(f"  bench {algo} q={q} T={threads} N={n} trial={trial}")
            row = run_point(bp, n, q, threads, iters, warmup, trial, run_id, ts_utc, machine_id, host, shash)
            if row:
                rows.append(row)
    log(f"  check {algo} q={q} T={threads}")
    crow = run_check(bp, q, threads, run_id, ts_utc, shash, algo, machine_id, host)
    if crow:
        rows.append(crow)
    append_rows(path, rows)
    log(f"  wrote {len(rows)} rows -> {path}")
    return rows


def parse_n_list(s):
    return [int(x) for x in s.split(",") if x.strip()]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("algo")
    ap.add_argument("--q", type=float, required=True, help="death rate (required)")
    ap.add_argument("--threads", type=int, required=True, help="worker count (required)")
    ap.add_argument("--ns", default=None, help="comma-list of N (default: N_GRID)")
    ap.add_argument("--trials", type=int, default=3)
    ap.add_argument("--machine-id", default=None)
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--ts-utc", default=None)
    ap.add_argument("--skip-done", action="store_true",
                    help="skip (N,trial) points already present at current source_hash")
    a = ap.parse_args()
    bench_column(a.algo, a.q, a.threads,
                 n_list=parse_n_list(a.ns) if a.ns else None,
                 trials=a.trials, machine_id=a.machine_id,
                 run_id=a.run_id, ts_utc=a.ts_utc, skip_done=a.skip_done)


if __name__ == "__main__":
    main()
