import Foundation

public struct SupplementalMetrics: Sendable {
    public let cpuPercent: Double?
    public let threads: Int?
    public let ports: Int?
    public let memoryBytes: UInt64?
}

public enum TopMetricsParser {
    public static func parse(_ text: String) -> [Int32: SupplementalMetrics] {
        var result: [Int32: SupplementalMetrics] = [:]
        var inTable = false
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.first == "PID" {
                inTable = parts.count == 5 && parts[1] == "%CPU" && parts[2] == "#TH" && parts[3] == "#PORTS" && parts[4] == "MEM"
                continue
            }
            guard inTable, parts.count == 5, let pid = Int32(parts[0]) else { continue }
            let cpu = Double(parts[1]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let threads = parts[2].split(separator: "/").first.flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))) }
            let ports = Int(parts[3].trimmingCharacters(in: CharacterSet(charactersIn: "+-")))
            // A later table replaces the warm-up sample from top -l 2.
            result[pid] = SupplementalMetrics(cpuPercent: cpu, threads: threads, ports: ports, memoryBytes: memoryBytes(parts[4]))
        }
        return result
    }

    private static func memoryBytes(_ text: Substring) -> UInt64? {
        var value = text
        while value.last == "+" || value.last == "-" { value = value.dropLast() }
        guard let suffix = value.last else { return nil }
        // top's K/M/G units are binary; the UI formats the resulting byte count.
        let units: [Character: Double] = ["B": 1, "K": 1024, "M": 1_048_576, "G": 1_073_741_824, "T": 1_099_511_627_776]
        guard let scale = units[suffix], let number = Double(value.dropLast()), number >= 0 else { return nil }
        let bytes = (number * scale).rounded()
        guard bytes.isFinite, bytes < Double(UInt64.max) else { return nil }
        return UInt64(bytes)
    }
}

public struct PortSnapshot: Sendable {
    public let readings: [ProcessIdentity: SupplementalMetrics]
    public let date: Date
    public let error: String?
    public var counts: [ProcessIdentity: Int] { readings.compactMapValues(\.ports) }
}

// top is Apple's signed, read-only process observer. Its task inspection
// privileges provide the same Mach-port counts as Activity Monitor, without a
// root helper or adding private entitlements to this app.
public final class PortSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var stopped = false
    private let queue = DispatchQueue(label: "io.jbro.Thumper.ports", qos: .utility)

    public init() {}
    deinit { stop() }

    public func stop() {
        lock.lock()
        stopped = true
        let running = child
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    public func sample(identities: [ProcessIdentity]) async -> PortSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: collect(identities: identities))
            }
        }
    }

    private func collect(identities: [ProcessIdentity]) -> PortSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "2", "-s", "1", "-stats", "pid,cpu,threads,ports,mem", "-F", "-R", "-ncols", "128"]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return PortSnapshot(readings: [:], date: Date(), error: "Port sampling stopped.")
        }
        child = process
        do {
            try process.run()
            lock.unlock()
        } catch {
            child = nil
            lock.unlock()
            return PortSnapshot(readings: [:], date: Date(), error: "Mach-port counts are unavailable.")
        }
        let deadline = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        lock.lock()
        child = nil
        lock.unlock()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return PortSnapshot(readings: [:], date: Date(), error: "Mach-port counts are unavailable.")
        }
        let parsed = TopMetricsParser.parse(text)
        var readings: [ProcessIdentity: SupplementalMetrics] = [:]
        for id in identities {
            // Never attach an asynchronous result to a different process that
            // happened to reuse the same PID while top was running.
            if let value = parsed[id.pid], ProcessSampler.identity(for: id.pid) == id {
                readings[id] = value
            }
        }
        return PortSnapshot(readings: readings, date: Date(), error: parsed.isEmpty ? "Waiting for additional process metrics…" : nil)
    }
}
