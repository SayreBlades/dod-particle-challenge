#!/usr/bin/env python3
"""Unified data-collection sweep for one memory layout.

Runs every algorithm (or a subset) in a memory layout across the N-sweep,
emitting one JSONL row per (algorithm, death_q, threads, N, trial) into the
host's runs.jsonl, plus a checks.jsonl row per (algorithm, death_q) from the
invariant suite. Data is host-partitioned + append-only (§6.5):

    experiments/data/<machine_id>/{runs.jsonl, checks.jsonl, hardware.json}

Every run row is self-describing: the bench binary (`--json`) carries
build-time provenance (git_sha, source_hash, machine_id, host, run_id,
ts_utc) + the algo_meta axes + measurements, so this script just greps
`^json,` and appends. Hardware is a host-level dimension written once
(hardware.json); the report joins on machine_id.

Append-only by design: re-runs duplicate rows; dedup/filtering is a
loader/report concern (the jsonl is a historical audit of every run).

Concurrency / resume:
  Two phases: (1) BUILD one binary per algorithm in PARALLEL (q is runtime, so
               zig AND halide are one binary each — no per-q fan-out) into flat
               out/bin/. (2) BENCH+check SERIAL, always, for clean timing.
  PARALLEL=N    phase-1 build workers (default = cpu count). zig's content-
               addressed .zig-cache is concurrency-safe and the flat binaries
               have unique names, so parallel builds into shared out/ are sound.
  SKIP_DONE=1   (default) skip an (algorithm, q) unit whose CURRENT-source data
                already covers every thread in runs.jsonl. A source change
                (different source_hash) forces a re-bench; SKIP_DONE=0 re-benches all.
  VERBOSE=0     (default) fancy live progress bar (phase · fill · % · ETA).
                VERBOSE=1 = per-step build/bench/check chatter instead.
  HALIDE_FORCE=1  attempt halide algorithms even if `import halide` fails.

Env knobs (all optional; override the regime grid):
  NS, TRIALS, DEATH_RATES, THREADS, REFRESH_HW, HALIDE_PYTHON

Usage:
    scripts/collect.py                            # every algorithm of every memory layout (all)
    scripts/collect.py ML01                        # every algorithm of memory layout ML01
    scripts/collect.py ML01.AF01.LP1-autovec.LP2-simple   # one algorithm (full name)
    scripts/collect.py "AF01.LP1-x AF01.LP1-y"     # a space-list of algorithms
    NS=4000,65000 TRIALS=5 scripts/collect.py ML01
    DEATH_RATES="0 0.5" scripts/collect.py ML01
    THREADS="1 2 4 8" scripts/collect.py ML01   # T is the OUTER loop: all algos@T=1, then -par algos @T=2,4,8
    PARALLEL=4 SKIP_DONE=1 scripts/collect.py ML01
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RATES_FILE = os.path.join(ROOT, "experiments", "sweeps", "death_rates.txt")


def mem_layout_ids() -> list[str]:
    """Memory-layout ids = the ML<digits> directories under src/layouts/. The
    folder name IS the mem_layout id, so there's no id->folder mapping to maintain."""
    import re
    base = os.path.join(ROOT, "src", "layouts")
    return sorted(d for d in os.listdir(base)
                  if re.fullmatch(r"ML\d+", d) and os.path.isdir(os.path.join(base, d)))

# Locks: append_lock serializes JSONL writes; state_lock guards counters.
APPEND_LOCK = threading.Lock()
STATE_LOCK = threading.Lock()
FAILED: set[str] = set()  # algorithms whose build failed (q-independent) — short-circuit


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def read_algos(mem_layout: str) -> list[str]:
    path = os.path.join(ROOT, "experiments", "sweeps", f"{mem_layout}.algos")
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def resolve_algo(name: str) -> str:
    """Validate a full algorithm name (ML<mem_layout>.<algo>). Bare algos are
    rejected — the same algo names recur across memory layouts (AF01–AF08 share
    families), so a bare algo is ambiguous once a second layout lands."""
    if name.split(".", 1)[0] in mem_layout_ids():
        return name
    sys.exit(f"error: '{name}' is not a full algorithm name "
            f"(expected ML<mem_layout>.<algo>, e.g. ML01.AF01.LP1-autovec.LP2-simple)")


