#!/usr/bin/env python3
"""Unified data-collection sweep for one layout.

Runs every cell (or a subset) in a layout across the N-sweep, emitting one
JSONL row per (cell, death_q, threads, N, trial) into the host's runs.jsonl,
plus a checks.jsonl row per (cell, death_q) from the invariant suite. Data is
host-partitioned + append-only (§6.5):

    experiments/data/<machine_id>/{runs.jsonl, checks.jsonl, hardware.json}

Every run row is self-describing: the bench binary (`--json`) carries
build-time provenance (git_sha, source_hash, machine_id, host, run_id,
ts_utc) + the cell_decl axes + measurements, so this script just greps
`^json,` and appends. Hardware is a host-level dimension written once
(hardware.json); the report joins on machine_id.

Append-only by design: re-runs duplicate rows; dedup/filtering is a
loader/report concern (the jsonl is a historical audit of every run).

Concurrency / resume:
  PARALLEL=N    run up to N (cell, q) tasks concurrently. Each worker gets
                its own build prefix (out.w0..) so builds don't collide; the
                Halide generator output is partitioned via -Dhalide_prefix.
                NOTE: concurrent bench runs contend for cores and can skew
                ns_frame — keep N<=1 for publication-grade data, use N>1
                only for throughput "collect everything" passes you intend
                to re-run clean.
  SKIP_DONE=1   skip a (cell, q) task whose run rows already cover every
                thread in the cell's THREADS set in runs.jsonl (resume an
                interrupted sweep without duplicating completed units).
  VERBOSE=0     suppress per-step build/bench/check log lines and show only
                a live progress bar (default 1 = keep the classic chatter).
  HALIDE_FORCE=1  attempt halide cells even if `import halide` fails.

Env knobs (all optional; override the regime grid):
  NS, TRIALS, DEATH_RATES, THREADS, REFRESH_HW, HALIDE_PYTHON

Usage:
    scripts/collect.py                       # every cell of every layout (all)
    scripts/collect.py L1                    # every cell of layout L1
    scripts/collect.py L1.B1.w1-autovec.w2-simple   # one cell (full name)
    scripts/collect.py "B1.w1-x B1.w1-y"     # a space-list of cells
    NS=4000,65000 TRIALS=5 scripts/collect.py L1
    DEATH_RATES="0 0.5" scripts/collect.py L1
    THREADS="1 4" scripts/collect.py L1.B3.w1-autovec-par.w2-rmerge
    PARALLEL=4 SKIP_DONE=1 scripts/collect.py L1
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RATES_FILE = os.path.join(ROOT, "experiments", "sweeps", "death_rates.txt")


def layout_ids() -> list[str]:
    """Layout ids = the L<digits> directories under src/layouts/. The folder
    name IS the layout id, so there's no id->folder mapping to maintain."""
    import re
    base = os.path.join(ROOT, "src", "layouts")
    return sorted(d for d in os.listdir(base)
                  if re.fullmatch(r"L\d+", d) and os.path.isdir(os.path.join(base, d)))

# Locks: append_lock serializes JSONL writes; state_lock guards counters.
APPEND_LOCK = threading.Lock()
STATE_LOCK = threading.Lock()
FAILED: set[str] = set()  # cells whose build failed (q-independent) — short-circuit


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def read_cells(layout: str) -> list[str]:
    path = os.path.join(ROOT, "experiments", "sweeps", f"{layout}.cells")
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def resolve_cell(name: str) -> str:
    """Validate a full cell name (L<layout>.<strat>). Bare strats are rejected —
    the same strat names recur across layouts (B1–B8 share blueprints), so a
    bare strat is ambiguous once a second layout lands."""
    if name.split(".", 1)[0] in layout_ids():
        return name
    sys.exit(f"error: '{name}' is not a full cell name "
            f"(expected L<layout>.<strat>, e.g. L1.B1.w1-autovec.w2-simple)")


