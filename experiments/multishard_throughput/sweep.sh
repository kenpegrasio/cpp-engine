#!/usr/bin/env bash
# sweep.sh — V6A multishard throughput study: engine_<E> @ N producers × S shards
# over the multi_<S>_* testcases in tests/generated_shards/.
#
# --engine selects the shard-boundary queue under test. Both engines are otherwise
# IDENTICAL (same books, same router, same runner, same stats output), so a diff
# between them isolates the queue mechanism and nothing else:
#
#   --engine v6a      MutexQueue          mutex + condition_variable. pop() BLOCKS on an
#                     (default)           empty queue -> FUTEX_WAIT; push() notifies ->
#                                         FUTEX_WAKE. Measured: ~1.0 futex syscall/order
#                                         on uniform, ~0.03 on one-hot.
#   --engine v6a_nb   NonblockingMutexQueue  mutex only, no cv. pop() returns nullopt on
#                                         an empty queue and the shard thread spins. No
#                                         futex from the cv at all -- but the mutex is
#                                         still there, and a spinning consumer hammers the
#                                         same cache line the producer is writing.
#
# The head-to-head is the experiment: does deleting the condition variable recover the
# scaling, or does the cost just move from the futex to the cache line?
#
# This is the Phase 3 *skew* study (CLAUDE.md, "Load Patterns"): it varies the
# instrument-skew axis (uniform / zipf / one-hot) at fixed price distribution,
# and measures throughput at SATURATION. There is deliberately no arrival-process
# pacing here — saturation has no arrival process, and saturation *latency* is
# input-size-bounded garbage. Pacing belongs to the queue-latency preview, which
# is a separate experiment.
#
# The headline number is `operations_per_sec` (aggregate orders/sec across all
# shards). Note that agg_queue / agg_match / agg_total all share one batch span
# and one sample count, so operations_per_sec is IDENTICAL in all three blocks —
# only the latency percentiles differ between them.
#
# Per config × testcase:
#   1. --warmup untimed runs (default 0 — median across back-to-back reps already
#      absorbs rep 1's cold-start transients).
#   2. --runs benchmark runs; each run's stderr (the key=value stats) is appended
#      to <out>/<config>_<testcase>.txt, separated by "---" lines, matching the
#      format used by multithread_bench/sweep.sh.
#   3. Raw per-order latency dumps on the LAST rep. V6A runs THREE BenchmarkRunners
#      (queue wait / match service / total sojourn), so BENCH_PERF_DUMP fans out
#      into three tagged files rather than one:
#          <out>/<config>_<testcase>.lat.queue.csv   enqueue -> dequeue  (W_q)
#          <out>/<config>_<testcase>.lat.match.csv   dequeue -> match end (S)
#          <out>/<config>_<testcase>.lat.total.csv   enqueue -> match end (W_q + S)
#      The tag is inserted before the extension by BenchmarkRunner::taggedDumpPath();
#      single-runner engines (V1-V5S) pass no tag and still write $BENCH_PERF_DUMP
#      verbatim, so multithread_bench/ and cache_distribution_analysis/ are unaffected.
#
#      That decomposition is the point: total = queue + match, so these three files
#      are what separate "the shard boundary cost" from "the matcher's service time".
#
# Pinning:
#   the engine self-pins every worker via CoreAllocator, so no taskset wrapper is
#   used (and none should be: an outer taskset mask would fight CoreAllocator).
#   How many cores that consumes is ENGINE-SPECIFIC: v6a / v6a_nb take N+S (producers
#   plus shards), while v6b (shared feed, no producer threads) and v6a_static (no
#   queues) take fewer. Only 5 clean physical P-cores exist {2,4,6,8,10} — past that
#   CoreAllocator hands out hyperthread siblings and the run is not comparable. The
#   script no longer guards this, because no single formula covers every engine.
#
# Bench controls (governor, turbo, AC power) are checked up front via
# bench_controls/check_controls.sh; use --skip-controls for smoke tests only.
#
# Usage:
#   ./experiments/multishard_throughput/sweep.sh
#   ./experiments/multishard_throughput/sweep.sh --engine v6a_nb
#   ./experiments/multishard_throughput/sweep.sh --runs 20
#   ./experiments/multishard_throughput/sweep.sh --shards 2 --producers 2
#
# The head-to-head (run both, then plot them against each other):
#   ./experiments/multishard_throughput/sweep.sh --engine v6a
#   ./experiments/multishard_throughput/sweep.sh --engine v6a_nb
#   python3 experiments/multishard_throughput/plot_engine_comparison.py
#   ./experiments/multishard_throughput/sweep.sh --runs 1 --skip-controls   # smoke

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENGINE=v6a                  # which engine binary: v6a (MutexQueue, cv) | v6a_nb (NonblockingMutexQueue, spin)
RUN_BASELINE=1              # also measure mu (engine_v5s, 1 thread, no queue) into $OUTPUT_DIR
BASELINE_CPU=2              # taskset core for v5s. MUST be a clean core and MUST match
                            # core_order[0] in core_allocator.hpp, so mu and the shard
                            # threads are measured on equivalent hardware. NEVER 0 (kernel/
                            # ACPI work saturates cpu0) and never 1 (its hyperthread sibling).
