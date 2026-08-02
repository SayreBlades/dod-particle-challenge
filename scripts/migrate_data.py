#!/usr/bin/env python3
"""One-time migration: convert the old per-run-dir CSV data layout into the
new host-partitioned JSONL layout (refactor §6.7).

Old:  experiments/data/L1/<run-id>/{runs.csv, checks.csv, pmc_rollup.csv,
                                hardware.json, meta.json}
New:  experiments/data/<machine_id>/{runs.jsonl, checks.jsonl, pmc.jsonl,
                                     hardware.json}

Each migrated row is enriched to the §6.2 schema: provenance from meta.json
(ts_utc, git_sha, git_branch, zig_version, machine_id, host) + the static
cell_decl axes (blueprint, ordering, intermediates, golden_class,
halide_expressible) parsed from the generated manifest
(experiments/cells/L1.md). source_hash is null for migrated rows
(historical; recomputing against the old git sha is fiddly — new rows from
collect.sh carry the real hash).

Append-only: safe to re-run (will duplicate rows unless --clean is passed
to first remove the host jsonl targets). Default: append, warn on duplicates.

Usage:
    scripts/migrate_data.py                  # migrate all old run dirs
    scripts/migrate_data.py --clean          # wipe host jsonl targets first
    scripts/migrate_data.py --dry-run        # show counts, write nothing
"""
import csv
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "experiments", "data")
MANIFEST = os.path.join(ROOT, "experiments", "cells", "L1.md")


def parse_manifest(path):
    """Parse experiments/cells/L1.md into {cell_name: {static axes}}.
    Each section is `## <cell>` followed by a ``` block of `key: value` lines."""
    cells = {}
    text = open(path, encoding="utf-8").read()
    # Sections: ## <name> then a fenced ``` block.
    for m in re.finditer(r"^## (\S+)\s*\n```\n(.*?)\n```", text, re.MULTILINE | re.DOTALL):
        name = m.group(1)
        block = m.group(2)
        d = {}
        for line in block.splitlines():
            if ":" in line:
                k, _, v = line.partition(":")
                d[k.strip()] = v.strip()
        # blueprint line: "B5  (math+decide+respawn+render)" -> "B5"
        bp = d.get("blueprint", "").split(" ")[0]
        cells[name] = {
            "layout": d.get("layout", ""),
            "blueprint": bp,
            "ordering": d.get("ordering", ""),
            "intermediates": d.get("intermediates", ""),
            "golden_class": d.get("golden", ""),
            "halide_expressible": d.get("halide_expressible", ""),
        }
    return cells


def host_from_machine_id(mid):
    """minibits-b7641c0e -> minibits"""
    return mid.split("-", 1)[0] if "-" in mid else mid


