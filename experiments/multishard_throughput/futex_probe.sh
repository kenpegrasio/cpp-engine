#!/usr/bin/env bash
# futex_probe.sh — count FUTEX syscalls per order for engine_<E>, per skew × price mode.
#
# --engine v6a     (default) MutexQueue: mutex + condition_variable. Expect ~1 futex/order
#                  on uniform (the cv wakeup floor) and ~0.03 on one-hot.
# --engine v6a_nb  NonblockingMutexQueue: mutex only, no cv, pop() spins on empty. The cv's
#                  futexes should VANISH. Whatever futexes SURVIVE are mutex contention --
#                  which is exactly the number this probe exists to isolate.
#
# WHAT THIS TESTS
#
# PINNING / CORES: this script never tasksets. Workers self-pin via CoreAllocator,
# whose core_order omits cpu0 (kernel/ACPI saturated it: ~97% %sys, 3x slower) and
# cpu1 (cpu0's HT sibling: 35% slower while reporting 93% idle), leaving 5 clean
# physical P-cores {2,4,6,8,10}. Spilling past those onto a shared physical core is
# NOT checked for — the worker count is engine-specific, so no formula covers every
# engine. Any result recorded before the cpu0/cpu1 fix is contaminated — re-run
# rather than compare.
#
# The question: how much of the shard boundary's cost is the CONDITION VARIABLE?
# Measured on clean cores, the cv path costs ~1 futex syscall per order on uniform
# vs ~0.03 on one-hot — the queue is empty on uniform (consumer sleeps, every push
# must FUTEX_WAKE) and permanently backlogged on one-hot (predicate already true,
# no syscall at all). The mechanism:
#
#     cond_var_.wait(lock, pred)   with pred TRUE  on entry -> returns, NO syscall
#                                  with pred FALSE on entry -> FUTEX_WAIT, thread sleeps
#     cond_var_.notify_one()       with NO waiter registered -> returns, NO syscall
#                                  with a waiter registered  -> FUTEX_WAKE syscall
#
# So the cv's cost is conditional on the queue being EMPTY, and the per-item cost is
#
#     wakeup cost / items drained per wakeup   <- queue depth IS the amortization factor
#
# By Little's law on the sweep's own numbers (L = lambda * W_q):
#     one-hot: L ~ 260,000 orders queued  -> consumer never sleeps  -> ~0 futex/order
#     uniform: L ~      1  order  queued  -> consumer sleeps ~always -> ~1+ futex/order
#
# MEASURED (v6a, clean cores):
#
#     uniform / zipf : ~1.0 futex per order   (~0.12 sleeps + ~0.9 wakes)
#     one-hot        : ~0.03 futex per order  (backlogged queue -> no syscall)
#
# Note the asymmetry inside that number: wakes >> sleeps, because a thread registers
# as a waiter BEFORE it sleeps and stays registered until fully awake, so notify_one()
# is obliged to syscall for waiters that never actually slept.
#
# CAVEAT: a LOW futex count does not exonerate a lock. Uncontended locks take a plain
# CAS with no syscall, so a cost that is cache-line ping-pong on shared metadata shows
# up as zero futexes. Cross-check invol_ctxsw (preemption) and cache counters before
# concluding "not a lock, therefore not synchronization".
#
# WHAT IS COUNTED
#
#   syscalls:sys_enter_futex        every futex(2) call. glibc 2.39 uses the classic
#                                   syscall for BOTH mutex contention and cv wait/signal.
#   syscalls:sys_enter_futex_wait   the futex2 syscalls. glibc 2.39 does not use these;
#   syscalls:sys_enter_futex_wake   counted only to PROVE they are zero, so that
#                                   sys_enter_futex is known to be the whole story.
#   context-switches, cpu-migrations
#
#   Voluntary / involuntary context switches (from /usr/bin/time -v, i.e. getrusage):
#                                   these need NO privileges at all, and voluntary
#                                   ctxsw ~= "how many times did a thread actually go
#                                   to sleep" ~= FUTEX_WAITs that really blocked. That
#                                   gives a WAIT-vs-WAKE decomposition for free:
#                                       futex_total - vol_ctxsw  ~=  FUTEX_WAKEs
#                                   which is exactly the producer-side vs consumer-side
#                                   split. (perf stat has no --filter, so filtering the
#                                   tracepoint's `op` field is not available to us.)
#
# PERTURBATION WARNING — READ THIS BEFORE QUOTING ANY THROUGHPUT FROM HERE
#
# Counting a tracepoint is not free: every futex hit runs a perf handler (~hundreds of
# ns). At ~2M events that can add hundreds of ms to a ~1.3s run. So:
#
#     * The futex COUNTS are the deliverable. They are exact.
#     * The ops_per_sec column in the CSV is a PERTURBED throughput. Do not quote it.
#       It is recorded only so you can see how much perf cost you — compare it against
#       results/multishard_throughput/ (the clean sweep) and expect it to be lower.
#     * Perf slows the PRODUCERS (the threads issuing FUTEX_WAKE) more than the shards,
#       which empties the queues further, which if anything INCREASES the futex count in
#       the starved configs. Treat uniform/zipf counts as an upper bound; the ~30x ratio
#       against one-hot is far too large for that to explain away.
#
# PRIVILEGES
#
# This box ships kernel.perf_event_paranoid=4 and /sys/kernel/tracing at mode 700, so
# tracepoints are root-only out of the box.
#
#   (a) SIMPLEST — ./futex_probe.sh --sudo
#       Wraps perf in sudo. The engine then runs as root, which changes nothing about
#       its scheduling or its futex behaviour.
#
#   (b) Run as yourself. This needs THREE things, not two — the third is the one people
#       miss, and the script's error message will tell you which one is still failing:
#
#           sudo sysctl -w kernel.perf_event_paranoid=1      # 1. the sysctl
#           sudo mount -o remount,mode=755 /sys/kernel/tracing # 2. the tracefs DIRECTORIES
#           sudo chmod -R o+r /sys/kernel/tracing/events       # 3. the per-event FILES
#
#       Step 2 makes the directories traversable but leaves each event's `id` file at
#       0440 root:root — and perf must READ that `id` to learn the tracepoint's numeric
#       ID before it can call perf_event_open(). Hence step 3. (Some kernels refuse
#       chmod on tracefs; if yours does, use --sudo.) All three revert on reboot.
#
#   (c) ./futex_probe.sh --no-perf   no privileges at all. Skips perf and reports ONLY
#       the getrusage context-switch counters. These count the SLEEPER (a thread blocking
#       in FUTEX_WAIT) but never the WAKER (a producer issuing FUTEX_WAKE keeps running
#       and is never descheduled), so they undercount the true futex traffic — roughly by
#       half. Weaker, but it still shows the effect and it cannot perturb the run.
#
# USAGE
#
#   ./experiments/multishard_throughput/futex_probe.sh
#   ./experiments/multishard_throughput/futex_probe.sh --runs 10
#   ./experiments/multishard_throughput/futex_probe.sh --sudo
#   ./experiments/multishard_throughput/futex_probe.sh --no-perf --skip-controls   # smoke
#
# Then plot:
#   python3 experiments/multishard_throughput/plot_futex.py

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENGINE=v6a
SHARDS=3
PRODUCERS=3
N_RUNS=5
N_WARMUP=1                  # one untimed rep to warm the page cache for the ~25MB input
TEST_DIR="tests/generated_shards"
OUTPUT_DIR="results/multishard_futex"
USE_SUDO=0
NO_PERF=0
SKIP_CONTROLS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)        ENGINE="$2"; shift 2 ;;
        --shards)        SHARDS="$2"; shift 2 ;;
        --producers|--N) PRODUCERS="$2"; shift 2 ;;
        --runs)          N_RUNS="$2"; shift 2 ;;
        --warmup)        N_WARMUP="$2"; shift 2 ;;
        --test-dir)      TEST_DIR="$2"; shift 2 ;;
        --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
        --sudo)          USE_SUDO=1; shift ;;
        --no-perf)       NO_PERF=1; shift ;;
        --skip-controls) SKIP_CONTROLS=1; shift ;;
        -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -90; exit 0 ;;
        *)               echo "[error] unknown argument: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Preflight: binary, testcases, bench controls