BASELINE_DIR="tests/generated"   # v5s parses the SINGLE-instrument format, not multi_*
SHARDS=3                    # S: shard/matching threads (--shard passed to engine)
PRODUCERS=3                 # N: order/producer threads (--N passed to engine)
N_RUNS=10                   # benchmark reps per testcase (median ± IQR)
N_WARMUP=0
TEST_DIR="tests/generated_shards"
OUTPUT_DIR="results/multishard_throughput"
DUMP_ALL=0
SKIP_CONTROLS=0

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)        ENGINE="$2"; shift 2 ;;
        --baseline-cpu)  BASELINE_CPU="$2"; shift 2 ;;
        --no-baseline)   RUN_BASELINE=0; shift ;;
        --shards)        SHARDS="$2"; shift 2 ;;
        --producers|--N) PRODUCERS="$2"; shift 2 ;;
        --runs)          N_RUNS="$2"; shift 2 ;;
        --warmup)        N_WARMUP="$2"; shift 2 ;;
        --test-dir)      TEST_DIR="$2"; shift 2 ;;
        --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
        --dump-all)      DUMP_ALL=1; shift ;;
        --skip-controls) SKIP_CONTROLS=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -48
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
BIN="./engine_${ENGINE}"
if [[ ! -x "$BIN" ]]; then
    echo "[error] $BIN not found — run \`make engine_${ENGINE}\` first" >&2
    exit 1
fi

# Only the testcases whose declared shard count matches --shards. The engine's
# shard_map comes from the file header, while --shard sets the thread/barrier
# count; if they disagree, orders get routed to queues that no thread drains
# (file > --shard) or threads spin up for shards that never exist (file <
# --shard). Globbing on $SHARDS makes the mismatch unrepresentable here.
mapfile -t TEST_FILES < <(ls "$TEST_DIR"/multi_${SHARDS}_*.txt 2>/dev/null | sort)
if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    echo "[error] no multi_${SHARDS}_*.txt files in $TEST_DIR" >&2
    echo "        generate them with: ./tests/generate_bulk_multishard_testcases.sh" >&2
    exit 1
fi

# Upper bound on threads, NOT an assertion: N+S holds for v6a / v6a_nb, but not for
# every multishard engine. engine_v6b has no producer threads (its pool pulls from a
# shared feed) and engine_v6a_static has no queues to feed, so both spawn fewer than
# N+S workers and a guard on this sum rejected configurations that actually fit.
WORKER_COUNT=$(( PRODUCERS + SHARDS ))

# ---------------------------------------------------------------------------
# Core budget — YOUR responsibility now, not the script's.
#
# core_allocator.hpp omits cpu0 (kernel/IRQ/ACPI work saturates it — ~97% %sys, and a
# thread pinned there ran 3x slower), leaving the clean physical P-cores {2,4,6,8,10}.
# The NEXT entries in core_order are hyperthread siblings, starting with cpu1, which
# shares its physical core with the cpu0 kernel load and measured 35% slower even while
# reporting 93% idle (idle% does not capture HT execution-port contention).
#
# So if this engine's ACTUAL worker count exceeds 5, some worker lands on a degraded
# core and the numbers are not comparable across configs — silently, because the
# end-of-batch barrier just waits for the straggler. Check the engine's own thread
# count before quoting a run that is near the limit.
#
# To reclaim cpu0 and get a 6th clean core:
#     echo disable | sudo tee /sys/firmware/acpi/interrupts/gpe6F
#     mpstat -P 0 2 1        # %sys should fall to ~0
# ---------------------------------------------------------------------------

