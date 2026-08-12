# Makefile — common actions for the DoD Particle Challenge.
#
# A thin verb menu over zig build (building) and python scripts (collection +
# analysis). No loops, no target resolution — those live in build.zig / the
# scripts. Positional target: an algorithm (ML01.AF01…), a memory layout (ML01),
# or all (default).
#
#   make init               # one-time: submodules + python env
#   make build [target]     # build bench binaries (algo | ML<layout> | all)
#   make play  [algo]       # build + open the raylib window
#   make bench  [algo]      # build + run a quick bench table (one algorithm)
#   make check  [algo]      # build + run the invariant suite (one algorithm)
#   make collect [target]   # full sweep: bench + check + profile (prereq: build)
#   make report             # build the dashboard (duckdb + LLM)
#   make serve              # view the dashboard on :8000
#   make profile [algo]     # hardware-counter profiling (macOS Xcode / Linux perf)
#   make clean              # rm -rf out
#
# Target is positional & optional. play/bench/check/profile take a single
# algorithm and default to the ML01 reference (ML01.AF02.LP1-autovec.LP2-simple).
# `make build JOBS=8` caps zig's compile parallelism (defaults to every core).

REF := ML01.AF02.LP1-autovec.LP2-simple
ZIGFLAGS := -p out -Doptimize=ReleaseFast $(if $(JOBS),-j$(JOBS))

# Extra positional goal (if any), with known targets filtered out, so
# `make build ML01` doesn't try to build a file named ML01.
KNOWN := init build play bench check collect report serve profile clean help
TARGET := $(filter-out $(KNOWN),$(MAKECMDGOALS))
$(TARGET): ; @:

# Everything that needs the env gets init as an order-only prereq.
# init is idempotent (submodule update + uv sync are no-ops when up-to-date).
build play bench check collect report serve profile: | init

.PHONY: init build play bench check collect report serve profile clean help

# --- one-time setup (idempotent; safe to re-run) ---
init:
	git submodule update --init --recursive
	uv sync

# --- build bench binaries (timestamp-gated: skips entirely when sources are unchanged) ---
# Coarse source prereq -> stamp gate -> ONE zig invocation. make short-circuits
# (~50ms, no zig call) when the stamp is newer than every source; when stale,
# zig's DAG runner compiles all selected algos in parallel (every core) and its
# content cache rebuilds only what actually changed. NOT per-algo make targets:
# each would be a separate `zig build` (many configure passes + .zig-cache
# contention under -j — slower). The stamp is keyed by TARGET so build-ML01 /
# build-all / build-<algo> don't share state.
SOURCES := $(shell find src -name '*.zig') $(shell find src -name '*_gen.py') build.zig
BUILD_STAMP := out/.build-$(or $(TARGET),all)-stamp
build: $(BUILD_STAMP)
$(BUILD_STAMP): $(SOURCES)
	@mkdir -p out
	zig build -Dselect=$(or $(TARGET),all) -Dmode=bench $(ZIGFLAGS) --summary all
	@touch $(BUILD_STAMP)

# --- interactive raylib window ---
play:
	zig build -Dselect=$(or $(TARGET),$(REF)) -Dmode=play $(ZIGFLAGS)
	./out/bin/$(or $(TARGET),$(REF)).play $(if $(N),--n $(N))

# --- quick one-algorithm bench table (no JSONL, no sweep) ---
bench:
	zig build -Dselect=$(or $(TARGET),$(REF)) -Dmode=bench $(ZIGFLAGS)
	./out/bin/$(or $(TARGET),$(REF)).bench --n 1000000 --q 0.1 --threads 1 --iters 100 --trial 1

# --- invariant suite, one algorithm (default REF) ---
check:
	zig build -Dselect=$(or $(TARGET),$(REF)) -Dmode=bench $(ZIGFLAGS)
	./out/bin/$(or $(TARGET),$(REF)).bench --check --q 0 --threads 1

# --- full sweep: bench + check + profile per unit. Builds first. ---
# profile is Mac-gated (xctrace); on Linux it degrades gracefully (no profile
# rows, timing+check still run). Narrow via env: NS, TRIALS, THREADS,
# DEATH_RATES, PROFILE_NS, PROFILE_THREADS, PROFILE_DEATH_RATES, PROFILE=0.
collect: build
	uv run python scripts/collect.py $(TARGET) --with-profile

# --- analysis tree + verify gate (needs duckdb — runs under uv) ---
report:
	uv run python scripts/build_report.py

# --- serve the SPA ---
serve:
	uv run python -m http.server -d experiments 8000

# --- hardware-counter profiling, one point (macOS: Xcode/xctrace; Linux: perf) ---
profile:
	uv run python scripts/profile.py $(or $(TARGET),$(REF)) --n 1000000 --q 0.1 --threads 1 --trial 1

clean:
	rm -rf out out.w*

help:
	@echo "DoD Particle Challenge — common actions"
	@echo ""
	@echo "  make init               one-time: submodules + python env (uv sync)"
	@echo "  make build [target]     build bench binaries (algo | ML<layout> | all)"
	@echo "  make play  [algo]       open the interactive raylib window (N=<count> to size)"
	@echo "  make bench  [algo]      quick one-algorithm bench table"
	@echo "  make check  [algo]      run the invariant suite (one algorithm)"
	@echo "  make collect [target]   full sweep: bench + check + profile (builds first)"
	@echo "  make report             build the dashboard (duckdb + LLM narratives)"
	@echo "  make serve              serve experiments/ on :8000"
	@echo "  make profile [algo]     hardware-counter profiling, one point (macOS Xcode / Linux perf)"
	@echo "  make clean              rm -rf out"
	@echo ""
	@echo "  JOBS=8 caps build parallelism (default: every core)"
	@echo "  Target is positional & optional: ML01.AF02.LP1-autovec.LP2-simple | ML01 | all."

.DEFAULT_GOAL := help
