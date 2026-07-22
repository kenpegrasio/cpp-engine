#!/usr/bin/env bash
# thread_ablation.sh — isolate CONCURRENCY cost from BOOK-FAN-OUT cost in V6B.
#
# THE QUESTION
#
# The shard sweep (sweep.sh) showed V6B rising with shard count but topping out at
# ~4.4M orders/sec at S=64, N=2 -- below the 6.2M/sec of single-threaded engine_v5s.
# The tempting reading is "Design A's locking loses to one thread". That reading is
# unattributable, because moving from v5s to v6b changes THREE things at once:
#
#     1. thread count        1  ->  2
#     2. books touched       1  ->  64      (31 KB  ->  1.97 MB working set)
#     3. orders per book     1M ->  ~15.6k  (book depth, and hence E[S], collapses)
#
# A number that moves when three inputs move attributes to none of them.
#
# THE CUT
#
# Run the SAME binary on the SAME testcase at the SAME shard count, varying only N.
# That holds (2) and (3) exactly fixed -- byte-identical input, identical book
# layout, identical sizeof(EngineV6B) -- so the only surviving variable is threads.
#
#     T(N=1, S)   zero lock contention, full fan-out  ->  the FAN-OUT cost
#     T(N=2, S)   adds the second thread              ->  the CONCURRENCY cost
#
# Read the ladder as:
#
#     mu_v5s   -> T(N=1,S)     everything here is a DATA-STRUCTURE result
#     T(N=1,S) -> T(N=2,S)     everything here is a CONCURRENCY result
#
# If T(N=1,S=64) is already far below mu_v5s, the headline "64 shards loses to
# single-threaded" is mostly cache fan-out, not locking, and the interesting work
# moves to the book layout (see experiments/struct_bloat) rather than to the mutex.
#
# WHY THE INPUT IS GENUINELY FIXED ACROSS S (verified, not assumed)
#
# generate_multishard_testcases.py draws the shard index with random.choices, which
# consumes exactly one random() call regardless of how long the weight vector is, so
# the RNG stream stays aligned across --shards values. Stripping the shard column
# from multi_2_* and multi_64_* yields byte-identical files (same md5). The order
# bodies ARE the same workload; only the partitioning differs.
#
# Note this does NOT hold for the v5s baseline file (tests/generated/wide_range_mixed
# .txt): it comes from the other generator, one fewer random() per order, so its
# stream is shifted. Same DISTRIBUTION, different REALIZATION -- fine for comparing
# aggregate throughput over 1M orders, not fine for order-by-order claims.
#
# WHAT IS REPORTED
#
#   throughput      median orders/sec over --runs reps
#   ns/order/thr    N * 1e9 / throughput -- per-thread service time. This is the
#                   number that is directly comparable to mu_v5s's 1e9/mu, and the
#                   one that exposes a per-thread regression that aggregate
#                   throughput hides.
#   speedup         T(N) / T(1)
#   efficiency      T(N) / (N * T(1)) -- 1.0 is perfect scaling
#
# COUNTERS (optional, --perf)
#
# perf stat is attached WITHOUT region scoping, so it also counts the single-threaded
# parse of a ~21 MB file and the final agg.merge. Absolute per-order counts from it
# are NOT trustworthy. Since every cell here reads a same-sized file, that
# contamination is near-constant and DIFFERENTIAL comparison across cells survives --
# use it for trends, never for "X misses per order". For absolute attribution, scope
# the counters to the timed loop with include/perf_counters.hpp instead.
#
# REQUIREMENTS
#
#   * ./engine_v6b built at the MAX_SHARDS you intend to sweep (changing MAX_SHARDS
#     changes sizeof(EngineV6B) and the memory layout; build once).
#   * Testcases: ./tests/generate_bulk_multishard_testcases.sh
#
# Usage:
#   ./experiments/huge_shards_throughput/thread_ablation.sh
#   ./experiments/huge_shards_throughput/thread_ablation.sh --shards 64 --threads "1 2 4"
#   ./experiments/huge_shards_throughput/thread_ablation.sh --perf --runs 5
#   ./experiments/huge_shards_throughput/thread_ablation.sh --runs 1 --skip-controls  # smoke

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENGINE=v6b
SHARD_LIST=(2 16 32 64)
THREAD_LIST=(1 2)
SKEWS=(uniform)
PRICES=(wide_range)
N_RUNS=10
N_WARMUP=0
TEST_DIR="tests/generated_shards"
OUTPUT_DIR="results/thread_ablation"
BASELINE_DIR="tests/generated"
BASELINE_CPU=2              # core_order[0] in core_allocator.hpp — also the core the
                            # N=1 run pins to, so baseline and ablation share a core
