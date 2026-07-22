#!/usr/bin/env bash
# perf_counters_sweep.sh — hardware counters across the shard x thread grid, 10 reps, median.
#
# THE QUESTION
#
# Throughput rises with shard count but tops out below single-threaded v5s. Two forces
# pull in opposite directions as shards grow:
#
#     contention   FALLS  (futex/order 0.70 @ S=2  ->  0.027 @ S=64)   helps
#     L2 misses    RISE   (bigger working set: 64 books x 31.4 KB)     hurts
#
# and a third never moves at all:
#
#     line migration  FLAT  (both threads walk every book, so each line is
#                            last-touched by the other core ~50% of the time,
#                            REGARDLESS of shard count)
#
# This script measures all three across the grid so the trade-off is a table of
# numbers instead of an argument.
#
# THE N=1 NULL CONTROL (the reason the grid has a threads axis)
#
# At N=1 there is no second thread, so cross-core HITM must be ~0 BY CONSTRUCTION.
# The script checks this and prints PASS/FAIL. If HITM is materially non-zero at N=1,
# the counter is not measuring what its name claims (system noise, another process,
# or an Alder/Raptor Lake counter quirk) and NOTHING else in the output is trustworthy.
# Run the control before believing the N=2 numbers.
#
# N=1 also gives the cache-only curve: zero contention, zero migration, so the
# L2-miss trend there is pure working-set effect.
#
# ############################################################################
# # SCOPING CAVEAT — READ BEFORE QUOTING ANY PER-ORDER NUMBER                #
# ############################################################################
#
# perf stat counts the WHOLE PROCESS. That includes the single-threaded parse of a
# ~21 MB testcase, splitOrders copying 1M orders, thread spawn, and the final
# agg.merge -- none of which is the matching loop. Typical coverage is only ~30%
# (222 ms of benchmark inside a 868 ms process), so ~70% of every count below comes
# from somewhere other than the thing under study.
#
#   * ABSOLUTE per-order counts from this script are NOT trustworthy.
#   * DIFFERENTIAL comparison across cells IS, because every cell reads a same-sized
#     file (the multi_<S>_* testcases are all 20.3-21.2 MB) so the contamination is
#     near-constant and cancels in the difference.
#
# The `coverage` column reports bench_elapsed / perf_elapsed per cell so you can see
# how much contamination you are carrying. For absolute attribution, scope the
# counters to the timed loop with include/perf_counters.hpp (ioctl enable/disable)
# instead of using this script.
#
# WHY EVENTS ARE RUN IN SMALL GROUPS
#
# Each group is a separate process invocation with <= 4 events, so the PMU never
# multiplexes and every event sees ~99% enabled time. Cramming all groups into one
# run would time-slice the counters and scale the results, which silently adds noise
# to exactly the small differences this study cares about. The pct_enabled column is
# recorded per rep -- anything materially below ~95% means multiplexing happened and
# that cell should be re-run with fewer events.
#
# WHAT IS REPORTED
#
#   median over --runs reps of each event's raw count, plus /order, plus coverage.
#   Median (not mean) because run-to-run noise is one-sided: a scheduler tick or an
#   interrupt can only inflate a count, never deflate it.
#
# REQUIREMENTS
#
#   * ./engine_v6b built at the MAX_SHARDS being swept (changing MAX_SHARDS changes
#     sizeof(EngineV6B) and the layout; build once, vary S via --shard).
#   * Testcases: ./tests/generate_bulk_multishard_testcases.sh
#   * kernel.perf_event_paranoid <= 2 (currently fine at 1 for own processes).
#
# Usage:
#   ./experiments/huge_shards_throughput/perf_counters_sweep.sh
#   ./experiments/huge_shards_throughput/perf_counters_sweep.sh --groups "l2 hitm tlb"
#   ./experiments/huge_shards_throughput/perf_counters_sweep.sh --shards 64 --threads "1 2"
#   ./experiments/huge_shards_throughput/perf_counters_sweep.sh --runs 1 --skip-controls  # smoke

set -euo pipefail

