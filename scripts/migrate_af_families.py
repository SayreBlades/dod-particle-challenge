#!/usr/bin/env python3
# [One-time AF renumber — run against the per-algo data-layer layout
# (commit e07c666). Kept as the as-built record, alongside migrate_names.py
# (B->AF) and migrate_data.py (CSV->JSONL). Idempotent; --dry-run supported.]
#
# Two renumber modes (placeholder technique — no permutation double-app):
#  - FULL   (FAMMAP+FILEMAP): data + analysis — renumber family labels AND names.
#  - NAMES  (FILEMAP; bare family numbers restored): scripts + report.js +
#    sweeps + Makefile + READMEs — preserves "AF01–AF08" ranges and
#    migrate_names.py history. (report.js's ALGO_FAMS map and algo_hash's
#    halideGenBase mirror are hand-fixed: they embed family SEMANTICS, not
#    just tokens.)
# Also renames per-algo files in experiments/data (ML01.AFxx.<name>.*) and
# experiments/analysis (AFxx.<name>.{json,md}). source_hash left as-is.
import re, glob, os, sys
DRY = "--dry-run" in sys.argv
FILEMAP = {
  "AF01.LP1-autovec-par.LP2-simple":"AF02.LP1-autovec-par.LP2-simple",
  "AF01.LP1-autovec.LP2-opt":"AF02.LP1-autovec.LP2-opt",
  "AF01.LP1-autovec.LP2-simple":"AF02.LP1-autovec.LP2-simple",
  "AF01.LP1-blend-par.LP2-simple":"AF02.LP1-blend-par.LP2-simple",
  "AF01.LP1-blend.LP2-simple":"AF02.LP1-blend.LP2-simple",
  "AF01.LP1-halide-par.LP2-simple":"AF02.LP1-halide-par.LP2-simple",
  "AF01.LP1-halide.LP2-opt":"AF02.LP1-halide.LP2-opt",
  "AF01.LP1-halide.LP2-simple":"AF02.LP1-halide.LP2-simple",
  "AF01.LP1-scalar.LP2-simple":"AF02.LP1-scalar.LP2-simple",
  "AF01.LP1-unroll.LP2-simple":"AF02.LP1-unroll.LP2-simple",
  "AF02.LP1-autovec-par.LP2-simple":"AF05.LP1-autovec-par.LP2-simple",
  "AF02.LP1-autovec.LP2-simple":"AF05.LP1-autovec.LP2-simple",
  "AF02.LP1-halide-par.LP2-simple":"AF05.LP1-halide-par.LP2-simple",
  "AF02.LP1-halide.LP2-simple":"AF05.LP1-halide.LP2-simple",
  "AF03.LP1-autovec-par.LP2-rmerge":"AF06.LP1-autovec-par.LP2-mask-rmerge",
  "AF03.LP1-autovec.LP2-simple":"AF06.LP1-autovec.LP2-mask",
  "AF03.LP1-halide.LP2-simple":"AF06.LP1-halide.LP2-mask",
  "AF04.LP1-autovec-par.LP2-rmerge":"AF06.LP1-autovec-par.LP2-list-rmerge",
  "AF04.LP1-autovec.LP2-simple":"AF06.LP1-autovec.LP2-list",
  "AF05.LP1-fused":"AF01.LP1-fused",
  "AF06.LP1-autovec.LP2-fused":"AF04.LP1-autovec.LP2-fused",
  "AF07.LP1-autovec.LP2-fused":"AF03.LP1-autovec.LP2-fused",
  "AF08.LP1-autovec.LP2-fused":"AF06.LP1-autovec.LP2-list-fused",
}
FAMMAP = {"AF01":"AF02","AF02":"AF05","AF03":"AF06","AF04":"AF06",
          "AF05":"AF01","AF06":"AF04","AF07":"AF03","AF08":"AF06"}
BASES = [k for k in FILEMAP if "_api" not in k and "_gen" not in k]
_AF = re.compile(r"AF(0[1-9]|1[01])(?!\d)")
def ph(m): return f"AF__OLD{m.group(1)}__"
def _apply(t, resolve):
    t = _AF.sub(ph, t)
    for old,new in sorted(FILEMAP.items(), key=lambda kv:-len(kv[0])):
        t = t.replace(_AF.sub(ph, old), new)
    return re.sub(r"AF__OLD(0[1-9]|1[01])__", resolve, t)
migrate_full  = lambda t: _apply(t, lambda m: FAMMAP["AF"+m.group(1)])
migrate_names = lambda t: _apply(t, lambda m: "AF"+m.group(1))
def two_phase(pairs):  # temp name kept in the TARGET dir (collision-safe)
    for o,n in pairs: os.rename(o, os.path.join(os.path.dirname(n), "__mig__"+os.path.basename(n)))
    for o,n in pairs: os.rename(os.path.join(os.path.dirname(n), "__mig__"+os.path.basename(n)), n)

def text_migrate(pats, fn):
    c=0
    for pat in pats:
        for f in glob.glob(pat, recursive=True):
            if not os.path.isfile(f) or "__pycache__" in f: continue
            s=open(f).read(); m=fn(s)
            if m!=s: c+=1; open(f,"w").write(m) if not DRY else None
    return c
def rename_files():
    n=0
    for d in glob.glob("experiments/data/*/"):           # ML01.AFxx.<name>.<ext>
        pairs=[(os.path.join(d,"ML01."+b+e), os.path.join(d,"ML01."+FILEMAP[b]+e))
               for b in BASES for e in (".json",".runs.jsonl",".profile.jsonl")
               if os.path.exists(os.path.join(d,"ML01."+b+e))]
        if pairs: two_phase(pairs) if not DRY else None; n+=len(pairs)
    for d in glob.glob("experiments/analysis/*/ML01/"):  # AFxx.<name>.{json,md}
        for e in (".json",".md"):
            pairs=[(os.path.join(d,b+e), os.path.join(d,FILEMAP[b]+e)) for b in BASES
                   if os.path.exists(os.path.join(d,b+e))]
            if pairs: two_phase(pairs) if not DRY else None; n+=len(pairs)
    return n

if __name__ == "__main__":
    print("full-migrate (data+analysis):", text_migrate(["experiments/data/**","experiments/analysis/**"], migrate_full), "files")
    print("names-migrate (scripts+readmes+sweeps+Makefile):",
          text_migrate(["scripts/**","experiments/report.js","experiments/sweeps/**","Makefile","README.md","experiments/README.md"], migrate_names), "files")
    print("renamed per-algo files:", rename_files(), "(hand-fix report.js ALGO_FAMS + algo_hash halideGenBase mirror separately)")
