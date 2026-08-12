#!/usr/bin/env python3
"""Compute a reproducible content hash for an algorithm = the SHA-256 of the sorted
(path -> file-hash) map over the algorithm's full @import closure, plus the Halide
generator .py for halide algorithms.

The hash answers "did the algorithm's *source* change?" — it covers every .zig file
the algorithm transitively imports (framework/sim.zig, config.zig, data.zig,
layouts/common/render_*.zig, the halide FFI, etc.) and, for halide algorithms, the
generator whose output the algorithm links. It does NOT cover build flags
(-Doptimize, -Ddeath — those are run-level fields) or the generated .a binary
(reproducible from the generator .py, which IS hashed).

Usage:
    scripts/algo_hash.py ML01.AF05.LP1-autovec.LP2-simple           # prints the hash
    scripts/algo_hash.py ML01.AF05.LP1-halide.LP2-simple            # includes the gen .py
    scripts/algo_hash.py ML01.AF05.LP1-autovec.LP2-simple --files   # also lists the closure

Stamped on every `<algo>.runs.jsonl` row as `source_hash` (refactor §5/§6.2) so a row
pins not just the git commit but the exact code that ran (catches uncommitted
edits to the algorithm or its imports).
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")

# Module imports (not files) — skip these in the closure walk.
MODULE_IMPORTS = {"std", "options", "raylib"}

IMPORT_RE = re.compile(r'@import\("([^"]+)"\)')


def algo_file_path(algo_name: str) -> str:
    """ML01.AF05.LP1-autovec.LP2-simple -> src/layouts/ML01/AF05.LP1-autovec.LP2-simple.zig
    (the folder name IS the mem_layout id)."""
    mem_layout, algo = algo_name.split(".", 1)
    return os.path.join(SRC, "layouts", mem_layout, algo + ".zig")


def halide_generator_path(algo_name: str) -> str | None:
    """For halide algorithms, the generator .py that produces the linked .a.
    Mirrors build.zig halideGenBase: AF02/AF05/AF06.LP1-halide algorithms each have
    their own generator at the mem_layout root."""
    mem_layout, algo = algo_name.split(".", 1)
    if "LP1-halide" not in algo:
        return None
    if algo.startswith("AF05."):
        base = "AF05.LP1-halide"
    elif algo.startswith("AF06."):
        base = "AF06.LP1-halide"
    else:
        base = "AF02.LP1-halide"
    return os.path.join(SRC, "layouts", mem_layout, base + "_gen.py")


def file_imports(path: str) -> list[str]:
    """Return the file imports (relative to this file's dir) in a .zig file."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return []
    imports = []
    for m in IMPORT_RE.finditer(text):
        spec = m.group(1)
        if spec in MODULE_IMPORTS:
            continue
        if not spec.endswith(".zig"):
            continue  # not a file import we can resolve
        imports.append(spec)
    return imports


def resolve(importing_file: str, spec: str) -> str:
    """Resolve a .zig @import path relative to the importing file's directory
    (Zig's semantics: all @import paths are relative to the importing file)."""
    base = os.path.dirname(importing_file)
    return os.path.normpath(os.path.join(base, spec))


def walk_closure(start: str) -> set[str]:
    """Walk the @import closure starting from a .zig file; return the set of
    absolute paths in the closure (including the start file)."""
    visited: set[str] = set()
    stack = [start]
    while stack:
        path = stack.pop()
        if path in visited:
            continue
        if not os.path.isfile(path):
            continue
        visited.add(path)
        for spec in file_imports(path):
            child = resolve(path, spec)
            if child not in visited:
                stack.append(child)
    return visited


def hash_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def algo_hash(algo_name: str) -> tuple[str, list[str]]:
    """Return (hash_hex, sorted_closure_paths) for an algorithm."""
    start = algo_file_path(algo_name)
    if not os.path.isfile(start):
        raise SystemExit(f"algorithm file not found: {start}")

    closure = walk_closure(start)

    # Halide algorithms: add the generator .py (the .a is reproducible from it).
    gen = halide_generator_path(algo_name)
    if gen and os.path.isfile(gen):
        closure.add(gen)

    # Deterministic: sort by normalized relative-to-ROOT path.
    rel = sorted(os.path.relpath(p, ROOT) for p in closure)

    # Hash the concatenation of path + file hash.
    h = hashlib.sha256()
    for r in rel:
        abs_p = os.path.join(ROOT, r)
        h.update(r.encode())
        h.update(b"\0")
        h.update(hash_file(abs_p).encode())
        h.update(b"\n")
    return h.hexdigest(), rel


def main() -> int:
    args = sys.argv[1:]
    show_files = False
    if "--files" in args:
        show_files = True
        args = [a for a in args if a != "--files"]
    if len(args) != 1:
        print("usage: algo_hash.py <algo-name> [--files]", file=sys.stderr)
        return 2
    h, files = algo_hash(args[0])
    print(h)
    if show_files:
        for f in files:
            print(f"  {f}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
