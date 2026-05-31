#!/usr/bin/env bash
# check_controls.sh — verify the environment matches single_threaded.md.
#
# Reports the state of the controls described in bench_controls/single_threaded.md:
#   1. CPU frequency scaling governor    (should be `performance`)
#   2. Frequency boost / turbo            (should be disabled)
#   3. Power source                       (laptop should be plugged in)
#
# Kernel-level load balancing is NOT checked — the sweeps pin with taskset.
# rdpmc / perf_event_paranoid are NOT checked here either — the rdpmc-based
# sweep (experiments/cache_distribution_analysis/bench_sweep.sh) preflights
# those itself, so checking them in two places would just duplicate noise.
#
# Exit code:
#   0 if no FAIL (warnings are fine)
#   1 if any FAIL
#
# Usage:
#   ./bench_controls/check_controls.sh

set -u

# ---------------------------------------------------------------------------
# Color helpers (only if stdout is a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'
    B=$'\033[1m';  X=$'\033[0m'
else
    R=''; G=''; Y=''; C=''; B=''; X=''
fi

PASS=0; FAIL=0; WARN=0

pass() { printf "${G}[ PASS ]${X} %-22s  %s\n" "$1" "$2"; PASS=$((PASS+1)); }
fail() {
    printf "${R}[ FAIL ]${X} %-22s  %s\n" "$1" "$2"
    FAIL=$((FAIL+1))
    [[ ${3-} ]] && printf "         ${C}fix:${X} %s\n" "$3"
}
warn() {
    printf "${Y}[ WARN ]${X} %-22s  %s\n" "$1" "$2"
    WARN=$((WARN+1))
    [[ ${3-} ]] && printf "         ${C}fix:${X} %s\n" "$3"
}
info() { printf "${C}[ INFO ]${X} %-22s  %s\n" "$1" "$2"; }

# ---------------------------------------------------------------------------
echo "${B}=== Single-threaded benchmark controls check ===${X}"
echo "$(date)"
echo

# 1. CPU governor — every core should be on `performance`.
# ---------------------------------------------------------------------------
GOV_FILES=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
if [[ ! -f "${GOV_FILES[0]}" ]]; then
    warn "CPU governor" "no cpufreq/scaling_governor (driver may not support it)"
else
    GOVS_UNIQUE="$(cat "${GOV_FILES[@]}" 2>/dev/null | sort -u)"
    N_UNIQUE="$(echo "$GOVS_UNIQUE" | wc -l)"
    if [[ "$GOVS_UNIQUE" == "performance" ]]; then
        pass "CPU governor" "all cores = performance"
    elif [[ "$N_UNIQUE" -eq 1 ]]; then
        fail "CPU governor" "all cores = $GOVS_UNIQUE (should be performance)" \
            "sudo cpupower frequency-set -g performance"
    else
        SUM="$(echo "$GOVS_UNIQUE" | tr '\n' ',' | sed 's/,$//')"
        fail "CPU governor" "mixed: $SUM (should be performance)" \
            "sudo cpupower frequency-set -g performance"
    fi
fi

# 2. Turbo / frequency boost.
# ---------------------------------------------------------------------------
NO_TURBO=/sys/devices/system/cpu/intel_pstate/no_turbo
CPUFREQ_BOOST=/sys/devices/system/cpu/cpufreq/boost
if [[ -f $NO_TURBO ]]; then
    if [[ "$(cat $NO_TURBO)" == "1" ]]; then
        pass "Turbo boost" "disabled (intel_pstate/no_turbo=1)"
    else
        fail "Turbo boost" "enabled (intel_pstate/no_turbo=0)" \
            "echo 1 | sudo tee $NO_TURBO"
    fi
elif [[ -f $CPUFREQ_BOOST ]]; then
    # AMD or generic cpufreq path: 0 = disabled.
    if [[ "$(cat $CPUFREQ_BOOST)" == "0" ]]; then
        pass "Turbo boost" "disabled (cpufreq/boost=0)"
    else
        fail "Turbo boost" "enabled (cpufreq/boost=1)" \
            "echo 0 | sudo tee $CPUFREQ_BOOST"
    fi
else
    warn "Turbo boost" "no intel_pstate/no_turbo or cpufreq/boost knob found"
fi

# 3. Power source — laptop must be plugged in.
# ---------------------------------------------------------------------------
AC_NAME=""; AC_ONLINE=""
BAT_STATUS=""; BAT_CAP=""

for psy in /sys/class/power_supply/*/; do
    [[ -d $psy ]] || continue
    [[ -f "$psy/type" ]] || continue
    TYPE="$(cat "$psy/type")"
    if [[ "$TYPE" == "Mains" && -z "$AC_NAME" ]]; then
        AC_NAME="$(basename "$psy")"
        AC_ONLINE="$(cat "$psy/online" 2>/dev/null || echo '?')"
    elif [[ "$TYPE" == "Battery" && -z "$BAT_STATUS" ]]; then
        BAT_STATUS="$(cat "$psy/status"   2>/dev/null || echo '?')"
        BAT_CAP="$(   cat "$psy/capacity" 2>/dev/null || echo '?')"
    fi
done

BAT_SUFFIX=""
[[ -n "$BAT_STATUS" ]] && BAT_SUFFIX="  (battery: $BAT_STATUS, ${BAT_CAP}%)"

if [[ -z "$AC_NAME" ]]; then
    info "Power source" "no AC adapter exposed (desktop or VM?)"
elif [[ "$AC_ONLINE" == "1" ]]; then
    pass "Power source" "$AC_NAME online${BAT_SUFFIX}"
else
    fail "Power source" "$AC_NAME offline (running on battery)${BAT_SUFFIX}" \
        "plug in the AC adapter before running the sweep"
fi

# ---------------------------------------------------------------------------
echo
printf "${B}Result:${X} ${G}%d pass${X}, ${Y}%d warn${X}, ${R}%d fail${X}\n" \
    "$PASS" "$WARN" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
    echo "${R}One or more critical controls are not set — fix before benchmarking.${X}"
    exit 1
fi
exit 0
