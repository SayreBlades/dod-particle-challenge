#!/usr/bin/env python3
"""Build the full analysis tree under experiments/analysis/.

Two-stage model (reporting-and-analysis.md §0/§6):
  - collect.py        = pure measurement (unchanged; writes only data/)
  - THIS script       = all analysis: per-algo bundles (delegated to
                        analyze_algo.py via subprocess), the machine/mem_layout
                        aggregations, the markdown narrative tree,
                        and the --verify integrity gate.

Per-algo bundles (<algo>.json evidence + <algo>.md narrative) are produced by
`scripts/analyze_algo.py`; this script owns the duckdb aggregation
(machines/overview/mem_layout bundles) + the README tree + the gate. The SPA
(experiments/report.html + report.js + style.css) is thin — it fetches
everything from experiments/analysis/.

The verify gate (Q2/§12.0): every algo narrative is checked; a failure is
retried once (at a higher token budget to absorb reasoning-heavy cases), then
marked. The report is ALWAYS fully written; failing algos carry
`verified: false` (the SPA banners them) and the build exits nonzero if any
remain unverified — loud, but never blocks the deterministic aggregation.

Usage:
    uv run python scripts/build_report.py              # full build
    uv run python scripts/build_report.py --no-algos   # aggregation only (skip per-algo gen)
    uv run python scripts/build_report.py --force      # force-regenerate all narratives
    uv run python scripts/build_report.py --verify-only
    uv run python scripts/build_report.py ML01           # restrict to one mem_layout

Needs duckdb — run via `uv run` (or `make report`). Re-run after every collect.
"""
from __future__ import annotations
import glob, json, os, subprocess, sys, tempfile

import duckdb

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import layout_facts
DATA = os.path.join(ROOT, "experiments", "data")
OUT = os.path.join(ROOT, "experiments", "analysis")
PY = os.path.join(ROOT, ".venv", "bin", "python")
ANALYZE = os.path.join(ROOT, "scripts", "analyze_algo.py")
RETRY_MAX_TOKENS = "24000"   # bump on verify-fail retry (reasoning model headroom)

# Death-rate points EXCLUDED from the report. Legacy sweep values not in
# sweep_config.DEATH_RATES; raw data retains them. Both the duckdb
# aggregation (here) and the per-algo bundles (analyze_algo.py) drop them so the
# SPA never surfaces them. Keep in sync with analyze_algo.py.
EXCLUDE_DEATH_Q = (0.0, 0.75)

# Particle counts (N) EXCLUDED from the report. Legacy sweep points retired
# from the bench SWEEP (src/framework/bench.zig); raw data retains them.
# 16000 was an L1-era point, dropped in the one-pass sparse grid (97f2541) but
# the collected rows were never purged. Same sync rule as EXCLUDE_DEATH_Q.
EXCLUDE_N = (16000,
             380, 640, 960, 1400, 2400, 25000, 41000, 62000, 93000,
             320, 480, 720, 3100, 5100, 7700, 12000, 19000, 99000,
             160000, 250000, 370000, 620000)

# Per-mem_layout struct diagram shown atop the algo page (the data-model identity).
# TODO: read from the mem_layout README spec; hardcoded per-mem_layout for now (L1 only).
MEM_LAYOUT_MEMORY = {
    "ML01": (
        "particles: []Particle        ONE AoS array, plain alloc, natural alignment\n"
        "┌────────┬────────┬──────┬─────┬───────┬──────┬──────────┬──────┬───────┬──────┬──────┐\n"
        "│pos 12B │vel 12B │life 4│age 4│color16│size 4│rotation 4│mass 4│flags 1│kind 1│seed 4│  = 68 B\n"
        "└────────┴────────┴──────┴─────┴───────┴──────┴──────────┴──────┴───────┴──────┴──────┘"
    ),
}


# ---- duckdb load ----