def migrate(dry_run=False, clean=False):
    cells = parse_manifest(MANIFEST)
    print(f"manifest: {len(cells)} cells parsed from {MANIFEST}", file=sys.stderr)

    old_layout_dir = os.path.join(DATA, "L1")
    if not os.path.isdir(old_layout_dir):
        print(f"no old run dirs at {old_layout_dir} — nothing to migrate.", file=sys.stderr)
        return

    # Group target paths by machine_id.
    targets = {}  # machine_id -> {runs, checks, pmc, hw}

    for run_id in sorted(os.listdir(old_layout_dir)):
        run_dir = os.path.join(old_layout_dir, run_id)
        if not os.path.isdir(run_dir):
            continue
        meta_path = os.path.join(run_dir, "meta.json")
        if not os.path.isfile(meta_path):
            print(f"  skip {run_id}: no meta.json", file=sys.stderr)
            continue
        meta = json.load(open(meta_path))
        mid = meta["machine_id"]
        host = host_from_machine_id(mid)
        ts = meta.get("timestamp_utc", "")
        git_sha = meta.get("git_sha", "")
        git_branch = meta.get("git_branch", "")
        zig_version = meta.get("zig_version", "")
        layout = meta.get("layout", "L1")

        if mid not in targets:
            host_dir = os.path.join(DATA, mid)
            os.makedirs(host_dir, exist_ok=True)
            t = {
                "runs": os.path.join(host_dir, "runs.jsonl"),
                "checks": os.path.join(host_dir, "checks.jsonl"),
                "pmc": os.path.join(host_dir, "pmc.jsonl"),
                "hw": os.path.join(host_dir, "hardware.json"),
            }
            if clean and not dry_run:
                for p in (t["runs"], t["checks"], t["pmc"]):
                    if os.path.exists(p):
                        os.remove(p)
            targets[mid] = t
        t = targets[mid]

        # hardware.json: copy from the run dir if the host's doesn't exist.
        hw_src = os.path.join(run_dir, "hardware.json")
        if os.path.isfile(hw_src) and not os.path.exists(t["hw"]) and not dry_run:
            with open(hw_src) as f:
                hw = json.load(f)
            with open(t["hw"], "w") as f:
                json.dump(hw, f, indent=2, sort_keys=True)
                f.write("\n")
            print(f"  wrote {t['hw']}", file=sys.stderr)

        n_runs = n_checks = n_pmc = 0

        # runs.csv -> runs.jsonl
        runs_csv = os.path.join(run_dir, "runs.csv")
        if os.path.isfile(runs_csv):
            with open(runs_csv) as f:
                for row in csv.DictReader(f):
                    cell = row["cell"]
                    cd = cells.get(cell, {})
                    out = {
                        "run_id": row["run_id"], "ts_utc": ts, "host": host,
                        "machine_id": mid, "layout": layout, "cell": cell,
                        "source_hash": None, "git_sha": git_sha,
                        "git_branch": git_branch, "zig_version": zig_version,
                        "death_q": _float(row["death_q"]),
                        "threads": int(row["threads"]),
                        "N": int(row["N"]),
                        "bytes_per_particle": int(row["bytes_per_particle"]),
                        "trial": int(row["trial"]),
                        "ns_frame": _float(row["ns_frame"]),
                        "ns_particle": _float(row["ns_particle"]),
                        "blueprint": cd.get("blueprint", ""),
                        "ordering": cd.get("ordering", ""),
                        "intermediates": cd.get("intermediates", ""),
                        "golden_class": cd.get("golden_class", ""),
                        "halide_expressible": cd.get("halide_expressible", ""),
                    }
                    if not dry_run:
                        with open(t["runs"], "a") as wf:
                            wf.write(json.dumps(out) + "\n")
                    n_runs += 1

        # checks.csv -> checks.jsonl
        checks_csv = os.path.join(run_dir, "checks.csv")
        if os.path.isfile(checks_csv):
            with open(checks_csv) as f:
                for row in csv.DictReader(f):
                    out = {
                        "run_id": row["run_id"], "ts_utc": ts, "machine_id": mid,
                        "layout": layout, "cell": row["cell"],
                        "death_q": _float(row["death_q"]), "source_hash": None,
                        "git_sha": git_sha,
                        "checked": "PASS" if "PASS" in row["checked"] else "FAIL",
                    }
                    if not dry_run:
                        with open(t["checks"], "a") as wf:
                            wf.write(json.dumps(out) + "\n")
                    n_checks += 1

        # pmc_rollup.csv -> pmc.jsonl
        pmc_csv = os.path.join(run_dir, "pmc_rollup.csv")
        if os.path.isfile(pmc_csv):
            with open(pmc_csv) as f:
                for row in csv.DictReader(f):
                    out = {
                        "run_id": run_id, "ts_utc": ts, "machine_id": mid,
                        "layout": layout, "cell": row["cell"],
                        "N": int(row["N"]), "death_q": _float(row["death_q"]),
                        "trial": int(row.get("trial", 0)), "source_hash": None,
                        "git_sha": git_sha, "cycles": int(row["cycles"]),
                        "useful_pct": _float(row.get("useful_pct")),
                        "processing_pct": _float(row.get("processing_pct")),
                        "delivery_pct": _float(row.get("delivery_pct")),
                        "discarded_pct": _float(row.get("discarded_pct")),
                    }
                    if not dry_run:
                        with open(t["pmc"], "a") as wf:
                            wf.write(json.dumps(out) + "\n")
                    n_pmc += 1

        print(f"  {run_id}: {n_runs} runs, {n_checks} checks, {n_pmc} pmc", file=sys.stderr)


def _float(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


if __name__ == "__main__":
    dry = "--dry-run" in sys.argv
    clean = "--clean" in sys.argv
    migrate(dry_run=dry, clean=clean)
