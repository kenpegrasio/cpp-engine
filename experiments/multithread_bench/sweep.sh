#!/usr/bin/env bash
# sweep.sh — Phase 2 run-matrix sweep: v3 / v5s / v4@{threads} / v5@{threads}
# over every testcase in tests/generated (see multithread_benchmark_notes.md).
#
# Per config × testcase:
#   1. --warmup untimed runs (default 0 — median±IQR across back-to-back reps
#      already absorbs rep 1's one-time cold-start transients).
#   2. --runs benchmark runs; per-run stats blocks ("---"-separated key=value,
#      same format as bench_stability/multirun.sh) appended to
#          <out>/<config>_<testcase>.txt
#   3. Raw per-order latency dump (BENCH_PERF_DUMP) on the LAST benchmark rep:
#          <out>/<config>_<testcase>.lat.csv
#      With --dump-all, EVERY rep dumps to <config>_<testcase>.lat.rep<k>.csv
#      (the plot script pools them; ~8 MB per rep per 1M-order testcase).
#   4. Verifier (OPT-IN via --verify; default off). Benchmark-mode runs emit
#      no logs, so the measured runs are unverifiable by construction — in-sweep
#      verification is a separate stress campaign of the same config, worth
#      running once per engine build (notes line 16), not on every sweep.
#        v4/v5  → tier-1 replay verifier (./multi_check), --verify-runs times.
#                 Each verify run is a fresh non-benchmark engine execution —
#                 scheduler nondeterminism makes repetition the stress campaign.
#        v3/v5s → exact diff against engine_v1 (./single_check), once
#                 (deterministic, so one run suffices).
#      Logs land in <out>/verify/; any failure is reported at the end and the
#      script exits non-zero.
#
# Pinning:
#   - v4/v5 self-pin one thread per physical P-core via CoreAllocator (2,4,6,8,10 —
#     cpu0 and its HT sibling cpu1 are excluded; see core_allocator.hpp).
#   - v3/v5s are pinned with `taskset -c <--cpu>` (default 2 = core_order[0], the core
#     that v4@1/v5@1 pin themselves to, so the differential v4@1-vs-v3 and
#     v5@1-vs-v5s comparisons run on the same core).
#
# Bench controls (governor, turbo, AC power) are checked up front via
# bench_controls/check_controls.sh; use --skip-controls for smoke tests only.
#
# Usage:
#   ./experiments/multithread_bench/sweep.sh
#   ./experiments/multithread_bench/sweep.sh --output-dir phase2_sweep --runs 10
#   ./experiments/multithread_bench/sweep.sh --threads "1 2 4 6" --verify-runs 10
#
# Then plot:
#   python3 experiments/multithread_bench/plot_latency_cdf.py \
#       --results-dir results/multithread_bench

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
THREAD_COUNTS=(1 2 4)       # v4/v5 thread sweep. CAPPED AT 4, not 6: core_allocator.hpp
                            # now omits cpu0 (kernel/ACPI saturated it: ~97% %sys, a thread
                            # pinned there ran 3x slower) and cpu1 (cpu0's hyperthread
                            # sibling: 35% slower while still reporting 93% idle). That
                            # leaves 5 clean physical P-cores {2,4,6,8,10}; at 6 threads one
                            # would land on an HT sibling and share a physical core, which
                            # reads as "scaling stopped" when it is really core contention.
N_RUNS=10                   # benchmark reps per config × testcase (median ± IQR)
N_WARMUP=0                  # discarded warmup runs. Default 0: back-to-back reps
                            # + median±IQR already absorb rep 1's cold-start
                            # transients (C-state exit, text-page faults), and the
                            # CDF dump comes from the last rep. Raise only for
                            # short passes (--runs 1..3) where the median can't
                            # clip rep 1, or when quoting per-rep max latency.
VERIFY=0                    # opt-in via --verify (or --verify-runs)
N_VERIFY=""                 # verify reps for v4/v5 (default: same as N_RUNS)
TEST_DIR="tests/generated"
OUTPUT_DIR="results/multithread_bench"
CPU_ID=2                    # taskset core for the single-threaded engines (NOT 0: cpu0
                            # is saturated by kernel/ACPI work and cpu1 is its HT sibling;
                            # must match core_order[0] in core_allocator.hpp so the
                            # v4@1-vs-v3 differential compares like with like)
DUMP_ALL=0
SKIP_CONTROLS=0
SKIP_VERIFY=0

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
        --runs)          N_RUNS="$2"; shift 2 ;;
        --warmup)        N_WARMUP="$2"; shift 2 ;;
        --verify)        VERIFY=1; shift ;;
        --verify-runs)   N_VERIFY="$2"; VERIFY=1; shift 2 ;;
        --threads)       read -r -a THREAD_COUNTS <<< "$2"; shift 2 ;;
        --test-dir)      TEST_DIR="$2"; shift 2 ;;
        --cpu)           CPU_ID="$2"; shift 2 ;;
        --dump-all)      DUMP_ALL=1; shift ;;
        --skip-controls) SKIP_CONTROLS=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -40
            exit 0
            ;;
        *)
            echo "[error] unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