if [[ $SKIP_CONTROLS -eq 0 ]]; then
    if ! ./bench_controls/check_controls.sh; then
        echo "" >&2
        echo "[error] bench controls not satisfied — fix the FAILs above, or pass --skip-controls (smoke tests only)" >&2
        exit 1
    fi
else
    echo "[warn] --skip-controls: numbers from this sweep are NOT quotable" >&2
fi

LABEL="${ENGINE}_N${PRODUCERS}_S${SHARDS}"

echo "multishard throughput sweep"
echo "  engine      : $BIN --benchmark --N $PRODUCERS --shard $SHARDS"
echo "  workers     : $PRODUCERS producers + $SHARDS shards = $WORKER_COUNT threads (self-pinned)"
echo "  test cases  : ${#TEST_FILES[@]} (from $TEST_DIR)"
for f in "${TEST_FILES[@]}"; do echo "                  $(basename "$f")"; done
echo "  runs each   : $N_RUNS (+$N_WARMUP warmup)"
echo "  latency dump: $( [[ $DUMP_ALL -eq 1 ]] && echo 'every rep' || echo 'last rep only' )"
echo "  output      : $OUTPUT_DIR/"
echo ""

# ---------------------------------------------------------------------------
# One benchmark invocation.
#   $1 = test file   $2 = stats file ("" = warmup, discard)   $3 = dump path ("")
# ---------------------------------------------------------------------------
run_bench() {
    local test_file="$1" stats_file="$2" dump="$3"
    local rc=0

    if [[ -n "$stats_file" ]]; then
        BENCH_PERF_DUMP="$dump" \
            "$BIN" --benchmark --N "$PRODUCERS" --shard "$SHARDS" \
            < "$test_file" 2>> "$stats_file" 1>/dev/null || rc=$?
        echo "---" >> "$stats_file"
    else
        "$BIN" --benchmark --N "$PRODUCERS" --shard "$SHARDS" \
            < "$test_file" &>/dev/null || rc=$?
    fi
    return $rc
}

# Median of the operations_per_sec values in a stats file (all three blocks carry
# the same value, so triplication does not move the median).
median_throughput() {
    grep -h '^operations_per_sec=' "$1" 2>/dev/null \
        | cut -d= -f2 \
        | sort -n \
        | awk '{ v[NR] = $1 } END { if (NR == 0) { print "n/a"; exit } printf "%.0f\n", v[int((NR + 1) / 2)] }'
}

# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Baseline mu — engine_v5s, ONE thread, ONE book, NO queue.
#
# Measured HERE, in this same session, rather than reused from
# results/multithread_bench/: that file was written weeks earlier with
# `taskset -c 0`, and cpu0 is saturated by kernel/ACPI work. It reported
# mu ~2.5M when a clean core gives ~6.2M, so every "x mu" and every ceiling
# computed from it was understated ~2.5x -- which is how bars ended up
# "beating" a ceiling that is mathematically unbeatable.
#
# Pinned to $BASELINE_CPU (must equal core_order[0]) so mu and the shard threads
# see equivalent hardware. Same bench-controls gate, same reps, same session.
#
# CAVEAT, and it is a real one: v5s parses the SINGLE-instrument format, so mu
# comes from tests/generated/<prices>_mixed.txt while the shard engines run
# tests/generated_shards/multi_<S>_<skew>_<prices>.txt. Different generators ->
# possibly different crossing rates, so mu is an APPROXIMATE unit for these
# workloads, not an exact one. It is now at least measured on clean hardware in
# the same session; closing the workload gap needs a single-shard multi_1_*
# testcase (does not exist yet) or a single-threaded multi-instrument engine.
# ---------------------------------------------------------------------------
run_baseline() {
    if [[ ! -x ./engine_v5s ]]; then
        echo "[warn] ./engine_v5s not found — skipping baseline (run \`make engine_v5s\`)" >&2
        return 0
    fi
    if [[ "$BASELINE_CPU" -eq 0 || "$BASELINE_CPU" -eq 1 ]]; then
        echo "[error] --baseline-cpu $BASELINE_CPU is cpu0 or its hyperthread sibling cpu1;" >&2
        echo "        both are contaminated by kernel/ACPI load. Pick a core from core_order." >&2
        exit 1
    fi

    # The price modes actually present in this sweep's testcases, so the baseline
    # covers exactly the modes the plots will ask for (and nothing else).
    local modes=()
    for f in "${TEST_FILES[@]}"; do
        local stem rest prices
        stem="$(basename "$f" .txt)"      # multi_3_uniform_wide_range
        rest="${stem#multi_${SHARDS}_}"   # uniform_wide_range
        prices="${rest#*_}"               # wide_range
        [[ " ${modes[*]-} " == *" $prices "* ]] || modes+=("$prices")
    done

    echo "baseline: engine_v5s (1 thread, no queue) on cpu $BASELINE_CPU"
    for prices in "${modes[@]}"; do
        local src="$BASELINE_DIR/${prices}_mixed.txt"
        local out="$OUTPUT_DIR/v5s_${prices}_mixed.txt"
        if [[ ! -f "$src" ]]; then
            echo "  [warn] no $src — skipping $prices" >&2
            continue
        fi
        : > "$out"
        for (( i = 1; i <= N_RUNS; i++ )); do
            printf "\r  %-14s run %2d / %d ..." "$prices" "$i" "$N_RUNS"
            taskset -c "$BASELINE_CPU" ./engine_v5s --benchmark < "$src" 2>> "$out" 1>/dev/null \
                || echo -e "\n[warn] v5s run $i failed for $prices" >&2
            echo "---" >> "$out"
        done
        printf "\r%-40s\r" " "
        local med
        med=$(grep -h '^operations_per_sec=' "$out" | cut -d= -f2 | sort -n \
              | awk '{ v[NR] = $1 } END { if (NR) printf "%.0f", v[int((NR + 1) / 2)] }')
        echo "  mu(${prices}) = ${med:-n/a} orders/sec   -> $out"
    done
    echo ""
}

if [[ $RUN_BASELINE -eq 1 ]]; then
    run_baseline
fi

SWEEP_START=$(date +%s)
CELL=0
TOTAL=${#TEST_FILES[@]}
FAILURES=()

for TEST_FILE in "${TEST_FILES[@]}"; do
    STEM="$(basename "$TEST_FILE" .txt)"
    STATS_FILE="$OUTPUT_DIR/${LABEL}_${STEM}.txt"
    CELL=$(( CELL + 1 ))
    T0=$(date +%s)

    echo "[$CELL/$TOTAL]  $LABEL  ×  $STEM"
    : > "$STATS_FILE"

    for (( i = 1; i <= N_WARMUP; i++ )); do
        printf "\r  warmup %2d / %d ..." "$i" "$N_WARMUP"
        run_bench "$TEST_FILE" "" "" \
            || echo -e "\n[warn] warmup run $i failed for $STEM" >&2
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

        RC=0
        run_bench "$TEST_FILE" "$STATS_FILE" "$DUMP" || RC=$?
        if [[ $RC -ne 0 ]]; then
            FAILED=$(( FAILED + 1 ))
            printf "\n"
            echo "[warn] run $i failed (exit $RC) for $STEM" >&2
        fi
    done
    printf "\r%-40s\r" " "

    if [[ $FAILED -gt 0 ]]; then
        FAILURES+=("$STEM: $FAILED/$N_RUNS runs failed")
    fi

    T1=$(date +%s)
    THPT="$(median_throughput "$STATS_FILE")"
    echo "  → median throughput: ${THPT} orders/sec   (${N_RUNS} runs, $(( T1 - T0 ))s)"
    echo "     $STATS_FILE"
    echo ""
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
echo ""
echo "median throughput by testcase (orders/sec):"
for TEST_FILE in "${TEST_FILES[@]}"; do
    STEM="$(basename "$TEST_FILE" .txt)"
    printf "  %-34s %s\n" "$STEM" "$(median_throughput "$OUTPUT_DIR/${LABEL}_${STEM}.txt")"
done

RC=0
if [[ ${#FAILURES[@]} -gt 0 ]]; then
    RC=1
    echo ""
    echo "FAILURES:"
    printf '  %s\n' "${FAILURES[@]}"
fi

exit $RC
