#!/usr/bin/env python3
"""Build the full analysis tree under experiments/analysis/.

Two-stage model (reporting-and-analysis.md §0/§6):
  - collect.py        = pure measurement (unchanged; writes only data/)
  - THIS script       = all analysis: per-cell bundles (delegated to
                        analyze_cell.py via subprocess), the machine/layout
                        aggregations, the markdown narrative tree, queries.sql,
                        and the --verify integrity gate.

Per-cell bundles (<cell>.json evidence + <cell>.md narrative) are produced by
`scripts/analyze_cell.py`; this script owns the duckdb aggregation
(machines/overview/layout bundles) + the README tree + the gate. The SPA
(experiments/report.html + report.js + style.css) is thin — it fetches
everything from experiments/analysis/.

The verify gate (Q2/§12.0): every cell narrative is checked; a failure is
retried once (at a higher token budget to absorb reasoning-heavy cases), then
marked. The report is ALWAYS fully written; failing cells carry
`verified: false` (the SPA banners them) and the build exits nonzero if any
remain unverified — loud, but never blocks the deterministic aggregation.

Usage:
    .venv/bin/python scripts/build_report.py              # full build
    .venv/bin/python scripts/build_report.py --no-cells   # aggregation only (skip per-cell gen)
    .venv/bin/python scripts/build_report.py --force      # force-regenerate all narratives
    .venv/bin/python scripts/build_report.py --verify-only
    .venv/bin/python scripts/build_report.py L2           # restrict to one layout

Needs duckdb — run under the venv. Re-run after every collect.
"""
from __future__ import annotations
import glob, json, os, subprocess, sys, tempfile

import duckdb

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "experiments", "data")
OUT = os.path.join(ROOT, "experiments", "analysis")
PY = os.path.join(ROOT, ".venv", "bin", "python")
ANALYZE = os.path.join(ROOT, "scripts", "analyze_cell.py")
RETRY_MAX_TOKENS = "24000"   # bump on verify-fail retry (reasoning model headroom)

# Death-rate points EXCLUDED from the report. Legacy sweep values not in
# experiments/sweeps/death_rates.txt; raw data retains them. Both the duckdb
# aggregation (here) and the per-cell bundles (analyze_cell.py) drop them so the
# SPA never surfaces them. Keep in sync with analyze_cell.py.
EXCLUDE_DEATH_Q = (0.0, 0.75)

# Per-layout struct diagram shown atop the cell page (the data-model identity).
# TODO: read from the layout README spec; hardcoded per-layout for now (L1 only).
LAYOUT_MEMORY = {
    "L1": (
        "particles: []Particle        ONE AoS array, plain alloc, natural alignment\n"
        "┌────────┬────────┬──────┬─────┬───────┬──────┬──────────┬──────┬───────┬──────┬──────┐\n"
        "│pos 12B │vel 12B │life 4│age 4│color16│size 4│rotation 4│mass 4│flags 1│kind 1│seed 4│  = 68 B\n"
        "└────────┴────────┴──────┴─────┴───────┴──────┴──────────┴──────┴───────┴──────┴──────┘"
    ),
}


# ---- duckdb load ----

def load(con):
    paths = sorted(glob.glob(os.path.join(DATA, "*", "runs.jsonl")))
    if not paths:
        sys.exit(f"no runs.jsonl under {DATA}; run collect.py first")
    con.execute("CREATE TABLE runs AS " +
                " UNION ALL ".join(f"SELECT * FROM read_json_auto('{p}')" for p in paths))
    if EXCLUDE_DEATH_Q:
        qmarks = ",".join(map(str, EXCLUDE_DEATH_Q))
        con.execute(f"DELETE FROM runs WHERE death_q IN ({qmarks})")
        print(f"  excluded death_q in ({qmarks}) from the report", file=sys.stderr)
    hws = sorted(glob.glob(os.path.join(DATA, "*", "hardware.json")))
    con.execute("CREATE TABLE hardware AS " +
                " UNION ALL ".join(f"SELECT * FROM read_json_auto('{p}')" for p in hws))
    for kind in ("checks", "pmc"):
        ps = sorted(glob.glob(os.path.join(DATA, "*", f"{kind}.jsonl")))
        if ps:
            con.execute(f"CREATE TABLE {kind} AS " +
                        " UNION ALL ".join(f"SELECT * FROM read_json_auto('{p}')" for p in ps))
        else:
            con.execute(f"CREATE TABLE {kind}(cell VARCHAR, death_q DOUBLE)")
    con.execute("""CREATE TABLE report AS
        SELECT r.*, h.streaming_bw_gbs,
               (r.bytes_per_particle * r.N / NULLIF(r.ns_frame, 0)) AS achieved_bw_gbs
        FROM runs r LEFT JOIN hardware h USING (machine_id)""")


