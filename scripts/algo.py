#!/usr/bin/env python3
"""algo.py — the disassembly atomic.

Rebuilds an algorithm's ReleaseFast binary and captures the disassembly of its
`step` function (otool for clean arm64 + llvm-objdump --source for source-line
attribution) into experiments/data/<machine_id>/<algo>.json — the asm source of
truth, captured once at collection time so `make report` needs no toolchain.

The bundle is a MEASUREMENT of the compiled artifact (a deterministic function
of source + target + opts), keyed by source_hash. Skipped if the bundle's
source_hash already matches the current source (--force rebuilds).

The disassembly functions here are the canonical home; analyze_algo.py will
import them (Phase E) instead of carrying its own copy.

Usage:
    scripts/algo.py ML01.AF01.LP1-autovec.LP2-simple           # write <algo>.json
    scripts/algo.py ML01.AF01.LP1-autovec.LP2-simple --force    # rebuild even if current
"""
from __future__ import annotations
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "experiments", "data")
ASM_CACHE = os.path.join(ROOT, ".scratch", "asm_cache")
ADDR = re.compile(r"^[0-9a-f]{16}$")
OBJDUMP = ["xcrun", "llvm-objdump"]


def sh(cmd):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True).stdout


def split_algo(algo):
    mem_layout, algo_part = algo.split(".", 1)
    return mem_layout, algo_part


def source_hash(algo):
    return sh([sys.executable, os.path.join(ROOT, "scripts", "algo_hash.py"), algo]).strip()


def machine_id():
    """The single host dir under data/ (one host per dir, as today)."""
    ids = [d for d in os.listdir(DATA) if os.path.isdir(os.path.join(DATA, d))]
    if len(ids) != 1:
        sys.exit(f"expected one machine under {DATA}, found {ids}; pass -M <id>")
    return ids[0]


# ---- assembly: build (cached) + disassemble step ----

def ensure_binary(algo, shash):
    mem_layout, algo_part = split_algo(algo)
    cache = os.path.join(ASM_CACHE, shash)
    binp = os.path.join(cache, "bin", f"{algo}.bench")
    if os.path.exists(binp):
        return binp, cache
    os.makedirs(cache, exist_ok=True)
    cmd = ["zig", "build", "-p", cache, f"-Dmem_layout={mem_layout}", f"-Dalgo={algo_part}",
           "-Dmode=bench", "-Doptimize=ReleaseFast"]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("build failed:\n" + (r.stderr or r.stdout)[-800:])
    return binp, cache


def step_symbol(algo_part):
    return f"_framework.sim.Strategy(layouts.ML01.data.Data,layouts.ML01.{algo_part}.H).step"


def disasm_step(binp, algo_part):
    sym = step_symbol(algo_part)
    nm = sh(["nm", binp])
    if sym not in nm:
        return None
    ot = sh(["otool", "-tV", binp]).splitlines()
    start = next((i + 1 for i, l in enumerate(ot)
                  if l.startswith("_") and l.rstrip().endswith(":") and sym in l), None)
    if start is None:
        return None
    body = []
    for l in ot[start:]:
        if l.startswith("_") and l.rstrip().endswith(":"):
            break
        body.append(l)
    return body


def histogram(body):
    from collections import Counter
    base = Counter()
    vector = 0
    for l in body:
        t = l.split()
        if len(t) < 2 or not ADDR.match(t[0]):
            continue
        m = t[1]
        base[m.split(".")[0]] += 1
        if "." in m and re.match(r"(2|3|4|8|16)[sdh]", m.split(".", 1)[1]):
            vector += 1
    return dict(base.most_common()), vector


# ---- godbolt source↔asm attribution ----
# The same ReleaseFast codegen, built strip=false + dsymutil, lets llvm-objdump
# --source attribute each asm address to its source line. llvm-objdump garbles
# the Mach-O arm64 *decode* (<unknown>), so we take ADDRESSES + SOURCE from it
# and the clean asm from otool, joined on address.

def ensure_debug_binary(algo, shash):
    """Build the strip=false (same ReleaseFast codegen) variant + its dSYM.
    Cached at asm_cache/<shash>/bin-debug/. Returns (binp, dwarffile) or (None,None)."""
    mem_layout, _ = split_algo(algo)
    cache = os.path.join(ASM_CACHE, shash)
    dbgprefix = os.path.join(cache, "bin-debug")
    binp = os.path.join(dbgprefix, "bin", f"{algo}.bench")
    dwarffile = os.path.join(dbgprefix, "dod.dSYM", "Contents", "Resources", "DWARF", f"{algo}.bench")
    if os.path.exists(dwarffile):
        return binp, dwarffile
    cmd = ["zig", "build", "-p", dbgprefix, f"-Dmem_layout={mem_layout}", f"-Dalgo={algo.split('.',1)[1]}",
           "-Dmode=bench", "-Doptimize=ReleaseFast", "-Dkeep-debug=true"]
    if subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True).returncode != 0:
        return None, None
    subprocess.run(["dsymutil", binp, "-o", os.path.join(dbgprefix, "dod.dSYM")],
                   capture_output=True, text=True)
    return (binp, dwarffile) if os.path.exists(dwarffile) else (None, None)