def load(con):
    # Per-algo files: data/<id>/<algo>.runs.jsonl (kind-discriminated timing +
    # check rows). The report table keeps only kind='timing'; check rows aren't timings.
    paths = sorted(glob.glob(os.path.join(DATA, "*", "*.runs.jsonl")))
    if not paths:
        sys.exit(f"no <algo>.runs.jsonl under {DATA}; run collect.py first")
    con.execute("CREATE TABLE runs AS " +
                " UNION ALL ".join(f"SELECT * FROM read_json_auto('{p}')" for p in paths))
    if EXCLUDE_DEATH_Q:
        qmarks = ",".join(map(str, EXCLUDE_DEATH_Q))
        con.execute(f"DELETE FROM runs WHERE death_q IN ({qmarks})")
        print(f"  excluded death_q in ({qmarks}) from the report", file=sys.stderr)
    if EXCLUDE_N:
        nmarks = ",".join(map(str, EXCLUDE_N))
        con.execute(f"DELETE FROM runs WHERE N IN ({nmarks})")
        print(f"  excluded N in ({nmarks}) from the report", file=sys.stderr)
    hws = sorted(glob.glob(os.path.join(DATA, "*", "hardware.json")))
    con.execute("CREATE TABLE hardware AS " +
                " UNION ALL ".join(f"SELECT * FROM read_json_auto('{p}')" for p in hws))
    # Keep only rows pinned to each algorithm's LATEST source_hash PER MACHINE
    # — this allows historical data from machines that haven't re-collected yet
    # (e.g. minibits with an older source_hash) to remain visible in the report,
    # while still dropping pre-versioning null rows and truly stale duplicates
    # within a single machine's timeline.
    con.execute("""CREATE TABLE latest_source AS
        SELECT algo, machine_id, source_hash AS shash
        FROM (
            SELECT algo, machine_id, source_hash,
                   ROW_NUMBER() OVER (PARTITION BY algo, machine_id ORDER BY ts_utc DESC) AS rn
            FROM runs
            WHERE source_hash IS NOT NULL
        )
        WHERE rn = 1
    """)
    con.execute("""CREATE TABLE report AS
        SELECT r.*, h.streaming_bw_gbs,
               (r.bytes_per_particle * r.N / NULLIF(r.ns_frame, 0)) AS achieved_bw_gbs
        FROM runs r
        JOIN latest_source ls ON r.algo = ls.algo AND r.machine_id = ls.machine_id
                              AND r.source_hash = ls.shash
        LEFT JOIN hardware h ON h.machine_id = r.machine_id
        WHERE r.kind = 'timing'""")


def rows(con, sql, params=()):
    cur = con.execute(sql, params)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def distinct(con, col, machine, mem_layout=None):
    where = f"machine_id = ?" + (f" AND mem_layout = ?" if mem_layout else "")
    params = [machine] + ([mem_layout] if mem_layout else [])
    return [r[0] for r in con.execute(
        f"SELECT DISTINCT {col} FROM report WHERE {where} ORDER BY {col}", params).fetchall()]


def champs_sql(machine, mem_layout=None):
    """Top-3 algos per (N × death_q × threads). Partitioned by threads
    (decision 8): a parallel algo's T=10 and a serial algo's T=1 never share a
    podium. min ns_particle across trials."""
    where = "machine_id = ?" + (" AND mem_layout = ?" if mem_layout else "")
    params = [machine] + ([mem_layout] if mem_layout else [])
    sql = f"""
      SELECT * FROM (
        SELECT algo, mem_layout, death_q, threads, N, ns_particle, achieved_bw_gbs,
               row_number() OVER (PARTITION BY N, death_q, threads
                                   ORDER BY ns_particle) AS rk
        FROM (
          SELECT algo, mem_layout, death_q, threads, N,
            min(ns_particle) AS ns_particle, min(achieved_bw_gbs) AS achieved_bw_gbs
          FROM report WHERE {where}
          GROUP BY algo, mem_layout, death_q, threads, N
        )
      ) WHERE rk <= 3 ORDER BY threads, N, death_q, rk"""
    return sql, params


def teaser(md_path):
    """One-line Intent extract from a algo .md, for the featured-algo list."""
    if not os.path.exists(md_path):
        return ""
    md = open(md_path).read()
    import re
    m = re.search(r"## Intent\s*\n(.+?)(\n## |\Z)", md, re.S)
    if not m:
        return ""
    txt = re.sub(r"[`*]", "", m.group(1)).strip().replace("\n", " ")
    return txt[:160]


# ---- per-algo generation + verify gate (delegated to analyze_algo.py) ----