def parallel_threads(strat: str, threads_set: list[int]) -> list[int]:
    """Parallel cells (strat carries -par / rmerge) sweep the thread set;
    serial cells run T=1 only (no duplicate rows)."""
    if "-par" in strat or "rmerge" in strat:
        return threads_set
    return [1]


def cell_source_hash(cell: str) -> str:
    try:
        out = subprocess.run(
            [sys.executable, os.path.join(ROOT, "scripts", "cell_hash.py"), cell],
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


def is_done(runs_jsonl: str, cell: str, q: float, threads: list[int]) -> bool:
    """runs.jsonl already has every thread in `threads` for (cell, death_q)?"""
    if not os.path.exists(runs_jsonl):
        return False
    have: set[str] = set()
    with open(runs_jsonl, encoding="utf-8") as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("cell") != cell:
                continue
            dq = r.get("death_q")
            if dq is None or abs(float(dq) - q) > 1e-12:
                continue
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


def write_check(checks_jsonl: str, run_id, ts, mid, layout, cell, q, sh, sha, checked) -> None:
    row = {
        "run_id": run_id, "ts_utc": ts, "machine_id": mid, "layout": layout,
        "cell": cell,
        "death_q": float(q) if q not in ("", "n/a") else None,
        "source_hash": sh or None, "git_sha": sha,
        "checked": "PASS" if "PASS" in checked else "FAIL",
    }
    append_jsonl(checks_jsonl, [json.dumps(row)])


def run_zig_build(prefix, layout, strat, q, source_hash, machine_id, host,
                  run_id, ts_utc, halide_prefix, halide_python, verbose) -> bool:
    env = os.environ.copy()
    if halide_python:
        env["HALIDE_PYTHON"] = halide_python
    cmd = [
        "zig", "build", "-p", prefix,
        f"-Dlayout={layout}", f"-Dstrat={strat}", f"-Ddeath={q}",
        "-Dmode=bench", "-Doptimize=ReleaseFast",
        f"-Dsource_hash={source_hash}", f"-Dmachine_id={machine_id}",
        f"-Dhost={host}", f"-Drun_id={run_id}", f"-Dts_utc={ts_utc}",
        f"-Dhalide_prefix={halide_prefix}",
    ]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env)
    if r.returncode != 0 and verbose:
        # Show a short tail of the build failure (not the whole traceback wall).
        tail = "\n".join((r.stderr or r.stdout).splitlines()[-12:])
        if tail:
            print(tail, file=sys.stderr)
    return r.returncode == 0


def run_bench(bin_path, ns_arg, trials, threads, runs_jsonl) -> None:
    cmd = [bin_path]
    if ns_arg:
        cmd += ["--ns", ns_arg]
    cmd += ["--trials", str(trials), "--json", "--threads", str(threads)]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    rows = []
    for stream in (r.stdout, r.stderr):
        for line in (stream or "").splitlines():
            if line.startswith("json,"):
                rows.append(line[len("json,"):])
    append_jsonl(runs_jsonl, rows)