def step_addr_range(binp, algo_part):
    """(start, stop) of the step symbol via nm."""
    sym = step_symbol(algo_part)
    start, addrs = None, []
    for l in sh(["nm", binp]).splitlines():
        p = l.split()
        if len(p) < 2:
            continue
        if p[-1] == sym:
            start = int(p[0], 16)
        if p[1] in ("t", "T"):
            addrs.append(int(p[0], 16))
    if start is None:
        return None, None
    addrs.sort()
    return start, next((a for a in addrs if a > start), start + 0x800)


def source_map(dwarffile, start, stop):
    """{addr_int: source_line} from llvm-objdump --source."""
    r = subprocess.run(OBJDUMP + ["--source", f"--start-address=0x{start:x}",
                                  f"--stop-address=0x{stop:x}", dwarffile],
                       capture_output=True, text=True)
    out, cur = {}, None
    for l in r.stdout.splitlines():
        s = l.strip()
        if s.startswith(";"):
            cur = s[1:].strip() or cur
        elif (m := re.match(r"^([0-9a-f]+):", s)):
            out[int(m.group(1), 16)] = cur
    return out


def algo_source(algo, groups):
    """The algo's own source file + a per-group map to line numbers in it."""
    try:
        import algo_hash
    except ImportError:
        return None
    path = algo_hash.algo_file_path(algo)
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return None
    textline = {}
    for i, s in enumerate(lines, 1):
        key = s.strip()
        if key and key not in textline:
            textline[key] = i
    group_lines = [textline.get((g.get("source") or "").strip()) for g in groups]
    return {"file": os.path.relpath(path, ROOT), "lines": lines, "group_lines": group_lines}


def reindent_sources(algo, groups):
    """Recover real indentation: match stripped source text to the @import closure."""
    try:
        import algo_hash
    except ImportError:
        return groups
    closure = algo_hash.walk_closure(algo_hash.algo_file_path(algo))
    lookup = {}
    for f in closure:
        try:
            for raw in open(f, encoding="utf-8"):
                s = raw.rstrip("\n")
                key = s.strip()
                if key and key not in lookup:
                    lookup[key] = s
        except OSError:
            continue
    for g in groups:
        key = (g.get("source") or "").strip()
        g["source"] = lookup.get(key, key)
    return groups


def attributed_asm(algo, shash, algo_part, otool_body):
    """Godbolt grouping [{source, asm:[...]}]. None if the debug build / toolchain
    is unavailable (SPA falls back to a flat listing)."""
    binp, dwarffile = ensure_debug_binary(algo, shash)
    if not binp:
        return None
    start, stop = step_addr_range(binp, algo_part)
    if start is None:
        return None
    smap = source_map(dwarffile, start, stop)
    if not smap:
        return None
    groups, cur_src, cur_asm = [], None, []
    for line in otool_body:
        t = line.split("\t")
        if len(t) < 2 or not ADDR.match(t[0]):
            continue
        src = smap.get(int(t[0], 16), cur_src)
        if src != cur_src and cur_asm:
            groups.append({"source": cur_src or "", "asm": cur_asm}); cur_asm = []
        cur_src = src
        cur_asm.append("\t".join(t[1:]).rstrip())
    if cur_asm:
        groups.append({"source": cur_src or "", "asm": cur_asm})
    return reindent_sources(algo, groups)


# ---- the bundle ----

def build_asm(algo, shash=None):
    """Build + disassemble; return the asm dict."""
    if shash is None:
        shash = source_hash(algo)
    _, algo_part = split_algo(algo)
    binp, _ = ensure_binary(algo, shash)
    body = disasm_step(binp, algo_part) or []
    hist, vec = histogram(body)
    asm = {"source_hash": shash, "symbol": step_symbol(algo_part),
           "n_instructions": len(body), "histogram": hist, "vector_insns": vec,
           "excerpt": "\n".join(body)}
    src = attributed_asm(algo, shash, algo_part, body)
    if src is not None:
        asm["source_attributed"] = src
        cs = algo_source(algo, src)
        if cs:
            asm["algo_source"] = cs
    return asm


def bundle_path(algo, m=None):
    if m is None:
        m = machine_id()
    return os.path.join(DATA, m, f"{algo}.json")


def write_bundle(algo, force=False, m=None):
    """Write data/<m>/<algo>.json. Skips if current source_hash matches."""
    shash = source_hash(algo)
    path = bundle_path(algo, m)
    if os.path.exists(path) and not force:
        try:
            existing = json.load(open(path))
        except Exception:
            existing = {}
        if existing.get("source_hash") == shash:
            print(f"  {algo}.json current (source_hash matches) — skip", file=sys.stderr)
            return path
    asm = build_asm(algo, shash)
    bundle = {"source_hash": shash, "asm": asm}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(bundle, f, indent=2)
        f.write("\n")
    print(f"  wrote {path}  ({asm['n_instructions']} insn)", file=sys.stderr)
    return path


def main():
    argv = sys.argv[1:]
    force = "--force" in argv
    argv = [a for a in argv if not a.startswith("-")]
    if not argv:
        sys.exit("usage: algo.py <algo> [--force]")
    write_bundle(argv[0], force=force)


if __name__ == "__main__":
    main()