def mem_layouts_in_data(con):
    return [r[0] for r in con.execute(
        "SELECT DISTINCT mem_layout FROM runs WHERE mem_layout IS NOT NULL ORDER BY mem_layout").fetchall()]


def run_analyze(args, env=None):
    """Subprocess analyze_algo.py under the venv; stream stderr."""
    cmd = [PY, ANALYZE] + args
    r = subprocess.run(cmd, cwd=ROOT, env={**os.environ, **(env or {})})
    return r.returncode


def generate_algo_bundles(mids, layouts, force, narratives=False):
    """Per (machine, mem_layout): analyze_algo.py --machine <mid> <L> [--force].
    Default: --json-only — the evidence .json for EVERY machine with data (asm,
    runs, profile; no LLM, no narrative). --narratives adds the LLM .md pass
    (slow + costs tokens; also regenerates missing narratives). Resume-skips
    existing work either way; --force regenerates all narratives."""
    flags = (["--force"] if force else []) + ([] if narratives else ["--json-only"])
    for mid in mids:
        for L in layouts:
            print(f"== per-algo bundles ({'narratives' if narratives else 'evidence-only'}): {mid} / {L} ==", file=sys.stderr)
            run_analyze(["--machine", mid, L] + flags)


def verify_mem_layout(mid, target, machine_hint=None):
    """Run analyze_algo.py --machine <mid> <target> --verify --verify-json <tmp>;
    return {algo: {...}}. `target` is a mem_layout (all its algos) or one algo."""
    with tempfile.NamedTemporaryFile("w+", suffix=".json", delete=False) as f:
        path = f.name
    try:
        run_analyze(["--machine", mid, target, "--verify", "--verify-json", path])
        return json.load(open(path))
    except Exception as e:
        print(f"  verify failed for {mid}/{target}: {e}", file=sys.stderr)
        return {}
    finally:
        os.unlink(path)


def retry_algo(mid, algo):
    """One retry at a higher token budget (covers truncation + fresh re-roll
    for hallucination)."""
    print(f"  retry (MAX_TOKENS={RETRY_MAX_TOKENS}): {mid}/{algo}", file=sys.stderr)
    run_analyze(["--machine", mid, algo, "--force"], env={"MAX_TOKENS": RETRY_MAX_TOKENS})


def run_gate(mids, layouts):
    """Per machine: verify → retry FAILs once → re-verify those. Returns
    ({mid: {algo: {...}}}, total_fail). Nonzero-failing algos are NOT regenerated
    again — they keep their (best-effort) narrative, marked unverified."""
    final_by_mid = {}
    n_fail_total = 0
    for mid in mids:
        final = {}
        for L in layouts:
            res = verify_mem_layout(mid, L)
            fails = [c for c, v in res.items() if v["status"] == "FAIL"]
            for c in fails:
                retry_algo(mid, c)
            if fails:
                # re-verify just the retried algos, one per call (single-algo verify)
                for c in fails:
                    res[c] = verify_mem_layout(mid, c).get(c, res[c])
            final.update(res)
        n_fail = sum(1 for v in final.values() if v["status"] == "FAIL")
        n_miss = sum(1 for v in final.values() if v["status"] == "MISS")
        n_fail_total += n_fail
        print(f"== gate[{mid}]: {len(final)} algos, {n_fail} FAIL, {n_miss} MISS ==", file=sys.stderr)
        final_by_mid[mid] = final
    return final_by_mid, n_fail_total


def inject_verified(machine, mem_layout, verify_results):
    """Stamp `verified` + `verify_errors` into each algo .json so the SPA can
    banner unverified narratives. (Additive; analyze_algo.py owns the rest of
    the schema and rewrites the .json each run — this runs after.)"""
    if not mem_layout:
        return
    base = os.path.join(OUT, machine)
    for algo, v in verify_results.items():
        if algo.split(".")[0] != mem_layout:
            continue
        if v["status"] == "MISS":
            continue  # no narrative to verify — leave unstamped (no SPA banner)
        jpath = os.path.join(base, f"{algo}.json")
        if not os.path.exists(jpath):
            continue
        try:
            j = json.load(open(jpath))
        except Exception:
            continue
        j["verified"] = v["status"] == "OK"
        j["verify_errors"] = v["errors"]
        with open(jpath, "w") as f:
            json.dump(j, f, indent=2)