RUN_BASELINE=1
SKIP_CONTROLS=0
RUN_PERF=0
CLEAN_PHYSICAL_CORES=5      # {2,4,6,8,10} — cpu0 (kernel/ACPI) and cpu1 (its HT sibling) excluded

# Cross-core sharing counters. The .snoop_hitm suffix is the one that requires
# another core to have held the line MODIFIED, i.e. a real core-to-core transfer --
# plain .l3_hit without it is an ordinary capacity miss out of L2. mem_load_* are
# PEBS retired-load events and cross-check the offcore (ocr.*) ones, which have
# known accuracy caveats on Alder/Raptor Lake.
PERF_EVENTS="cpu_core/ocr.demand_data_rd.l3_hit.snoop_hitm/,cpu_core/ocr.demand_rfo.l3_hit.snoop_hitm/,cpu_core/mem_load_l3_hit_retired.xsnp_hitm/,cpu_core/mem_load_l3_hit_retired.xsnp_fwd/"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)        ENGINE="$2"; shift 2 ;;
        --shards)        read -r -a SHARD_LIST <<< "$2"; shift 2 ;;
        --threads|--N)   read -r -a THREAD_LIST <<< "$2"; shift 2 ;;
        --skews)         read -r -a SKEWS <<< "$2"; shift 2 ;;
        --prices)        read -r -a PRICES <<< "$2"; shift 2 ;;
        --runs)          N_RUNS="$2"; shift 2 ;;
        --warmup)        N_WARMUP="$2"; shift 2 ;;
        --test-dir)      TEST_DIR="$2"; shift 2 ;;
        --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
        --baseline-cpu)  BASELINE_CPU="$2"; shift 2 ;;
        --perf)          RUN_PERF=1; shift ;;
        --perf-events)   PERF_EVENTS="$2"; shift 2 ;;
        --no-baseline)   RUN_BASELINE=0; shift ;;
        --skip-controls) SKIP_CONTROLS=1; shift ;;
        -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -70; exit 0 ;;
        *)               echo "[error] unknown argument: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
mkdir -p "$OUTPUT_DIR"

BIN="./engine_${ENGINE}"
[[ -x "$BIN" ]] || { echo "[error] $BIN not found — run \`make engine_${ENGINE}\`" >&2; exit 1; }

if [[ "$BASELINE_CPU" -eq 0 || "$BASELINE_CPU" -eq 1 ]]; then
    echo "[error] --baseline-cpu $BASELINE_CPU is cpu0 or its HT sibling cpu1; both are" >&2
    echo "        contaminated by kernel/ACPI load. Pick a core from core_order." >&2
    exit 1
fi

for n in "${THREAD_LIST[@]}"; do
    if [[ $n -gt $CLEAN_PHYSICAL_CORES ]]; then
        echo "[error] --threads $n exceeds $CLEAN_PHYSICAL_CORES clean physical cores {2,4,6,8,10}." >&2
        echo "        Beyond that CoreAllocator wraps onto HT siblings and you are measuring" >&2
        echo "        hyperthread contention, not sharding." >&2
        exit 1
    fi
done

if [[ $RUN_PERF -eq 1 ]] && ! command -v perf >/dev/null 2>&1; then
    echo "[error] --perf requested but perf is not on PATH" >&2; exit 1
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
echo "thread ablation — concurrency cost vs book-fan-out cost"
echo "  engine      : $ENGINE"
echo "  shard list  : ${SHARD_LIST[*]}"
echo "  thread list : ${THREAD_LIST[*]}"
echo "  skews       : ${SKEWS[*]}     prices: ${PRICES[*]}"
echo "  runs each   : $N_RUNS (+$N_WARMUP warmup)"
echo "  perf        : $([[ $RUN_PERF -eq 1 ]] && echo "on (UNSCOPED — differential only)" || echo off)"
echo "  output      : $OUTPUT_DIR/"
echo ""

# ---------------------------------------------------------------------------
# Median of operations_per_sec across reps.
#
# The V6 engines print several labelled blocks per run (Push/Queue/Match/Total) that
# share one batch span and one sample count, so operations_per_sec is identical in
# each; taking every occurrence then the median is exact, not a choice. V6B prints one.
# ---------------------------------------------------------------------------
median_throughput() {
    grep -h '^operations_per_sec=' "$1" 2>/dev/null | cut -d= -f2 | sort -n \
        | awk '{ v[NR] = $1 } END { if (NR == 0) { print "n/a"; exit } printf "%.0f\n", v[int((NR + 1) / 2)] }'
}

