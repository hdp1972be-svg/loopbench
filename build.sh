#!/usr/bin/env bash
set -Eeuo pipefail

# build.sh — compile src/loopbench.c with one or more C compilers.
# Defaults: every installed gcc version (gcc and gcc-N) plus clang.
# Binaries are written to build/loopbench-<cc>.
# Pass explicit compilers as arguments to override auto-detection.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src/loopbench.c"
BUILD_DIR="$ROOT/build"
CC_FLAGS="${CC_FLAGS:--O3 -march=native -Wall -Wextra -std=c11}"

# Determine compilers to build with.
if [[ $# -gt 0 ]]; then
    COMPILERS=("$@")
else
    COMPILERS=()
    # Plain gcc first.
    command -v gcc >/dev/null 2>&1 && COMPILERS+=("gcc")
    # All versioned gcc-N installed on the system (skip gcc-ar/nm/ranlib).
    for g in /usr/bin/gcc-*; do
        [ -x "$g" ] || continue
        case "$(basename "$g")" in
            gcc-[0-9]*) COMPILERS+=("$(basename "$g")") ;;
        esac
    done
    # clang (requested).
    command -v clang >/dev/null 2>&1 && COMPILERS+=("clang")
fi

if [[ ! -f "$SRC" ]]; then
    echo "ERROR: Missing benchmark source: $SRC" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"

for CC in "${COMPILERS[@]}"; do
    if ! command -v "$CC" >/dev/null 2>&1; then
        echo "SKIP: $CC unavailable"
        continue
    fi

    OUT="$BUILD_DIR/loopbench-$CC"

    echo "Building $CC -> $OUT"
    echo "$CC $CC_FLAGS -o $OUT $SRC" > "$BUILD_DIR/build-command-$CC.txt"

    if "$CC" $CC_FLAGS -o "$OUT" "$SRC" 2>"$BUILD_DIR/build-errors-$CC.txt"; then
        # Preserve machine code for inspection.
        objdump -drwC "$OUT" > "$BUILD_DIR/disassembly-$CC.txt" 2>/dev/null || true

        # Record compiler version and binary hash.
        "$CC" --version > "$BUILD_DIR/compiler-version-$CC.txt" 2>&1 || true
        sha256sum "$OUT" > "$BUILD_DIR/binary-$CC.sha256"

        echo "  OK: $OUT"
    else
        echo "  FAIL: $CC (see $BUILD_DIR/build-errors-$CC.txt)"
        rm -f "$OUT"
    fi
done

echo
echo "Build complete. Binaries in: $BUILD_DIR"
ls -1 "$BUILD_DIR"/loopbench-* 2>/dev/null || true