def rows(con, sql, params=()):
    cur = con.execute(sql, params)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def distinct(con, col, machine, layout=None):
    where = f"machine_id = ?" + (f" AND layout = ?" if layout else "")
    params = [machine] + ([layout] if layout else [])
    return [r[0] for r in con.execute(
        f"SELECT DISTINCT {col} FROM report WHERE {where} ORDER BY {col}", params).fetchall()]


def champs_sql(machine, layout=None):
    """Top-3 cells per (N × death_q × threads). Partitioned by threads
    (decision 8): a parallel cell's T=10 and a serial cell's T=1 never share a
    podium. min ns_particle across trials."""
    where = "machine_id = ?" + (" AND layout = ?" if layout else "")
    params = [machine] + ([layout] if layout else [])
    sql = f"""
      SELECT * FROM (
        SELECT cell, layout, death_q, threads, N, ns_particle, achieved_bw_gbs,
               row_number() OVER (PARTITION BY N, death_q, threads
                                   ORDER BY ns_particle) AS rk
        FROM (
          SELECT cell, layout, death_q, threads, N,
            min(ns_particle) AS ns_particle, min(achieved_bw_gbs) AS achieved_bw_gbs
          FROM report WHERE {where}
          GROUP BY cell, layout, death_q, threads, N
        )
      ) WHERE rk <= 3 ORDER BY threads, N, death_q, rk"""
    return sql, params


def teaser(md_path):
    """One-line Intent extract from a cell .md, for the featured-cell list."""
    if not os.path.exists(md_path):
        return ""
    md = open(md_path).read()
    import re
    m = re.search(r"## Intent\s*\n(.+?)(\n## |\Z)", md, re.S)
    if not m:
        return ""
    txt = re.sub(r"[`*]", "", m.group(1)).strip().replace("\n", " ")
    return txt[:160]


# ---- per-cell generation + verify gate (delegated to analyze_cell.py) ----

def layouts_in_data(con):
    return [r[0] for r in con.execute(
        "SELECT DISTINCT layout FROM runs ORDER BY layout").fetchall()]


def run_analyze(args, env=None):
    """Subprocess analyze_cell.py under the venv; stream stderr."""
    cmd = [PY, ANALYZE] + args
    r = subprocess.run(cmd, cwd=ROOT, env={**os.environ, **(env or {})})
    return r.returncode


def generate_cell_bundles(layouts, force):
    """Per layout: analyze_cell.py <L> [--force]. Resume-skips cells whose .md
    exists (default); --force regenerates all narratives."""
    flag = ["--force"] if force else []
    for L in layouts:
        print(f"== per-cell bundles: {L} ==", file=sys.stderr)
        run_analyze([L] + flag)


def verify_layout(L, machine_hint=None):
    """Run analyze_cell.py <L> --verify --verify-json <tmp>; return {cell: {...}}."""
    with tempfile.NamedTemporaryFile("w+", suffix=".json", delete=False) as f:
        path = f.name
    try:
        run_analyze([L, "--verify", "--verify-json", path])
        return json.load(open(path))
    except Exception as e:
        print(f"  verify failed for {L}: {e}", file=sys.stderr)
        return {}
    finally:
        os.unlink(path)


def retry_cell(cell):
    """One retry at a higher token budget (covers truncation + fresh re-roll
    for hallucination)."""
    print(f"  retry (MAX_TOKENS={RETRY_MAX_TOKENS}): {cell}", file=sys.stderr)
    run_analyze([cell, "--force"], env={"MAX_TOKENS": RETRY_MAX_TOKENS})


