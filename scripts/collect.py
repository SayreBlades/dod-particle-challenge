#!/usr/bin/env python3
"""collect.py — the data-collection orchestrator.

Owns ALL sweep policy + resume. Calls the atomic scripts:
  hardware_json → hardware.json                    (once)
  algo          → <algo>.json                      (when source changes)
  bench         → <algo>.runs.jsonl                (timing + check, per q × threads)
  profile       → <algo>.profile.jsonl             (cycle attribution, per N × q, T=1,
                                                   where a profiler backend exists)

Default run = timing + check + algo + hardware, NO profiling. --with-profile adds
the profile loop; --only profile runs just it (the radar's data source). Profiling
is skipped with a note where no backend is available — never a hard failure.

Two phases, as before: (1) BUILD one binary per algorithm in PARALLEL (zig's
content-addressed cache is concurrency-safe; flat binaries have unique names);
(2) BENCH + profile SERIAL, always, for clean timing. SKIP_DONE (default on)
resumes an interrupted sweep without duplicating rows at the current source_hash.

Usage:
    scripts/collect.py                              # every algo of every memory layout
    scripts/collect.py ML01                          # one memory layout
    scripts/collect.py ML01.AF01.LP1-autovec.LP2-simple   # one algorithm
    scripts/collect.py ML01 --with-profile           # + cycle attribution
    scripts/collect.py ML01 --only profile           # just the profile loop
    NS=4000,65000 TRIALS=5 scripts/collect.py ML01
    THREADS="1 2 4 8" scripts/collect.py ML01
"""
from __future__ import annotations
import argparse, datetime, json, os, re, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import algo, bench, profile, hardware_json, sweep_config

DATA = os.path.join(ROOT, "experiments", "data")
FAILED: set[str] = set()
STATE_LOCK = threading.Lock()


def env(name, default=""):
    return os.environ.get(name, default)


def mem_layout_ids():
    base = os.path.join(ROOT, "src", "layouts")
    return sorted(d for d in os.listdir(base)
                  if re.fullmatch(r"ML\d+", d) and os.path.isdir(os.path.join(base, d)))


def read_algos(mem_layout):
    path = os.path.join(ROOT, "experiments", "sweeps", f"{mem_layout}.algos")
    return [l.strip() for l in open(path, encoding="utf-8")
            if l.strip() and not l.strip().startswith("#")]


def resolve(target):
    """target -> list of full algorithm names. Accepts ''|'all' (every memory
    layout), a memory layout (ML01), a full algo name, or a space-list of those."""
    known = mem_layout_ids()
    tokens = target.split() if target else []
    if not tokens or tokens == ["all"]:
        out = []
        for ml in known:
            out.extend(read_algos(ml))
        return out
    out = []
    for tok in tokens:
        if tok in known:
            out.extend(read_algos(tok))
        elif "." in tok and tok.split(".", 1)[0] in known:
            out.append(tok)
        else:
            sys.exit(f"error: '{tok}' is not a memory layout or full algorithm name "
                     f"(expected ML<mem_layout>.<algo>, e.g. ML01.AF01.LP1-autovec.LP2-simple)")
    return out


def is_parallel(algo):
    """Parallel algorithms (algo carries -par / rmerge) sweep the thread set;
    serial algorithms run T=1 only."""
    return "-par" in algo or "rmerge" in algo


def threads_for(algo, thread_set):
    return thread_set if is_parallel(algo) else [1]


def _fmt_dur(s):
    m, sec = divmod(int(s), 60)
    return f"{m}:{sec:02d}"