# ---------------------------------------------------------------------------
BIN="./engine_${ENGINE}"
if [[ ! -x "$BIN" ]]; then
    echo "[error] $BIN not found — run \`make engine_${ENGINE}\` first" >&2
    exit 1
fi

mapfile -t TEST_FILES < <(ls "$TEST_DIR"/multi_${SHARDS}_*.txt 2>/dev/null | sort)
if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    echo "[error] no multi_${SHARDS}_*.txt files in $TEST_DIR" >&2
    echo "        generate them with: ./tests/generate_bulk_multishard_testcases.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Core budget — YOUR responsibility, same as in sweep.sh (which also no longer guards).
#
# This script does NOT taskset: every worker self-pins via CoreAllocator, whose
# core_order deliberately omits cpu0 (kernel/IRQ/ACPI work saturates it — measured
# ~97% %sys, and a thread pinned there ran 3x slower) and cpu1 (cpu0's hyperthread
# sibling, which shares execution ports with that same load and measured 35% slower
# while still reporting 93% idle).
#
# That leaves 5 clean physical P-cores {2,4,6,8,10}. Past those, core_order hands out
# hyperthread siblings {3,5,7,9,11}, so two workers land on ONE physical core and
# contend for its execution ports.
#
# There is no automatic check because the worker count is engine-specific: v6a / v6a_nb
# spawn N+S, but v6b (shared feed, no producer threads) and v6a_static (no queues)
# spawn fewer, and a guard on N+S rejected configurations that actually fit.
#
# Futex COUNTS are fairly robust to a slow core (a syscall is a syscall), but the
# co-recorded ops_per_sec and invol_ctxsw columns are not — and invol_ctxsw is exactly
# the column that exposed the cpu0 problem. Keep the configuration honest yourself.
# ---------------------------------------------------------------------------

