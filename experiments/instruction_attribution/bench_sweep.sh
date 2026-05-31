#!/usr/bin/env bash
# bench_sweep.sh — perf record + perf annotate of insertOrder + matchOrders
# across engines × workloads.
#
# The engines (v1, v2, v3) now expose the per-order push as its own free
# function `insertOrder(...)`, called from `main`'s per-order loop alongside
# `matchOrders()`. Both functions live ENTIRELY inside the per-order timed
# region — so samples landing in them are by construction per-order matching
# work, free of parser / startup / cleanup pollution that would corrupt
# whole-process attribution.
#
# Per (engine × workload) we produce:
#   <engine>_<workload>.data                    raw perf event stream
#   <engine>_<workload>_insertOrder.annot.txt   line-level cycle attribution
#                                               for the push
#   <engine>_<workload>_matchOrders.annot.txt   same for the matching loop
#
# Why annotate by mangled name: insertOrder's signature differs between v1
# (takes `Order*`) and v2/v3 (takes `Order const&`). Demangled names differ
# accordingly. Resolving via `nm | grep _Z11insertOrder` gives us the exact
# mangled symbol per engine, which we then demangle with `c++filt` and pass
# to `perf annotate --symbol=<demangled>` so it matches what perf sees.
#
# Prerequisites (one-time, requires sudo):
#   sudo sysctl kernel.perf_event_paranoid=2
#   make            # release flags now include -g (no codegen impact, just
#                   # adds DWARF so perf annotate can show source lines)
#
# Usage:
#   ./experiments/instruction_attribution/bench_sweep.sh
#   ./experiments/instruction_attribution/bench_sweep.sh --cpu 3 --rate 9999
#   ./experiments/instruction_attribution/bench_sweep.sh --engines "v1 v3"
#   ./experiments/instruction_attribution/bench_sweep.sh --reparse-only

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENGINES=(v1 v2 v3)
TEST_DIR="tests/generated"
CPU_ID=3
SAMPLE_RATE=9999
OUTPUT_SUBDIR="instruction_attribution"
REPARSE_ONLY=0

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)   OUTPUT_SUBDIR="$2"; shift 2 ;;
        --cpu)          CPU_ID="$2";        shift 2 ;;
        --rate)         SAMPLE_RATE="$2";   shift 2 ;;
        --engines)      read -r -a ENGINES <<< "$2"; shift 2 ;;
        --reparse-only) REPARSE_ONLY=1;     shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--output-dir <subdir>] [--cpu ID] [--rate Hz] [--engines "v1 v2 v3"] [--reparse-only]

  --output-dir <subdir>  write to results/<subdir>/ (default: instruction_attribution)
  --cpu ID               CPU core for both perf -C and taskset (default: 3, a P-core)
  --rate Hz              perf record -F sample rate (default: 9999;
                         clamped to /proc/sys/kernel/perf_event_max_sample_rate)
  --engines "v1 v2 ..."  which engines to sweep (default: v1 v2 v3)
  --reparse-only         skip perf record; re-run perf annotate on existing
                         .data files. Use after editing this script or the
                         summarizer without paying the perf record cost again.
EOF
            exit 0
            ;;
        *) echo "[error] unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve paths (always relative to project root)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

OUT_BASE="results/$OUTPUT_SUBDIR"
mkdir -p "$OUT_BASE"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for cmd in perf taskset nm c++filt awk; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[error] '$cmd' not found in PATH" >&2
        exit 1
    fi
done

if [[ "$REPARSE_ONLY" -eq 0 ]]; then
    PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo '?')"
    if [[ "$PARANOID" != "?" && "$PARANOID" -gt 2 ]]; then
        echo "[error] kernel.perf_event_paranoid = $PARANOID  (need ≤ 2)" >&2
        echo "        sudo sysctl kernel.perf_event_paranoid=2" >&2
        exit 1
    fi
    MAX_RATE="$(cat /proc/sys/kernel/perf_event_max_sample_rate 2>/dev/null || echo 0)"
    if [[ "$MAX_RATE" -gt 0 && "$SAMPLE_RATE" -gt "$MAX_RATE" ]]; then
        echo "[warn] requested -F $SAMPLE_RATE exceeds kernel max $MAX_RATE; clamping." >&2
        SAMPLE_RATE="$MAX_RATE"
    fi
fi

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

echo "perf annotate sweep — insertOrder + matchOrders"
echo "  engines    : ${ENGINES[*]}"
echo "  test cases : ${#TEST_FILES[@]}"
echo "  cpu pin    : $CPU_ID"
echo "  sample rate: $SAMPLE_RATE Hz"
echo "  output     : $OUT_BASE/"
echo "  total      : $TOTAL combinations"
[[ "$REPARSE_ONLY" -eq 1 ]] && echo "  mode       : --reparse-only (skipping perf record)"
echo ""

SWEEP_START=$(date +%s)