class Bar:
    """Single-line progress bar: phase · fill · n/total · % · task · elapsed · ETA.
    Live \\r redraw on a TTY (default, non-verbose); one line per update otherwise.
    Silent in verbose mode (the atomics' per-step chatter is the progress then).
    update(label, n) advances by n units at once (used to skip a failed algo's
    remaining units so the bar still reaches 100%)."""
    def __init__(self, total, phase, verbose):
        self.total = total
        self.phase = phase
        self.verbose = verbose
        self.done = 0
        self.t0 = time.monotonic()
        self.tty = sys.stderr.isatty()

    def _render(self, label):
        pct = (self.done / self.total * 100) if self.total else 100.0
        w = 24
        filled = int(w * self.done / self.total) if self.total else w
        bar = "█" * filled + "░" * (w - filled)
        el = time.monotonic() - self.t0
        eta = (el / self.done * (self.total - self.done)) if self.done else 0.0
        lbl = label if len(label) <= 38 else label[:35] + "..."
        return (f"{self.phase:<5} ▕{bar}▏ {self.done}/{self.total} {pct:3.0f}%"
                f"  · {lbl:<38} · {_fmt_dur(el)} elapsed · ~{_fmt_dur(eta)} left")

    def update(self, label="", n=1):
        self.done += n
        if self.verbose:
            return
        line = self._render(label)
        if self.tty:
            sys.stderr.write("\r" + line + " ")
            sys.stderr.flush()
        else:
            sys.stderr.write(line + "\n")

    def finish(self, label=""):
        el = time.monotonic() - self.t0
        if self.verbose:
            sys.stderr.write(f"  {self.phase}: {self.done}/{self.total} in {_fmt_dur(el)}\n")
            return
        line = self._render(label)
        sys.stderr.write(("\r" if self.tty else "") + line + "\n")
        sys.stderr.flush()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", nargs="?", default="all",
                    help="memory layout (ML01), full algorithm, or all (default: all)")
    ap.add_argument("--trials", type=int, default=int(env("TRIALS", "3")))
    ap.add_argument("--threads", default=env("THREADS", sweep_config.THREADS_DEFAULT),
                    help="space-list of worker counts (parallel algorithms only)")
    ap.add_argument("--ns", default=env("NS", ""),
                    help="comma-list of N (default: sweep_config.N_GRID)")
    ap.add_argument("--skip-done", action=argparse.BooleanOptionalAction,
                    default=env("SKIP_DONE", "1") == "1",
                    help="skip points already present at the current source_hash (default on)")
    ap.add_argument("--with-profile", action="store_true",
                    help="also collect cycle attribution (where a profiler backend exists)")
    ap.add_argument("--only", choices=["profile"], default=None,
                    help="run only the profile loop (the radar's data source)")
    ap.add_argument("--refresh-hw", action="store_true", default=env("REFRESH_HW", "0") == "1")
    ap.add_argument("--parallel", type=int, default=int(env("PARALLEL", str(os.cpu_count() or 4))))
    ap.add_argument("--verbose", action="store_true", default=env("VERBOSE", "0") == "1",
                    help="per-step chatter instead of the progress bar (default: bar)")
    a = ap.parse_args()
    a.threads = [int(t) for t in a.threads.split() if t.strip()]
    a.n_list = [int(x) for x in a.ns.split(",") if x.strip()] if a.ns else None

    algos = resolve(a.target)
    if not algos:
        sys.exit("error: no algorithms to run.")

    # --- hardware (host-level): ensure hardware.json exists, then read machine_id ---
    hw_exists = any(os.path.exists(os.path.join(DATA, d, "hardware.json"))
                    for d in os.listdir(DATA) if os.path.isdir(os.path.join(DATA, d)))
    if a.refresh_hw or not hw_exists:
        hardware_json.write_to_host_dir()  # detect + write (runs BW microbench ~0.7s)
    machine_id, host = _machine_host()

    short_sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                               capture_output=True, text=True).stdout.strip() or "nogit"
    ts_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_id = f"{ts_utc}-{machine_id}-{short_sha}"

    profilers = profile.available_backends()
    print(f"=== collect: target={a.target} run={run_id} ===", file=sys.stderr)
    print(f"  algos:   {' '.join(algos)}", file=sys.stderr)
    print(f"  machine: {machine_id} ({host})", file=sys.stderr)
    print(f"  ns:      {a.n_list or sweep_config.N_GRID}  trials={a.trials}  "
          f"threads={a.threads} (parallel only)", file=sys.stderr)
    print(f"  profile: {'--with-profile' if a.with_profile else ('--only profile' if a.only == 'profile' else 'off')}  "
          f"backends={profilers or 'none'}", file=sys.stderr)
    print(f"  skip_done={int(a.skip_done)}", file=sys.stderr)

    # --- PHASE 1: build one binary per algorithm (PARALLEL) ---
    build_workers = max(1, min(len(algos), a.parallel))
    print(f"  phase 1: build {len(algos)} binaries ({build_workers} parallel) -> out/bin/",
          file=sys.stderr)
    build_failures = []

    def _build(al):
        ok = True
        try:
            bench.build_binary(al, machine_id, host)
        except SystemExit:
            ok = False
        return al, ok

    try:
        with ThreadPoolExecutor(max_workers=build_workers) as ex:
            futs = [ex.submit(_build, al) for al in algos]
            for fut in as_completed(futs):
                al, ok = fut.result()
                if not ok:
                    with STATE_LOCK:
                        FAILED.add(al)
                    build_failures.append(al)
    except KeyboardInterrupt:
        sys.stderr.write("\ninterrupted (phase 1)\n")
        return 130
    for al in build_failures:
        print(f"    BUILD FAILED — {al}", file=sys.stderr)

    # --- PHASE 2: per-algo collect (SERIAL — clean timing / clean counters) ---
    # Interleaved: fully process one algorithm (bundle + bench + profile) before
    # the next, so progress tracks by completed algorithm. Bench and profile
    # can't share a run (xctrace perturbs timing), but they share the binary.
    do_bench = a.only != "profile"
    do_profile = (a.only == "profile" or a.with_profile) and bool(profilers)
    rates = sweep_config.death_rates()
    n_list = a.n_list or sweep_config.N_GRID

    def _units(al):
        u = 0
        if do_bench:
            u += len(rates) * len(threads_for(al, a.threads))
        if do_profile:
            u += len(n_list) * len(rates)
        return u

    total = sum(_units(al) for al in algos)
    what = ("bench+profile" if do_bench and do_profile
            else "profile" if do_profile else "bench")
    if do_profile and not profilers:
        print("  (profile requested but no backend — timing only)", file=sys.stderr)
    print(f"  phase 2: collect {len(algos)} algos serially ({total} units, {what})", file=sys.stderr)
    bar = Bar(total, "coll", a.verbose)
    counts = {"algo": 0, "columns": 0, "skip": 0, "fail": 0}
    for i, al in enumerate(algos, 1):
        tag = f"[{i}/{len(algos)}]"
        with STATE_LOCK:
            failed = al in FAILED
        if failed:
            counts["fail"] += 1
            bar.update(f"{tag} {al} (build failed)", _units(al))
            continue
        # asm bundle (full/bench path only; --only profile assumes it exists)
        if do_bench:
            try:
                algo.write_bundle(al)
                counts["algo"] += 1
            except SystemExit as e:
                print(f"\n    ALGO FAIL {al}: {e}", file=sys.stderr)
                with STATE_LOCK:
                    FAILED.add(al)
                counts["fail"] += 1
                bar.update(f"{tag} {al} ALGO FAIL", _units(al))
                continue
        if do_bench:
            for q in rates:
                for T in threads_for(al, a.threads):
                    try:
                        rows = bench.bench_column(al, q, T, n_list=a.n_list, trials=a.trials,
                                                  machine_id=machine_id, run_id=run_id,
                                                  ts_utc=ts_utc, skip_done=a.skip_done,
                                                  verbose=a.verbose)
                        counts["columns" if rows else "skip"] += 1
                    except SystemExit as e:
                        print(f"\n    BENCH FAIL {al} q={q} T={T}: {e}", file=sys.stderr)
                        counts["fail"] += 1
                    bar.update(f"{tag} {al} q={q} T={T}")
        if do_profile:
            for q in rates:
                for n in n_list:
                    try:
                        profile.profile_point(al, n, q, 1, machine_id=machine_id,
                                              run_id=run_id, ts_utc=ts_utc,
                                              skip_done=a.skip_done, verbose=a.verbose)
                    except (SystemExit, RuntimeError) as e:
                        print(f"\n    PROFILE FAIL {al} N={n} q={q}: {e}", file=sys.stderr)
                    bar.update(f"{tag} {al} N={n} q={q}")
    bar.finish()
    print(f"=== done: {counts}", file=sys.stderr)
    print("  report: scripts/build_report.py  (then serve experiments/)", file=sys.stderr)
    return 0


def _machine_host():
    """Read machine_id + hostname from the single hardware.json under data/."""
    ids = [d for d in os.listdir(DATA) if os.path.isdir(os.path.join(DATA, d))]
    if len(ids) != 1:
        sys.exit(f"expected one machine under {DATA}, found {ids}")
    hw = json.load(open(os.path.join(DATA, ids[0], "hardware.json")))
    return hw["machine_id"], hw.get("hostname", "")


if __name__ == "__main__":
    raise SystemExit(main())