# ---- aggregation bundles (machines / overview / mem_layout) + markdown ----

def build_machines_index(con):
    os.makedirs(OUT, exist_ok=True)
    mids = [r[0] for r in con.execute(
        "SELECT DISTINCT machine_id FROM hardware ORDER BY machine_id").fetchall()]
    entries = []  # [(hw, layouts)] — read once, feeds both outputs below
    mlist = []
    for mid in mids:
        hw = json.load(open(os.path.join(DATA, mid, "hardware.json")))
        layouts = distinct(con, "mem_layout", mid)
        entries.append((hw, layouts))
        mlist.append({"machine_id": hw.get("machine_id", mid), "cpu": hw.get("cpu")})
    # machines.json — the SPA's DISCOVERY index only: which machines exist + a
    # selector label. Hardware facts are NOT duplicated here; they live in
    # data/<mid>/hardware.json (raw) and flow verbatim into each machine's
    # overview.json (derived). A static-file SPA can't glob data/ over HTTP, so
    # this one small root index has to exist.
    json.dump({"machines": mlist}, open(os.path.join(OUT, "machines.json"), "w"), indent=2)

    # analysis/README.md — the machine index (the only honest cross-machine view)
    def kb(v): return f"{v // 1024} KB" if v else "—"
    def cache_sz(v): return f"{v / 1048576:.1f} MB" if v >= 1048576 else (f"{v // 1024} KB" if v else "—")
    lines = ["# Analysis — machine index", ""]
    lines.append("The derived analysis layer, rebuilt by `scripts/build_report.py`. "
                 "Raw data lives in `experiments/data/<machine_id>/`; this tree is the "
                 "browsable + machine-readable reading of it. Open `experiments/report.html` "
                 "for the interactive SPA (machine- + thread-group-scoped, three-tier "
                 "drill-down).")
    lines.append("")
    lines.append("The only honest cross-machine view: each machine's hardware facts side "
                 "by side. Absolute ns/p across microarchitectures is meaningless; "
                 "normalized comparison (% of ceiling, which algo_fam wins) is a "
                 "Phase-3 deliverable, not built here.")
    lines.append("")
    lines.append("| machine_id | cpu | streaming BW | L1d | L2 | L3 | layouts |")
    lines.append("|---|---|---|---|---|---|---|")
    for hw, layouts in entries:
        lines.append(f"| [`{hw['machine_id']}`]({hw['machine_id']}/) | {hw['cpu']} | "
                     f"{hw['streaming_bw_gbs']} GB/s | {kb(hw['l1dcachesize'])} | "
                     f"{cache_sz(hw['l2cachesize'])} | {cache_sz(hw['l3cachesize'])} | "
                     f"{', '.join(layouts)} |")
    lines.append("")
    lines.append("Per machine: `<machine_id>/README.md` (overview) → "
                 "`<machine_id>/<L>.mem_layout.md` (mem_layout) → "
                 "`<machine_id>/<algo>.md` (the per-algo narrative).")
    open(os.path.join(OUT, "README.md"), "w").write("\n".join(lines) + "\n")
    print(f"  wrote analysis/README.md + analysis/machines.json ({len(mlist)} machine(s))",
          file=sys.stderr)
    return mlist


def build_overview(con, mid):
    hw = json.load(open(os.path.join(DATA, mid, "hardware.json")))
    layouts = distinct(con, "mem_layout", mid)
    deaths = distinct(con, "death_q", mid)
    nvals = distinct(con, "N", mid)
    threads = distinct(con, "threads", mid)
    champs = rows(con, *champs_sql(mid))
    # Hardware flows VERBATIM from data/<mid>/hardware.json — no hand-picked
    # field subset to drift out of sync when hardware.json grows a field.
    overview = {**hw, "layouts": layouts, "death_rates": deaths,
                "n_values": nvals, "thread_groups": threads, "champions": champs}
    os.makedirs(os.path.join(OUT, mid), exist_ok=True)
    json.dump(overview, open(os.path.join(OUT, mid, "overview.json"), "w"), indent=2)

    default_t = threads[0] if threads else 1
    lines = [f"# {hw['cpu']} (`{mid}`)", ""]
    lines.append(f"Streaming ceiling **{hw['streaming_bw_gbs']} GB/s** · "
                 f"L1d {hw['l1dcachesize'] // 1024} KB · "
                 f"L2 {hw['l2cachesize'] // 1048576:.0f} MB · "
                 f"{hw['logicalcpu']} logical cores.")
    lines.append("")
    lines.append(f"Memory layouts measured: {', '.join(f'[{L}]({L}.mem_layout.md)' for L in layouts)}.")
    lines.append("")
    lines.append(f"## Winners (top-3) (T={default_t})")
    lines.append("")
    lines.append(_grid_md([c for c in champs if c["threads"] == default_t], nvals, deaths))
    open(os.path.join(OUT, mid, "README.md"), "w").write("\n".join(lines) + "\n")
    print(f"  wrote analysis/{mid}/README.md + overview.json", file=sys.stderr)