# ---------------------------------------------------------------------------
# Helper: resolve a function's demangled name in a binary.
# Looks up the mangled symbol with the prefix `_Z11<name>`, demangles via
# c++filt. The length prefix `11` after `_Z` is Itanium ABI for the 11-char
# identifier "insertOrder" / "matchOrders" — both happen to be 11 chars,
# which is convenient but coincidental.
# Returns empty string if the symbol is missing (inlined / stripped).
# ---------------------------------------------------------------------------
resolve_symbol() {
    local bin="$1" raw="$2"
    local mangled
    mangled="$(nm "$bin" 2>/dev/null \
        | awk -v pat=" T _Z11${raw}" '$0 ~ pat {print $NF; exit}')"
    [[ -z "$mangled" ]] && return 1
    c++filt -- "$mangled"
}

# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------
for ENGINE in "${ENGINES[@]}"; do
    BIN="./engine_${ENGINE}"

    if [[ ! -x "$BIN" ]]; then
        echo "  [skip] $BIN not found — run \`make\` first"
        SKIPPED=$(( SKIPPED + ${#TEST_FILES[@]} ))
        continue
    fi

    # Resolve symbol names once per engine — they're stable across workloads.
    INSERT_SYM="$(resolve_symbol "$BIN" "insertOrder" || true)"
    MATCH_SYM="$(resolve_symbol "$BIN" "matchOrders" || true)"

    if [[ -z "$INSERT_SYM" ]]; then
        echo "  [warn] insertOrder not found in $BIN — it was inlined."
        echo "         Add __attribute__((noinline)) in src/engine_${ENGINE}.cpp" \
             "to preserve it as a separate symbol."
    fi
    if [[ -z "$MATCH_SYM" ]]; then
        echo "  [warn] matchOrders not found in $BIN — it was inlined."
    fi

    for TEST_FILE in "${TEST_FILES[@]}"; do
        STEM="$(basename "$TEST_FILE" .txt)"
        DONE=$(( DONE + 1 ))

        DATA="$OUT_BASE/${ENGINE}_${STEM}.data"
        INSERT_OUT="$OUT_BASE/${ENGINE}_${STEM}_insertOrder.annot.txt"
        MATCH_OUT="$OUT_BASE/${ENGINE}_${STEM}_matchOrders.annot.txt"

        echo "[$DONE/$TOTAL]  engine_${ENGINE}  ×  $STEM"
        T0=$(date +%s)

        if [[ "$REPARSE_ONLY" -eq 0 ]]; then
            # -C pins perf sampling to CPU $CPU_ID, killing the hybrid-CPU
            # cpu_atom startup-noise group; taskset pins the process there
            # too so all matching work falls on the same P-core.
            perf record \
                -F "$SAMPLE_RATE" \
                -e cycles \
                -C "$CPU_ID" \
                -o "$DATA" \
                -- taskset -c "$CPU_ID" "$BIN" --benchmark < "$TEST_FILE" \
                >/dev/null 2>"$OUT_BASE/.record.stderr"
        fi

        if [[ ! -f "$DATA" ]]; then
            echo "  [skip] no .data file at $DATA"
            continue
        fi

        # Annotate each function. `--symbol` takes the demangled name; we
        # already resolved both via nm + c++filt above. perf prints to stdout
        # even when the symbol has zero samples (just a header), so an empty
        # file post-hoc means perf didn't write anything (usually: bad symbol
        # name). We don't fail the sweep on a bad symbol — surface it instead.
        : > "$INSERT_OUT"
        if [[ -n "$INSERT_SYM" ]]; then
            perf annotate -i "$DATA" --stdio --source \
                --symbol="$INSERT_SYM" \
                > "$INSERT_OUT" 2>/dev/null || true
        fi
        : > "$MATCH_OUT"
        if [[ -n "$MATCH_SYM" ]]; then
            perf annotate -i "$DATA" --stdio --source \
                --symbol="$MATCH_SYM" \
                > "$MATCH_OUT" 2>/dev/null || true
        fi

        T1=$(date +%s)
        echo "  → done in $(( T1 - T0 ))s"
        echo "     data         : $DATA"
        echo "     insertOrder  : $INSERT_OUT  ($(wc -l < "$INSERT_OUT") lines)"
        echo "     matchOrders  : $MATCH_OUT  ($(wc -l < "$MATCH_OUT") lines)"
        echo ""
    done
done

rm -f "$OUT_BASE/.record.stderr"

SWEEP_END=$(date +%s)
SUCCEEDED=$(( TOTAL - SKIPPED ))

echo "────────────────────────────────────────"
echo "perf annotate sweep complete"
echo "  succeeded : $SUCCEEDED / $TOTAL combinations"
echo "  skipped   : $SKIPPED"
echo "  output    : $OUT_BASE/"
echo "  wall time : $(( SWEEP_END - SWEEP_START ))s"
echo ""
echo "next:"
echo "  python3 experiments/instruction_attribution/summarize.py"
echo ""
echo "interactive inspection of any run:"
echo "  less $OUT_BASE/v3_heavy_overlap_mixed_matchOrders.annot.txt"
echo "  perf annotate -i $OUT_BASE/v3_heavy_overlap_mixed.data --stdio --source"
