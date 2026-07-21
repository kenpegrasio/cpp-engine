#!/usr/bin/env bash
# sweep.sh — SHARD-COUNT scaling study: throughput vs number of instruments (books).
#
# THE QUESTION
#
# Both V6A and V6B partition by instrument, but they pay for it differently:
#
#   V6A (Design B: ownership + queue)  every order is PUSHED across a shard boundary.
#       Measured push mean ~1.76us vs a ~144ns match, so V6A is HANDOFF-BOUND: the
#       queue, not the matcher, sets throughput. Adding books cannot help, because
#       every order still pays exactly one push.
#
#   V6B (Design A: per-book lock)      no queue at all; a thread locks the book it
#       needs. Contention-bound: with T threads over B books the expected number of
#       books in play is B*(1-(1-1/B)^T), so efficiency RISES with B --
#       B=4 -> 68%, B=16 -> 91%, B=64 -> 98% (at T=4).
#
# Prediction under test: V6A stays FLAT as B grows; V6B RISES.
#
# THE TOPOLOGY ASYMMETRY (why the two engines get different shard ranges)
#
#   V6A spawns N producers + S shard threads  -> workers = N + S
#       Every book needs an OWNING THREAD, so S is bounded by the core count. At
#       N=2 on 5 clean cores, S can only reach 3. Its line is SHORT BY CONSTRUCTION,
#       and that truncation is itself the result: Design B's parallelism is capped
#       by cores, so it cannot even express "64 instruments on 4 cores".
#
#   V6B spawns N worker threads only          -> workers = N
#       shard_count sizes the book/mutex arrays, NOT the thread pool, so books are
#       decoupled from threads and B can run to MAX_SHARDS.
#
# The script computes each engine's feasible shard range from its own topology and
# skips (with a message) anything that would oversubscribe. Cores are precious here:
# core_allocator.hpp omits cpu0 (kernel/ACPI saturated it) and cpu1 (its hyperthread
# sibling), leaving 5 clean physical P-cores {2,4,6,8,10}.
#
# BASELINE
#
# mu (engine_v5s: one thread, one book, NO queue) is measured in THIS session on a
# clean core, not reused from an older results dir -- a stale mu taken on cpu0 once
# understated it 2.5x and made bars appear to beat an unbeatable ceiling.
#
# REQUIREMENTS
#
#   * MAX_SHARDS (include/constants.hpp) >= the largest shard count swept, and the
#     engines REBUILT at that value. Changing MAX_SHARDS changes sizeof(EngineV6*),
#     so numbers from different MAX_SHARDS builds are not comparable -- build once.
#   * Testcases multi_<S>_<skew>_<prices>.txt for every S swept:
#         ./tests/generate_bulk_multishard_testcases.sh
#
# Usage:
#   ./experiments/huge_shards_throughput/sweep.sh
#   ./experiments/huge_shards_throughput/sweep.sh --engines "v6a v6b" --shards "2 4 8 16 32 64"
#   ./experiments/huge_shards_throughput/sweep.sh --producers 3 --runs 10
#   ./experiments/huge_shards_throughput/sweep.sh --runs 1 --skip-controls   # smoke
#
# Then plot:
#   python3 experiments/huge_shards_throughput/plot_shard_scaling.py

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENGINES=(v6a v6b)
SHARD_LIST=(2 3 4 8 16 32 64)   # 3 is included so the queue-based engine gets >1 point
                                # before its core cap (at N=2 it can only reach S=3)
PRODUCERS=2                 # N. For V6A this is producer threads; for V6B it IS the pool.
SKEWS=(uniform)             # uniform is the point: it is the only skew that SPREADS
                            # load over books. one-hot pins everything to book 0 and is
                            # flat for both engines by construction (useful as a control,
                            # not as the headline).
PRICES=(wide_range)
N_RUNS=10
N_WARMUP=0
TEST_DIR="tests/generated_shards"
OUTPUT_DIR="results/huge_shards_throughput"
BASELINE_DIR="tests/generated"
BASELINE_CPU=2              # must be a clean core AND core_order[0]; never 0 or 1
RUN_BASELINE=1
SKIP_CONTROLS=0
CLEAN_PHYSICAL_CORES=5      # {2,4,6,8,10} — NUMBER_OF_PHYSICAL_P_CORES minus cpu0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engines)       read -r -a ENGINES <<< "$2"; shift 2 ;;
        --shards)        read -r -a SHARD_LIST <<< "$2"; shift 2 ;;
        --skews)         read -r -a SKEWS <<< "$2"; shift 2 ;;
        --prices)        read -r -a PRICES <<< "$2"; shift 2 ;;
        --producers|--N) PRODUCERS="$2"; shift 2 ;;
        --runs)          N_RUNS="$2"; shift 2 ;;
        --warmup)        N_WARMUP="$2"; shift 2 ;;
        --test-dir)      TEST_DIR="$2"; shift 2 ;;
        --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
        --baseline-cpu)  BASELINE_CPU="$2"; shift 2 ;;
        --no-baseline)   RUN_BASELINE=0; shift ;;
        --skip-controls) SKIP_CONTROLS=1; shift ;;
        -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -60; exit 0 ;;
        *)               echo "[error] unknown argument: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Topology: how many THREADS does this engine spawn for (N producers, S shards)?
