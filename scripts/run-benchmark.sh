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

HOST="$(hostname -s)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

OUT="$ROOT/results/${HOST}-${STAMP}"
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

run_one gcc gcc
run_one clang clang

echo
echo "=================================="
echo "BENCHMARK COMPLETE"
echo "=================================="
echo "Results: $OUT"
