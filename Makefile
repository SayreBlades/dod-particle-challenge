# Makefile — common actions for the DoD Particle Challenge.
#
# Each target accepts an optional positional target: a full cell name
# (L1.B1.w1-autovec.w2-simple), a layout (L1), or `all` (default). It's read
# from any extra goal on the
# command line, e.g.:
#
#   make build                              # build every cell of every layout
#   make build L1                           # build every cell of L1
#   make build L1.B1.w1-autovec.w2-simple   # build one cell (full name; layouts share strat names)
#   make play L1.B1.w1-autovec.w2-simple    # open the interactive raylib window
#   make profile L1.B1.w1-autovec.w2-simple # PMC cycle-attribution (macOS+Xcode)
#   make report                             # build the analysis tree + verify gate
#   make serve                              # serve experiments/ on :8000 (open report.html)
#   make clean                              # remove out/ and worker build dirs
#
# Heavy data-collection sweeps (with parallelism, resume, JSONL append) use
# scripts/collect.py directly (or `make collect`) — see scripts/README.md.
# A raw one-cell benchmark (build + run the table, no data append) is
# `python3 scripts/run.py bench <cell>`, also documented in scripts/README.md.

PY := python3
# build_report.py needs duckdb (in the venv); prefer it when present.
PY_REPORT := $(if $(wildcard .venv/bin/python),.venv/bin/python,$(PY))

# The extra positional goal (if any), with the known targets filtered out.
KNOWN := build profile play report serve clean help collect
TARGET := $(filter-out $(KNOWN),$(MAKECMDGOALS))

# `make build L1` would also try to build L1 as a file target; neutralize that
# with a silent no-op recipe so make doesn't print "Nothing to be done".
$(TARGET): ; @:

.PHONY: build profile play report serve clean help collect

build:
	$(PY) scripts/run.py build $(TARGET)

play:
	$(PY) scripts/run.py play $(TARGET) $(if $(N),--n $(N))

profile:
	$(PY) scripts/run.py profile $(TARGET)

report:
	$(PY_REPORT) scripts/build_report.py

serve:
	@echo "serving experiments/ on http://localhost:8000 (open report.html)"
	$(PY) -m http.server -d experiments 8000

clean:
	rm -rf out out.w*

# Data-collection sweep (see scripts/README.md). Target is a layout (L1), a
# cell/strat (L1.B1.w1-autovec.w2-simple), or empty = all layouts.
collect:
	$(PY) scripts/collect.py $(TARGET)

help:
	@echo "DoD Particle Challenge — common actions"
	@echo ""
	@echo "  make build [target]     build cells into out/ (target: cell|layout|all)"
	@echo "  make play  [cell]       open the interactive raylib window (N=<count> to size particles)"
	@echo "  make profile [cell]     PMC cycle-attribution (macOS + Xcode)"
	@echo "  make report             build experiments/analysis/ + run the verify gate"
	@echo "  make serve              serve experiments/ (open report.html)"
	@echo "  make clean              rm -rf out out.w*"
	@echo ""
	@echo "  make collect [target]       data-collection sweep (target: cell|layout|all)"
	@echo ""
	@echo "Target may be a cell (L1.B1.w1-autovec.w2-simple), a layout (L1),"
	@echo "a layout (L1), or all (default). See scripts/README.md for details."

.DEFAULT_GOAL := help