if [[ $SKIP_CONTROLS -eq 0 ]]; then
    if ! ./bench_controls/check_controls.sh; then
        echo "" >&2
        echo "[error] bench controls not satisfied — fix the FAILs above, or pass --skip-controls." >&2
        echo "        (Counts are robust to governor/turbo; the ops_per_sec column is not.)" >&2
        exit 1
    fi
else
    echo "[warn] --skip-controls: the ops_per_sec column from this run is NOT quotable" >&2
fi

# ---------------------------------------------------------------------------
# Preflight: perf. Decide the mode, then probe each event so that one unsupported
# tracepoint on some other kernel does not sink the whole event list.
# ---------------------------------------------------------------------------
PERF_PREFIX=()
PERF_OK=0
EVENTS=""

perf_can_open() {   # $1 = event name
    "${PERF_PREFIX[@]}" perf stat -e "$1" -- /bin/true >/dev/null 2>&1
}

# syscalls:sys_enter_futex is the entire point of this script. It is REQUIRED, never
# "skipped with a warning" — a CSV with no futex column silently answers a different
# question than the one that was asked.
REQUIRED_EVENT="syscalls:sys_enter_futex"

if [[ $NO_PERF -eq 1 ]]; then
    echo "[mode] --no-perf: getrusage context-switch counters only (no futex totals)."