# Run-to-run spread of throughput, as +/-% of the median.
#
# This exists because the decomposition SUBTRACTS medians, and a difference of two
# similar numbers amplifies relative noise. The concurrency term (252 -> 443) is a
# large gap and shrugs off a few percent; the fan-out term (161 -> 252 = 90) is a
# small difference of similar values, so the same few percent on each end puts ~+/-8 ns
# on it. Print the spread so that asymmetry is visible instead of implied.
spread_pct() {
    grep -h '^operations_per_sec=' "$1" 2>/dev/null | cut -d= -f2 | sort -n \
        | awk '{ v[NR] = $1 }
               END { if (NR < 2) { print "-"; exit }
                     med = v[int((NR + 1) / 2)]
                     if (med <= 0) { print "-"; exit }
                     lo = (med - v[1]) / med * 100; hi = (v[NR] - med) / med * 100
                     printf "-%.1f/+%.1f%%", lo, hi }'
}

median_field() {   # $1 = stats file  $2 = field name (e.g. p99_latency_ns)
    grep -h "^$2=" "$1" 2>/dev/null | cut -d= -f2 | sort -n \
        | awk '{ v[NR] = $1 } END { if (NR == 0) { print "n/a"; exit } printf "%.0f\n", v[int((NR + 1) / 2)] }'
}

# ---------------------------------------------------------------------------
# Baseline mu — engine_v5s, one thread, ONE book, no locks. Measured in-session on a
# clean core; a stale mu taken on cpu0 once understated it 2.5x.
#
# Caveat carried into the summary: this reads a DIFFERENT input file (different
# generator, shifted RNG stream) with ONE book. It is the "how fast is one hot book"
# reference point, NOT a control for the sharded workload. The control is T(N=1).
# ---------------------------------------------------------------------------
declare -A MU
run_baseline() {
    [[ -x ./engine_v5s ]] || { echo "[warn] ./engine_v5s missing — skipping baseline" >&2; return 0; }
    echo "baseline: engine_v5s (1 thread, 1 book, no locks) on cpu $BASELINE_CPU"
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
        MU[$prices]=$(median_throughput "$out")
        echo "  mu(${prices}) = ${MU[$prices]:-n/a} orders/sec  ($(awk -v m="${MU[$prices]:-0}" 'BEGIN{ if (m>0) printf "%.0f", 1e9/m; else printf "n/a" }') ns/order)"
    done
    echo ""
}
[[ $RUN_BASELINE -eq 1 ]] && run_baseline

# ---------------------------------------------------------------------------
# Sweep: for each (shards, skew, prices), vary ONLY N.
# ---------------------------------------------------------------------------
SWEEP_START=$(date +%s)
SKIPPED=()
FAILURES=()
CELL=0

for shards in "${SHARD_LIST[@]}"; do
  for skew in "${SKEWS[@]}"; do
    for prices in "${PRICES[@]}"; do

      TEST_FILE="$TEST_DIR/multi_${shards}_${skew}_${prices}.txt"
      if [[ ! -f "$TEST_FILE" ]]; then
          SKIPPED+=("S=$shards: missing $TEST_FILE (run tests/generate_bulk_multishard_testcases.sh)")
          continue
      fi

      for n in "${THREAD_LIST[@]}"; do
        STEM="${ENGINE}_N${n}_S${shards}_${skew}_${prices}"
        STATS_FILE="$OUTPUT_DIR/${STEM}.txt"
        CELL=$(( CELL + 1 ))
        T0=$(date +%s)
        echo "[$CELL]  $ENGINE  N=$n  S=$shards  $skew/$prices"
        : > "$STATS_FILE"

        for (( i = 1; i <= N_WARMUP; i++ )); do
            printf "\r  warmup %2d / %d ..." "$i" "$N_WARMUP"
            "$BIN" --benchmark --N "$n" --shard "$shards" < "$TEST_FILE" &>/dev/null || true
        done

        FAILED=0
        for (( i = 1; i <= N_RUNS; i++ )); do
            printf "\r  run    %2d / %d ..." "$i" "$N_RUNS"
            if ! "$BIN" --benchmark --N "$n" --shard "$shards" \
                    < "$TEST_FILE" 2>> "$STATS_FILE" 1>/dev/null; then
                FAILED=$(( FAILED + 1 ))
                printf "\n[warn] run %d failed for %s\n" "$i" "$STEM" >&2
            fi
            echo "---" >> "$STATS_FILE"
        done
        printf "\r%-46s\r" " "
        [[ $FAILED -gt 0 ]] && FAILURES+=("$STEM: $FAILED/$N_RUNS failed")

        if [[ $RUN_PERF -eq 1 ]]; then
            printf "\r  perf ..."
            perf stat -e "$PERF_EVENTS" \
                "$BIN" --benchmark --N "$n" --shard "$shards" \
                < "$TEST_FILE" 1>/dev/null 2>> "$OUTPUT_DIR/${STEM}.perf.txt" \
                || echo -e "\n[warn] perf run failed for $STEM (events may be unsupported)" >&2
            printf "\r%-46s\r" " "
        fi

        TP=$(median_throughput "$STATS_FILE")
        echo "  → median $TP orders/sec   $(awk -v t="$TP" -v n="$n" 'BEGIN{ if (t+0>0) printf "(%.0f ns/order/thread)", n*1e9/t }')   ($(( $(date +%s) - T0 ))s)"
      done
    done
  done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "────────────────────────────────────────"
