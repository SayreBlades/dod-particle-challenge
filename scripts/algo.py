#!/usr/bin/env python3
"""algo.py — the disassembly atomic.

Rebuilds an algorithm's ReleaseFast binary and captures the disassembly of its
`step` function (otool for clean arm64, objdump for x86-64) into
experiments/data/<machine_id>/<algo>.json — the asm source of truth, captured
once at collection time so `make report` needs no toolchain.

SCHEMA v2 (report-v2.md §1): alongside the flat `excerpt` + `histogram`, the
bundle carries a structured per-instruction list (`insns`: address, mnemonic,
operands, class, branch-target index), DWARF **inline-chain** attribution
(`attribution.chains`, innermost-first per instruction, + the algo-file
call-site line per instruction), a deterministic loop digest (`loops`), and
decoded float immediates (`fconst`, arm64). Attribution comes from a debug
build with IDENTICAL codegen (strip=false + dsymutil on macOS; in-ELF DWARF on
Linux) via `atos -i` / `addr2line -i` — superseding the text-matching scheme
(26% coverage on the spike algo → 85%). Instruction classification is per-arch
(arm64 + x86-64); `vector_insns` counts SIMD correctly on both.

The bundle is a MEASUREMENT of the compiled artifact (a deterministic function
of source + target + opts), keyed by source_hash. Skipped if the bundle's
source_hash matches AND its asm schema is current (--force rebuilds).

Usage:
    scripts/algo.py ML01.AF02.LP1-autovec.LP2-simple           # write <algo>.json
    scripts/algo.py ML01.AF02.LP1-autovec.LP2-simple --force    # rebuild even if current
"""
from __future__ import annotations
import json, os, platform, re, struct, subprocess, sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "experiments", "data")
ASM_CACHE = os.path.join(ROOT, ".scratch", "asm_cache")
ADDR = re.compile(r"^[0-9a-f]{16}$")
IS_LINUX = platform.system() == "Linux"
OBJDUMP = ["objdump"] if IS_LINUX else ["xcrun", "llvm-objdump"]
ARCH = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x86_64", "amd64": "x86_64"}.get(
    platform.machine(), platform.machine())
ASM_SCHEMA = 2


def sh(cmd):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True).stdout


def split_algo(algo):
    mem_layout, algo_part = algo.split(".", 1)
    return mem_layout, algo_part


def source_hash(algo):
    return sh([sys.executable, os.path.join(ROOT, "scripts", "algo_hash.py"), algo]).strip()


def machine_id():
    """Return this host's machine_id (auto-detected, works with multi-machine data dirs)."""
    import hardware_json
    return hardware_json.detect()["machine_id"]


# ---- per-arch instruction classification -------------------------------------
# One source of truth: the bundle carries `cls` per instruction; the SPA and
# the LLM evidence consume it without re-classifying (report.js's old
# ARM-shaped classifier painted every x86 instruction "other").

_ARM_FP = frozenset("fmov fadd fsub fmul fdiv fmla fmls fmin fmax fneg fabs fsqrt fcmp fcsel "
                    "fcvt scvtf ucvtf fcvtzs fcvtns fcvtas frintm frintp frintz".split())
_ARM_VEC = frozenset("dup ext ins umov smov movi mvni ushr sshr shl usra ssra xtn tbl tbx "
                     "uzp1 uzp2 zip1 zip2 trn1 trn2 sqadd uqadd sqsub uqsub rev16 rev32 rev64".split())


