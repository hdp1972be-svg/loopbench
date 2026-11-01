#define _GNU_SOURCE

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <inttypes.h>
#include <string.h>
#include <errno.h>

#define OUTER 10000
#define INNER 100000
#define DEFAULT_U 97
#define DEFAULT_R 7

static int32_t a[OUTER];
static volatile uint64_t result_sink;

/*
 * Keep benchmark workload in a separate, non-inlined function.
 * No volatile accesses inside the hot loop: we want to measure
 * the compiler's actual optimization of the original workload.
 */
__attribute__((noinline))
static void benchmark(int32_t u, int32_t r)
{
    for (int i = 0; i < OUTER; i++) {
        for (int j = 0; j < INNER; j++) {
            a[i] = a[i] + j % u;
        }
        a[i] += r;
    }
}

static uint64_t checksum(void)
{
    uint64_t sum = 0;

    for (int i = 0; i < OUTER; i++)
        sum += (uint32_t)a[i];

    return sum;
}

static double elapsed_ns(struct timespec *start,
                         struct timespec *end)
{
    return (end->tv_sec - start->tv_sec) * 1e9 +
           (end->tv_nsec - start->tv_nsec);
}

int main(int argc, char **argv)
{
    int32_t u = DEFAULT_U;
    int32_t r = DEFAULT_R;
    int repetitions = 5;

    if (argc > 1) u = atoi(argv[1]);
    if (argc > 2) r = atoi(argv[2]);
    if (argc > 3) repetitions = atoi(argv[3]);

    if (u <= 0 || r < 0 || r >= OUTER || repetitions < 1) {
        fprintf(stderr,
                "Usage: %s [u>0] [r=0..9999] [repetitions]\n",
                argv[0]);
        return 1;
    }

    printf("Nested loop benchmark\n");
    printf("---------------------\n");
    printf("Outer loops : %d\n", OUTER);
    printf("Inner loops : %d\n", INNER);
    printf("Total       : %" PRIu64 "\n",
           (uint64_t)OUTER * INNER);
    printf("Modulo u    : %d\n", u);
    printf("Index r     : %d\n", r);
    printf("Repetitions : %d\n\n", repetitions);

    double total_ns = 0;
    double best_ns = 1e99;

    for (int n = 0; n < repetitions; n++) {
        memset(a, 0, sizeof(a));

        struct timespec start, end;

        clock_gettime(CLOCK_MONOTONIC_RAW, &start);

        benchmark(u, r);

        clock_gettime(CLOCK_MONOTONIC_RAW, &end);

        double ns = elapsed_ns(&start, &end);

        uint64_t sum = checksum();
        result_sink = sum;

        double ns_per_iteration =
            ns / ((double)OUTER * INNER);

        printf("Run %d: %.3f ms | %.3f ns/iteration"
               " | checksum: %" PRIu64 "\n",
               n + 1,
               ns / 1e6,
               ns_per_iteration,
               sum);

        total_ns += ns;

        if (ns < best_ns)
            best_ns = ns;
    }

    printf("\nResults\n");
    printf("-------\n");
    printf("Average : %.3f ms\n",
           total_ns / repetitions / 1e6);
    printf("Best    : %.3f ms\n", best_ns / 1e6);
    printf("Best throughput: %.2f billion iterations/s\n",
           1e9 / best_ns);
    printf("Best ns/iteration: %.4f\n",
           best_ns / 1e9);
    printf("Final sink: %" PRIu64 "\n", result_sink);

    return 0;
}