def build_mem_layout_bundle(con, mid, L):
    hw = json.load(open(os.path.join(DATA, mid, "hardware.json")))
    deaths = distinct(con, "death_q", mid, L)
    nvals = distinct(con, "N", mid, L)
    threads = distinct(con, "threads", mid, L)
    champs = rows(con, *champs_sql(mid, L))
    algos_all = sorted({r[0] for r in con.execute(
        "SELECT DISTINCT algo FROM report WHERE machine_id=? AND mem_layout=?", [mid, L]).fetchall()})
    default_t = threads[0] if threads else 1
    featured = []
    for r in champs:
        if r["rk"] == 1 and r["threads"] == default_t:
            c = r["algo"]
            if not any(f["algo"] == c for f in featured):
                featured.append({"algo": c, "ns": round(r["ns_particle"], 2),
                                 "teaser": teaser(os.path.join(OUT, mid, f"{c}.md"))})
    lb = {"machine_id": mid, "mem_layout": L, "death_rates": deaths, "n_values": nvals,
          "thread_groups": threads, "streaming_bw_gbs": hw["streaming_bw_gbs"],
          "memory_layout": MEM_LAYOUT_MEMORY.get(L, ""),
          "layout_facts": {"struct": layout_facts.LAYOUTS.get(L, {}).get("struct"),
                           "fields": layout_facts.LAYOUTS.get(L, {}).get("fields"),
                           "loops_by_fam": {fam: layout_facts.loop_hot_bytes(L, fam)
                                            for fam in layout_facts.AF_LOOPS}},
          "champions": champs,
          "algos": algos_all, "featured": featured}
    os.makedirs(os.path.join(OUT, mid), exist_ok=True)
    json.dump(lb, open(os.path.join(OUT, mid, f"{L}.mem_layout.json"), "w"), indent=2)

    lines = [f"# Memory layout {L} on {hw['cpu']} (`{mid}`)", ""]
    lines.append(f"## Champion grid (T={default_t})")
    lines.append("")
    lines.append(_grid_md([c for c in champs if c["threads"] == default_t], nvals, deaths))
    lines.append("")
    lines.append("## Featured algos")
    lines.append("")
    if featured:
        for f in featured:
            t = f" — {f['teaser']}…" if f["teaser"] else ""
            lines.append(f"- **[{f['algo']}]({f['algo']}.md)** — {f['ns']} ns/p{t}")
    else:
        lines.append("_(no featured algos)_")
    lines.append("")
    lines.append("## All algos")
    lines.append("")
    for c in algos_all:
        lines.append(f"- [{c}]({c}.md)")
    open(os.path.join(OUT, mid, f"{L}.mem_layout.md"), "w").write("\n".join(lines) + "\n")
    print(f"  wrote analysis/{mid}/{L}.mem_layout.md + {L}.mem_layout.json "
          f"({len(algos_all)} algos)", file=sys.stderr)


def _fmt_n(n):
    if n >= 1_000_000:
        return f"{n // 1_000_000}M" if n % 1_000_000 == 0 else f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n // 1_000}K" if n % 1_000 == 0 else f"{n / 1_000:.1f}K"
    return str(n)


