#ifndef C_PROCESS_METRICS_H
#define C_PROCESS_METRICS_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int32_t pid;
    uint32_t uid;
    uint64_t started_at_us;
    uint64_t cpu_time_ns;
    uint64_t gpu_time_ns;
    uint64_t resident_bytes;
    uint64_t footprint_bytes;
    int32_t threads;
    bool has_cpu;
    bool has_gpu;
    bool has_memory;
    char name[256];
    char executable[4096];
} PGProcessSample;

// Returns the process count, or -1 on an enumeration failure. Caller frees *out.
int pg_copy_processes(PGProcessSample **out);
void pg_free_processes(PGProcessSample *samples);
// The monotonic clock has the same nanosecond unit as the task CPU counters.
uint64_t pg_monotonic_time_ns(void);
bool pg_read_identity(int32_t pid, uint64_t *started_at_us);
bool pg_gpu_counters_supported(void);

#endif
