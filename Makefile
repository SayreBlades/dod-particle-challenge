# Makefile — common actions for the DoD Particle Challenge.
#
# Each target accepts an optional positional target: a full algorithm name
# (ML1.AF1.LP1-autovec.LP2-simple), a memory layout (ML1), or `all` (default). It's read
# from any extra goal on the
# command line, e.g.:
#
#   make init                               # one-time setup: git submodules + python env (uv sync)
#   make build                              # build every algorithm of every memory layout
#   make build ML1                           # build every algorithm of ML1
#   make build ML1.AF1.LP1-autovec.LP2-simple   # build one algorithm (full name; memory layouts share algo names)
#   make play ML1.AF1.LP1-autovec.LP2-simple    # open the interactive raylib window
#   make profile ML1.AF1.LP1-autovec.LP2-simple # PMC cycle-attribution (macOS+Xcode)
#   make report                             # build the analysis tree + verify gate
#   make serve                              # serve experiments/ on :8000 (open report.html)
#   make clean                              # remove out/ and worker build dirs
#
# Heavy data-collection sweeps (with parallelism, resume, JSONL append) use
# scripts/collect.py directly (or `make collect`) — see scripts/README.md.
# A raw one-algorithm benchmark (build + run the table, no data append) is
# `uv run python scripts/run.py bench <algorithm>`, also documented in scripts/README.md.

# uv run guarantees the project venv (duckdb, zai-sdk, halide — all installed by `uv sync`)
# for every target and propagates it to child scripts via sys.executable. uv is a
# documented prerequisite (README §Setup); `uv sync` provisions the env.
PY := uv run python

# The extra positional goal (if any), with the known targets filtered out.
KNOWN := init build profile play report serve clean help collect
TARGET := $(filter-out $(KNOWN),$(MAKECMDGOALS))

# `make build ML1` would also try to build ML1 as a file target; neutralize that
# with a silent no-op recipe so make doesn't print "Nothing to be done".
$(TARGET): ; @:

.PHONY: init build profile play report serve clean help collect

# One-time setup: clone/update git submodules (raylib) + create the python venv
# (duckdb + halide + zai-sdk via uv sync). Idempotent — safe to re-run anytime.
init:
	@echo "==> git submodules (update --init --recursive)"
	git submodule update --init --recursive
	@test -f vendor/raylib/src/rcore.c || { echo "ERROR: vendor/raylib not populated (submodule init failed)"; exit 1; }
	@echo "  OK: vendor/raylib populated"
	@echo "==> python env (uv sync)"
	uv sync
	@echo "==> done. Next: 'make build ML1' or 'make help'."

build:
	$(PY) scripts/run.py build $(TARGET)

play:
	$(PY) scripts/run.py play $(TARGET) $(if $(N),--n $(N))

profile:
	$(PY) scripts/run.py profile $(TARGET)

report:
	$(PY) scripts/build_report.py

serve:
	@echo "serving experiments/ on http://localhost:8000 (open report.html)"
	$(PY) -m http.server -d experiments 8000

clean:
	rm -rf out out.w*

# Data-collection sweep (see scripts/README.md). Target is a memory layout (ML1), a
# algorithm (ML1.AF1.LP1-autovec.LP2-simple), or empty = all memory layouts.
collect:
	$(PY) scripts/collect.py $(TARGET)

help:
	@echo "DoD Particle Challenge — common actions"
	@echo ""
	@echo "  make init               one-time setup: git submodules + python env (uv sync)"
	@echo "  make build [target]     build algorithms into out/ (target: algorithm|memory layout|all)"
	@echo "  make play  [algorithm]       open the interactive raylib window (N=<count> to size particles)"
	@echo "  make profile [algorithm]     PMC cycle-attribution (macOS + Xcode)"
	@echo "  make report             build experiments/analysis/ + run the verify gate"
	@echo "  make serve              serve experiments/ (open report.html)"
	@echo "  make clean              rm -rf out out.w*"
	@echo ""
	@echo "  make collect [target]       data-collection sweep (target: algorithm|memory layout|all)"
	@echo ""
	@echo "Target may be an algorithm (ML1.AF1.LP1-autovec.LP2-simple), a memory layout (ML1),"
	@echo "a memory layout (ML1), or all (default). See scripts/README.md for details."

.DEFAULT_GOAL := help
