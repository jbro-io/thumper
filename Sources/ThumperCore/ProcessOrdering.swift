import Foundation

public enum ProcessSortField: String, Codable, CaseIterable, Sendable {
    case name, cpu, gpu, memory, threads, ports, pid
}

public struct ProcessSortValues {
    public let id: ProcessIdentity
    public let name: String
    public let cpu: Double?
    public let gpu: Double?
    public let threads: Int?
    public let ports: Int?
    public let memoryBytes: UInt64?

    public init(id: ProcessIdentity, name: String, cpu: Double?, gpu: Double?, threads: Int?, ports: Int?, memoryBytes: UInt64? = nil) {
        self.id = id; self.name = name; self.cpu = cpu; self.gpu = gpu; self.threads = threads; self.ports = ports
        self.memoryBytes = memoryBytes
    }

    fileprivate func value(for field: ProcessSortField) -> Double? {
        switch field {
        case .name: return nil
        case .cpu: return cpu
        case .gpu: return gpu
        case .memory: return memoryBytes.map(Double.init)
        case .threads: return threads.map(Double.init)
        case .ports: return ports.map(Double.init)
        case .pid: return Double(id.pid)
        }
    }
}

public enum ProcessOrdering {
    public static func precedes(_ left: ProcessSortValues, _ right: ProcessSortValues,
                                by field: ProcessSortField, ascending: Bool) -> Bool {
        if field == .name {
            let comparison = left.name.localizedStandardCompare(right.name)
            if comparison != .orderedSame { return ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
        } else {
            let l = left.value(for: field), r = right.value(for: field)
            if l == nil && r != nil { return false }
            if l != nil && r == nil { return true }
            if let l, let r, l != r { return ascending ? l < r : l > r }
        }
        return left.id.pid < right.id.pid
    }
}
