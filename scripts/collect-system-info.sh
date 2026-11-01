#!/usr/bin/env bash
set -u

OUT="${1:-system-info.txt}"

{
    echo "=== SYSTEM INFORMATION ==="
    date --iso-8601=seconds
    echo

    echo "=== HOST ==="
    hostname
    uname -a
    echo

    echo "=== CPU ==="
    lscpu
    echo

    echo "=== CPU MICROCODE ==="
    grep -m1 microcode /proc/cpuinfo || true
    echo

    echo "=== GOVERNOR ==="
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -r "$f" ] && echo "$f: $(cat "$f")"
    done
    echo

    echo "=== FREQUENCY ==="
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        [ -r "$f" ] && echo "$f: $(cat "$f")"
    done
    echo

    echo "=== MEMORY ==="
    free -h
    echo

    echo "=== KERNEL ==="
    cat /proc/version
    echo

    echo "=== COMPILERS ==="
    for compiler in gcc clang; do
        if command -v "$compiler" >/dev/null 2>&1; then
            "$compiler" --version
            echo
        fi
    done

    echo "=== BINUTILS ==="
    objdump --version | head -n 1
    echo

    echo "=== PERF ==="
    if command -v perf >/dev/null 2>&1; then
        perf --version
    else
        echo "perf unavailable"
    fi

    echo
    echo "=== ENVIRONMENT ==="
    env | grep -E '^(CC|CFLAGS|OMP_|LD_)' || true

} > "$OUT" 2>&1

echo "System information written to: $OUT"
