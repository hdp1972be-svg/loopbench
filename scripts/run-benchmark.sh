#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src/loopbench.c"

U="${1:-97}"
R="${2:-7}"
REPS="${3:-5}"

# Optional environment configuration
CPU="${CPU:-}"
PERF="${PERF:-1}"
CC_FLAGS="${CC_FLAGS:--O3 -march=native -Wall -Wextra -std=c11}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

OUT="$ROOT/results/${STAMP}"
mkdir -p "$OUT"

if [[ ! -f "$SRC" ]]; then
    echo "ERROR: Missing benchmark source: $SRC" >&2
    exit 1
fi

echo "Benchmark output: $OUT"

# Record system and source information
"$ROOT/scripts/collect-system-info.sh" "$OUT/system-info.txt"

sha256sum "$SRC" > "$OUT/source.sha256"

git -C "$ROOT" rev-parse HEAD \
    > "$OUT/git-commit.txt" 2>/dev/null || true

echo "u=$U r=$R repetitions=$REPS" > "$OUT/parameters.txt"
echo "CPU affinity=${CPU:-unrestricted}" >> "$OUT/parameters.txt"
echo "Compiler flags=$CC_FLAGS" >> "$OUT/parameters.txt"

# Construct optional CPU affinity wrapper
RUN=()

if [[ -n "$CPU" ]]; then
    if ! command -v taskset >/dev/null 2>&1; then
        echo "ERROR: taskset unavailable" >&2
        exit 1
    fi
    RUN=(taskset -c "$CPU")
fi