def _arm_class(mnem: str) -> str:
    if re.fullmatch(r"ld[1-4]", mnem): return "vload"
    if re.fullmatch(r"st[1-4]", mnem): return "vstore"
    if mnem in ("ldp", "ldr", "ldur", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw"): return "load"
    if mnem in ("stp", "str", "stur", "strb", "strh"): return "store"
    if mnem in _ARM_FP: return "fp"
    if mnem in ("b", "bl", "br", "braa", "braaz", "ret"): return "branch"
    if re.fullmatch(r"b\.\w+", mnem) or mnem in ("cbz", "cbnz", "tbz", "tbnz"): return "branch"
    if mnem in ("cmp", "cmn", "tst", "ccmp", "ccmn"): return "cmp"
    if mnem in _ARM_VEC: return "vec"
    return "other"


_X86_LOADISH = frozenset("mov movzx movsx vmovss vmovsd vmovups vmovaps vmovdqa vmovdqu vmovd vmovq".split())
_X86_VEC_MEM = frozenset("vmovups vmovaps vmovdqa vmovdqu".split())
_X86_FP = re.compile(r"^(v?(add|sub|mul|div|min|max|sqrt|rcp|rsqrt|round|hadd|hsub|fmadd|fmsub|fnmadd)"
                     r"(231|132|213)?(ss|sd|ps|pd)|v?u?comis[sd]|v?comis[sd]|v?fma.*)$")
_X86_VECOP = re.compile(r"^(vbroadcast|vpshuf|vpunpck|vperm|vinsert|vextract|vpxor|vpor|vpand|vpandn|"
                        r"vpaddd|vpsub|vmovd|vmovq|vcvtsi2|vcvtt|vcvt|vround|vpslld|vpsrld)")


def _x86_class(mnem: str, ops: str) -> str:
    if mnem.startswith("j") or mnem in ("ret", "call", "loop", "jmp"): return "branch"
    if mnem in ("cmp", "test"): return "cmp"
    if mnem.startswith("cmov") or mnem.startswith("set"): return "cmp"
    if _X86_FP.match(mnem): return "fp"
    if _X86_VECOP.match(mnem): return "vec"
    if mnem in _X86_LOADISH and ("[" in ops):
        # intel syntax: dest is the FIRST operand — a bracket in it is a store
        first = ops.split(",")[0]
        is_store = "[" in first
        if is_store:
            return "vstore" if mnem in _X86_VEC_MEM else "store"
        return "vload" if mnem in _X86_VEC_MEM else "load"
    if mnem == "lea": return "other"
    return "other"


def classify_insn(mnem: str, ops: str, arch: str) -> str:
    base = mnem.split(".")[0].lower()
    return _arm_class(base) if arch == "arm64" else _x86_class(mnem.lower(), ops)


def is_vector_insn(mnem: str, ops: str, arch: str) -> bool:
    """SIMD-width check, per arch (drives `vector_insns` + the digest)."""
    if arch == "arm64":
        return "." in mnem and bool(re.match(r"(2|3|4|8|16)[sdh]", mnem.split(".", 1)[1]))
    m = mnem.lower()
    if m.endswith(("ps", "pd")):
        return True
    return bool(re.search(r"\b[xy]mm\d", ops, re.I))


def branch_target(mnem: str, ops: str, arch: str):
    """(hex_addr_int | None, external_symbol | None) for branch/call-class insns."""
    m = mnem.lower()
    is_branch = m in ("b", "bl", "br", "ret") or m.startswith("b.") or \
        m in ("cbz", "cbnz", "tbz", "tbnz") or m.startswith("j") or m in ("call", "jmp", "loop")
    if not is_branch:
        return None, None
    if arch == "arm64":
        hit = re.search(r"0x[0-9a-f]{6,}", ops)
        if hit:
            return int(hit.group(0), 16), None
        if m == "bl":
            return None, ops.strip() or None
        return None, None
    # x86 objdump intel: "10004de58 <_sym+0x30>" or "401223 <foo>"
    mm = re.match(r"\s*([0-9a-f]{5,})(?:\s+<([^>]+)>)?", ops)
    if mm:
        return int(mm.group(1), 16), mm.group(2)
    return None, None


# ---- assembly: build (cached) + disassemble step ----

def cache_dir(shash):
    # arch-suffixed: the asm cache is per (source, target); a repo holding two
    # machines' data must never reuse the other arch's binaries.
    return os.path.join(ASM_CACHE, f"{shash}-{ARCH}")


def ensure_binary(algo, shash):
    mem_layout, algo_part = split_algo(algo)
    cache = cache_dir(shash)
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
    # Mach-O prefixes every symbol with "_"; ELF (Linux) does not.
    sym = f"framework.sim.Strategy(layouts.ML01.data.Data,layouts.ML01.{algo_part}.H).step"
    return sym if IS_LINUX else "_" + sym


def disasm_step(binp, algo_part):
    if IS_LINUX:
        return disasm_step_linux(binp, algo_part)
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


# GNU objdump instruction line:  "  401120:\tpush   rbp" (intel syntax,
# --no-show-raw-insn). Normalized into the otool-ish tab form the parsers
# consume: "<addr16>\t<mnem>\t<ops>".
_OBJDUMP_INSN = re.compile(r"^\s*([0-9a-f]+):\s*(\S+)(?:\s+(.*))?$")


def disasm_step_linux(binp, algo_part):
    """Scoped objdump -d of the step symbol, via its nm address range."""
    start, stop = step_addr_range(binp, algo_part)
    if start is None:
        return None
    out = sh(["objdump", "-d", "-M", "intel", "--no-show-raw-insn",
              f"--start-address=0x{start:x}", f"--stop-address=0x{stop:x}", binp])
    body = []
    for l in out.splitlines():
        m = _OBJDUMP_INSN.match(l)
        if not m:
            continue  # file headers, blank lines, the symbol label
        addr, mnem, ops = m.group(1), m.group(2), (m.group(3) or "").strip()
        body.append(f"{int(addr, 16):016x}\t{mnem}\t{ops}")
    return body or None


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


def histogram(body):
    from collections import Counter
    base = Counter()
    for l in body:
        t = l.split("\t")
        if len(t) < 2 or not ADDR.match(t[0]):
            continue
        base[t[1].split(".")[0]] += 1
    return dict(base.most_common())


def count_vector(insns, arch):
    return sum(1 for i in insns if is_vector_insn(i["m"], i["o"], arch))


# ---- godbolt attribution v2: DWARF inline chains -----------------------------
# The same ReleaseFast codegen, built strip=false + dsymutil: every asm address
# carries its FULL inline chain (innermost frame first). `atos -i` on the dSYM
# (macOS) or `addr2line -i -C` (Linux) resolves the batch in one call.

def ensure_debug_binary(algo, shash):
    """Build the strip=false (same ReleaseFast codegen) variant + its dSYM.
    Cached at asm_cache/<shash>-<arch>/bin-debug/. Returns (binp, dwarffile)
    or (None, None). Linux: no dsymutil — DWARF stays in the ELF."""
    mem_layout, _ = split_algo(algo)
    cache = cache_dir(shash)
    dbgprefix = os.path.join(cache, "bin-debug")
    binp = os.path.join(dbgprefix, "bin", f"{algo}.bench")
    if IS_LINUX:
        if os.path.exists(binp):
            return binp, binp
        cmd = ["zig", "build", "-p", dbgprefix, f"-Dmem_layout={mem_layout}",
               f"-Dalgo={algo.split('.', 1)[1]}", "-Dmode=bench",
               "-Doptimize=ReleaseFast", "-Dkeep-debug=true"]
        if subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True).returncode != 0:
            return None, None
        return (binp, binp) if os.path.exists(binp) else (None, None)
    dwarffile = os.path.join(dbgprefix, "dod.dSYM", "Contents", "Resources", "DWARF", f"{algo}.bench")
    if os.path.exists(dwarffile):
        return binp, dwarffile
    cmd = ["zig", "build", "-p", dbgprefix, f"-Dmem_layout={mem_layout}",
           f"-Dalgo={algo.split('.', 1)[1]}", "-Dmode=bench",
           "-Doptimize=ReleaseFast", "-Dkeep-debug=true"]
    if subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True).returncode != 0:
        return None, None
    subprocess.run(["dsymutil", binp, "-o", os.path.join(dbgprefix, "dod.dSYM")],
                   capture_output=True, text=True)
    return (binp, dwarffile) if os.path.exists(dwarffile) else (None, None)


