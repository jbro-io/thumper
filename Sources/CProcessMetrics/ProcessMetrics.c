#include "CProcessMetrics.h"
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/task_info.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <time.h>

static uint64_t start_time(const struct proc_bsdinfo *info) {
    return info->pbi_start_tvsec * 1000000ULL + info->pbi_start_tvusec;
}

static bool kernel_process(pid_t pid, struct kinfo_proc *info) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    size_t size = sizeof(*info);
    return sysctl(mib, 4, info, &size, NULL, 0) == 0 && size == sizeof(*info);
}

uint64_t pg_monotonic_time_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

bool pg_gpu_counters_supported(void) {
    // XNU's legacy per-task GPU accounting is implemented for Intel. A zero
    // counter on Apple silicon does not establish that the GPU is idle.
#if defined(__x86_64__)
    return true;
#else
    return false;
#endif
}

bool pg_read_identity(int32_t pid, uint64_t *started_at_us) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) {
        struct kinfo_proc kernel = {0};
        if (!kernel_process(pid, &kernel)) return false;
        *started_at_us = (uint64_t)kernel.kp_proc.p_starttime.tv_sec * 1000000ULL + kernel.kp_proc.p_starttime.tv_usec;
        return true;
    }
    *started_at_us = start_time(&info);
    return true;
}

int pg_copy_processes(PGProcessSample **out) {
    *out = NULL;
    int estimated = proc_listallpids(NULL, 0);
    if (estimated <= 0) return -1;
    int capacity = estimated + 512;
    pid_t *pids = NULL;
    int count = 0;
    // A process may launch between the size query and enumeration.
    for (int attempt = 0; attempt < 3; attempt++) {
        free(pids);
        pids = calloc((size_t)capacity, sizeof(pid_t));
        if (!pids) return -1;
        count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
        if (count < capacity) break;
        capacity *= 2;
    }
    if (count <= 0) { free(pids); return -1; }
    PGProcessSample *samples = calloc((size_t)count, sizeof(PGProcessSample));
    if (!samples) { free(pids); return -1; }
    int written = 0;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid < 0) continue;
        struct proc_bsdinfo bsd = {0};
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) {
            // macOS restricts detailed libproc reads for other users. sysctl
            // still provides their basic identity, so they remain selectable.
            struct kinfo_proc kernel = {0};
            if (!kernel_process(pid, &kernel)) continue;
            bsd.pbi_uid = kernel.kp_eproc.e_ucred.cr_uid;
            bsd.pbi_start_tvsec = kernel.kp_proc.p_starttime.tv_sec;
            bsd.pbi_start_tvusec = kernel.kp_proc.p_starttime.tv_usec;
            strlcpy(bsd.pbi_name, kernel.kp_proc.p_comm, sizeof(bsd.pbi_name));
        }
        PGProcessSample *sample = &samples[written++];
        sample->pid = pid;
        sample->uid = bsd.pbi_uid;
        sample->started_at_us = start_time(&bsd);
        if (proc_name(pid, sample->name, sizeof(sample->name)) <= 0) {
            strlcpy(sample->name, bsd.pbi_name[0] ? bsd.pbi_name : bsd.pbi_comm, sizeof(sample->name));
        }
        proc_pidpath(pid, sample->executable, sizeof(sample->executable));
        struct proc_taskinfo task = {0};
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
            sample->has_cpu = true;
            // proc_taskinfo reports Mach absolute ticks (125/3 ns on many
            // Apple silicon Macs), not nanoseconds. Intel's 1:1 hides this bug.
            __uint128_t ticks = (__uint128_t)task.pti_total_user + task.pti_total_system;
            sample->cpu_time_ns = (uint64_t)(ticks * timebase.numer / timebase.denom);
            sample->resident_bytes = task.pti_resident_size;
            sample->threads = task.pti_threadnum;
        }
#if defined(__x86_64__)
        task_name_t task_port = MACH_PORT_NULL;
        if (task_name_for_pid(mach_task_self(), pid, &task_port) == KERN_SUCCESS) {
            struct task_power_info_v2 power = {0};
            mach_msg_type_number_t size = TASK_POWER_INFO_V2_COUNT;
            if (task_info(task_port, TASK_POWER_INFO_V2, (task_info_t)&power, &size) == KERN_SUCCESS) {
                sample->has_gpu = true;
                sample->gpu_time_ns = power.gpu_energy.task_gpu_utilisation;
            }
            mach_port_deallocate(mach_task_self(), task_port);
        }
#endif
        // Discard a sample if the PID was recycled while its counters were read.
        uint64_t verified_start = 0;
        if (!pg_read_identity(pid, &verified_start) || verified_start != sample->started_at_us) written--;
    }
    free(pids);
    *out = samples;
    return written;
}

void pg_free_processes(PGProcessSample *samples) { free(samples); }
