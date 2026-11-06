import Foundation
import IOKit

public struct GPUClientSample: Sendable {
    public let registryID: UInt64
    public let process: ProcessIdentity
    public let queueTimes: [UInt64]

    public init(registryID: UInt64, process: ProcessIdentity, queueTimes: [UInt64]) {
        self.registryID = registryID
        self.process = process
        self.queueTimes = queueTimes
    }
}

public struct GPUUsageTracker: Sendable {
    private var previous: [UInt64: GPUClientSample] = [:]
    private var previousTime: UInt64?
    public init() {}

    public mutating func sample(_ clients: [GPUClientSample], at time: UInt64) -> [ProcessIdentity: Double] {
        defer {
            previous = Dictionary(clients.map { ($0.registryID, $0) }, uniquingKeysWith: { first, _ in first })
            previousTime = time
        }
        guard let previousTime, time > previousTime, time - previousTime < 30_000_000_000 else { return [:] }
        let elapsed = Double(time - previousTime)
        var rates: [ProcessIdentity: Double] = [:]
        for client in clients {
            guard let old = previous[client.registryID], old.process == client.process,
                  old.queueTimes.count == client.queueTimes.count else { continue }
            let pairs = Array(zip(client.queueTimes, old.queueTimes))
            // Queue teardown, a counter reset, or a changed client establishes a
            // new baseline. Never subtract aggregate counters across clients.
            guard pairs.allSatisfy({ $0.0 >= $0.1 }) else { continue }
            let delta = pairs.reduce(0.0) { $0 + Double($1.0 - $1.1) }
            rates[client.process, default: 0] += delta / elapsed * 100
        }
        return rates
    }
}

struct GPURegistrySnapshot {
    let clients: [GPUClientSample]
    let available: Bool
}

enum GPURegistryReader {
    static func read(identities: [Int32: ProcessIdentity]) -> GPURegistrySnapshot {
        var clients: [UInt64: GPUClientSample] = [:]
        var available = false
        // AGXAccelerator inherits from IOAccelerator. Match its registered
        // parent, then walk children: AGXDeviceUserClient itself is unregistered
        // and cannot be found with IOServiceGetMatchingServices.
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            return GPURegistrySnapshot(clients: [], available: false)
        }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                guard let creator = property(child, "IOUserClientCreator") as? String,
                      creator.hasPrefix("pid "),
                      let pidString = creator.split(separator: ",", maxSplits: 1).first?.split(separator: " ").last,
                      let pid = Int32(pidString), let identity = identities[pid] else { continue }
                let times: [UInt64]
                if let usage = property(child, "AppUsage") as? [[String: Any]] {
                    let numbers = usage.compactMap { $0["accumulatedGPUTime"] as? NSNumber }
                    guard numbers.count == usage.count, numbers.allSatisfy({ $0.doubleValue.isFinite && $0.doubleValue >= 0 }) else { continue }
                    times = numbers.map(\.uint64Value)
                } else if let direct = property(child, "accumulatedGPUTime") as? NSNumber, direct.doubleValue >= 0 {
                    times = [direct.uint64Value]
                } else {
                    continue
                }
                available = true
                var registryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(child, &registryID) == KERN_SUCCESS,
                      ProcessSampler.identity(for: pid) == identity else { continue }
                clients[registryID] = GPUClientSample(registryID: registryID, process: identity, queueTimes: times)
            }
        }
        return GPURegistrySnapshot(clients: Array(clients.values), available: available)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