#
#   queue-based (v6a, v6a_nb): N + S   -- every book is owned by its own thread
#   lock-based  (v6b):         N       -- books are plain state; the pool is fixed
#
# This is the whole reason the two engines get different shard ranges, so it lives in
# one function rather than being sprinkled through the loops.
# ---------------------------------------------------------------------------
worker_count_for() {   # $1 = engine  $2 = shards  -> echoes thread count
    case "$1" in
        v6a|v6a_nb|v6a_static) echo $(( PRODUCERS + $2 )) ;;
        v6b)                   echo "$PRODUCERS" ;;
        *)                     echo $(( PRODUCERS + $2 )) ;;   # conservative default
    esac
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for e in "${ENGINES[@]}"; do
    [[ -x "./engine_${e}" ]] || { echo "[error] ./engine_${e} not found — run \`make engine_${e}\`" >&2; exit 1; }
done

if [[ "$BASELINE_CPU" -eq 0 || "$BASELINE_CPU" -eq 1 ]]; then
    echo "[error] --baseline-cpu $BASELINE_CPU is cpu0 or its HT sibling cpu1; both are" >&2
    echo "        contaminated by kernel/ACPI load. Pick a core from core_order." >&2
    exit 1
fi

if [[ $SKIP_CONTROLS -eq 0 ]]; then
    ./bench_controls/check_controls.sh || {
        echo "" >&2
        echo "[error] bench controls not satisfied — fix the FAILs above, or --skip-controls (smoke only)" >&2
        exit 1
    }
else
    echo "[warn] --skip-controls: numbers from this sweep are NOT quotable" >&2
fi

echo ""
echo "shard-count scaling sweep"
echo "  engines     : ${ENGINES[*]}"
echo "  shard list  : ${SHARD_LIST[*]}"
echo "  producers N : $PRODUCERS"
echo "  skews       : ${SKEWS[*]}     prices: ${PRICES[*]}"
echo "  runs each   : $N_RUNS (+$N_WARMUP warmup)"
echo "  clean cores : $CLEAN_PHYSICAL_CORES  {2,4,6,8,10}"
echo "  output      : $OUTPUT_DIR/"
echo ""
echo "  feasible shard range per engine (workers must fit the clean cores):"
for e in "${ENGINES[@]}"; do
    ok=()
    for s in "${SHARD_LIST[@]}"; do
        [[ $(worker_count_for "$e" "$s") -le $CLEAN_PHYSICAL_CORES ]] && ok+=("$s")
    done
    case "$e" in
        v6b) why="workers = N = $PRODUCERS, independent of shards" ;;
        *)   why="workers = N + S = $PRODUCERS + S, so S <= $(( CLEAN_PHYSICAL_CORES - PRODUCERS ))" ;;
    esac
    printf "    %-8s %-28s (%s)\n" "$e" "${ok[*]:-<none>}" "$why"
done
echo ""

# ---------------------------------------------------------------------------
# Baseline mu — engine_v5s, one thread, one book, no queue. Measured in-session.
# ---------------------------------------------------------------------------
run_baseline() {
    [[ -x ./engine_v5s ]] || { echo "[warn] ./engine_v5s missing — skipping baseline" >&2; return 0; }
    echo "baseline: engine_v5s (1 thread, no queue) on cpu $BASELINE_CPU"
    for prices in "${PRICES[@]}"; do
        local src="$BASELINE_DIR/${prices}_mixed.txt" out="$OUTPUT_DIR/v5s_${prices}_mixed.txt"
        [[ -f "$src" ]] || { echo "  [warn] no $src — skipping $prices" >&2; continue; }
        : > "$out"
        for (( i = 1; i <= N_RUNS; i++ )); do
            printf "\r  %-14s run %2d / %d ..." "$prices" "$i" "$N_RUNS"
            taskset -c "$BASELINE_CPU" ./engine_v5s --benchmark < "$src" 2>> "$out" 1>/dev/null \
                || echo -e "\n[warn] v5s run $i failed for $prices" >&2
            echo "---" >> "$out"
        done
        printf "\r%-46s\r" " "
        local med
        med=$(grep -h '^operations_per_sec=' "$out" | cut -d= -f2 | sort -n \
              | awk '{ v[NR] = $1 } END { if (NR) printf "%.0f", v[int((NR + 1) / 2)] }')
        echo "  mu(${prices}) = ${med:-n/a} orders/sec"
    done
    echo ""
}
[[ $RUN_BASELINE -eq 1 ]] && run_baseline

