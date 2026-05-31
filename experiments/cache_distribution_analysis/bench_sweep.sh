#!/usr/bin/env bash
# bench_sweep.sh — per-order cache-miss distribution per engine × workload.
#
# Companion to ../cache_analysis/perf_sweep.sh — but instead of `perf stat`
# wrapping the whole binary (which is dominated by allocator + destructor
# noise, not the matching loop), this script drives the in-process rdpmc
# capture wired into BenchmarkRunner. The engine dumps one CSV row per order
# bracketed by startOperation/endOperation, so we get the *distribution*
# of per-order cache misses inside the timed region — exactly the thing
# perf-stat aggregation can't show.
#
# Output (one CSV per engine × workload × run):
#   results/<subdir>/raw_<engine>_<workload>_run<NN>.csv
# with header: latency_ns,cache-misses,LLC-load-misses,dTLB-load-misses
#
# 1 run per combo is usually enough (1M sample distribution). Use --runs > 1
# only to check run-to-run stability; the plot script pools them.
#
# Prerequisites (one-time, requires sudo):
#   sudo sysctl kernel.perf_event_paranoid=2
#   echo 2 | sudo tee /sys/devices/cpu_core/rdpmc
#   echo 2 | sudo tee /sys/devices/cpu_atom/rdpmc   # hybrid CPUs only
#
# Usage:
#   ./experiments/cache_distribution_analysis/bench_sweep.sh
#   ./experiments/cache_distribution_analysis/bench_sweep.sh --runs 3 --cpu 3
#   ./experiments/cache_distribution_analysis/bench_sweep.sh --engines "v1 v2"

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENGINES=(v1 v2 v3)
TEST_DIR="tests/generated"
N_RUNS=1
CPU_ID=3
OUTPUT_SUBDIR="cache_distribution_analysis"
EVENTS="cache-misses,LLC-load-misses,dTLB-load-misses"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_SUBDIR="$2"; shift 2 ;;
        --runs)       N_RUNS="$2";        shift 2 ;;
        --cpu)        CPU_ID="$2";        shift 2 ;;
        --events)     EVENTS="$2";        shift 2 ;;
        --engines)    read -r -a ENGINES <<< "$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--output-dir <subdir>] [--runs N] [--cpu ID] [--events LIST] [--engines \"v1 v2 v3\"]"
            echo ""
            echo "  --output-dir <subdir>  write to results/<subdir>/ (default: cache_distribution_analysis)"
            echo "  --runs N               independent runs per engine×workload (default: 1)"
            echo "  --cpu ID               CPU core to pin to via taskset (default: 3, a P-core)"
            echo "  --events LIST          BENCH_PERF_EVENTS value (default: cache-misses,LLC-load-misses,dTLB-load-misses)"
            echo "  --engines \"v1 v2 ...\"  which engines to sweep (default: v1 v2 v3)"
            exit 0
            ;;
        *) echo "[error] unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve paths (always relative to project root)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

OUT_BASE="results/$OUTPUT_SUBDIR"
mkdir -p "$OUT_BASE"

# ---------------------------------------------------------------------------
# Preflight: rdpmc + perf_event_open must be usable.
# ---------------------------------------------------------------------------
if ! command -v taskset &>/dev/null; then
    echo "[error] taskset not found — install util-linux" >&2
    exit 1
fi

PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo '?')"
if [[ "$PARANOID" != "?" && "$PARANOID" -gt 2 ]]; then
    echo "[error] kernel.perf_event_paranoid = $PARANOID  (need ≤ 2)" >&2
    echo "        sudo sysctl kernel.perf_event_paranoid=2" >&2
    exit 1
fi

for PMU_DIR in /sys/devices/cpu_core /sys/devices/cpu_atom /sys/devices/cpu; do
    if [[ -f "$PMU_DIR/rdpmc" ]]; then
        RDPMC_VAL="$(cat "$PMU_DIR/rdpmc" 2>/dev/null || echo '?')"
        if [[ "$RDPMC_VAL" != "?" && "$RDPMC_VAL" -lt 2 ]]; then
            echo "[warn] $PMU_DIR/rdpmc = $RDPMC_VAL  (recommend 2)" >&2
            echo "       echo 2 | sudo tee $PMU_DIR/rdpmc" >&2
        fi
    fi
done

# ---------------------------------------------------------------------------
# Collect test files
# ---------------------------------------------------------------------------
mapfile -t TEST_FILES < <(ls "$TEST_DIR"/*.txt 2>/dev/null | sort)
if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    echo "[error] no .txt files found in $TEST_DIR" >&2
    exit 1
fi

TOTAL=$(( ${#ENGINES[@]} * ${#TEST_FILES[@]} ))
DONE=0
SKIPPED=0

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "rdpmc distribution sweep"
echo "  engines    : ${ENGINES[*]}"
echo "  test cases : ${#TEST_FILES[@]}"
echo "  runs each  : $N_RUNS"
echo "  cpu pin    : $CPU_ID"
echo "  events     : $EVENTS"
echo "  output     : $OUT_BASE/"
echo "  total      : $TOTAL combinations × $N_RUNS = $(( TOTAL * N_RUNS )) engine invocations"
echo ""

# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------
SWEEP_START=$(date +%s)

for ENGINE in "${ENGINES[@]}"; do
    BIN="./engine_$ENGINE"

    if [[ ! -x "$BIN" ]]; then
        echo "  [skip] $BIN not found or not executable — skipping all workloads for $ENGINE"
        SKIPPED=$(( SKIPPED + ${#TEST_FILES[@]} ))
        continue
    fi

    for TEST_FILE in "${TEST_FILES[@]}"; do
        STEM="$(basename "$TEST_FILE" .txt)"
        DONE=$(( DONE + 1 ))

        echo "[$DONE/$TOTAL]  engine_$ENGINE  ×  $STEM"

        T0=$(date +%s)
        for i in $(seq 1 "$N_RUNS"); do
            RUN_TAG="$(printf "run%02d" "$i")"
            OUT_FILE="$OUT_BASE/raw_${ENGINE}_${STEM}_${RUN_TAG}.csv"
            printf "\r  run %3d / %d ..." "$i" "$N_RUNS"

            # Engine stderr carries the aggregate stats; discard it (the raw
            # per-order CSV is what we plot). Stdout is the trade stream.
            BENCH_PERF_EVENTS="$EVENTS" \
            BENCH_PERF_DUMP="$OUT_FILE" \
                taskset -c "$CPU_ID" "$BIN" --benchmark < "$TEST_FILE" \
                >/dev/null 2>/dev/null
        done
        printf "\n"
        T1=$(date +%s)

        echo "  → done in $(( T1 - T0 ))s  —  $OUT_BASE/raw_${ENGINE}_${STEM}_run*.csv"
        echo ""
    done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
SWEEP_END=$(date +%s)
SUCCEEDED=$(( TOTAL - SKIPPED ))

echo "────────────────────────────────────────"
echo "rdpmc distribution sweep complete"
echo "  succeeded : $SUCCEEDED / $TOTAL combinations"
echo "  skipped   : $SKIPPED"
echo "  output    : $OUT_BASE/"
echo "  wall time : $(( SWEEP_END - SWEEP_START ))s"
echo ""
echo "plot results with:"
echo "  python3 experiments/cache_distribution_analysis/plot_distribution.py"
