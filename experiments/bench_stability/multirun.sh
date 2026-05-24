#!/usr/bin/env bash
# multirun.sh — run one engine benchmark N times and collect per-run stats.
#
# Usage:
#   ./scripts/multirun.sh <engine> <test_file> <n_runs> <output_file> [cpu_id]
#
# Output format (one block per run, blocks separated by "---"):
#   elapsed_ms=45.2
#   operations_per_sec=22123.4
#   avg_latency_ns=45.2
#   min_latency_ns=30
#   ...
#   transactions=1000
#   ---
#   elapsed_ms=46.1
#   ...
#   ---
#
# The output file is overwritten fresh each invocation.
#
# Examples:
#   ./scripts/multirun.sh ./engine_v1 tests/generated/heavy_overlap_mixed.txt \
#       30 results/v1_heavy_overlap.txt
#
#   ./scripts/multirun.sh ./engine_v3 tests/generated/all_buy.txt \
#       30 results/v3_all_buy.txt 5          # pin to CPU 5

set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <engine> <test_file> <n_runs> <output_file> [cpu_id]" >&2
    echo ""
    echo "  engine      path to a compiled engine binary (must accept --benchmark)"
    echo "  test_file   input workload (.txt in the standard order format)"
    echo "  n_runs      number of repetitions (e.g. 30)"
    echo "  output_file where to write the per-run stats (overwritten)"
    echo "  cpu_id      CPU core to pin to via taskset (default: 3)"
    exit 1
fi

ENGINE="$1"
TEST_FILE="$2"
N_RUNS="$3"
OUTPUT_FILE="$4"
CPU_ID="${5:-3}"

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [[ ! -x "$ENGINE" ]]; then
    echo "[error] not executable or not found: $ENGINE" >&2
    exit 1
fi

if [[ ! -f "$TEST_FILE" ]]; then
    echo "[error] test file not found: $TEST_FILE" >&2
    exit 1
fi

if ! [[ "$N_RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "[error] n_runs must be a positive integer, got: $N_RUNS" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Check for taskset; fall back to plain execution if unavailable.
# ---------------------------------------------------------------------------
if command -v taskset &>/dev/null; then
    RUNNER="taskset -c $CPU_ID"
    PIN_INFO="CPU $CPU_ID"
else
    RUNNER=""
    PIN_INFO="none (taskset not found — install util-linux for CPU pinning)"
    echo "[warn] taskset not available; running without CPU pinning" >&2
fi

# ---------------------------------------------------------------------------
# Prepare output directory
# ---------------------------------------------------------------------------
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
if [[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" != "." ]]; then
    mkdir -p "$OUTPUT_DIR"
fi

# Overwrite fresh each run
: > "$OUTPUT_FILE"

# ---------------------------------------------------------------------------
# Print run summary
# ---------------------------------------------------------------------------
echo "engine   : $ENGINE"
echo "test     : $TEST_FILE"
echo "n_runs   : $N_RUNS"
echo "output   : $OUTPUT_FILE"
echo "cpu pin  : $PIN_INFO"
echo ""

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
FAILED=0

for i in $(seq 1 "$N_RUNS"); do
    printf "\r  run %3d / %d ..." "$i" "$N_RUNS"

    # Capture stderr (benchmark stats) and stdout (trade output) separately.
    # We only want stderr in the output file.
    if $RUNNER "$ENGINE" --benchmark < "$TEST_FILE" \
            2>> "$OUTPUT_FILE" \
            1>/dev/null; then
        echo "---" >> "$OUTPUT_FILE"
    else
        EXIT_CODE=$?
        printf "\n"
        echo "[warn] run $i exited with code $EXIT_CODE — skipping" >&2
        FAILED=$((FAILED + 1))
        # Remove the potentially partial block so the parser doesn't choke.
        # Append a separator so blocks remain consistently delimited.
        echo "---" >> "$OUTPUT_FILE"
    fi
done

printf "\n"

SUCCEEDED=$((N_RUNS - FAILED))
echo "Completed: $SUCCEEDED / $N_RUNS runs succeeded → $OUTPUT_FILE"

if [[ $SUCCEEDED -eq 0 ]]; then
    echo "[error] every run failed — output file may be empty" >&2
    exit 1
fi