# ---------------------------------------------------------------------------
# Event groups. Keep each <= 4 events so the PMU does not multiplex.
# ---------------------------------------------------------------------------
#
# l2         cache pressure. l2_request.miss is the "working set outgrew L2" signal.
#            NOTE: a miss COUNT says nothing about miss COST -- an L2 miss served by a
#            clean L3 line (~40-50 cyc) and one served by another core's dirty L2
#            (~100-130 cyc) both count as exactly one miss here. That is why this
#            group alone can never explain the N=1 -> N=2 gap; see the hitm group.
#
# hitm       cross-core line transfer -- the migration/ping-pong signal. The
#            .snoop_hitm suffix REQUIRES another core to have held the line MODIFIED;
#            plain .l3_hit without it is an ordinary capacity miss with nobody else
#            caching the line. Split load-side vs store-side because they tell
#            different stories: RFO (stores) = migration + contention retries, so it
#            falls as shards grow; data_rd (loads) = migration only, so it stays flat.
#
# hitm_pebs  cross-check on the above. These are PEBS retired-load events; the ocr.*
#            offcore encodings have known accuracy caveats on Alder/Raptor Lake.
#
#            MEASURED ON THIS CPU (i7-13620H): .xsnp_hitm and .xsnp_fwd return
#            BYTE-IDENTICAL counts -- they alias to the same underlying umask here, so
#            this group yields ONE number reported twice, not two readings. Do not
#            treat their agreement as corroboration; it is a tautology.
#
#            The real cross-check is hitm_pebs vs hitm: 2.72 vs 4.74 per order at
#            N=2/S=64, a ~1.7x gap. That gap is EXPECTED, not an error -- PEBS counts
#            only retired LOAD uops, while ocr.demand_data_rd counts every demand data
#            read that left the core. Same order of magnitude means the offcore counter
#            is credible. A ~10x disagreement would not be; believe the PEBS one then.
#
# l3         does the traffic escape to DRAM, or stay on-socket? Distinguishes a
#            capacity problem (L3 misses rise) from a sharing problem (they do not).
#
# tlb        1.97 MB of books / 4 KB = 481 pages against a ~96-entry L1 dTLB. Small
#            term (~4 ns per walk) but real, and it scales with shard count too.
# ---------------------------------------------------------------------------
declare -A EVENT_GROUPS=(
    [l2]="cpu_core/l2_request.all/,cpu_core/l2_request.miss/"
    [hitm]="cpu_core/ocr.demand_data_rd.l3_hit.snoop_hitm/,cpu_core/ocr.demand_rfo.l3_hit.snoop_hitm/"
    [hitm_pebs]="cpu_core/mem_load_l3_hit_retired.xsnp_hitm/,cpu_core/mem_load_l3_hit_retired.xsnp_fwd/"
    [l3]="cpu_core/longest_lat_cache.reference/,cpu_core/longest_lat_cache.miss/"
    [tlb]="cpu_core/dtlb_load_misses.walk_completed/,cpu_core/dtlb_store_misses.walk_completed/"
)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENGINE=v6b

# Ordered list of every group. EVENT_GROUPS is an associative array and bash iterates
# those in HASH order, which is not stable — so the canonical ordering lives here, and
# both the default and `--groups all` use it. Otherwise the summary tables would come
# out in a different order on different runs, which makes diffing two sweeps miserable.
ALL_GROUPS=(l2 hitm hitm_pebs l3 tlb)