def is_parallel(algo: str) -> bool:
    """Parallel algorithms (algo carries -par / rmerge) sweep the thread set;
    serial algorithms run T=1 only."""
    return "-par" in algo or "rmerge" in algo


def algo_source_hash(algo: str) -> str:
    try:
        out = subprocess.run(
            [sys.executable, os.path.join(ROOT, "scripts", "algo_hash.py"), algo],
            capture_output=True, text=True, timeout=30,
        )
        return out.stdout.strip()
    except Exception:
        return ""


def halide_available(halide_python: str | None) -> bool:
    if os.environ.get("HALIDE_FORCE"):
        return True
    if not halide_python or not os.path.exists(halide_python):
        return False
    try:
        r = subprocess.run([halide_python, "-c", "import halide"],
                           capture_output=True, timeout=15)
        return r.returncode == 0
    except Exception:
        return False


def is_done(runs_jsonl: str, algo: str, q: float, threads: list[int], source_hash: str = "") -> bool:
    """runs.jsonl already has every thread in `threads` for (algo, death_q),
    measured against the CURRENT source? If source_hash is given, rows from a
    prior source version don't count — a source change forces a re-bench."""
    if not os.path.exists(runs_jsonl):
        return False
    have: set[str] = set()
    with open(runs_jsonl, encoding="utf-8") as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("algo") != algo:
                continue
            dq = r.get("death_q")
            if dq is None or abs(float(dq) - q) > 1e-12:
                continue
            if source_hash and r.get("source_hash") != source_hash:
                continue  # stale: measured against a prior source — must re-bench
            t = r.get("threads")
            if t is None:
                continue
            have.add(str(int(float(t))))
    return set(str(t) for t in threads) <= have


def append_jsonl(path: str, lines: list[str]) -> None:
    if not lines:
        return
    with APPEND_LOCK:
        with open(path, "a", encoding="utf-8") as f:
            for ln in lines:
                f.write(ln.rstrip("\n") + "\n")


def write_check(checks_jsonl: str, run_id, ts, mid, mem_layout, algo, q, sh, sha, checked) -> None:
    row = {
        "run_id": run_id, "ts_utc": ts, "machine_id": mid, "mem_layout": mem_layout,
        "algo": algo,
        "death_q": float(q) if q not in ("", "n/a") else None,
        "source_hash": sh or None, "git_sha": sha,
        "checked": "PASS" if "PASS" in checked else "FAIL",
    }
    append_jsonl(checks_jsonl, [json.dumps(row)])


def run_zig_build(prefix, mem_layout, algo, q, source_hash, machine_id, host,
                  run_id, ts_utc, halide_prefix, halide_python, verbose) -> bool:
    env = os.environ.copy()
    if halide_python:
        env["HALIDE_PYTHON"] = halide_python
    cmd = [
        "zig", "build", "-p", prefix,
        f"-Dmem_layout={mem_layout}", f"-Dalgo={algo}", f"-Ddeath={q}",
        "-Dmode=bench", "-Doptimize=ReleaseFast",
        f"-Dsource_hash={source_hash}", f"-Dmachine_id={machine_id}",
        f"-Dhost={host}",
        f"-Dhalide_prefix={halide_prefix}",
    ]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env)
    if r.returncode != 0 and verbose:
        # Show a short tail of the build failure (not the whole traceback wall).
        tail = "\n".join((r.stderr or r.stdout).splitlines()[-12:])
        if tail:
            print(tail, file=sys.stderr)
    return r.returncode == 0


def run_bench(bin_path, ns_arg, trials, threads, runs_jsonl, extra_args=None) -> None:
    cmd = [bin_path]
    if ns_arg:
        cmd += ["--ns", ns_arg]
    cmd += ["--trials", str(trials), "--json", "--threads", str(threads)]
    if extra_args:
        cmd += extra_args
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    rows = []
    for stream in (r.stdout, r.stderr):
        for line in (stream or "").splitlines():
            if line.startswith("json,"):
                rows.append(line[len("json,"):])
    append_jsonl(runs_jsonl, rows)


def run_check(bin_path, threads, extra_args=None) -> str:
    cmd = [bin_path, "--check", "--threads", str(threads)]
    if extra_args:
        cmd += extra_args
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines():
        if line.startswith("checked="):
            return line
    return "checked=ERROR"


def bin_path_for(algo: str) -> str:
    """Flat-name binary: out/bin/<algo>.bench (one per algorithm; q is runtime)."""
    return os.path.join(ROOT, "out", "bin", f"{algo}.bench")