def run_gate(layouts):
    """Verify → retry FAILs once → re-verify those → return {cell: {...}}
    with final statuses. Nonzero-failing cells are NOT regenerated again —
    they keep their (best-effort) narrative, marked unverified."""
    final = {}
    for L in layouts:
        res = verify_layout(L)
        fails = [c for c, v in res.items() if v["status"] == "FAIL"]
        for c in fails:
            retry_cell(c)
        if fails:
            # re-verify just the retried cells, one per call (single-cell verify)
            for c in fails:
                res[c] = verify_layout(c).get(c, res[c])
        final.update(res)
    n_fail = sum(1 for v in final.values() if v["status"] == "FAIL")
    n_miss = sum(1 for v in final.values() if v["status"] == "MISS")
    print(f"== gate: {len(final)} cells, {n_fail} FAIL, {n_miss} MISS ==", file=sys.stderr)
    return final, n_fail


def inject_verified(machine, layout, verify_results):
    """Stamp `verified` + `verify_errors` into each cell .json so the SPA can
    banner unverified narratives. (Additive; analyze_cell.py owns the rest of
    the schema and rewrites the .json each run — this runs after.)"""
    base = os.path.join(OUT, machine, layout)
    for cell, v in verify_results.items():
        if cell.split(".")[0] != layout:
            continue
        strat = cell.split(".", 1)[1]
        jpath = os.path.join(base, f"{strat}.json")
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


# ---- aggregation bundles (machines / overview / layout) + markdown ----

def build_machines_index(con):
    os.makedirs(OUT, exist_ok=True)
    mids = [r[0] for r in con.execute(
        "SELECT DISTINCT machine_id FROM hardware ORDER BY machine_id").fetchall()]
    mlist = []
    for mid in mids:
        hw = json.load(open(os.path.join(DATA, mid, "hardware.json")))
        layouts = distinct(con, "layout", mid)
        m = {k: hw.get(k) for k in ("machine_id", "cpu", "streaming_bw_gbs",
             "l1dcachesize", "l2cachesize", "l3cachesize", "cachelinesize",
             "logicalcpu", "memsize_bytes")}
        m["layouts"] = layouts
        mlist.append(m)
    json.dump({"machines": mlist}, open(os.path.join(OUT, "machines.json"), "w"), indent=2)

    # analysis/README.md — the machine index (the only honest cross-machine view)
    def kb(v): return f"{v // 1024} KB" if v else "—"
    def mb(v): return f"{v / 1048576:.0f} MB" if v else "—"
    lines = ["# Analysis — machine index", ""]
    lines.append("The derived analysis layer, rebuilt by `scripts/build_report.py`. "
                 "Raw data lives in `experiments/data/<machine_id>/`; this tree is the "
                 "browsable + machine-readable reading of it. Open `experiments/report.html` "
                 "for the interactive SPA (machine- + thread-group-scoped, three-tier "
                 "drill-down).")
    lines.append("")
    lines.append("The only honest cross-machine view: each machine's hardware facts side "
                 "by side. Absolute ns/p across microarchitectures is meaningless; "
                 "normalized comparison (% of ceiling, which blueprint wins) is a "
                 "Phase-3 deliverable, not built here.")
    lines.append("")
    lines.append("| machine_id | cpu | streaming BW | L1d | L2 | L3 | layouts |")
    lines.append("|---|---|---|---|---|---|---|")
    for m in mlist:
        lines.append(f"| [`{m['machine_id']}`]({m['machine_id']}/) | {m['cpu']} | "
                     f"{m['streaming_bw_gbs']} GB/s | {kb(m['l1dcachesize'])} | "
                     f"{mb(m['l2cachesize'])} | {m['l3cachesize'] or '—'} | "
                     f"{', '.join(m['layouts'])} |")
    lines.append("")
    lines.append("Per machine: `<machine_id>/README.md` (overview) → "
                 "`<machine_id>/<L>/README.md` (layout) → "
                 "`<machine_id>/<L>/<cell>.md` (the per-cell narrative).")
    open(os.path.join(OUT, "README.md"), "w").write("\n".join(lines) + "\n")
    print(f"  wrote analysis/README.md + analysis/machines.json ({len(mlist)} machine(s))",
          file=sys.stderr)
    return mlist


