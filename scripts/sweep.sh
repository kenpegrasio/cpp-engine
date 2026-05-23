#!/usr/bin/env bash
# sweep.sh — run multirun.sh for every engine × every test case.
#
# Usage:
#   ./scripts/sweep.sh
#   ./scripts/sweep.sh --output-dir exp1
#   ./scripts/sweep.sh --output-dir exp1 --runs 30 --cpu 3
#
# Output files are written to:
#   results/<output-dir>/v1_all_buy.txt
#   results/<output-dir>/v2_heavy_overlap_mixed.txt
#   ...
# If --output-dir is omitted, files go directly into results/.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENGINES=(v1 v2 v3)
TEST_DIR="tests/generated"
N_RUNS=30
CPU_ID=3
OUTPUT_SUBDIR=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_SUBDIR="$2"
            shift 2
            ;;
        --runs)
            N_RUNS="$2"
            shift 2
            ;;
        --cpu)
            CPU_ID="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--output-dir <subdir>] [--runs N] [--cpu ID]"
            echo ""
            echo "  --output-dir <subdir>  write results to results/<subdir>/ (default: results/)"
            echo "  --runs N               repetitions per engine×workload (default: 30)"
            echo "  --cpu ID               CPU core to pin to (default: 3)"
            exit 0
            ;;
        *)
            echo "[error] unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve paths (always relative to project root)
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -n "$OUTPUT_SUBDIR" ]]; then
    OUT_BASE="results/$OUTPUT_SUBDIR"
else
    OUT_BASE="results"
fi

mkdir -p "$OUT_BASE"

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
echo "sweep configuration"
echo "  engines    : ${ENGINES[*]}"
echo "  test cases : ${#TEST_FILES[@]}"
echo "  runs each  : $N_RUNS"
echo "  cpu pin    : $CPU_ID"
echo "  output     : $OUT_BASE/"
echo "  total runs : $TOTAL combinations × $N_RUNS = $(( TOTAL * N_RUNS )) engine invocations"
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
        OUT_FILE="$OUT_BASE/${ENGINE}_${STEM}.txt"
        DONE=$(( DONE + 1 ))

        echo "[$DONE/$TOTAL]  engine_$ENGINE  ×  $STEM"

        T0=$(date +%s)
        taskset -c "$CPU_ID" ./scripts/multirun.sh \
            "$BIN" "$TEST_FILE" "$N_RUNS" "$OUT_FILE" "$CPU_ID"
        T1=$(date +%s)

        echo "  → done in $(( T1 - T0 ))s  —  $OUT_FILE"
        echo ""
    done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
SWEEP_END=$(date +%s)
SUCCEEDED=$(( TOTAL - SKIPPED ))

echo "────────────────────────────────────────"
echo "sweep complete"
echo "  succeeded : $SUCCEEDED / $TOTAL combinations"
echo "  skipped   : $SKIPPED"
echo "  output    : $OUT_BASE/"
echo "  wall time : $(( SWEEP_END - SWEEP_START ))s"
echo ""
echo "compare results with:"
echo "  python3 scripts/compare_runs.py \\"

for TEST_FILE in "${TEST_FILES[@]}"; do
    STEM="$(basename "$TEST_FILE" .txt)"
    PATHS=""
    LBLS=""
    for ENGINE in "${ENGINES[@]}"; do
        PATHS="$PATHS $OUT_BASE/${ENGINE}_${STEM}.txt"
        LBLS="$LBLS $ENGINE"
    done
    echo "    # $STEM"
    echo "    python3 scripts/compare_runs.py$PATHS --labels$LBLS"
done
