#!/bin/env bash

CSV="test_cpuwork.log.csv"
INTERVAL=3600  # 1 hour
# INTERVAL=5

CPU_IDLE="/sys/devices/system/cpu/cpu0/cpuidle"

get_cpuidle() {
    local state=$1
    local field=$2
    cat "$CPU_IDLE/state${state}/${field}" 2>/dev/null || echo "N/A"
}


# test sudo access
if ! cat /sys/power/suspend_stats/success > /dev/null 2>&1; then
    echo "ERROR: sudo access required. Run with sudo or fix sudoers." >&2
    exit 1
fi

get_suspend_stat() {
    local field=$1
    sudo cat /sys/power/suspend_stats/${field} 2>/dev/null | tr -d '[:space:]' || printf "N/A"
}

# header
if [ ! -f "$CSV" ]; then
    printf "%-12s  , %-10s  , %-12s  , %-12s  , %-12s  , %-14s  , %-14s  , %-14s  , %-22s  , %-20s  , %-s\n"\
        "date" "time" "c0_usage" "c1_usage" "c2_usage" "c0_time_us" "c1_time_us" "c2_time_us" "suspend_stats_success" "suspend_stats_fail" "hash" >> "$CSV"
fi

while true; do
    dt=$(date '+%Y-%m-%d')
    tm=$(date '+%H:%M:%S')
    c0u=$(get_cpuidle 0 usage)
    c1u=$(get_cpuidle 1 usage)
    c2u=$(get_cpuidle 2 usage)
    c0t=$(get_cpuidle 0 time)
    c1t=$(get_cpuidle 1 time)
    c2t=$(get_cpuidle 2 time)
    ss=$(get_suspend_stat success)
    sf=$(get_suspend_stat fail)

    hash=$(find /proc/self -maxdepth 1 2>/dev/null | md5sum | cut -d' ' -f1)

    printf "%-12s  , %-10s  , %-12s  , %-12s  , %-12s  , %-14s  , %-14s  , %-14s  , %-22s  , %-20s  , %-s\n" \
        "$dt" "$tm" "$c0u" "$c1u" "$c2u" "$c0t" "$c1t" "$c2t" "$ss" "$sf" "$hash" >> "$CSV"

    sleep $INTERVAL
done