else
    # --sudo means "use sudo", not "use sudo only if the unprivileged path fails". Set
    # the prefix up front; do not probe our way around an explicit instruction.
    if [[ $USE_SUDO -eq 1 ]]; then
        echo "[perf] --sudo: caching credentials..."
        sudo -v
        PERF_PREFIX=(sudo)
    fi

    # Probe the event we actually came here for. Probing a proxy (task-clock, a SOFTWARE
    # event) proves nothing: software events open fine at paranoid=1 while tracepoints
    # still fail on the per-event `id` file mode, so a proxy check reports a false OK.
    if perf_can_open "$REQUIRED_EVENT"; then
        PERF_OK=1
    else
        ID_FILE=/sys/kernel/tracing/events/syscalls/sys_enter_futex/id
        cat >&2 <<EOF

[error] perf cannot open $REQUIRED_EVENT — the futex count is the whole point of this
        script, so this is fatal rather than a warning.

        diagnosis
          kernel.perf_event_paranoid  = $(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo '?')       (needs <= 1)
          /sys/kernel/tracing         = $(stat -c '%a %U' /sys/kernel/tracing 2>/dev/null || echo '?')     (dir needs to be traversable)
          $ID_FILE
                                      = $(stat -c '%a %U' "$ID_FILE" 2>/dev/null || echo '?')     (perf must READ this file)

        Note the last line: remounting tracefs 755 fixes the DIRECTORIES but leaves the
        per-event files at 0440 root:root, and perf has to read that \`id\` to learn the
        tracepoint's numeric ID. That is usually what is still blocking you.

        fixes
          (a) re-run with --sudo                        <- simplest; engine runs as root
          (b) sudo chmod -R o+r /sys/kernel/tracing/events
              (then run as yourself; some kernels refuse chmod on tracefs — if so, use (a))
          (c) re-run with --no-perf                     <- no privileges, no futex column:
              getrusage context switches only. Counts the SLEEPER but never the WAKER,
              so it undercounts. Weaker, but still shows the effect.

        for reference, the sysctl (you have likely already done this one):
          sudo sysctl -w kernel.perf_event_paranoid=1

EOF
        exit 1
    fi

    EVENTS="$REQUIRED_EVENT"

    # Optional extras. These MAY legitimately be absent on some kernels, so a warning
    # is the right response here — unlike the required event above.
    #   sys_enter_futex_wait  — futex2. Expected 0 on glibc 2.39; counted so that a
    #   sys_enter_futex_wake    zero PROVES sys_enter_futex is the whole story.
    for ev in syscalls:sys_enter_futex_wait \
              syscalls:sys_enter_futex_wake \
              context-switches \
              cpu-migrations; do
        if perf_can_open "$ev"; then
            EVENTS="$EVENTS,$ev"
        else
            echo "[warn] optional event not available, skipping: $ev" >&2
        fi
    done

    echo "[mode] perf ${PERF_PREFIX[*]:+(sudo) }counting: $EVENTS"
fi

# ---------------------------------------------------------------------------
# Scratch space. perf/time write here; under --sudo these come out root-owned, which
# is fine — rm needs write permission on the DIRECTORY, not on the file, and this
# directory is ours. Unique filename per rep, so nothing is ever truncated.
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LABEL="${ENGINE}_N${PRODUCERS}_S${SHARDS}"
# One CSV per (engine, N, S), so `--engine v6a_nb` cannot clobber the v6a run, AND a
# `--shards 64` run cannot clobber a `--shards 3` run of the SAME engine (this used to
# key on $ENGINE alone and silently truncated the previous shard count's data — lost a
# real B=3 dataset to a B=64 run before this fix). The explicit `engine`/`shards` columns
# let plot_futex.py / plot_engine_comparison.py filter without parsing $LABEL (which is
# ambiguous on its own: "v6a_nb_N3_S3" does not split cleanly on "_N").
CSV="$OUTPUT_DIR/futex_counts_${LABEL}.csv"
echo "engine,label,producers,shards,skew,prices,rep,orders,elapsed_ms,ops_per_sec,futex,futex2_wait,futex2_wake,ctx_switches,cpu_migrations,vol_ctxsw,invol_ctxsw" > "$CSV"

echo ""
echo "futex probe"
echo "  engine     : $BIN --benchmark --N $PRODUCERS --shard $SHARDS"
echo "  test cases : ${#TEST_FILES[@]} (from $TEST_DIR)"
echo "  runs each  : $N_RUNS (+$N_WARMUP warmup)"
echo "  output     : $CSV"
echo ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# The input header is:  <num_shards>\n <symbol> x num_shards \n\n <num_orders>\n ...
# so token[num_shards + 2] is the order count. Read tokens, don't count lines.
#
# The comment above always said this; a previous implementation used `NR<=32` as a
# shortcut, which silently broke for shard counts >~30 (the order-count token falls
# past line 32, so it was never collected -> printed 0 -> every futex/order ratio in
# the run divided by zero). Stop by TOKEN COUNT instead, so it is correct for any
# shard count and, as a bonus, exits as soon as it has the answer instead of scanning
# a 1M-order file.
order_count() {
    awk '
        NR == 1 { s = $1 + 0 }
        {
            for (i = 1; i <= NF; i++) {
                n++
                if (n == s + 2) { print $i; found = 1; exit }
            }
        }
        END { if (!found) print 0 }
    ' "$1"
}

# perf stat -x, emits: <value>,<unit>,<event>,<run_ns>,<pct>,...
# The value is "<not counted>" / "<not supported>" when the counter never opened.
perf_value() {   # $1 = perf output file   $2 = event name
    [[ -f "$1" ]] || { echo ""; return; }
    awk -F',' -v ev="$2" '
        $3 == ev {
            v = $1
            gsub(/[^0-9]/, "", v)
            print (v == "" ? "" : v)
            exit
        }' "$1"
}

rusage_value() { # $1 = time -v output file   $2 = grep key
    [[ -f "$1" ]] || { echo ""; return; }
    grep -m1 "$2" "$1" 2>/dev/null | awk -F': ' '{ gsub(/ /, "", $2); print $2 }'
}

# The engine prints three key=value blocks (Queue / Match / Total). All three carry the
# same elapsed_ms and operations_per_sec — one batch span, one sample count — so taking
# the last occurrence (Total) is exact, not a choice.
last_stat() {    # $1 = engine stderr file   $2 = key
    [[ -f "$1" ]] || { echo ""; return; }
    grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2
}

# Median of (field $4 / field $5) over the rows of one cell. Done with sort(1) rather
# than awk's asort() — /usr/bin/awk here is mawk, which has no asort.
cell_median() {  # $1 = csv  $2 = skew  $3 = prices  $4 = numerator field  $5 = denom field ("" = raw)
    awk -F',' -v s="$2" -v p="$3" -v a="$4" -v b="$5" '
        $5 == s && $6 == p && $a != "" {
            printf "%.6f\n", (b == "" ? $a : $a / $b)
        }' "$1" 2>/dev/null \
    | sort -n \
    | awk '{ v[NR] = $1 }
           END { if (NR == 0) print "n/a"; else printf "%.3f\n", v[int((NR + 1) / 2)] }'
}

# ---------------------------------------------------------------------------
# One measured invocation
# ---------------------------------------------------------------------------
run_one() {   # $1 = test file  $2 = tag (unique per rep)  -> echoes a CSV tail
    local test_file="$1" tag="$2"
    local perf_out="$TMP/perf.$tag" time_out="$TMP/time.$tag" eng_out="$TMP/eng.$tag"
    : > "$eng_out"

    if [[ $NO_PERF -eq 1 ]]; then
        /usr/bin/time -v -o "$time_out" \
            "$BIN" --benchmark --N "$PRODUCERS" --shard "$SHARDS" \
            < "$test_file" 1>/dev/null 2>>"$eng_out" || return 1
    else
        "${PERF_PREFIX[@]}" perf stat -x, -o "$perf_out" -e "$EVENTS" -- \
            /usr/bin/time -v -o "$time_out" \
            "$BIN" --benchmark --N "$PRODUCERS" --shard "$SHARDS" \
            < "$test_file" 1>/dev/null 2>>"$eng_out" || return 1
    fi

    # A missing counter yields an empty field, never a missing column.
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(last_stat "$eng_out" elapsed_ms)" \
        "$(last_stat "$eng_out" operations_per_sec)" \
        "$(perf_value "$perf_out" syscalls:sys_enter_futex)" \
        "$(perf_value "$perf_out" syscalls:sys_enter_futex_wait)" \
        "$(perf_value "$perf_out" syscalls:sys_enter_futex_wake)" \
        "$(perf_value "$perf_out" context-switches)" \
        "$(perf_value "$perf_out" cpu-migrations)" \
        "$(rusage_value "$time_out" 'Voluntary context switches')" \
        "$(rusage_value "$time_out" 'Involuntary context switches')"
}

# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------
CELL=0
TOTAL=${#TEST_FILES[@]}
FAILURES=()

for TEST_FILE in "${TEST_FILES[@]}"; do
    STEM="$(basename "$TEST_FILE" .txt)"          # multi_3_uniform_wide_range
    REST="${STEM#multi_${SHARDS}_}"               # uniform_wide_range
    SKEW="${REST%%_*}"                            # uniform
    PRICES="${REST#*_}"                           # wide_range
    ORDERS="$(order_count "$TEST_FILE")"
    if [[ -z "$ORDERS" || "$ORDERS" -eq 0 ]]; then
        echo "[error] order_count() returned 0 for $TEST_FILE — the header parse is" >&2
        echo "        broken for this file, and every futex/order ratio from this run" >&2
        echo "        would silently divide by zero. Refusing to continue." >&2
        exit 1
    fi
    CELL=$(( CELL + 1 ))

    echo "[$CELL/$TOTAL]  $SKEW / $PRICES   ($ORDERS orders)"

    for (( i = 1; i <= N_WARMUP; i++ )); do
        printf "\r  warmup %d/%d ..." "$i" "$N_WARMUP"
        run_one "$TEST_FILE" "warm.$CELL.$i" >/dev/null 2>&1 || true
    done

    FAILED=0
    for (( i = 1; i <= N_RUNS; i++ )); do
        printf "\r  run    %d/%d ..." "$i" "$N_RUNS"
        if TAIL="$(run_one "$TEST_FILE" "$CELL.$i")"; then
            echo "$ENGINE,$LABEL,$PRODUCERS,$SHARDS,$SKEW,$PRICES,$i,$ORDERS,$TAIL" >> "$CSV"
        else
            FAILED=$(( FAILED + 1 ))
            printf "\n[warn] run %d failed for %s\n" "$i" "$STEM" >&2
        fi
    done
    printf "\r%-40s\r" " "

    [[ $FAILED -gt 0 ]] && FAILURES+=("$STEM: $FAILED/$N_RUNS runs failed")

    # Median futex/order, vol-ctxsw/order and (perturbed) throughput for this cell.
    printf "  → futex/order %s   vol-ctxsw/order %s   throughput %s ops/s (PERTURBED — see header)\n" \
        "$(cell_median "$CSV" "$SKEW" "$PRICES" 11 8)" \
        "$(cell_median "$CSV" "$SKEW" "$PRICES" 16 8)" \
        "$(cell_median "$CSV" "$SKEW" "$PRICES" 10 '')"
    echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "────────────────────────────────────────"
echo "wrote $CSV"
echo ""
echo "The prediction under test: uniform/zipf ~ 1+ futex per order; one-hot ~ 0."
echo "If futex2_wait / futex2_wake are 0 (they should be on glibc 2.39), then"
echo "sys_enter_futex is the complete futex story for this binary."
echo ""
echo "Plot it:  python3 experiments/multishard_throughput/plot_futex.py --engine $ENGINE --producers $PRODUCERS --shards $SHARDS"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    echo "FAILURES:"
    printf '  %s\n' "${FAILURES[@]}"
    exit 1
fi
