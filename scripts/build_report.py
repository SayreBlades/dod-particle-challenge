#!/usr/bin/env python3
"""Build the experiment report: read the host-partitioned JSONL data +
hardware.json, emit a chart-ready ``experiments/report/report.json`` (fetched
by the static ECharts dashboard), and write the per-layout champion-grid
markdown tables into each layout README's auto-generated block (§9).

The dashboard is pure-charts (ECharts from CDN) — no duckdb-wasm, no SQL
console, no parquet. All aggregation happens server-side in duckdb; the page
just renders the JSON. Re-run after every collect.

Usage:
    scripts/build_report.py                 # build report.json + refresh READMEs
    scripts/build_report.py --no-readme    # just the json
    scripts/build_report.py --no-json      # just the README grids (debug)
"""
import glob
import json
import os
import sys

import duckdb

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "experiments", "data")
REPORT = os.path.join(ROOT, "experiments", "report")


def layout_ids() -> list[str]:
    """Layout ids = the L<digits> directories under src/layouts/. The folder
    name IS the layout id, so there's no id->folder mapping to maintain."""
    import re
    base = os.path.join(ROOT, "src", "layouts")
    return sorted(d for d in os.listdir(base)
                  if re.fullmatch(r"L\d+", d) and os.path.isdir(os.path.join(base, d)))

# Regime bucketing (§9): small <=65K, mid 1M, large >=16M.
def regime(n):
    if n <= 65000:
        return "small"
    if n <= 1000000:
        return "mid"
    return "large"


def load_jsonl(con, kind):
    """Register all <host>/<kind>.jsonl files into a duckdb table named <kind>."""
    paths = sorted(glob.glob(os.path.join(DATA, "*", f"{kind}.jsonl")))
    if not paths:
        return 0
    union = " UNION ALL ".join(
        f"SELECT * FROM read_json_auto('{p}')" for p in paths
    )
    con.execute(f"CREATE TABLE {kind} AS {union}")
    return con.execute(f"SELECT count(*) FROM {kind}").fetchone()[0]


def build_report_table(con):
    """runs JOIN hardware + derived achieved_bw_gbs -> the `report` table
    every downstream (json + README grids) reads."""
    hw_paths = sorted(glob.glob(os.path.join(DATA, "*", "hardware.json")))
    if hw_paths:
        union = " UNION ALL ".join(
            f"SELECT * FROM read_json_auto('{p}')" for p in hw_paths
        )
        con.execute(f"CREATE TABLE hardware AS {union}")
    else:
        con.execute("CREATE TABLE hardware(machine_id VARCHAR, streaming_bw_gbs DOUBLE)")
    con.execute("""
        CREATE TABLE report AS
        SELECT r.*, h.streaming_bw_gbs,
               (r.bytes_per_particle * r.N / NULLIF(r.ns_frame, 0)) AS achieved_bw_gbs
        FROM runs r LEFT JOIN hardware h USING (machine_id)
    """)


