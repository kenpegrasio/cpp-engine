#!/usr/bin/env bash
# Run one or more engines against every test case and print only errors.
# Normal trade output is suppressed. Anything on stderr (ASan, UBSan, TSan,
# uncaught exceptions, crashes) is shown with the offending test case labelled.
#
# Usage:
#   ./tests/run_sanitizer_check.sh ./engine_v1_asan
#   ./tests/run_sanitizer_check.sh ./engine_v1_asan ./engine_v2_asan
#   ./tests/run_sanitizer_check.sh ./engine_v1_tsan

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR/generated"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <engine> [engine ...]" >&2
    exit 1
fi

shopt -s nullglob
test_files=("$TEST_DIR"/*.txt)
shopt -u nullglob

if [[ ${#test_files[@]} -eq 0 ]]; then
    echo "[error] no test files found in $TEST_DIR" >&2
    exit 1
fi

any_error=0

for engine in "$@"; do
    if [[ ! -f "$engine" ]]; then
        echo "[error] engine not found: $engine" >&2
        exit 1
    fi
    if [[ ! -x "$engine" ]]; then
        echo "[error] not executable: $engine  (try: chmod +x $engine)" >&2
        exit 1
    fi

    engine_name="$(basename "$engine")"
    echo "=== $engine_name ==="

    for test_file in "${test_files[@]}"; do
        test_name="$(basename "$test_file" .txt)"
        printf "  %-35s" "$test_name ..."

        # stdout (trade output) -> /dev/null
        # stderr (sanitizer / crash output) -> captured
        # Redirect order matters: 2>&1 first (stderr -> current stdout = capture pipe),
        # then 1>/dev/null (stdout -> /dev/null).
        stderr_out=$("$engine" < "$test_file" 2>&1 1>/dev/null)
        exit_code=$?

        if [[ $exit_code -eq 0 && -z "$stderr_out" ]]; then
            echo "ok"
        else
            echo "FAIL (exit $exit_code)"
            if [[ -n "$stderr_out" ]]; then
                echo "$stderr_out" | sed 's/^/    /'
            fi
            any_error=1
        fi
    done

    echo ""
done

if [[ $any_error -eq 0 ]]; then
    echo "All clean."
else
    echo "Errors detected — see output above."
fi

exit $any_error
