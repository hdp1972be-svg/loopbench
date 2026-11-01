# loopbench

Nested-loop C benchmark measuring iterations per second, ns/iteration, and
checksum stability across repetitions. The benchmark source (`src/loopbench.c`)
is intentionally left untouched; tooling lives in `scripts/` and the root
helper scripts.

## Origin

This benchmark is based on the C implementation by Benjamin Dicken, published in
November 2024 (repository: bddicken/languages), discussed on Hacker News:
https://news.ycombinator.com/item?id=42248315&utm_source=chatgpt.com

Unlike an abstract empty-loop test, it does real work:

    int32_t a[10000] = {0};

    for (int i = 0; i < 10000; i++) {
        for (int j = 0; j < 100000; j++) {
            a[i] = a[i] + j % u;
        }
        a[i] += r;
    }

    printf("%d\n", a[r]);

That is roughly one billion modulo operations, one billion accumulator additions,
repeated updates to an array element, and a result that is eventually printed.

## Quick start

```bash
./build.sh          # compile with gcc and clang
./run.sh            # print machine specs, then run all benches
```

## Scripts

- `build.sh` — compile `src/loopbench.c` with every installed `gcc` version
  (`gcc` and `gcc-N`) plus `clang`, using
  `-O3 -march=native -Wall -Wextra -std=c11`. Binaries are written to
  `build/loopbench-<cc>`. Pass explicit compilers as arguments to override
  auto-detection.
- `run.sh` — print CPU/cache/RAM/compiler/temp/governor/no_hz/no_irq specs,
  then execute every built binary with default parameters (`u=97 r=7
  repetitions=5`).
- `scripts/run-benchmark.sh` — fuller harness: per-compiler build, disassembly,
  perf counters, and result archiving under `results/<host>-<stamp>/`.
- `scripts/collect-system-info.sh` — one-shot system-info dump to a text file.

## Benchmark parameters

`./build/loopbench-gcc [u] [r] [repetitions]`

- `u` — modulo divisor (must be > 0), default `97`.
- `r` — array index offset (0 .. OUTER-1), default `7`.
- `repetitions` — number of timed runs, default `5`.

## Build requirements

- `gcc` (and/or `gcc-N`), `clang`, `binutils` (objdump),
  `coreutils`, `util-linux`
- Optional: `perf`, `valgrind`, `upx`, `strip`

## Output layout

```
build/
  loopbench-gcc
  loopbench-clang
results/<host>-<stamp>/
  system-info.txt
  source.sha256
  git-commit.txt
  parameters.txt
  gcc/
    compiler-version.txt
    build-command.txt
    loopbench
    disassembly.txt
    benchmark-assembly.txt
    binary.sha256
    output.txt
    perf-stat.csv
    perf-output.txt
    perf-exit-status.txt
  clang/
    ...
```