_ATOS_FRAME = re.compile(r"^(.*?)\s*\(in [^)]*\)\s*\(([^():]+):(\d+)\)\s*$")


def _parse_atos(out: str):
    """atos -i output → list of chains [(file, line) innermost-first]."""
    chains = []
    for stack in out.split("\n\n"):
        frames = []
        for line in stack.strip().splitlines():
            m = _ATOS_FRAME.match(line.strip())
            if m and not m.group(2).startswith("??"):
                frames.append((m.group(2), int(m.group(3))))
        chains.append(frames)
    return chains


def _parse_symbolizer(out: str, n: int):
    """llvm-symbolizer output (blank-line-separated per address, alternating
    function / file:line lines, innermost first) → n chains."""
    chains = []
    for block in out.split("\n\n"):
        frames = []
        lines = [l for l in block.strip().splitlines() if l.strip()]
        for i in range(0, len(lines) - 1, 2):
            m = re.match(r"^(.+?):(\d+)", lines[i + 1].strip())
            if m and not lines[i + 1].startswith("??"):
                frames.append((m.group(1), int(m.group(2))))
        chains.append(frames)
    chains = (chains + [[]] * n)[:n]
    return chains


def _addr2line_per_addr(binp, hexaddrs):
    """GNU addr2line -f -i prints NO separator between addresses — run it once
    per address (slow but unambiguous). Returns chains or None."""
    chains = []
    for h in hexaddrs:
        try:
            r = subprocess.run(["addr2line", "-e", binp, "-f", "-i", "-C", h],
                               capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if r.returncode != 0:
            return None
        frames = []
        lines = [l for l in r.stdout.splitlines() if l.strip()]
        for i in range(0, len(lines) - 1, 2):
            m = re.match(r"^(.+?):(\d+)$", lines[i + 1].strip())
            if m and not lines[i + 1].startswith("??"):
                frames.append((m.group(1), int(m.group(2))))
            else:
                break
        chains.append(frames)
    return chains


def inline_chains(algo, shash, addrs):
    """Resolve DWARF inline chains for every address. Returns
    {files: [...], chains: [[[file_idx, line], ...]], call_site: [line|null]}
    or None when no debug info / toolchain. `call_site` = the algo file's frame
    in each chain (the line to nest under in the folded view)."""
    binp, dwarffile = ensure_debug_binary(algo, shash)
    if not binp:
        return None
    hexaddrs = [f"0x{a:x}" for a in addrs]
    if IS_LINUX:
        chains = None
        # llvm-symbolizer: blank-line-separated inline stacks, one batch call.
        try:
            r = subprocess.run(["llvm-symbolizer", "--obj", binp, "-f", "--inlines",
                                "--output-style=GNU"],
                               input="\n".join(hexaddrs) + "\n",
                               capture_output=True, text=True, timeout=180)
        except (OSError, subprocess.TimeoutExpired):
            r = None
        if r is not None and r.returncode == 0 and r.stdout.strip():
            chains = _parse_symbolizer(r.stdout, len(addrs))
        if chains is None:
            chains = _addr2line_per_addr(binp, hexaddrs)
        if chains is None:
            return None
    else:
        try:
            r = subprocess.run(["atos", "-o", dwarffile, "-i"], input="\n".join(hexaddrs),
                               capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if r.returncode != 0 or not r.stdout.strip():
            return None
        chains = _parse_atos(r.stdout)
        chains = (chains + [[]] * len(addrs))[:len(addrs)]
    # files table (first-seen order) + compact chains
    files, fidx = [], {}
    compact = []
    for frames in chains:
        c = []
        for f, ln in frames:
            if f not in fidx:
                fidx[f] = len(files)
                files.append(f)
            c.append([fidx[f], ln])
        compact.append(c)
    algo_base = os.path.basename(split_algo(algo)[1]) + ".zig"
    call_site = []
    for frames in chains:
        cs = next((ln for f, ln in frames if os.path.basename(f) == algo_base and ln > 0), None)
        call_site.append(cs)
    # which chain files are repo sources (the algo's import closure) vs zig std /
    # runtime — the SPA tints repo inlines differently and black-boxes std.
    repo_files = []
    try:
        import algo_hash
        repo_files = sorted({os.path.basename(p) for p in algo_hash.walk_closure(algo_hash.algo_file_path(algo))})
    except Exception:
        pass
    return {"files": files, "chains": compact, "call_site": call_site,
            "repo_files": repo_files}


# ---- loop digest (deterministic; every number labeled ≈ in the UI) ----------

def decode_fconst(insns, arch):
    """arm64 `mov wN,#imm` / `movk wN,#imm[,lsl #16]` → `fmov sM,wN` chains,
    decoded to f32. x86: RIP-relative — none (decoder is arm-only)."""
    out = []
    if arch != "arm64":
        return out
    wval = {}
    for idx, ins in enumerate(insns):
        m, o = ins["m"], ins["o"]
        mm = re.match(r"^mov\s+w(\d+),\s*#(0x[0-9a-f]+|\d+)$", f"{m}\t{o}")
        if mm:
            wval[mm.group(1)] = int(mm.group(2), 0) & 0xFFFFFFFF
            continue
        mm = re.match(r"^movk\s+w(\d+),\s*#(0x[0-9a-f]+|\d+)(,\s*lsl #(\d+))?$", f"{m}\t{o}")
        if mm:
            reg, imm, sh = mm.group(1), int(mm.group(2), 0), int(mm.group(4) or 0)
            wval[reg] = (wval.get(reg, 0) | ((imm & 0xFFFF) << sh)) & 0xFFFFFFFF
            continue
        mm = re.match(r"^fmov\s+s(\d+),\s*w(\d+)$", f"{m}\t{o}")
        if mm and mm.group(2) in wval:
            v = struct.unpack("<f", struct.pack("<I", wval[mm.group(2)]))[0]
            if v == v and abs(v) != float("inf"):  # NaN/inf guard
                out.append({"i": idx, "v": round(v, 6)})
    return out


_STD_CALLEE = re.compile(r"^(_?)(std\.|Random\.|math\.|mem\.|start\.)", re.I)


def _is_delegation(sym: str) -> bool:
    """External callee that is the loop's PURPOSE (halide kernel, etc.) — not a
    spawn discipline call and not an outlined std/library helper."""
    s = sym.lstrip("_")
    if "spawn" in s.lower():
        return False
    return not _STD_CALLEE.match(sym)


def external_calls(insns, attr):
    """Distinct external callees with a source line — the call-delegated loops
    (e.g. `halide.run`) that have no backward branch in OUR step body."""
    out, seen = [], set()
    for i, ins in enumerate(insns):
        sym = ins.get("t")
        if not sym or sym in seen:
            continue
        seen.add(sym)
        out.append({"sym": sym.lstrip("_"), "line": attr["call_site"][i] if attr else None,
                    "std": not _is_delegation(sym)})
    return out


def _loop_notes(span, insns, attr, arch):
    notes = []
    cond = [i for i in span if insns[i]["cls"] == "branch"]
    calls = [i for i in span if "t" in insns[i] and insns[i]["t"]]
    # branchy respawn: a conditional branch into a block containing a spawn call
    for i in cond:
        bt = insns[i].get("bt")
        if bt is None:
            continue
        j = bt
        while j < len(insns) and j <= i:
            if insns[j].get("t") and "spawn" in insns[j]["t"].lower():
                line = attr["call_site"][bt] if attr else None
                notes.append(f"branchy respawn (→ L{line})" if line else "branchy respawn")
                break
            if j != i and insns[j]["cls"] == "branch":
                break
            j += 1
        if any("respawn" in n for n in notes):
            break
    sel = sum(1 for i in span if re.fullmatch(r"(f?csel|cmov\w*|cset|cinc|csinc)", insns[i]["m"]))
    if sel >= 3:
        notes.append(f"select-based (csel/cmov ×{sel})")
    byte_st = sum(1 for i in span if insns[i]["m"] in ("strb", "strh") or
                  (arch == "x86_64" and insns[i]["cls"] in ("store", "vstore") and
                   re.search(r"(BYTE|WORD) PTR", insns[i]["o"], re.I)))
    if byte_st >= 8:
        notes.append(f"byte-granular scatter (×{byte_st})")
    vfp = sum(1 for i in span if insns[i]["cls"] == "fp" and is_vector_insn(insns[i]["m"], insns[i]["o"], arch))
    sfp = sum(1 for i in span if insns[i]["cls"] == "fp" and not is_vector_insn(insns[i]["m"], insns[i]["o"], arch))
    if vfp and not sfp:
        notes.append("vectorized FP")
    elif vfp and sfp:
        notes.append(f"mixed FP (vec {vfp} / scalar {sfp})")
    elif sfp:
        notes.append(f"scalar FP (×{sfp})")
    # indexed NEON lane load (`ld1.s {v2}[1], [x8]`) = a gather
    if any(re.match(r"^ld[1-4]\.", insns[i]["m"]) and re.search(r"\}\[\d+\]", insns[i]["o"])
           for i in span):
        notes.append("indexed gather present")
    return notes, vfp, sfp


def detect_loops(insns, attr, arch):
    """Backward branches → merged loop spans; per-loop digest."""
    loops = []
    for idx, ins in enumerate(insns):
        if ins["cls"] != "branch" or ins.get("bt") is None:
            continue
        if ins["bt"] < idx:  # backward → loop-closing branch
            loops.append([ins["bt"], idx])
    if not loops:
        return []
    loops.sort()
    merged = [loops[0]]
    for s, e in loops[1:]:
        if s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    out = []
    for k, (s, e) in enumerate(merged, 1):
        span = list(range(s, e + 1))
        # stride: the modal immediate on POINTER SELF-INCREMENT adds inside
        # the span, where the register is also a load/store BASE in the loop
        # (excludes cold-path offsets and index/RNG arithmetic — an indexed
        # loop has no stride add at all and reports None, honestly)
        bases = set()
        for i in span:
            if insns[i]["cls"] in ("load", "store", "vload", "vstore"):
                bases.update(m2.group(1) for m2 in re.finditer(r"\[([a-z]\w*)", insns[i]["o"], re.I))
        adds = Counter()
        for i in span:
            m, o = insns[i]["m"], insns[i]["o"]
            mm = (re.match(r"^add\s+(\w+),\s*\1,\s*#(0x[0-9a-f]+|\d+)$", f"{m}\t{o}") if arch == "arm64"
                  else re.match(r"^add\s+(\w+),\1,(0x[0-9a-f]+|\d+)$", f"{m}\t{o}"))
            if mm and mm.group(1) in bases:
                v = int(mm.group(2), 0)
                if v >= 8:
                    adds[v] += 1
        stride = adds.most_common(1)[0][0] if adds else None
        notes, vfp, sfp = _loop_notes(span, insns, attr, arch)
        # a loop delegating to an external (non-spawn, non-std-helper) callee —
        # e.g. the AOT halide step — has no meaningful body/stride; say so.
        ext = [insns[i]["t"] for i in span
               if insns[i].get("t") and _is_delegation(insns[i]["t"])]
        if ext:
            sym = ext[0].lstrip("_").split("(")[0]
            notes.insert(0, f"delegates to {sym} (external)")
            stride = None
        lines = [attr["call_site"][i] for i in span if attr and attr["call_site"][i]]
        out.append({
            "loop": k, "addr_span": [insns[s]["a"], insns[e]["a"]],
            "lines": [min(lines), max(lines)] if lines else None,
            "insns": len(span), "cond_branches": sum(1 for i in span if insns[i]["cls"] == "branch"),
            "vector_fp": vfp, "scalar_fp": sfp,
            "stride_bytes": stride, "notes": notes,
        })
    return out


# ---- the bundle ----

def build_asm(algo, shash=None):
    """Build + disassemble; return the asm dict (schema 2)."""
    if shash is None:
        shash = source_hash(algo)
    _, algo_part = split_algo(algo)
    binp, _ = ensure_binary(algo, shash)
    body = disasm_step(binp, algo_part) or []
    # pass 1: address / mnemonic / operands / class
    insns = []
    for line in body:
        t = line.split("\t")
        if len(t) < 2 or not ADDR.match(t[0]):
            continue
        m = t[1]
        o = "\t".join(t[2:]).rstrip() if len(t) > 2 else ""
        insns.append({"a": int(t[0], 16), "m": m, "o": o,
                      "cls": classify_insn(m, o, ARCH)})
    # pass 2: branch targets (index into insns) + external call symbols
    addr_idx = {ins["a"]: i for i, ins in enumerate(insns)}
    for ins in insns:
        if ins["cls"] != "branch":
            continue
        taddr, sym = branch_target(ins["m"], ins["o"], ARCH)
        if taddr is not None and taddr in addr_idx:
            ins["bt"] = addr_idx[taddr]
        elif sym:
            ins["t"] = sym
    attr = inline_chains(algo, shash, [ins["a"] for ins in insns])
    loops = detect_loops(insns, attr, ARCH)
    fconst = decode_fconst(insns, ARCH)
    calls = external_calls(insns, attr)
    asm = {
        "schema": ASM_SCHEMA, "arch": ARCH,
        "source_hash": shash, "symbol": step_symbol(algo_part),
        "n_instructions": len(insns),
        "histogram": histogram(body),
        "vector_insns": count_vector(insns, ARCH),
        "excerpt": "\n".join(body),
        "insns": insns,
        "attribution": attr,
        "loops": loops,
        "calls": calls,
        "fconst": fconst,
    }
    path = None
    try:
        import algo_hash
        path = algo_hash.algo_file_path(algo)
        lines = open(path, encoding="utf-8").read().splitlines()
        asm["algo_source"] = {"file": os.path.relpath(path, ROOT), "lines": lines}
    except (ImportError, OSError):
        pass
    return asm


def bundle_path(algo, m=None):
    if m is None:
        m = machine_id()
    return os.path.join(DATA, m, f"{algo}.json")


def write_bundle(algo, force=False, m=None):
    """Write data/<m>/<algo>.json. Skips if current source_hash matches AND
    the asm schema is current (schema bump self-invalidates old bundles)."""
    shash = source_hash(algo)
    path = bundle_path(algo, m)
    if os.path.exists(path) and not force:
        try:
            existing = json.load(open(path))
        except Exception:
            existing = {}
        if (existing.get("source_hash") == shash
                and existing.get("asm", {}).get("schema") == ASM_SCHEMA):
            print(f"  {algo}.json current (source_hash + schema match) — skip", file=sys.stderr)
            return path
    asm = build_asm(algo, shash)
    bundle = {"source_hash": shash, "asm": asm}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(bundle, f, indent=2)
        f.write("\n")
    print(f"  wrote {path}  ({asm['n_instructions']} insn, "
          f"{len(asm['attribution']['call_site']) if asm['attribution'] else 0} attributed)",
          file=sys.stderr)
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