def run_check(bin_path, threads) -> str:
    r = subprocess.run([bin_path, "--check", "--threads", str(threads)],
                       cwd=ROOT, capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines():
        if line.startswith("checked="):
            return line
    return "checked=ERROR"


def run_task(cell, q, args, ctx, wid: int) -> str:
    """One (cell, q) unit: build, bench across threads, invariant check.
    Returns OK | SKIP | FAIL."""
    layout = cell.split(".", 1)[0]
    strat = cell.split(".", 1)[1]
    threads = parallel_threads(strat, args.threads)
    check_t = max(threads)
    prefix = f"out.w{wid}" if args.parallel > 1 else "out"
    hprefix = f"{prefix}/halide"
    bin_path = os.path.join(ROOT, prefix, "bin", "dod-particles")

    log = (lambda *a: print(*a, file=sys.stderr)) if args.verbose else (lambda *a: None)

    # 1. skip-done (resume)
    if args.skip_done and is_done(ctx["runs_jsonl"], cell, float(q), threads):
        log(f"  skip {cell} (q={q}) — already in {ctx['runs_jsonl']}")
        return "SKIP"

    # 2. halide unavailable → skip (one notice at startup, none here)
    if not ctx["halide_ok"] and "w1-halide" in strat:
        return "SKIP"

    # 3. short-circuit cells that failed to build at an earlier death_q
    with STATE_LOCK:
        if cell in FAILED:
            log(f"  skip {cell} (q={q}) — build failed at an earlier death_q")
            return "SKIP"

    source_hash = cell_source_hash(cell)
    log(f"  build {cell} (q={q})...")
    if not run_zig_build(prefix, layout, strat, q, source_hash,
                         ctx["machine_id"], ctx["host"], ctx["run_id"],
                         ctx["ts_utc"], hprefix, ctx["halide_python"], args.verbose):
        log(f"    BUILD FAILED — skipping {cell} (q={q}).")
        with STATE_LOCK:
            FAILED.add(cell)
        return "FAIL"

    for t in threads:
        log(f"    {cell}  bench (q={q}, T={t})...")
        run_bench(bin_path, args.ns_arg, args.trials, t, ctx["runs_jsonl"])

    log(f"    {cell}  --check (q={q}, T={check_t})...")
    checked = run_check(bin_path, check_t)
    write_check(ctx["checks_jsonl"], ctx["run_id"], ctx["ts_utc"],
                ctx["machine_id"], layout, cell, q,
                source_hash, ctx["short_sha"], checked)
    return "OK"


def bar(done: int, total: int, label: str, verbose: bool, final: bool = False) -> None:
    w = 30
    filled = min(w, done * w // total) if total else 0
    b = "#" * filled + "-" * (w - filled)
    pct = done * 100 // total if total else 0
    line = f"[{b}] {done}/{total} ({pct}%){' ' + label if label else ''}"
    if verbose:
        print(line, file=sys.stderr)
    else:
        # single live line, overwritten each tick
        sys.stderr.write("\r" + line + " " * 4)
        sys.stderr.flush()
        if final:
            sys.stderr.write("\n")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", nargs="?", default="all",
                    help="layout (L1), full cell name (L1.B1.w1-autovec.w2-simple), "
                         "space-list of cells, or all (default: all)")
    ap.add_argument("--ns", default=env("NS"), help="comma-list of N (default: bench SWEEP)")
    ap.add_argument("--trials", type=int, default=int(env("TRIALS", "3")))
    ap.add_argument("--death-rates", default=env("DEATH_RATES"),
                    help="space-list of accident rates q (default: death_rates.txt)")
    ap.add_argument("--threads", default=env("THREADS", "1 4 10"),
                    help="space-list of worker counts (parallel cells only)")
    ap.add_argument("--parallel", type=int, default=int(env("PARALLEL", "1")))
    ap.add_argument("--skip-done", action="store_true",
                    default=env("SKIP_DONE", "0") == "1")
    ap.add_argument("--verbose", default=env("VERBOSE", "1"),
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
        rates = ["0.01", "0.05", "0.25"]

    # cells: target is `all` | a layout | a cell/strat | a space-list of cells.
    target = args.target
    known = layout_ids()
    if target in ("", "all"):
        cells = []
        for L in known:
            cells.extend(read_cells(L))
    elif target in known:
        cells = read_cells(target)
    else:
        cells = [resolve_cell(c) for c in target.split()]
    if not cells:
        sys.exit("error: no cells to run.")
    for c in cells:
        if c.split(".", 1)[0] not in known:
            sys.exit(f"error: cell '{c}' has an unknown layout")

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

    # halide probe
    halide_python = os.environ.get("HALIDE_PYTHON")
    if not halide_python and os.path.exists(os.path.join(ROOT, ".venv/bin/python")):
        halide_python = os.path.join(ROOT, ".venv/bin/python")
    halide_ok = halide_available(halide_python)

    runs_jsonl = os.path.join(host_dir, "runs.jsonl")
    checks_jsonl = os.path.join(host_dir, "checks.jsonl")
    open(runs_jsonl, "a").close()
    open(checks_jsonl, "a").close()

    print(f"=== collect: target={args.target}  run={run_id} ===", file=sys.stderr)
    print(f"  host_dir: {host_dir}", file=sys.stderr)
    print(f"  cells:   {' '.join(cells)}", file=sys.stderr)
    print(f"  death:   {' '.join(rates)}", file=sys.stderr)
    print(f"  ns:      {args.ns or '<default SWEEP>'}  trials={args.trials}  "
          f"threads={' '.join(map(str, args.threads))} (parallel only)", file=sys.stderr)
    print(f"  skip_done={int(args.skip_done)}  parallel={args.parallel}  "
          f"verbose={int(args.verbose)}", file=sys.stderr)
    if halide_ok:
        print("  halide:  available", file=sys.stderr)
    else:
        print("  halide:  UNAVAILABLE (uv sync --extra halide) — "
              "halide cells will be skipped", file=sys.stderr)
    print("  -> runs.jsonl (append)", file=sys.stderr)

    ctx = dict(machine_id=machine_id, host=host, run_id=run_id, ts_utc=ts_utc,
               short_sha=short_sha, runs_jsonl=runs_jsonl,
               checks_jsonl=checks_jsonl, halide_ok=halide_ok,
               halide_python=halide_python)

    # task list: (cell, q), cell-major then q-minor
    tasks = [(c, q) for c in cells for q in rates]
    total = len(tasks)

    # clean per-worker build dirs (stale strat leak guard)
    if args.parallel > 1:
        for d in os.listdir(ROOT):
            if d.startswith("out.w"):
                shutil.rmtree(os.path.join(ROOT, d), ignore_errors=True)

    counts = {"OK": 0, "SKIP": 0, "FAIL": 0}
    done = 0

    try:
        if args.parallel <= 1:
            for i, (cell, q) in enumerate(tasks):
                status = run_task(cell, q, args, ctx, 0)
                counts[status] += 1
                done += 1
                bar(done, total, f"{cell} q={q}", args.verbose)
        else:
            with ThreadPoolExecutor(max_workers=args.parallel) as ex:
                futs = {ex.submit(run_task, cell, q, args, ctx, w % args.parallel): (cell, q)
                        for w, (cell, q) in enumerate(tasks)}
                for fut in as_completed(futs):
                    cell, q = futs[fut]
                    try:
                        status = fut.result()
                    except Exception:
                        status = "FAIL"
                    counts[status] += 1
                    done += 1
                    bar(done, total, f"{cell} q={q}", args.verbose)
    except KeyboardInterrupt:
        sys.stderr.write("\ninterrupted\n")
        return 130

    if not args.verbose:
        bar(done, total, "", False, final=True)

    runs_n = sum(1 for _ in open(runs_jsonl, encoding="utf-8"))
    checks_n = sum(1 for _ in open(checks_jsonl, encoding="utf-8"))
    print(f"=== done: {runs_n} run rows -> {runs_jsonl} ===", file=sys.stderr)
    print(f"         {checks_n} check rows -> {checks_jsonl}", file=sys.stderr)
    print(f"  tasks: ok={counts['OK']} skip={counts['SKIP']} "
          f"fail={counts['FAIL']} (of {total})", file=sys.stderr)
    if counts["FAIL"]:
        print("  failures:", file=sys.stderr)
        with STATE_LOCK:
            for c in sorted(FAILED):
                print(f"    {c}", file=sys.stderr)
    print("  report: scripts/build_report.py  (then serve experiments/report/)",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