def build_overview(con, mid):
    hw = json.load(open(os.path.join(DATA, mid, "hardware.json")))
    layouts = distinct(con, "layout", mid)
    deaths = distinct(con, "death_q", mid)
    nvals = distinct(con, "N", mid)
    threads = distinct(con, "threads", mid)
    champs = rows(con, *champs_sql(mid))
    mentry = {k: hw.get(k) for k in ("machine_id", "cpu", "streaming_bw_gbs",
              "l1dcachesize", "l2cachesize", "l3cachesize", "cachelinesize",
              "logicalcpu", "memsize_bytes")}
    overview = {**mentry, "layouts": layouts, "death_rates": deaths,
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
    lines.append(f"Layouts measured: {', '.join(f'[{L}]({L}/)' for L in layouts)}.")
    lines.append("")
    lines.append(f"## Winners (top-3) (T={default_t})")
    lines.append("")
    lines.append(_grid_md([c for c in champs if c["threads"] == default_t], nvals, deaths))
    open(os.path.join(OUT, mid, "README.md"), "w").write("\n".join(lines) + "\n")
    print(f"  wrote analysis/{mid}/README.md + overview.json", file=sys.stderr)


def build_layout_bundle(con, mid, L):
    hw = json.load(open(os.path.join(DATA, mid, "hardware.json")))
    deaths = distinct(con, "death_q", mid, L)
    nvals = distinct(con, "N", mid, L)
    threads = distinct(con, "threads", mid, L)
    champs = rows(con, *champs_sql(mid, L))
    cells_all = sorted({r[0] for r in con.execute(
        "SELECT DISTINCT cell FROM report WHERE machine_id=? AND layout=?", [mid, L]).fetchall()})
    default_t = threads[0] if threads else 1
    featured = []
    for r in champs:
        if r["rk"] == 1 and r["threads"] == default_t:
            c = r["cell"]
            if not any(f["cell"] == c for f in featured):
                strat = c.split(".", 1)[1]
                featured.append({"cell": c, "ns": round(r["ns_particle"], 2),
                                 "teaser": teaser(os.path.join(OUT, mid, L, f"{strat}.md"))})
    lb = {"machine_id": mid, "layout": L, "death_rates": deaths, "n_values": nvals,
          "thread_groups": threads, "streaming_bw_gbs": hw["streaming_bw_gbs"],
          "memory_layout": LAYOUT_MEMORY.get(L, ""), "champions": champs,
          "cells": cells_all, "featured": featured}
    os.makedirs(os.path.join(OUT, mid, L), exist_ok=True)
    json.dump(lb, open(os.path.join(OUT, mid, L, "layout.json"), "w"), indent=2)

    lines = [f"# Layout {L} on {hw['cpu']} (`{mid}`)", ""]
    lines.append(f"## Champion grid (T={default_t})")
    lines.append("")
    lines.append(_grid_md([c for c in champs if c["threads"] == default_t], nvals, deaths))
    lines.append("")
    lines.append("## Featured cells")
    lines.append("")
    if featured:
        for f in featured:
            strat = f["cell"].split(".", 1)[1]
            t = f" — {f['teaser']}…" if f["teaser"] else ""
            lines.append(f"- **[{f['cell']}]({strat}.md)** — {f['ns']} ns/p{t}")
    else:
        lines.append("_(no featured cells)_")
    lines.append("")
    lines.append("## All cells")
    lines.append("")
    for c in cells_all:
        strat = c.split(".", 1)[1]
        lines.append(f"- [{c}]({strat}.md)")
    open(os.path.join(OUT, mid, L, "README.md"), "w").write("\n".join(lines) + "\n")
    print(f"  wrote analysis/{mid}/{L}/README.md + layout.json "
          f"({len(cells_all)} cells)", file=sys.stderr)


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
            celltxt = []
            for rk in (1, 2, 3):
                c = byk.get((n, d, rk))
                if c:
                    strat = c["cell"].split(".", 1)[1]
                    celltxt.append(f"[{strat}]({strat}.md) {c['ns_particle']:.2f}")
            row.append("<br>".join(celltxt) or "—")
        out.append("| " + " | ".join(row) + " |")
    return "\n".join(out)


def build_grid(con, mid):
    """grid.json — every cell's best (min-ns) trial per (N, death_q, threads).
    Lets the SPA rank ALL cells at any (machine, threads, N, death_q) intersection
    with one fetch, instead of loading each per-cell bundle."""
    hw = json.load(open(os.path.join(DATA, mid, "hardware.json")))
    nvals = distinct(con, "N", mid)
    deaths = distinct(con, "death_q", mid)
    tgroups = distinct(con, "threads", mid)
    cells = [r[0] for r in con.execute(
        "SELECT DISTINCT cell FROM report WHERE machine_id=? ORDER BY cell", [mid]).fetchall()]
    pts = rows(con, """
        SELECT cell, N, death_q, threads, ns_particle, achieved_bw_gbs FROM (
          SELECT cell, N, death_q, threads, ns_particle, achieved_bw_gbs,
                 row_number() OVER (PARTITION BY cell, N, death_q, threads
                                    ORDER BY ns_particle) AS rn
          FROM report WHERE machine_id = ?
        ) WHERE rn = 1
        ORDER BY cell, N, death_q, threads""", [mid])
    grid = {"machine_id": mid, "streaming_bw_gbs": hw["streaming_bw_gbs"],
            "n_values": nvals, "death_rates": deaths, "thread_groups": tgroups,
            "cells": cells, "points": pts}
    json.dump(grid, open(os.path.join(OUT, mid, "grid.json"), "w"), indent=2)
    print(f"  wrote analysis/{mid}/grid.json ({len(pts)} points, {len(cells)} cells)",
          file=sys.stderr)


def render_queries(con):
    """The canonical SQL (documentary): the global top-3 + the layout top-K,
    both partitioned by threads (decision 8)."""
    sql = """-- Canonical queries for the analysis bundles.
-- Champions are partitioned by `threads` (decision 8): a parallel cell's
-- T=10 run and a serial cell's T=1 run never share a podium. min ns_particle
-- across trials; one row per (N, death_q, threads).

-- Global top-3 per (N, death_q, threads) on ONE machine:
WITH ranked AS (
  SELECT cell, layout, death_q, threads, N,
    min(ns_particle) AS ns_particle, min(achieved_bw_gbs) AS achieved_bw_gbs,
    row_number() OVER (PARTITION BY N, death_q, threads ORDER BY min(ns_particle)) AS rk
  FROM report
  WHERE machine_id = '<machine_id>'           -- :scope
  GROUP BY cell, layout, death_q, threads, N
)
SELECT N, death_q, threads, rk, cell, layout,
       round(ns_particle, 3) AS ns_particle,
       round(achieved_bw_gbs, 2) AS achieved_bw_gbs
FROM ranked WHERE rk <= 3 ORDER BY threads, N, death_q, rk;

-- Same, scoped to ONE layout (add: AND layout = '<L>').
"""
    open(os.path.join(OUT, "queries.sql"), "w").write(sql)
    print(f"  wrote analysis/queries.sql", file=sys.stderr)


# ---- main ----

def main():
    argv = [a for a in sys.argv[1:] if not a.startswith("-")]
    no_cells = "--no-cells" in sys.argv
    force = "--force" in sys.argv
    verify_only = "--verify-only" in sys.argv
    only_layout = argv[0] if argv else None

    con = duckdb.connect()
    load(con)
    n_runs = con.execute("SELECT count(*) FROM runs").fetchone()[0]
    mids = [r[0] for r in con.execute(
        "SELECT DISTINCT machine_id FROM hardware ORDER BY machine_id").fetchall()]
    print(f"loaded {n_runs} runs across {mids}", file=sys.stderr)

    layouts = layouts_in_data(con)
    if only_layout:
        layouts = [L for L in layouts if L == only_layout]

    # 1. per-cell bundles (delegated to analyze_cell.py via subprocess)
    if not verify_only and not no_cells:
        generate_cell_bundles(layouts, force)

    # 2. verify gate: verify -> retry FAILs once -> re-verify. Final per-cell
    #    status + fail count. (Q2: warn+mark+nonzero; report still written.)
    gate_results, n_fail = (run_gate(layouts) if not no_cells else ({}, 0))

    # 3. stamp verified status into each cell .json (SPA banners unverified)
    for mid in mids:
        for L in layouts:
            if distinct(con, "cell", mid, L):
                inject_verified(mid, L, gate_results)

    # 4. aggregation bundles + markdown tree
    build_machines_index(con)
    for mid in mids:
        build_overview(con, mid)
        build_grid(con, mid)
        for L in distinct(con, "layout", mid):
            if only_layout and L != only_layout:
                continue
            build_layout_bundle(con, mid, L)
    render_queries(con)

    print("done.", file=sys.stderr)
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