def _grid_md(champs, nvals, deaths):
    """Render the top-3 podium grid as a markdown table (rows = N, cols = death_q)."""
    byk = {}
    for c in champs:
        byk[(c["N"], c["death_q"], c["rk"])] = c
    out = ["| num-particles＼death | " + " | ".join(str(d) for d in deaths) + " |",
           "|" + "---|" * (len(deaths) + 1)]
    for n in nvals:
        row = [_fmt_n(n)]
        for d in deaths:
            algotxt = []
            for rk in (1, 2, 3):
                c = byk.get((n, d, rk))
                if c:
                    algo_part = c["algo"].split(".", 1)[1]
                    algotxt.append(f"[{algo_part}]({c['algo']}.md) {c['ns_particle']:.2f}")
            row.append("<br>".join(algotxt) or "—")
        out.append("| " + " | ".join(row) + " |")
    return "\n".join(out)


def build_grid(con, mid):
    """grid.json — every algo's best (min-ns) trial per (N, death_q, threads).
    Lets the SPA rank ALL algos at any (machine, threads, N, death_q) intersection
    with one fetch, instead of loading each per-algo bundle."""
    hw = json.load(open(os.path.join(DATA, mid, "hardware.json")))
    nvals = distinct(con, "N", mid)
    deaths = distinct(con, "death_q", mid)
    tgroups = distinct(con, "threads", mid)
    algos = [r[0] for r in con.execute(
        "SELECT DISTINCT algo FROM report WHERE machine_id=? ORDER BY algo", [mid]).fetchall()]
    pts = rows(con, """
        SELECT algo, N, death_q, threads, ns_particle, achieved_bw_gbs FROM (
          SELECT algo, N, death_q, threads, ns_particle, achieved_bw_gbs,
                 row_number() OVER (PARTITION BY algo, N, death_q, threads
                                    ORDER BY ns_particle) AS rn
          FROM report WHERE machine_id = ?
        ) WHERE rn = 1
        ORDER BY algo, N, death_q, threads""", [mid])
    grid = {"machine_id": mid, "streaming_bw_gbs": hw["streaming_bw_gbs"],
            "n_values": nvals, "death_rates": deaths, "thread_groups": tgroups,
            "algos": algos, "points": pts}
    json.dump(grid, open(os.path.join(OUT, mid, "grid.json"), "w"), indent=2)
    print(f"  wrote analysis/{mid}/grid.json ({len(pts)} points, {len(algos)} algos)",
          file=sys.stderr)


# ---- main ----


# ---- main ----

def main():
    argv = [a for a in sys.argv[1:] if not a.startswith("-")]
    no_algos = "--no-algos" in sys.argv
    force = "--force" in sys.argv
    narratives = "--narratives" in sys.argv
    verify_only = "--verify-only" in sys.argv
    only_mem_layout = argv[0] if argv else None

    con = duckdb.connect()
    load(con)
    n_runs = con.execute("SELECT count(*) FROM runs").fetchone()[0]
    mids = [r[0] for r in con.execute(
        "SELECT DISTINCT machine_id FROM hardware ORDER BY machine_id").fetchall()]
    print(f"loaded {n_runs} runs across {mids}", file=sys.stderr)

    layouts = mem_layouts_in_data(con)
    if only_mem_layout:
        layouts = [L for L in layouts if L == only_mem_layout]

    # 1. per-algo evidence bundles for every machine (json-only, no LLM);
    #    --narratives adds the LLM .md pass
    if not verify_only and not no_algos:
        generate_algo_bundles(mids, layouts, force, narratives=narratives)

    # 2. verify gate: verify -> retry FAILs once -> re-verify. Final per-algo
    #    status + fail count. (Q2: warn+mark+nonzero; report still written.)
    gate_results, n_fail = (run_gate(mids, layouts) if not no_algos else ({}, 0))

    # 3. stamp verified status into each algo .json (SPA banners unverified)
    for mid in mids:
        for L in layouts:
            if distinct(con, "algo", mid, L):
                inject_verified(mid, L, gate_results.get(mid, {}))

    # 4. aggregation bundles + markdown tree
    build_machines_index(con)
    for mid in mids:
        build_overview(con, mid)
        build_grid(con, mid)
        for L in distinct(con, "mem_layout", mid):
            if only_mem_layout and L != only_mem_layout:
                continue
            build_mem_layout_bundle(con, mid, L)

    print("done.", file=sys.stderr)
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
