#!/usr/bin/env bash
set -Eeuo pipefail

# run.sh — print machine specs, then run every built benchmark binary.
# If no binaries exist, runs ./build.sh first.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src/loopbench.c"
BUILD_DIR="$ROOT/build"
U="${U:-97}"
R="${R:-7}"
REPS="${REPS:-5}"

# ---- output capture ----
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG="${ROOT}/${RUN_STAMP}-loopbench.run.txt"

exec > >(tee -a "$RUN_LOG") 2>&1

echo "Run log: $RUN_LOG"

# ---- root / governor handling ----
IS_ROOT=0
if [[ "$(id -u)" -eq 0 ]]; then IS_ROOT=1; fi

declare -a GOV_FILES=()
declare -a GOV_ORIG=()
if [[ $IS_ROOT -eq 1 ]]; then
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -r "$f" ] || continue
        GOV_FILES+=("$f")
        GOV_ORIG+=("$(cat "$f" 2>/dev/null || echo unknown)")
    done
fi

restore_governors()
{
    if [[ $IS_ROOT -eq 1 && ${#GOV_FILES[@]} -gt 0 ]]; then
        local i
        for i in "${!GOV_FILES[@]}"; do
            echo "${GOV_ORIG[$i]}" > "${GOV_FILES[$i]}" 2>/dev/null || true
        done
    fi
}
trap restore_governors EXIT

# ---- machine specs ----
echo "============================================================"
echo " MACHINE SPECIFICATIONS"
echo "============================================================"
echo "Host        : $(hostname)"
echo "Kernel      : $(uname -r)"
echo "Architecture: $(uname -m)"
echo "Date        : $(date --iso-8601=seconds)"
echo

# Processor type (name)
cpu_name="$(awk -F: '/model name/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo N/A)"
echo "Processor   : $cpu_name"

# Logical & physical cores
logical_cores="$(nproc 2>/dev/null || echo N/A)"
physical_cores="N/A"
if command -v lscpu >/dev/null 2>&1; then
    cps="$(lscpu | awk -F: '/Core\(s\) per socket:/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
    sockets="$(lscpu | awk -F: '/Socket\(s\):/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
    if [ -n "$cps" ] && [ -n "$sockets" ]; then
        physical_cores=$(( cps * sockets ))
    fi
fi
echo "Logical     : $logical_cores cores"
echo "Physical    : $physical_cores cores"

# Instruction set
flags="$(awk -F: '/flags/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo N/A)"
echo "ISA flags   : $flags"

# Cache topology
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
                    *Data*)      l1d="$sz" ;;
                    *Instruction*) l1i="$sz" ;;
                esac ;;
            2) l2="$sz" ;;
            3) l3="$sz" ;;
        esac
    done
fi
echo "L1 data     : $l1d"
echo "L1 instr    : $l1i"
echo "L2 cache    : $l2"
echo "L3 cache    : $l3"

# RAM
ram_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo N/A)"
echo "RAM         : ${ram_kb} kB"

# Compiler versions
echo "gcc         : $(gcc --version 2>/dev/null | head -n1 || echo N/A)"
echo "clang       : $(clang --version 2>/dev/null | head -n1 || echo N/A)"

# Actual CPU speed
cur_freq="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo N/A)"
echo "CPU speed   : ${cur_freq} kHz"

# System temp (package zone preferred)
temp_c="N/A"
pkg_zone=""
for z in /sys/class/thermal/thermal_zone*; do
    [ -f "$z/type" ] || continue
    if [ "$(cat "$z/type" 2>/dev/null)" = "x86_pkg_temp" ]; then pkg_zone="$z"; break; fi
done
if [ -z "$pkg_zone" ]; then
    for z in /sys/class/thermal/thermal_zone*; do
        [ -f "$z/type" ] || continue
        pkg_zone="$z"; break
    done
fi
if [ -n "$pkg_zone" ] && [ -f "$pkg_zone/temp" ]; then
    t_raw="$(cat "$pkg_zone/temp" 2>/dev/null || echo 0)"
    if [ "$t_raw" -gt 1000 ] 2>/dev/null; then temp_c="$(( t_raw / 1000 ))°C"; else temp_c="${t_raw}°C"; fi
fi
echo "Temp        : $temp_c"

# Governor
governor="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo N/A)"
echo "Governor    : $governor"

# no_hz / no_irq
nohz="$(awk 'BEGIN{RS=" "} /^nohz=/ || /^nohz_full/ {print; exit}' /proc/cmdline 2>/dev/null || echo N/A)"
[ -n "$nohz" ] || nohz="N/A"
no_irq="$(awk 'BEGIN{RS=" "} /irqpoll/ {print; exit}' /proc/cmdline 2>/dev/null || echo N/A)"
[ -n "$no_irq" ] || no_irq="N/A"
echo "no_hz       : $nohz"
echo "no_irq      : $no_irq"

echo

# ---- build if needed ----
shopt -s nullglob
binaries=("$BUILD_DIR"/loopbench-*)
shopt -u nullglob

if [[ ${#binaries[@]} -eq 0 ]]; then
    echo "No benchmark binaries found; running build.sh..."
    "$ROOT/build.sh"
    shopt -s nullglob
    binaries=("$BUILD_DIR"/loopbench-*)
    shopt -u nullglob
fi

# ---- set governor to performance if root ----
if [[ $IS_ROOT -eq 1 && ${#GOV_FILES[@]} -gt 0 ]]; then
    for f in "${GOV_FILES[@]}"; do
        echo performance > "$f" 2>/dev/null || true
    done
    echo "Governor forced to performance (original restored on exit)"
fi

# ---- run benches ----
echo "============================================================"
echo " RUNNING BENCHMARKS (u=$U r=$R repetitions=$REPS)"
echo "============================================================"

for bin in "${binaries[@]}"; do
    name="$(basename "$bin")"
    echo
    echo "------------------------------------------------------------"
    echo " $name"
    echo "------------------------------------------------------------"
    "$bin" "$U" "$R" "$REPS"
done

echo
echo "All benches complete."