def rows(con, sql):
    cur = con.execute(sql)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def build_json(con):
    """Emit experiments/report/report.json — chart-ready datasets."""
    os.makedirs(REPORT, exist_ok=True)
    host = con.execute(
        "SELECT machine_id, streaming_bw_gbs FROM hardware ORDER BY machine_id LIMIT 1"
    ).fetchone()
    n_runs = con.execute("SELECT count(*) FROM runs").fetchone()[0]
    has_pmc = con.execute("SELECT count(*) > 0 FROM pmc").fetchone()[0]
    has_checks = con.execute("SELECT count(*) > 0 FROM checks").fetchone()[0]

    data = {
        "meta": {
            "machine_id": host[0] if host else None,
            "streaming_bw_gbs": host[1] if host else None,
            "n_runs": n_runs,
            "n_cells": con.execute("SELECT count(DISTINCT cell) FROM runs").fetchone()[0],
            "layouts": [r[0] for r in con.execute(
                "SELECT DISTINCT layout FROM runs ORDER BY layout").fetchall()],
            "death_rates": [r[0] for r in con.execute(
                "SELECT DISTINCT death_q FROM runs ORDER BY death_q").fetchall()],
            "n_values": [r[0] for r in con.execute(
                "SELECT DISTINCT N FROM runs ORDER BY N").fetchall()],
            "has_pmc": has_pmc,
            "has_checks": has_checks,
        },
        # Champion grid: fastest cell per (layout, regime, death_q),
        # min ns/particle across trials + threads (best-case per cell).
        "champions": rows(con, f"""
            WITH ranked AS (
              SELECT layout, death_q,
                CASE WHEN N<=65000 THEN 'small' WHEN N<=1000000 THEN 'mid' ELSE 'large' END AS regime,
                cell, min(ns_particle) AS ns_particle, min(achieved_bw_gbs) AS achieved_bw_gbs,
                row_number() OVER (PARTITION BY layout,
                  CASE WHEN N<=65000 THEN 'small' WHEN N<=1000000 THEN 'mid' ELSE 'large' END,
                  death_q ORDER BY min(ns_particle)) AS rk
              FROM report GROUP BY layout, regime, death_q, cell
            )
            SELECT layout, regime, death_q, cell,
                   round(ns_particle, 3) AS ns_particle,
                   round(achieved_bw_gbs, 2) AS achieved_bw_gbs
            FROM ranked WHERE rk = 1
            ORDER BY layout, regime, death_q
        """),
        # Performance landscape: ns/particle vs N per cell, per death_q.
        "landscape": rows(con, """
            SELECT cell, death_q, N, round(min(ns_particle), 3) AS ns_particle
            FROM report GROUP BY cell, death_q, N
            ORDER BY cell, death_q, N
        """),
        # Achieved bandwidth vs N per cell (min across trials/threads/death).
        "bandwidth": rows(con, """
            SELECT cell, N, round(min(achieved_bw_gbs), 2) AS achieved_bw_gbs
            FROM report GROUP BY cell, N ORDER BY cell, N
        """),
    }
    if has_pmc:
        data["pmc"] = rows(con, """
            SELECT cell, N, death_q, trial, cycles,
                   useful_pct, processing_pct, delivery_pct, discarded_pct
            FROM pmc ORDER BY cell, N, death_q
        """)
    if has_checks:
        # Latest check verdict per (cell, death_q).
        data["checks"] = rows(con, """
            SELECT cell, death_q, checked FROM (
              SELECT cell, death_q, checked,
                     row_number() OVER (PARTITION BY cell, death_q ORDER BY checked DESC) AS rk
              FROM checks
            ) WHERE rk = 1 ORDER BY cell, death_q
        """)

    out = os.path.join(REPORT, "report.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f)
    print(f"  wrote {out} ({len(data['champions'])} champion rows, "
          f"{len(data['landscape'])} landscape rows)", file=sys.stderr)
    return data


def champion_grid_sql(layout):
    """The canonical champion-grid SQL for one layout: the FASTEST cell per
    (regime, death_q). Embedded verbatim in the layout README (§9) so the
    README is self-contained; the live source is experiments/report/queries.sql."""
    return f"""-- Champion grid for {layout}: the fastest cell per (regime, death_q).
-- regime: small <=65K, mid 262K-1M, large >=16M. min ns/particle across trials.
WITH ranked AS (
  SELECT cell, death_q,
    CASE WHEN N <= 65000 THEN 'small' WHEN N <= 1000000 THEN 'mid' ELSE 'large' END AS regime,
    min(ns_particle) AS ns_particle,
    min(achieved_bw_gbs) AS achieved_bw_gbs,
    row_number() OVER (PARTITION BY
      CASE WHEN N <= 65000 THEN 'small' WHEN N <= 1000000 THEN 'mid' ELSE 'large' END,
      death_q
      ORDER BY min(ns_particle)) AS rk
  FROM report
  WHERE layout = '{layout}' AND machine_id = (
    SELECT machine_id FROM report WHERE layout='{layout}'
    GROUP BY machine_id ORDER BY count(*) DESC LIMIT 1)
  GROUP BY cell, death_q, regime
)
SELECT regime, death_q, cell,
       round(ns_particle, 3) AS ns_particle,
       round(achieved_bw_gbs, 2) AS achieved_bw_gbs,
       (SELECT streaming_bw_gbs FROM hardware LIMIT 1) AS streaming_bw_gbs
FROM ranked WHERE rk = 1
ORDER BY regime, death_q"""


def render_readme_grids(con):
    """Write the champion-grid markdown table into each layout README's
    auto-generated block (§9)."""
    for layout in layout_ids():
        readme = os.path.join(ROOT, "src", "layouts", layout, "README.md")
        if not os.path.isfile(readme):
            continue
        sql = champion_grid_sql(layout)
        try:
            rows = con.execute(sql).fetchall()
            cols = [d[0] for d in con.execute(sql).description]
        except Exception as e:
            print(f"  skip {layout} README grid: {e}", file=sys.stderr)
            continue
        lines = ["| " + " | ".join(cols) + " |",
                 "|" + "|".join(["---"] * len(cols)) + "|"]
        for r in rows:
            lines.append("| " + " | ".join(str(x) for x in r) + " |")
        block = (
            "<!-- AUTO-GENERATED by scripts/build_report.py — do not edit. -->\n"
            "## Champion grid\n\n"
            "The fastest cell per (regime, death_q), min ns/particle across "
            "trials. The canonical SQL lives in "
            "`experiments/report/queries.sql`; reproduced here verbatim so the "
            "README is self-contained:\n\n"
            "```sql\n" + sql + "\n```\n\n"
            + "\n".join(lines) + "\n"
            "<!-- /AUTO-GENERATED -->\n"
        )
        _replace_block(readme, block)
        print(f"  wrote champion grid into {readme} ({len(rows)} rows)", file=sys.stderr)


def _replace_block(path, block):
    """Replace the AUTO-GENERATED block in a README (or append if absent)."""
    text = open(path, encoding="utf-8").read()
    start = "<!-- AUTO-GENERATED by scripts/build_report.py"
    end = "<!-- /AUTO-GENERATED -->"
    if start in text and end in text:
        pre = text[: text.index(start)]
        post = text[text.index(end) + len(end):]
        text = pre + block + post
    else:
        text = text.rstrip() + "\n\n" + block
    open(path, "w", encoding="utf-8").write(text)


def main():
    no_json = "--no-json" in sys.argv
    no_readme = "--no-readme" in sys.argv
    con = duckdb.connect()
    n_runs = load_jsonl(con, "runs")
    n_checks = load_jsonl(con, "checks")
    n_pmc = load_jsonl(con, "pmc")
    print(f"loaded: {n_runs} runs, {n_checks} checks, {n_pmc} pmc", file=sys.stderr)
    build_report_table(con)
    if not no_json:
        build_json(con)
    if not no_readme:
        render_readme_grids(con)


if __name__ == "__main__":
    main()
