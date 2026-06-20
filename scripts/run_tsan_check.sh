#!/usr/bin/env bash
# Thread-sanitizer race check for the concurrent engine(s).
#
# Unlike run_sanitizer_check.sh (ASan/UBSan, single-threaded), data races only
# appear when the engine actually runs multiple threads, AND they are
# non-deterministic — one clean run proves nothing. So this script:
#   * runs each engine with --benchmark, so the benchmark code path executes —
#     that path is where the race lives (every worker calls agg.merge()
#     concurrently after the end barrier). Without --benchmark that code never
#     runs and TSan has nothing to analyse there.
#   * runs each engine with several thread counts (--N), >= 2 (THREADS env)
#   * repeats every (testcase x N) combination REPS times
#   * sets TSAN_OPTIONS for readable reports and a non-zero exit on detection
#
# Because --benchmark prints stats to stderr, "stderr is non-empty" is no longer
# the failure signal. We key off the process EXIT CODE instead: TSan exits with
# `exitcode` (66 by default) when it detects a race; a clean run exits 0 even
# though it printed stats. stdout+stderr are captured and, on failure, printed
# (the capture holds the TSan report).
#
# Build first:   make engine_v4_tsan
#
# Usage:
#   ./scripts/run_tsan_check.sh                       # defaults to ./engine_v4_tsan
#   ./scripts/run_tsan_check.sh ./engine_v4_tsan
#   THREADS="2 4 8 16" REPS=5 ./scripts/run_tsan_check.sh ./engine_v4_tsan
#   TSAN_OPTIONS="halt_on_error=0" ./scripts/run_tsan_check.sh   # show ALL races per run

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR/../tests/generated"

# ── Config (override via env) ────────────────────────────────────────────────
THREADS="${THREADS:-2 4 8}"   # thread counts to sweep; must be >= 2 to expose races
REPS="${REPS:-3}"             # repeats per (testcase x N) — races are flaky

# TSan runtime options. Respect a caller-provided TSAN_OPTIONS if already set.
# halt_on_error=1 stops at the first race (clean output); set it to 0 to list
# every distinct race in one run. exitcode defaults to 66, so a detection makes
# the process exit non-zero and we catch it below.
export TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=1 history_size=7 second_deadlock_stack=1}"

# ── Engines: positional args, or default to the v4 tsan binary ───────────────
if [[ $# -ge 1 ]]; then
    engines=("$@")
else
    engines=("./engine_v4_tsan")
fi

shopt -s nullglob
test_files=("$TEST_DIR"/*.txt)
shopt -u nullglob

if [[ ${#test_files[@]} -eq 0 ]]; then
    echo "[error] no test files found in $TEST_DIR" >&2
    exit 1
fi

any_error=0

for engine in "${engines[@]}"; do
    if [[ ! -f "$engine" ]]; then
        echo "[error] engine not found: $engine  (build it: make $(basename "$engine"))" >&2
        exit 1
    fi
    if [[ ! -x "$engine" ]]; then
        echo "[error] not executable: $engine  (try: chmod +x $engine)" >&2
        exit 1
    fi

    engine_name="$(basename "$engine")"
    echo "=== $engine_name   (THREADS='$THREADS', REPS=$REPS) ==="

    for test_file in "${test_files[@]}"; do
        test_name="$(basename "$test_file" .txt)"

        for n in $THREADS; do
            printf "  %-32s N=%-3s" "$test_name" "$n"

            fail=0
            exit_code=0
            report=""
            for ((r = 1; r <= REPS; r++)); do
                # Run with --benchmark so the merge path executes. Capture stdout
                # AND stderr (2>&1): on a clean run stderr holds benchmark stats,
                # on a dirty run it holds the TSan race report.
                run_out=$("$engine" --benchmark --N "$n" < "$test_file" 2>&1)
                exit_code=$?
                # Detection is by exit code only — TSan exits non-zero (exitcode,
                # 66 by default) on a race; a clean run exits 0 despite the stats.
                if [[ $exit_code -ne 0 ]]; then
                    fail=1
                    report="$run_out"
                    break   # one trip is enough; halt_on_error already stopped it
                fi
            done

            if [[ $fail -eq 0 ]]; then
                echo "ok (x$REPS)"
            else
                echo "FAIL (exit $exit_code, rep $r/$REPS)"
                [[ -n "$report" ]] && echo "$report" | sed 's/^/    /'
                any_error=1
            fi
        done
    done

    echo ""
done

if [[ $any_error -eq 0 ]]; then
    echo "All clean — no races detected."
else
    echo "Races / errors detected — see output above."
fi

exit $any_error