# Default: everything. l2 + hitm answer the headline question (cache cost vs sharing
# cost); the other three are corroboration — hitm_pebs cross-checks the offcore
# counters, l3 separates capacity from sharing, tlb picks up the page-walk term.
# Collecting all of it in one pass costs a few extra minutes and saves a second sweep.
SEL_GROUPS=("${ALL_GROUPS[@]}")
SHARD_LIST=(2 4 8 16 32 64)
THREAD_LIST=(1 2)
SKEWS=(uniform)
PRICES=(wide_range)
N_RUNS=10
N_WARMUP=0
TEST_DIR="tests/generated_shards"
OUTPUT_DIR="results/shard_cache_counters"
SKIP_CONTROLS=0
CLEAN_PHYSICAL_CORES=5      # {2,4,6,8,10} — cpu0 (kernel/ACPI) and cpu1 (HT sibling) excluded

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)        ENGINE="$2"; shift 2 ;;
        --groups)        if [[ "$2" == "all" ]]; then SEL_GROUPS=("${ALL_GROUPS[@]}")
                         else read -r -a SEL_GROUPS <<< "$2"; fi; shift 2 ;;
        --shards)        read -r -a SHARD_LIST <<< "$2"; shift 2 ;;
        --threads|--N)   read -r -a THREAD_LIST <<< "$2"; shift 2 ;;
        --skews)         read -r -a SKEWS <<< "$2"; shift 2 ;;
        --prices)        read -r -a PRICES <<< "$2"; shift 2 ;;
        --runs)          N_RUNS="$2"; shift 2 ;;
        --warmup)        N_WARMUP="$2"; shift 2 ;;
        --test-dir)      TEST_DIR="$2"; shift 2 ;;
        --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
        --skip-controls) SKIP_CONTROLS=1; shift ;;
        --list-groups)   for g in "${!EVENT_GROUPS[@]}"; do printf "  %-12s %s\n" "$g" "${EVENT_GROUPS[$g]}"; done; exit 0 ;;
        -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -75; exit 0 ;;
        *)               echo "[error] unknown argument: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
mkdir -p "$OUTPUT_DIR"

