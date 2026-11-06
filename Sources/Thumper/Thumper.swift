import AppKit
import ThumperCore

@main
struct Thumper {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--diagnose") {
            await diagnose()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func diagnose() async {
        let sampler = ProcessSampler()
        let first = await sampler.sample()
        var usageBefore = rusage()
        getrusage(RUSAGE_SELF, &usageBefore)
        let wallBefore = ProcessInfo.processInfo.systemUptime
        let until = Date().addingTimeInterval(0.35)
        var work = 0.0
        while Date() < until { work += sqrt(Double.random(in: 1...100)) }
        let second = await sampler.sample()
        let wallElapsed = ProcessInfo.processInfo.systemUptime - wallBefore
        var usageAfter = rusage()
        getrusage(RUSAGE_SELF, &usageAfter)
        func seconds(_ value: rusage) -> Double {
            Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
        }
        let expectedCPU = (seconds(usageAfter) - seconds(usageBefore)) / wallElapsed * 100
        let me = second.processes.first { $0.id.pid == getpid() }
        let cpuVerified = me?.cpuPercent.map { abs($0 - expectedCPU) < max(5, expectedCPU * 0.25) } ?? false
        let ports = PortSampler()
        let portSnapshot = await ports.sample(identities: second.processes.map(\.id))
        ports.stop()
        func memory(_ record: ProcessRecord) -> UInt64? { record.memoryBytes ?? portSnapshot.readings[record.id]?.memoryBytes }
        let memoryCount = second.processes.filter { memory($0) != nil }.count
        let result: [String: Any] = [
            "processCount": second.processes.count,
            "firstSampleCount": first.processes.count,
            "sampleError": second.error ?? "none",
            "selfCPUPercent": me?.cpuPercent as Any? ?? NSNull(),
            "referenceCPUPercent": expectedCPU,
            "cpuClockVerified": cpuVerified,
            "selfThreads": me?.threads as Any? ?? NSNull(),
            "selfMemoryBytes": me?.memoryBytes as Any? ?? NSNull(),
            "selfMemoryFromTop": me.flatMap { portSnapshot.readings[$0.id]?.memoryBytes } as Any? ?? NSNull(),
            "nativeMemoryReadingCount": second.processes.filter { $0.memoryBytes != nil }.count,
            "memoryReadingCount": memoryCount,
            "systemMemoryReadingCount": second.processes.filter { $0.uid == 0 && memory($0) != nil }.count,
            "portReadingCount": portSnapshot.counts.count,
            "selfPorts": me.flatMap { portSnapshot.counts[$0.id] } as Any? ?? NSNull(),
            "systemProcessCount": second.processes.filter { $0.uid == 0 }.count,
            "systemCPUReadingCount": second.processes.filter { $0.uid == 0 && portSnapshot.readings[$0.id]?.cpuPercent != nil }.count,
            "portError": portSnapshot.error ?? "none",
            "gpuDriverTelemetryAvailable": second.gpuTelemetryAvailable,
            "gpuReadingCount": second.processes.filter { $0.gpuPercent != nil }.count,
            "activeGPUProcesses": second.processes.filter { ($0.gpuPercent ?? 0) > 0 }.map { ["name": $0.name, "pid": $0.id.pid, "gpuPercent": $0.gpuPercent!] as [String: Any] },
            "workCompleted": work > 0
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        if second.processes.isEmpty || !cpuVerified || portSnapshot.counts.isEmpty || memoryCount == 0 || (me?.memoryBytes ?? 0) == 0 { exit(1) }
    }
}