run_one()
{
    local CC="$1"
    local NAME="$2"
    local DIR="$OUT/$NAME"

    mkdir -p "$DIR"

    if ! command -v "$CC" >/dev/null 2>&1; then
        echo "SKIP: $CC unavailable"
        return
    fi

    echo
    echo "=================================="
    echo "Compiler: $CC"
    echo "=================================="

    "$CC" --version > "$DIR/compiler-version.txt" 2>&1

    echo "$CC $CC_FLAGS -o $DIR/loopbench $SRC" \
        > "$DIR/build-command.txt"

    # Compile
    "$CC" $CC_FLAGS -o "$DIR/loopbench" "$SRC"

    # Preserve generated machine code
    objdump -drwC "$DIR/loopbench" \
        > "$DIR/disassembly.txt"

    objdump -drwC --disassemble=benchmark "$DIR/loopbench" \
        > "$DIR/benchmark-assembly.txt"

    sha256sum "$DIR/loopbench" > "$DIR/binary.sha256"

    # Normal benchmark run
    echo "Running benchmark..."

    "${RUN[@]}" "$DIR/loopbench" "$U" "$R" "$REPS" \
        > "$DIR/output.txt" 2>&1

    cat "$DIR/output.txt"

    # Hardware performance counters
    if [[ "$PERF" == "1" ]] && command -v perf >/dev/null 2>&1; then
        echo "Collecting perf counters..."

        set +e

        perf stat -x, \
            -e cycles,instructions,branches,branch-misses \
            -o "$DIR/perf-stat.csv" \
            -- "${RUN[@]}" "$DIR/loopbench" "$U" "$R" 1 \
            > "$DIR/perf-output.txt" 2>&1

        PERF_STATUS=$?

        set -e

        echo "$PERF_STATUS" > "$DIR/perf-exit-status.txt"

        if [[ "$PERF_STATUS" -ne 0 ]]; then
            echo "WARNING: perf unavailable or counters restricted"
            cat "$DIR/perf-output.txt"
        fi
    fi

    echo "Finished: $NAME"
    }

    print_system_info()
    {
        local cpu_name logical_cores physical_cores
        local flags l1d l1i l2 l3 ram_kb
        local gcc_ver clang_ver cur_freq temp_c governor
        local nohz no_irq pkg_zone t_raw cps sockets lvl t sz z d

        # --- Processor type (name) ---
        cpu_name="$(awk -F: '/model name/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
        [ -z "$cpu_name" ] && cpu_name="N/A"

        # --- Logical & physical cores ---
        logical_cores="$(nproc 2>/dev/null || echo N/A)"
        physical_cores="N/A"
        if command -v lscpu >/dev/null 2>&1; then
            cps="$(lscpu | awk -F: '/Core\(s\) per socket:/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
            sockets="$(lscpu | awk -F: '/Socket\(s\):/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
            if [ -n "$cps" ] && [ -n "$sockets" ]; then
                physical_cores=$(( cps * sockets ))
            fi
        fi

        # --- Instruction set (flags) ---
        flags="$(awk -F: '/flags/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
        [ -z "$flags" ] && flags="N/A"

        # --- Cache topology (L1/L2/L3) from sysfs ---
        l1d="N/A"; l1i="N/A"; l2="N/A"; l3="N/A"
        if [ -d /sys/devices/system/cpu/cpu0/cache ]; then
            for d in /sys/devices/system/cpu/cpu0/cache/index*; do
                [ -d "$d" ] || continue
                lvl="$(cat "$d/level" 2>/dev/null)"
                t="$(cat "$d/type" 2>/dev/null)"
                sz="$(cat "$d/size" 2>/dev/null)"
                case "$lvl" in
                    1)
                        case "$t" in
                            *Data*)   l1d="$sz" ;;
                            *Instruction*) l1i="$sz" ;;
                        esac ;;
                    2) l2="$sz" ;;
                    3) l3="$sz" ;;
                esac
            done
        fi

        # --- RAM ---
        ram_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)"
        [ -z "$ram_kb" ] && ram_kb="N/A"

        # --- Compiler versions (first line only, no pipe/head to avoid SIGPIPE) ---
        gcc_ver="N/A"
        if command -v gcc >/dev/null 2>&1; then
            gcc_ver="$(gcc --version 2>/dev/null)"
            gcc_ver="${gcc_ver%%$'\n'*}"
            [ -z "$gcc_ver" ] && gcc_ver="N/A"
        fi
        clang_ver="N/A"
        if command -v clang >/dev/null 2>&1; then
            clang_ver="$(clang --version 2>/dev/null)"
            clang_ver="${clang_ver%%$'\n'*}"
            [ -z "$clang_ver" ] && clang_ver="N/A"
        fi

        # --- Actual CPU speed (current frequency, kHz) ---
        cur_freq="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo N/A)"

        # --- System temp (package thermal zone preferred, millicelsius -> celsius) ---
        temp_c="N/A"
        pkg_zone=""
        for z in /sys/class/thermal/thermal_zone*; do
            [ -f "$z/type" ] || continue
            if [ "$(cat "$z/type" 2>/dev/null)" = "x86_pkg_temp" ]; then
                pkg_zone="$z"
                break
            fi
        done
        if [ -z "$pkg_zone" ]; then
            for z in /sys/class/thermal/thermal_zone*; do
                [ -f "$z/type" ] || continue
                pkg_zone="$z"
                break
            done
        fi
        if [ -n "$pkg_zone" ] && [ -f "$pkg_zone/temp" ]; then
            t_raw="$(cat "$pkg_zone/temp" 2>/dev/null || echo 0)"
            if [ "$t_raw" -gt 1000 ] 2>/dev/null; then
                temp_c="$(( t_raw / 1000 ))°C"
            else
                temp_c="${t_raw}°C"
            fi
        fi

        # --- Governor ---
        governor="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo N/A)"

        # --- no_hz / no_irq (kernel boot command line) ---
        nohz="$(awk 'BEGIN{RS=" "} /^nohz=/ || /^nohz_full/ {print; exit}' /proc/cmdline 2>/dev/null)"
        [ -z "$nohz" ] && nohz="N/A"
        no_irq="$(awk 'BEGIN{RS=" "} /irqpoll/ {print; exit}' /proc/cmdline 2>/dev/null)"
        [ -z "$no_irq" ] && no_irq="N/A"

        echo
        echo "=== SYSTEM INFORMATION ==="
        echo "Processor          : $cpu_name"
        echo "Logical cores      : $logical_cores"
        echo "Physical cores     : $physical_cores"
        echo "Instruction set    : $flags"
        echo "L1 data cache      : $l1d"
        echo "L1 instruction cache: $l1i"
        echo "L2 cache           : $l2"
        echo "L3 cache           : $l3"
        echo "RAM                : ${ram_kb} kB"
        echo "Compiler (gcc)     : $gcc_ver"
        echo "Compiler (clang)   : $clang_ver"
        echo "CPU speed          : ${cur_freq} kHz"
        echo "System temp        : $temp_c"
        echo "Governor           : $governor"
        echo "no_hz              : $nohz"
        echo "no_irq             : $no_irq"
        echo
    }

    print_system_info

    run_one gcc gcc
run_one clang clang

echo
echo "=================================="
echo "BENCHMARK COMPLETE"
echo "=================================="
echo "Results: $OUT"