BIN="./engine_${ENGINE}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ -x "$BIN" ]] || { echo "[error] $BIN not found — run \`make engine_${ENGINE}\`" >&2; exit 1; }
command -v perf >/dev/null 2>&1 || { echo "[error] perf not on PATH" >&2; exit 1; }

for g in "${SEL_GROUPS[@]}"; do
    [[ -n "${EVENT_GROUPS[$g]:-}" ]] || {
        echo "[error] unknown event group '$g'. Known: ${!EVENT_GROUPS[*]}" >&2; exit 1; }
done

PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 99)
if [[ "$PARANOID" -gt 2 ]]; then
    echo "[error] kernel.perf_event_paranoid=$PARANOID blocks counting. Run:" >&2
    echo "        sudo sysctl kernel.perf_event_paranoid=2" >&2
    exit 1
fi

for n in "${THREAD_LIST[@]}"; do
    if [[ $n -gt $CLEAN_PHYSICAL_CORES ]]; then
        echo "[error] --threads $n exceeds $CLEAN_PHYSICAL_CORES clean physical cores {2,4,6,8,10}." >&2
        echo "        Beyond that CoreAllocator wraps onto HT siblings; you would be" >&2
        echo "        measuring hyperthread contention, not sharding." >&2
        exit 1
    fi
done

# Fail fast on an unsupported event rather than 10 reps of <not supported>.
for g in "${SEL_GROUPS[@]}"; do
    if ! perf stat -x, -e "${EVENT_GROUPS[$g]}" true >/dev/null 2>&1; then
        echo "[error] event group '$g' is not supported on this PMU: ${EVENT_GROUPS[$g]}" >&2
        echo "        Check \`perf list\`, or drop it from --groups." >&2
        exit 1
    fi
done

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
echo "perf counter sweep — shards x threads"
echo "  engine      : $ENGINE"
echo "  groups      : ${SEL_GROUPS[*]}"
echo "  shard list  : ${SHARD_LIST[*]}"
echo "  thread list : ${THREAD_LIST[*]}"
echo "  skews       : ${SKEWS[*]}     prices: ${PRICES[*]}"
echo "  runs each   : $N_RUNS (+$N_WARMUP warmup)"
echo "  output      : $OUTPUT_DIR/"
echo "  total runs  : $(( ${#SEL_GROUPS[@]} * ${#SHARD_LIST[@]} * ${#THREAD_LIST[@]} * ${#SKEWS[@]} * ${#PRICES[@]} * (N_RUNS + N_WARMUP) ))  (~0.8s each — one process invocation per group so the PMU never multiplexes)"
echo ""
echo "  NOTE: perf stat is UNSCOPED (whole process incl. parse). Per-order numbers"
echo "        below are for DIFFERENTIAL comparison only — see the coverage column."
echo ""

RAW_CSV="$OUTPUT_DIR/raw_counters.csv"
echo "engine,group,threads,shards,skew,prices,rep,event,value,pct_enabled,perf_runtime_ns,bench_elapsed_ms,ops_per_sec,orders" > "$RAW_CSV"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Column label for an event. Hand-mapped rather than derived, because the naive
# "last dot-segment" rule collapses demand_data_rd.l3_hit.snoop_hitm and
# demand_rfo.l3_hit.snoop_hitm to the same string — the two events whose DIVERGENCE
# is the entire point of this study.
short_name() {
    case "$1" in
        *demand_data_rd*snoop_hitm*) echo "dataRd_HITM" ;;
        *demand_rfo*snoop_hitm*)     echo "rfo_HITM" ;;
        *xsnp_hitm*)                 echo "xsnp_hitm" ;;
        *xsnp_fwd*)                  echo "xsnp_fwd" ;;
        *l2_request.all*)            echo "l2_req_all" ;;
        *l2_request.miss*)           echo "l2_req_miss" ;;
        *longest_lat_cache.reference*) echo "llc_ref" ;;
        *longest_lat_cache.miss*)    echo "llc_miss" ;;
        *dtlb_load_misses*)          echo "dtlb_ld_walk" ;;
        *dtlb_store_misses*)         echo "dtlb_st_walk" ;;
        *) local s="${1#cpu_core/}"; echo "${s%/}" ;;
    esac
}

median() {   # stdin: one number per line
    sort -n | awk '{ v[NR] = $1 } END { if (NR == 0) { print "n/a"; exit } printf "%.0f\n", v[int((NR + 1) / 2)] }'
}

# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------
SWEEP_START=$(date +%s)
SKIPPED=()
FAILURES=()
CELL=0

for group in "${SEL_GROUPS[@]}"; do
  EVENTS="${EVENT_GROUPS[$group]}"
  for shards in "${SHARD_LIST[@]}"; do
    for skew in "${SKEWS[@]}"; do
      for prices in "${PRICES[@]}"; do

        TEST_FILE="$TEST_DIR/multi_${shards}_${skew}_${prices}.txt"
        if [[ ! -f "$TEST_FILE" ]]; then
            SKIPPED+=("$group S=$shards: missing $TEST_FILE (run tests/generate_bulk_multishard_testcases.sh)")
            continue
        fi

        for n in "${THREAD_LIST[@]}"; do
          CELL=$(( CELL + 1 ))
          T0=$(date +%s)
          echo "[$CELL]  $group  N=$n  S=$shards  $skew/$prices"

          for (( i = 1; i <= N_WARMUP; i++ )); do
              printf "\r  warmup %2d / %d ..." "$i" "$N_WARMUP"
              "$BIN" --benchmark --N "$n" --shard "$shards" < "$TEST_FILE" &>/dev/null || true
          done

          FAILED=0
          for (( i = 1; i <= N_RUNS; i++ )); do
              printf "\r  run    %2d / %d ..." "$i" "$N_RUNS"

              # perf's own output goes to -o (CSV); the engine's benchmark block stays
              # on stderr. Keeping them in separate streams avoids fragile interleaved
              # parsing.
              if ! perf stat -x, -o "$TMP_DIR/perf.csv" -e "$EVENTS" \
                      "$BIN" --benchmark --N "$n" --shard "$shards" \
                      < "$TEST_FILE" 1>/dev/null 2>"$TMP_DIR/eng.txt"; then
                  FAILED=$(( FAILED + 1 ))
                  printf "\n[warn] run %d failed for %s N=%s S=%s\n" "$i" "$group" "$n" "$shards" >&2
                  continue
              fi

              BENCH_MS=$(grep -m1 '^elapsed_ms=' "$TMP_DIR/eng.txt" | cut -d= -f2 || echo 0)
              OPS=$(grep -m1 '^operations_per_sec=' "$TMP_DIR/eng.txt" | cut -d= -f2 || echo 0)
              ORDERS=$(awk -v o="$OPS" -v e="$BENCH_MS" 'BEGIN{ printf "%.0f", o * e / 1000 }')

              # perf -x, CSV: value,unit,event,run_time_ns,pct_enabled,metric,metric_unit
              # Skip the "# started on" header and blank lines; guard against
              # <not supported> / <not counted> landing in field 1.
              awk -F, -v eng="$ENGINE" -v grp="$group" -v n="$n" -v s="$shards" \
                      -v skew="$skew" -v pr="$prices" -v rep="$i" \
                      -v bms="$BENCH_MS" -v ops="$OPS" -v ord="$ORDERS" '
                  /^#/ || NF < 5 { next }
                  { gsub(/,/, "", $1)
                    if ($1 !~ /^[0-9]+$/) next
                    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
                           eng, grp, n, s, skew, pr, rep, $3, $1, $5, $4, bms, ops, ord }
              ' "$TMP_DIR/perf.csv" >> "$RAW_CSV"
          done
          printf "\r%-46s\r" " "
          [[ $FAILED -gt 0 ]] && FAILURES+=("$group N=$n S=$shards: $FAILED/$N_RUNS failed")
          echo "  → $(( N_RUNS - FAILED ))/$N_RUNS reps recorded   ($(( $(date +%s) - T0 ))s)"
        done
      done
    done
  done
done

# ---------------------------------------------------------------------------
# Summary — median per (group, event, N, S)
# ---------------------------------------------------------------------------
echo ""
echo "────────────────────────────────────────"
echo "sweep complete   cells $CELL   wall $(( $(date +%s) - SWEEP_START ))s"
echo "raw: $RAW_CSV"
echo ""

SUMMARY_CSV="$OUTPUT_DIR/summary_counters.csv"
echo "engine,group,threads,shards,skew,prices,event,median_value,median_per_order,median_pct_enabled,coverage_pct" > "$SUMMARY_CSV"

for group in "${SEL_GROUPS[@]}"; do
  for skew in "${SKEWS[@]}"; do
    for prices in "${PRICES[@]}"; do

      # Event names, in the order the group declares them.
      IFS=',' read -r -a GRP_EVENTS <<< "${EVENT_GROUPS[$group]}"

      echo "═══ group: $group   ($skew / $prices) ═══"
      printf "  %-6s %-4s" "shards" "N"
      for ev in "${GRP_EVENTS[@]}"; do
          short="$(short_name "$ev")"
          printf " %16s %10s" "${short:0:16}" "/order"
      done
      printf " %10s\n" "coverage"

      for shards in "${SHARD_LIST[@]}"; do
        for n in "${THREAD_LIST[@]}"; do
          rows=$(awk -F, -v g="$group" -v n="$n" -v s="$shards" -v sk="$skew" -v pr="$prices" \
                     'NR>1 && $2==g && $3==n && $4==s && $5==sk && $6==pr' "$RAW_CSV")
          [[ -n "$rows" ]] || continue

          printf "  %-6s %-4s" "$shards" "$n"
          for ev in "${GRP_EVENTS[@]}"; do
              med=$(echo "$rows"      | awk -F, -v e="$ev" '$8==e{print $9}' | median)
              perord=$(echo "$rows"   | awk -F, -v e="$ev" '$8==e && $14+0>0 {print $9/$14}' \
                                      | sort -n | awk '{v[NR]=$1} END{ if(NR) printf "%.2f", v[int((NR+1)/2)]; else printf "n/a" }')
              pct=$(echo "$rows"      | awk -F, -v e="$ev" '$8==e{print $10}' | median)
              printf " %16s %10s" "$med" "$perord"

              echo "$ENGINE,$group,$n,$shards,$skew,$prices,$ev,$med,$perord,$pct," >> "$SUMMARY_CSV"
          done

          # coverage = benchmark region / whole perf window. Low coverage = most of the
          # count came from parse/setup, so absolute per-order numbers are inflated.
          cov=$(echo "$rows" | awk -F, '$11+0>0 && $12+0>0 {print 100.0 * ($12/1000.0) / ($11/1e9)}' \
                             | sort -n | awk '{v[NR]=$1} END{ if(NR) printf "%.0f%%", v[int((NR+1)/2)]; else printf "n/a" }')
          printf " %10s\n" "$cov"
        done
      done
      echo ""

      # ---------------------------------------------------------------------
      # N=1 null control. Cross-core HITM requires a second core holding the line
      # dirty; with one thread there is no such core, so these must be ~0. If they
      # are not, the counter is not measuring cross-thread sharing and every HITM
      # number in this run is suspect.
      # ---------------------------------------------------------------------
      if [[ "$group" == hitm* ]]; then
        has_n1=0; for n in "${THREAD_LIST[@]}"; do [[ "$n" == "1" ]] && has_n1=1; done
        if [[ $has_n1 -eq 1 ]]; then
          echo "  null control — HITM at N=1 must be ~0 (no second core to snoop):"
          for shards in "${SHARD_LIST[@]}"; do
            for ev in "${GRP_EVENTS[@]}"; do
              v1=$(awk -F, -v g="$group" -v s="$shards" -v e="$ev" -v sk="$skew" -v pr="$prices" \
                       'NR>1 && $2==g && $3==1 && $4==s && $5==sk && $6==pr && $8==e && $14+0>0 {print $9/$14}' \
                       "$RAW_CSV" | sort -n | awk '{v[NR]=$1} END{ if(NR) printf "%.3f", v[int((NR+1)/2)] }')
              v2=$(awk -F, -v g="$group" -v s="$shards" -v e="$ev" -v sk="$skew" -v pr="$prices" \
                       'NR>1 && $2==g && $3==2 && $4==s && $5==sk && $6==pr && $8==e && $14+0>0 {print $9/$14}' \
                       "$RAW_CSV" | sort -n | awk '{v[NR]=$1} END{ if(NR) printf "%.3f", v[int((NR+1)/2)] }')
              [[ -n "$v1" ]] || continue
              short="${ev#cpu_core/}"; short="${short%/}"
              # PASS if N=1 is under a tenth of N=2 (or N=2 absent, in which case
              # just report the absolute level and let the reader judge).
              verdict=$(awk -v a="$v1" -v b="${v2:-0}" 'BEGIN{
                  if (b+0 <= 0) { print (a+0 < 0.05) ? "PASS" : "CHECK" }
                  else          { print (a+0 < 0.1*b) ? "PASS" : "FAIL" } }')
              printf "    S=%-3s %-52s N=1 %8s/order   N=2 %8s/order   [%s]\n" \
                     "$shards" "$short" "$v1" "${v2:-n/a}" "$verdict"
            done
          done
          echo ""
          echo "    FAIL means the HITM counter fires without a second thread — treat every"
          echo "    HITM number in this run as unattributed until that is explained."
          echo ""
        fi
      fi
    done
  done
done

echo "summary: $SUMMARY_CSV"
echo ""
echo "Reading guide:"
echo "  l2_request.miss /order rising with S      = working set outgrew L2 (the cost of sharding)"
echo "  demand_rfo HITM /order falling with S     = contention retries dying (the benefit)"
echo "  demand_data_rd HITM /order FLAT with S    = line migration, which sharding cannot fix"
echo "  all HITM ~0 at N=1                        = the counters mean what they say"
echo ""
echo "  A miss COUNT is not a miss COST: the same l2_request.miss is ~40-50 cycles when"
echo "  L3 serves it clean and ~100-130 when another core forwards it dirty. That is why"
echo "  the l2 group alone can never explain the N=1 -> N=2 gap."

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo ""
    echo "skipped:"
    printf '  %s\n' "${SKIPPED[@]}"
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    echo "FAILURES:"
    printf '  %s\n' "${FAILURES[@]}"
    exit 1
fi