def build_one(algo, args, ctx) -> bool:
    """Build one algorithm's bench binary into out/bin/<algo>.bench (flat). q is
    runtime now (config.q defaults to 0; --death overrides at run time), so ONE
    binary per algorithm — no per-q rebuilds, zig or halide. Built with -p out
    so every binary lands in the flat out/bin/ tree."""
    mem_layout, algo_part = algo.split(".", 1)
    source_hash = algo_source_hash(algo)
    return run_zig_build("out", mem_layout, algo_part, "0", source_hash,
                         ctx["machine_id"], ctx["host"], ctx["run_id"],
                         ctx["ts_utc"], "out/halide", ctx["halide_python"], args.verbose)


def bench_check_one(algo, q, T, args, ctx) -> str:
    """Bench (at thread count T) + invariant check for one (algo, q, T) unit,
    SERIAL. Runs out/bin/<algo>.bench --death q --threads T. Works for zig AND
    halide — q is a runtime Param (the wrapper passes config.q)."""
    mem_layout, algo_part = algo.split(".", 1)
    bin_path = bin_path_for(algo)
    log = (lambda *a: print(*a, file=sys.stderr)) if args.verbose else (lambda *a: None)
    source_hash = algo_source_hash(algo)

    if args.skip_done and is_done(ctx["runs_jsonl"], algo, float(q), [T], source_hash):
        log(f"  skip {algo} (q={q}, T={T}) — current-source data already in runs.jsonl")
        return "SKIP"
    if not ctx["halide_ok"] and "LP1-halide" in algo_part:
        return "SKIP"
    with STATE_LOCK:
        if algo in FAILED:
            log(f"  skip {algo} (q={q}, T={T}) — build failed earlier")
            return "SKIP"

    extra = ["--death", str(q), "--run-id", ctx["run_id"], "--ts-utc", ctx["ts_utc"]]
    log(f"    {algo}  bench (q={q}, T={T})...")
    run_bench(bin_path, args.ns_arg, args.trials, T, ctx["runs_jsonl"], extra)
    log(f"    {algo}  --check (q={q}, T={T})...")
    checked = run_check(bin_path, T, extra)
    write_check(ctx["checks_jsonl"], ctx["run_id"], ctx["ts_utc"],
                ctx["machine_id"], mem_layout, algo, q,
                source_hash, ctx["short_sha"], checked)
    return "OK"


def _fmt_dur(s: float) -> str:
    m, sec = divmod(int(s), 60)
    return f"{m}:{sec:02d}"


