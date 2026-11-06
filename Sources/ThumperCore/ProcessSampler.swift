import CProcessMetrics
import Foundation

public struct ProcessSnapshot: Sendable {
    public let processes: [ProcessRecord]
    public let date: Date
    public let error: String?
    public let gpuTelemetryAvailable: Bool
}

public actor ProcessSampler {
    private var previous: [ProcessIdentity: CounterSample] = [:]
    private var gpuTracker = GPUUsageTracker()
    public init() {}

    public nonisolated static var supportsGPUCounters: Bool { pg_gpu_counters_supported() }

    public nonisolated static func identity(for pid: Int32) -> ProcessIdentity? {
        var start: UInt64 = 0
        guard pg_read_identity(pid, &start) else { return nil }
        return ProcessIdentity(pid: pid, startedAtMicroseconds: start)
    }

    public func sample() -> ProcessSnapshot {
        var pointer: UnsafeMutablePointer<PGProcessSample>?
        let count = pg_copy_processes(&pointer)
        guard count >= 0, let pointer else {
            previous.removeAll()
            return ProcessSnapshot(processes: [], date: Date(), error: "macOS could not provide the process list. Try reopening Thumper.", gpuTelemetryAvailable: false)
        }
        defer { pg_free_processes(pointer) }
        let now = pg_monotonic_time_ns()
        var next: [ProcessIdentity: CounterSample] = [:]
        var records: [ProcessRecord] = []
        records.reserveCapacity(Int(count))
        for var raw in UnsafeBufferPointer(start: pointer, count: Int(count)) {
            let id = ProcessIdentity(pid: raw.pid, startedAtMicroseconds: raw.started_at_us)
            let counters = CounterSample(time: now, cpu: raw.has_cpu ? raw.cpu_time_ns : nil,
                                         gpu: raw.has_gpu ? raw.gpu_time_ns : nil)
            let last = previous[id]
            let elapsed = last.map { now >= $0.time ? now - $0.time : 0 } ?? 0
            let cpu = CounterSample.percent(current: counters.cpu, previous: last?.cpu, elapsed: elapsed)
            // Some drivers return zero for an unsupported GPU counter. Only a
            // counter that has actually advanced is evidence of working telemetry.
            let gpu: Double? = (counters.gpu ?? 0) > 0
                ? CounterSample.percent(current: counters.gpu, previous: last?.gpu, elapsed: elapsed) : nil
            next[id] = counters
            let name = withUnsafePointer(to: &raw.name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            let executable = withUnsafePointer(to: &raw.executable) {
                $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
            }
            records.append(ProcessRecord(id: id, name: name.isEmpty ? "Process \(raw.pid)" : name,
                                         executable: executable, uid: raw.uid, cpuPercent: cpu, gpuPercent: gpu,
                                         threads: raw.has_cpu ? Int(raw.threads) : nil,
                                         residentBytes: raw.has_cpu ? raw.resident_bytes : nil))
        }
        previous = next
        let identities = Dictionary(records.map { ($0.id.pid, $0.id) }, uniquingKeysWith: { first, _ in first })
        let registry = GPURegistryReader.read(identities: identities)
        let gpuRates = gpuTracker.sample(registry.clients, at: pg_monotonic_time_ns())
        records = records.map { record in
            ProcessRecord(id: record.id, name: record.name, executable: record.executable, uid: record.uid,
                          cpuPercent: record.cpuPercent, gpuPercent: gpuRates[record.id] ?? record.gpuPercent,
                          threads: record.threads, residentBytes: record.residentBytes)
        }
        return ProcessSnapshot(processes: records, date: Date(), error: nil, gpuTelemetryAvailable: registry.available)
    }
}