# ---------------------------------------------------------------------------
# Median throughput across reps in a stats file. The V6 engines print several
# labelled blocks per run (Push/Queue/Match/Total) that all share one batch span and
# one sample count, so operations_per_sec is identical in each -- taking every
# occurrence and then the median is exact, not a choice. V6B prints one block.
# ---------------------------------------------------------------------------
median_throughput() {
    grep -h '^operations_per_sec=' "$1" 2>/dev/null | cut -d= -f2 | sort -n \
        | awk '{ v[NR] = $1 } END { if (NR == 0) { print "n/a"; exit } printf "%.0f\n", v[int((NR + 1) / 2)] }'
}

# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------
SWEEP_START=$(date +%s)
SKIPPED=()
FAILURES=()
CELL=0

for engine in "${ENGINES[@]}"; do
  BIN="./engine_${engine}"
  for shards in "${SHARD_LIST[@]}"; do

    workers=$(worker_count_for "$engine" "$shards")
    if [[ $workers -gt $CLEAN_PHYSICAL_CORES ]]; then
        SKIPPED+=("$engine S=$shards needs $workers threads > $CLEAN_PHYSICAL_CORES clean cores")
        continue
    fi

    for skew in "${SKEWS[@]}"; do
      for prices in "${PRICES[@]}"; do
        TEST_FILE="$TEST_DIR/multi_${shards}_${skew}_${prices}.txt"
        if [[ ! -f "$TEST_FILE" ]]; then
            SKIPPED+=("$engine S=$shards: missing $TEST_FILE (run tests/generate_bulk_multishard_testcases.sh)")
            continue
        fi

        STEM="${engine}_N${PRODUCERS}_S${shards}_${skew}_${prices}"
        STATS_FILE="$OUTPUT_DIR/${STEM}.txt"
        CELL=$(( CELL + 1 ))
        T0=$(date +%s)
        echo "[$CELL]  $engine  S=$shards  $skew/$prices  (${workers} threads)"
        : > "$STATS_FILE"

        for (( i = 1; i <= N_WARMUP; i++ )); do
            printf "\r  warmup %2d / %d ..." "$i" "$N_WARMUP"
            "$BIN" --benchmark --N "$PRODUCERS" --shard "$shards" < "$TEST_FILE" &>/dev/null || true
        done

        FAILED=0
        for (( i = 1; i <= N_RUNS; i++ )); do
            printf "\r  run    %2d / %d ..." "$i" "$N_RUNS"
            if ! "$BIN" --benchmark --N "$PRODUCERS" --shard "$shards" \
                    < "$TEST_FILE" 2>> "$STATS_FILE" 1>/dev/null; then
                FAILED=$(( FAILED + 1 ))
                printf "\n[warn] run %d failed for %s\n" "$i" "$STEM" >&2
            fi
            echo "---" >> "$STATS_FILE"
        done
        printf "\r%-46s\r" " "
        [[ $FAILED -gt 0 ]] && FAILURES+=("$STEM: $FAILED/$N_RUNS failed")

        echo "  → median throughput: $(median_throughput "$STATS_FILE") orders/sec   ($(( $(date +%s) - T0 ))s)"
      done
    done
  done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "────────────────────────────────────────"
echo "sweep complete   cells $CELL   wall $(( $(date +%s) - SWEEP_START ))s   output $OUTPUT_DIR/"
echo ""
for skew in "${SKEWS[@]}"; do
  for prices in "${PRICES[@]}"; do
    echo "median throughput, $skew/$prices (orders/sec):"
    printf "  %-10s" "shards"
    for s in "${SHARD_LIST[@]}"; do printf "%12s" "$s"; done; echo
    for engine in "${ENGINES[@]}"; do
      printf "  %-10s" "$engine"
      for s in "${SHARD_LIST[@]}"; do
        f="$OUTPUT_DIR/${engine}_N${PRODUCERS}_S${s}_${skew}_${prices}.txt"
        if [[ -f "$f" ]]; then printf "%12s" "$(median_throughput "$f")"; else printf "%12s" "-"; fi
      done
      echo
    done
    echo ""
  done
done

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "skipped (expected — the topology asymmetry is the result, not a failure):"
    printf '  %s\n' "${SKIPPED[@]}"
    echo ""
fi

echo "Plot it:  python3 experiments/huge_shards_throughput/plot_shard_scaling.py"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    echo "FAILURES:"
    printf '  %s\n' "${FAILURES[@]}"
    exit 1
fi