N_VERIFY="${N_VERIFY:-$N_RUNS}"

# ---------------------------------------------------------------------------
# Resolve paths (always relative to project root)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

mkdir -p "$OUTPUT_DIR"
[[ $VERIFY -eq 1 ]] && mkdir -p "$OUTPUT_DIR/verify"

# ---------------------------------------------------------------------------
# Preflight: binaries, taskset, testcases, bench controls
# ---------------------------------------------------------------------------
for BIN in engine_v1 engine_v3 engine_v4 engine_v5 engine_v5s multi_check single_check; do
    if [[ ! -x "./$BIN" ]]; then
        echo "[error] ./$BIN not found — run \`make\` first" >&2
        exit 1
    fi
done

if ! command -v taskset &>/dev/null; then
    echo "[error] taskset not found (install util-linux) — pinning is a bench control here, not optional" >&2
    exit 1
fi

mapfile -t TEST_FILES < <(ls "$TEST_DIR"/*.txt 2>/dev/null | sort)
if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    echo "[error] no .txt files found in $TEST_DIR" >&2
    exit 1
fi

if [[ $SKIP_CONTROLS -eq 0 ]]; then
    if ! ./bench_controls/check_controls.sh; then
        echo "" >&2
        echo "[error] bench controls not satisfied — fix the FAILs above, or pass --skip-controls (smoke tests only)" >&2
        exit 1
    fi
else
    echo "[warn] --skip-controls: numbers from this sweep are NOT quotable" >&2
fi

# ---------------------------------------------------------------------------
# Build the run matrix: config = "<label>:<binary>:<N-or-empty>"
# ---------------------------------------------------------------------------
CONFIGS=("v3:./engine_v3:" "v5s:./engine_v5s:")
for T in "${THREAD_COUNTS[@]}"; do
    CONFIGS+=("v4_t${T}:./engine_v4:${T}")
done
for T in "${THREAD_COUNTS[@]}"; do
    CONFIGS+=("v5_t${T}:./engine_v5:${T}")
done

TOTAL=$(( ${#CONFIGS[@]} * ${#TEST_FILES[@]} ))

echo "sweep configuration"
echo "  configs     : $(printf '%s ' "${CONFIGS[@]%%:*}")"
echo "  test cases  : ${#TEST_FILES[@]} (from $TEST_DIR)"
echo "  runs each   : $N_RUNS (+$N_WARMUP warmup)"
if [[ $VERIFY -eq 1 ]]; then
    echo "  verify runs : $N_VERIFY per v4/v5 cell"
else
    echo "  verify runs : off (opt in with --verify; run once per engine build)"
fi
echo "  st cpu pin  : taskset -c $CPU_ID (v3/v5s; v4/v5 self-pin to P-cores)"
echo "  latency dump: $( [[ $DUMP_ALL -eq 1 ]] && echo 'every rep' || echo 'last rep only' )"
echo "  output      : $OUTPUT_DIR/"
echo "  total cells : $TOTAL ($(( TOTAL * (N_RUNS + N_WARMUP) )) benchmark invocations)"
echo ""

# ---------------------------------------------------------------------------
# One benchmark invocation. Stats (stderr) append to $3; stdout discarded.
#   $1 = "<binary>:<N-or-empty>"   $2 = test file
#   $3 = stats file ("" = warmup, discard)   $4 = dump path ("" = no dump)
# ---------------------------------------------------------------------------
run_bench() {
    local bin="${1%%:*}" n="${1##*:}" test_file="$2" stats_file="$3" dump="$4"
    local -a cmd=()

    if [[ -z "$n" ]]; then
        cmd=(taskset -c "$CPU_ID" "$bin" --benchmark)
    else
        cmd=("$bin" --benchmark --N "$n")   # self-pins via CoreAllocator
    fi

    local rc=0
    if [[ -n "$stats_file" ]]; then
        BENCH_PERF_DUMP="$dump" "${cmd[@]}" < "$test_file" \
            2>> "$stats_file" 1>/dev/null || rc=$?
        echo "---" >> "$stats_file"
    else
        "${cmd[@]}" < "$test_file" &>/dev/null || rc=$?
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------
SWEEP_START=$(date +%s)
CELL=0
BENCH_FAILURES=()
VERIFY_FAILURES=()

for CONFIG in "${CONFIGS[@]}"; do
    LABEL="${CONFIG%%:*}"
    REST="${CONFIG#*:}"          # "<binary>:<N-or-empty>"

    for TEST_FILE in "${TEST_FILES[@]}"; do
        STEM="$(basename "$TEST_FILE" .txt)"
        STATS_FILE="$OUTPUT_DIR/${LABEL}_${STEM}.txt"
        CELL=$(( CELL + 1 ))
        T0=$(date +%s)

        echo "[$CELL/$TOTAL]  $LABEL  ×  $STEM"
        : > "$STATS_FILE"

        for (( i = 1; i <= N_WARMUP; i++ )); do
            printf "\r  warmup %2d / %d ..." "$i" "$N_WARMUP"
            run_bench "$REST" "$TEST_FILE" "" "" \
                || echo -e "\n[warn] warmup run $i failed for $LABEL × $STEM" >&2
        done

        FAILED=0
        for (( i = 1; i <= N_RUNS; i++ )); do
            printf "\r  run    %2d / %d ..." "$i" "$N_RUNS"

            DUMP=""
            if [[ $DUMP_ALL -eq 1 ]]; then
                DUMP="$OUTPUT_DIR/${LABEL}_${STEM}.lat.rep${i}.csv"
            elif [[ $i -eq $N_RUNS ]]; then
                DUMP="$OUTPUT_DIR/${LABEL}_${STEM}.lat.csv"
            fi

            if ! run_bench "$REST" "$TEST_FILE" "$STATS_FILE" "$DUMP"; then
                FAILED=$(( FAILED + 1 ))
                printf "\n"
                echo "[warn] run $i failed for $LABEL × $STEM" >&2
            fi
        done
        printf "\r%-40s\r" " "

        if [[ $FAILED -gt 0 ]]; then
            BENCH_FAILURES+=("$LABEL × $STEM: $FAILED/$N_RUNS runs failed")
        fi

        # ── Verification (opt-in) ───────────────────────────────────────────
        if [[ $VERIFY -eq 1 ]]; then
            VLOG="$OUTPUT_DIR/verify/${LABEL}_${STEM}.log"
            : > "$VLOG"
            case "$LABEL" in
                v3|v5s)
                    BIN="${REST%%:*}"
                    printf "  verify (diff vs v1) ..."
                    if ./single_check ./engine_v1 "$BIN" "$TEST_FILE" >> "$VLOG" 2>&1; then
                        echo " ok"
                    else
                        echo " FAIL"
                        VERIFY_FAILURES+=("$LABEL × $STEM (diff vs v1) — see $VLOG")
                    fi
                    ;;
                *)
                    BIN="${REST%%:*}"
                    NT="${REST##*:}"
                    VFAIL=0
                    for (( i = 1; i <= N_VERIFY; i++ )); do
                        printf "\r  verify %2d / %d (tier-1 replay) ..." "$i" "$N_VERIFY"
                        echo "== verify run $i ==" >> "$VLOG"
                        if ! ./multi_check "$BIN" "$TEST_FILE" --N "$NT" >> "$VLOG" 2>&1; then
                            VFAIL=$(( VFAIL + 1 ))
                        fi
                    done
                    printf "\r%-45s\r" " "
                    if [[ $VFAIL -gt 0 ]]; then
                        echo "  verify: $VFAIL / $N_VERIFY FAILED"
                        VERIFY_FAILURES+=("$LABEL × $STEM: $VFAIL/$N_VERIFY tier-1 replays failed — see $VLOG")
                    else
                        echo "  verify: $N_VERIFY / $N_VERIFY ok"
                    fi
                    ;;
            esac
        fi

        T1=$(date +%s)
        echo "  → done in $(( T1 - T0 ))s  —  $STATS_FILE"
        echo ""
    done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
SWEEP_END=$(date +%s)

echo "────────────────────────────────────────"
echo "sweep complete"
echo "  cells      : $CELL / $TOTAL"
echo "  wall time  : $(( SWEEP_END - SWEEP_START ))s"
echo "  output     : $OUTPUT_DIR/"

RC=0
if [[ ${#BENCH_FAILURES[@]} -gt 0 ]]; then
    RC=1
    echo ""
    echo "BENCHMARK FAILURES:"
    printf '  %s\n' "${BENCH_FAILURES[@]}"
fi
if [[ ${#VERIFY_FAILURES[@]} -gt 0 ]]; then
    RC=1
    echo ""
    echo "VERIFIER FAILURES:"
    printf '  %s\n' "${VERIFY_FAILURES[@]}"
fi
if [[ $RC -eq 0 ]]; then
    if [[ $VERIFY -eq 1 ]]; then
        echo "  all benchmark runs succeeded; all verifications passed"
    else
        echo "  all benchmark runs succeeded (verification off — opt in with --verify)"
    fi
fi

echo ""
echo "plot latency distributions with:"
echo "  python3 experiments/multithread_bench/plot_latency_cdf.py --results-dir $OUTPUT_DIR"
exit $RC
