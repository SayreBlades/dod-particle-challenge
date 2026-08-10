#!/usr/bin/env python3
"""One-time migration: rename the L/B/w → ML/AF/LP terminology across the
committed JSONL data (the terminology refactor of optimization-framework.md).

Rewrites, in place, every experiments/data/<machine_id>/{runs,checks,pmc}.jsonl:
  - JSON keys:   cell -> algo,  layout -> mem_layout,  blueprint -> algo_fam
  - JSON values: cell name  L1.B1.w1-x.w2-y   -> ML01.AF01.LP1-x.LP2-y
                 layout id  L1                -> ML01
                 family id  B1                -> AF01
hardware.json is untouched (no cell/layout fields).

Idempotent: running twice is a no-op (rename_cell is a fixed point on already-
renamed names — no leading L/B/.w tokens remain to match). source_hash values
are left as-is; they will read as "stale" on the next collect (the rename moved
files, so every source_hash changes) — that just forces a re-bench, which is
expected. Skip *.bak* (gitignored backups).

Usage:
    scripts/migrate_names.py            # migrate all host dirs
    scripts/migrate_names.py --dry-run  # show counts, write nothing
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "experiments", "data")


def rename_cell(name: str) -> str:
    """L1.B1.w1-x.w2-y -> ML01.AF01.LP1-x.LP2-y (fixed point on already-renamed)."""
    name = re.sub(r'^L(\d+)(\.|$)', r'ML\1\2', name)        # L1(.|$) -> ML01
    name = re.sub(r'(^|\.)B(\d+)(\.|$)', r'\1AF\2\3', name)  # B1 / .B1 -> AF01
    name = re.sub(r'\.w(\d+)', r'.LP\1', name)               # .w1 -> .LP1
    return name


def rename_layout(layout: str) -> str:
    return re.sub(r'^L(\d+)$', r'ML\1', layout)


def rename_fam(fam: str) -> str:
    return re.sub(r'^B(\d+)$', r'AF\1', fam)


# old-key -> (new-key, value-transform)
KEY_MAP = {
    "cell": ("algo", rename_cell),
    "layout": ("mem_layout", rename_layout),
    "blueprint": ("algo_fam", rename_fam),
}


def migrate_row(row: dict) -> dict:
    out = {}
    for k, v in row.items():
        if k in KEY_MAP:
            new_k, xform = KEY_MAP[k]
            out[new_k] = xform(v) if isinstance(v, str) else v
        else:
            out[k] = v
    return out


def migrate_file(path: str, dry_run: bool) -> int:
    n = 0
    new_lines = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                new_lines.append(line)
                continue
            try:
                row = json.loads(line)
            except Exception:
                new_lines.append(line)  # leave unparseable lines untouched
                continue
            new_lines.append(json.dumps(migrate_row(row)))
            n += 1
    if not dry_run:
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(new_lines) + "\n")
    return n


def main() -> int:
    dry_run = "--dry-run" in sys.argv
    if not os.path.isdir(DATA):
        sys.exit(f"no data dir at {DATA}")
    total = 0
    for mid in sorted(os.listdir(DATA)):
        host = os.path.join(DATA, mid)
        if not os.path.isdir(host):
            continue
        for name in ("runs.jsonl", "checks.jsonl", "pmc.jsonl"):
            path = os.path.join(host, name)
            if not os.path.exists(path) or ".bak" in name:
                continue
            n = migrate_file(path, dry_run)
            total += n
            print(f"  {'[dry] ' if dry_run else ''}{mid}/{name}: {n} rows", file=sys.stderr)
    print(f"== migrated {total} rows across {DATA} ==", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