echo "ablation complete   cells $CELL   wall $(( $(date +%s) - SWEEP_START ))s   output $OUTPUT_DIR/"
echo ""

for skew in "${SKEWS[@]}"; do
  for prices in "${PRICES[@]}"; do
    mu="${MU[$prices]:-}"
    echo "═══ $skew / $prices ═══"
    if [[ -n "$mu" && "$mu" != "n/a" ]]; then
        echo "  reference: v5s (1 thread, 1 book) = $mu orders/sec = $(awk -v m="$mu" 'BEGIN{printf "%.0f", 1e9/m}') ns/order"
        echo "             ^ different input file and ONE book — a reference point, not a control."
        echo ""
    fi

    printf "  %-8s %-4s %14s %13s %14s %10s %12s %12s\n" \
        "shards" "N" "orders/sec" "spread" "ns/order/thr" "speedup" "efficiency" "p99_ns"
    for shards in "${SHARD_LIST[@]}"; do
      base=""
      for n in "${THREAD_LIST[@]}"; do
        f="$OUTPUT_DIR/${ENGINE}_N${n}_S${shards}_${skew}_${prices}.txt"
        [[ -f "$f" ]] || continue
        tp=$(median_throughput "$f")
        p99=$(median_field "$f" p99_latency_ns)
        [[ -z "$base" ]] && base="$tp"
        printf "  %-8s %-4s %14s %13s %14s %10s %12s %12s\n" \
            "$shards" "$n" "$tp" "$(spread_pct "$f")" \
            "$(awk -v t="$tp" -v n="$n" 'BEGIN{ if (t+0>0) printf "%.0f", n*1e9/t; else printf "n/a" }')" \
            "$(awk -v t="$tp" -v b="$base" 'BEGIN{ if (b+0>0) printf "%.2fx", t/b; else printf "n/a" }')" \
            "$(awk -v t="$tp" -v b="$base" -v n="$n" 'BEGIN{ if (b+0>0) printf "%.2f", t/(n*b); else printf "n/a" }')" \
            "$p99"
      done
    done
    echo ""

    # The decomposition the whole script exists to produce.
    if [[ -n "$mu" && "$mu" != "n/a" ]]; then
      echo "  decomposition (ns/order/thread), per shard count:"
      printf "    %-8s %12s %12s %12s %12s\n" "shards" "mu_v5s" "N=1" "fan-out" "concurrency"
      for shards in "${SHARD_LIST[@]}"; do
        f1="$OUTPUT_DIR/${ENGINE}_N1_S${shards}_${skew}_${prices}.txt"
        [[ -f "$f1" ]] || continue
        t1=$(median_throughput "$f1")
        for n in "${THREAD_LIST[@]}"; do
          [[ "$n" == "1" ]] && continue
          fN="$OUTPUT_DIR/${ENGINE}_N${n}_S${shards}_${skew}_${prices}.txt"
          [[ -f "$fN" ]] || continue
          tN=$(median_throughput "$fN")
          awk -v s="$shards" -v mu="$mu" -v t1="$t1" -v tN="$tN" -v n="$n" 'BEGIN{
              if (mu+0<=0 || t1+0<=0 || tN+0<=0) exit
              a = 1e9/mu; b = 1e9/t1; c = n*1e9/tN
              printf "    %-8s %12.0f %12.0f %12.0f %12.0f   (N=%s)\n", s, a, b, b-a, c-b, n
          }'
        done
      done
      echo ""
      echo "  fan-out     = cost of spreading one hot book into S books (DATA STRUCTURE)"
      echo "  concurrency = cost of adding threads at fixed S (LOCKS + COHERENCE)"
      echo "  Whichever column dominates is where the remaining work is."
      echo ""
    fi
  done
done

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "skipped:"
    printf '  %s\n' "${SKIPPED[@]}"
    echo ""
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo "FAILURES:"
    printf '  %s\n' "${FAILURES[@]}"
    exit 1
fi