class Bar:
    """Fancy single-line progress bar: phase · fill · n/total · % · task ·
    elapsed · ETA. Live \\r update on a TTY (non-verbose); per-line otherwise.
    In verbose mode it's silent (the per-step chatter IS the progress) but
    prints a one-line summary on finish()."""

    def __init__(self, total: int, phase: str, verbose: bool):
        self.total = total
        self.phase = phase
        self.verbose = verbose
        self.done = 0
        self.t0 = time.monotonic()
        self.tty = sys.stderr.isatty()

    def _render(self, label: str) -> str:
        pct = (self.done / self.total * 100) if self.total else 100.0
        w = 24
        filled = int(w * self.done / self.total) if self.total else w
        bar = "█" * filled + "░" * (w - filled)
        el = time.monotonic() - self.t0
        eta = (el / self.done * (self.total - self.done)) if self.done else 0.0
        lbl = label if len(label) <= 38 else label[:35] + "..."
        return (f"{self.phase:<5} ▕{bar}▏ {self.done}/{self.total} {pct:3.0f}%"
                f"  · {lbl:<38} · {_fmt_dur(el)} elapsed · ~{_fmt_dur(eta)} left")

    def update(self, label: str) -> None:
        self.done += 1
        if self.verbose:
            return
        line = self._render(label)
        if self.tty:
            sys.stderr.write("\r" + line + " ")
            sys.stderr.flush()
        else:
            sys.stderr.write(line + "\n")

    def finish(self, label: str = "") -> None:
        el = time.monotonic() - self.t0
        if self.verbose:
            sys.stderr.write(f"  {self.phase}: {self.done}/{self.total} in {_fmt_dur(el)}\n")
            return
        line = self._render(label)
        sys.stderr.write(("\r" if self.tty else "") + line + "\n")
        sys.stderr.flush()


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", nargs="?", default="all",
                    help="memory layout (ML01), full algorithm name (ML01.AF01.LP1-autovec.LP2-simple), "
                         "space-list of algorithms, or all (default: all)")
    ap.add_argument("--ns", default=env("NS"), help="comma-list of N (default: bench SWEEP)")
    ap.add_argument("--trials", type=int, default=int(env("TRIALS", "3")))
    ap.add_argument("--death-rates", default=env("DEATH_RATES"),
                    help="space-list of accident rates q (default: death_rates.txt)")
    ap.add_argument("--threads", default=env("THREADS", "1 2 4 8"),
                    help="space-list of worker counts (parallel algorithms only)")
    ap.add_argument("--parallel", type=int, default=int(env("PARALLEL", str(os.cpu_count() or 4))))
    ap.add_argument("--skip-done", action=argparse.BooleanOptionalAction,
                    default=env("SKIP_DONE", "1") == "1",
                    help="skip (algo,q) whose current-source data is already in runs.jsonl "
                         "(default on; --no-skip-done or SKIP_DONE=0 re-benches all)")
    ap.add_argument("--verbose", default=env("VERBOSE", "0"),
                    help="1 (default) per-step chatter; 0 = progress bar only")
    ap.add_argument("--refresh-hw", action="store_true",
                    default=env("REFRESH_HW", "0") == "1")
    args = ap.parse_args()
    args.verbose = args.verbose not in ("0", "false", "no")
    args.threads = [int(t) for t in args.threads.split() if t.strip()]
    args.ns_arg = args.ns

    # death rates
    if args.death_rates:
        rates = args.death_rates.split()
    elif os.path.exists(RATES_FILE):
        rates = [l.strip() for l in open(RATES_FILE) if l.strip() and not l.strip().startswith("#")]
    else:
        rates = ["0.01", "0.05", "0.1", "0.25", "0.5"]

    # algorithms: target is `all` | a memory layout | an algo | a space-list of algos.
    target = args.target
    known = mem_layout_ids()
    if target in ("", "all"):
        algos = []
        for ml in known:
            algos.extend(read_algos(ml))
    elif target in known:
        algos = read_algos(target)
    else:
        algos = [resolve_algo(a) for a in target.split()]
    if not algos:
        sys.exit("error: no algorithms to run.")
    for a in algos:
        if a.split(".", 1)[0] not in known:
            sys.exit(f"error: algorithm '{a}' has an unknown mem_layout")

    # provenance + host data dir
    short_sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                               capture_output=True, text=True).stdout.strip() or "nogit"
    host = subprocess.run([sys.executable, "-c",
                           "import platform,sys;print(platform.node().split('.')[0])"],
                          capture_output=True, text=True).stdout.strip()
    hw_out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "hardware_json.py")],
                            capture_output=True, text=True).stdout
    machine_id = json.loads(hw_out)["machine_id"]
    host_dir = os.path.join(ROOT, "experiments", "data", machine_id)
    os.makedirs(host_dir, exist_ok=True)
    hw_path = os.path.join(host_dir, "hardware.json")
    if not os.path.exists(hw_path) or args.refresh_hw:
        with open(hw_path, "w") as f:
            f.write(hw_out if hw_out.endswith("\n") else hw_out + "\n")
        print(f"  wrote {hw_path}", file=sys.stderr)

    import datetime
    ts_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_id = f"{ts_utc}-{machine_id}-{short_sha}"

    # halide probe: under `uv run` sys.executable IS the project venv (halide is
    # a default dep); HALIDE_PYTHON overrides for ad-hoc probes.
    halide_python = os.environ.get("HALIDE_PYTHON") or sys.executable
    halide_ok = halide_available(halide_python)

    runs_jsonl = os.path.join(host_dir, "runs.jsonl")
    checks_jsonl = os.path.join(host_dir, "checks.jsonl")
    open(runs_jsonl, "a").close()
    open(checks_jsonl, "a").close()

    print(f"=== collect: target={args.target}  run={run_id} ===", file=sys.stderr)
    print(f"  host_dir: {host_dir}", file=sys.stderr)
    print(f"  algos:   {' '.join(algos)}", file=sys.stderr)
    print(f"  death:   {' '.join(rates)}", file=sys.stderr)
    print(f"  ns:      {args.ns or '<default SWEEP>'}  trials={args.trials}  "
          f"threads={' '.join(map(str, args.threads))} (parallel only)", file=sys.stderr)
    print(f"  skip_done={int(args.skip_done)}  parallel={args.parallel}  "
          f"verbose={int(args.verbose)}", file=sys.stderr)
    if halide_ok:
        print("  halide:  available", file=sys.stderr)
    else:
        print("  halide:  UNAVAILABLE (uv sync) — "
              "halide algorithms will be skipped", file=sys.stderr)
    print("  -> runs.jsonl (append)", file=sys.stderr)

    ctx = dict(machine_id=machine_id, host=host, run_id=run_id, ts_utc=ts_utc,
               short_sha=short_sha, runs_jsonl=runs_jsonl,
               checks_jsonl=checks_jsonl, halide_ok=halide_ok,
               halide_python=halide_python)

    # run units: T-MAJOR — all algos at T=1 first, then the -par algos at T=2,
    # T=4, … (serial algos only ever run at T=1). A sweep completes a full T=1
    # pass before any T>1 work, so comparisons group cleanly by thread count and
    # a re-run with a larger THREADS set resumes at the new T values.
    units = []
    for T in args.threads:
        for algo in algos:
            if T != 1 and not is_parallel(algo.split(".", 1)[1]):
                continue
            for q in rates:
                units.append((T, algo, q))

    # ---- PHASE 1: build one binary per algorithm into the flat out/bin/ (PARALLEL) ----
    # q is runtime (zig AND halide), so ONE binary per algorithm — no per-q rebuilds.
    # Builds run concurrently into the shared out/ prefix (zig's content-
    # addressed .zig-cache is concurrency-safe; binaries have unique flat names).
    to_build = [a for a in algos
                if not (not ctx["halide_ok"] and "LP1-halide" in a.split(".", 1)[1])]
    build_workers = max(1, min(len(to_build), args.parallel))
    print(f"  phase 1: build {len(to_build)} binaries ({build_workers} parallel) -> out/bin/",
          file=sys.stderr)

    def _build(algo):
        ok = build_one(algo, args, ctx)
        if not ok:
            with STATE_LOCK:
                FAILED.add(algo)
        return algo, ok

    build_bar = Bar(len(to_build), "build", args.verbose)
    build_failures = []
    try:
        with ThreadPoolExecutor(max_workers=build_workers) as ex:
            futs = [ex.submit(_build, a) for a in to_build]
            for fut in as_completed(futs):
                algo, ok = fut.result()
                if not ok:
                    build_failures.append(algo)
                build_bar.update(algo)
        build_bar.finish(f"{len(to_build)} binaries")
    except KeyboardInterrupt:
        sys.stderr.write("\ninterrupted (phase 1)\n")
        return 130
    for a in build_failures:
        print(f"    BUILD FAILED — {a}", file=sys.stderr)

    # ---- PHASE 2: bench + check, SERIAL (clean timing — no core contention) ----
    print(f"  phase 2: bench+check {len(units)} units serially...", file=sys.stderr)
    bench_bar = Bar(len(units), "bench", args.verbose)
    counts = {"OK": 0, "SKIP": 0, "FAIL": 0}
    try:
        for T, algo, q in units:
            status = bench_check_one(algo, q, T, args, ctx)
            counts[status] += 1
            bench_bar.update(f"T={T} {algo} q={q}")
        bench_bar.finish()
    except KeyboardInterrupt:
        sys.stderr.write("\ninterrupted (phase 2)\n")
        return 130

    runs_n = sum(1 for _ in open(runs_jsonl, encoding="utf-8"))
    checks_n = sum(1 for _ in open(checks_jsonl, encoding="utf-8"))
    print(f"=== done: {runs_n} run rows -> {runs_jsonl} ===", file=sys.stderr)
    print(f"         {checks_n} check rows -> {checks_jsonl}", file=sys.stderr)
    print(f"  tasks: ok={counts['OK']} skip={counts['SKIP']} "
          f"fail={counts['FAIL']} (of {len(units)})", file=sys.stderr)
    if counts["FAIL"]:
        print("  failures:", file=sys.stderr)
        with STATE_LOCK:
            for a in sorted(FAILED):
                print(f"    {a}", file=sys.stderr)
    print("  report: scripts/build_report.py  (then serve experiments/report/)",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
