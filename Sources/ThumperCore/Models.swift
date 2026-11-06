import CoreGraphics
import Foundation

public struct ProcessIdentity: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startedAtMicroseconds: UInt64

    public init(pid: Int32, startedAtMicroseconds: UInt64) {
        self.pid = pid
        self.startedAtMicroseconds = startedAtMicroseconds
    }
}

public struct ProcessRecord: Identifiable, Sendable {
    public let id: ProcessIdentity
    public let name: String
    public let executable: String
    public let uid: UInt32
    public let cpuPercent: Double?
    public let gpuPercent: Double?
    public let threads: Int?
    public let residentBytes: UInt64?

    public init(id: ProcessIdentity, name: String, executable: String, uid: UInt32,
                cpuPercent: Double?, gpuPercent: Double?, threads: Int?, residentBytes: UInt64?) {
        self.id = id
        self.name = name
        self.executable = executable
        self.uid = uid
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
        self.threads = threads
        self.residentBytes = residentBytes
    }
}

public struct TrackedProcess: Identifiable, Codable, Equatable, Sendable {
    public let id: ProcessIdentity
    public let name: String
    public let executable: String

    public init(_ process: ProcessRecord) {
        id = process.id
        name = process.name
        executable = process.executable
    }
}

public enum MetricFormat {
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func count(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }
}

public struct CounterSample: Sendable {
    public let time: UInt64
    public let cpu: UInt64?
    public let gpu: UInt64?

    public init(time: UInt64, cpu: UInt64?, gpu: UInt64?) {
        self.time = time
        self.cpu = cpu
        self.gpu = gpu
    }

    public static func percent(current: UInt64?, previous: UInt64?, elapsed: UInt64) -> Double? {
        guard let current, let previous, current >= previous, elapsed > 0 else { return nil }
        // Activity Monitor convention: 100% is one fully occupied CPU core.
        return Double(current - previous) / Double(elapsed) * 100
    }
}

public enum OverlayGeometry {
    public static func pickerFrame(size: CGSize, near overlay: CGRect?, on visible: CGRect) -> CGRect {
        guard let overlay else {
            return clamped(CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                  width: size.width, height: size.height), to: visible)
        }
        let gap: CGFloat = 12
        let candidates = [
            CGRect(x: overlay.maxX + gap, y: overlay.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: overlay.minX - size.width - gap, y: overlay.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: overlay.midX - size.width / 2, y: overlay.minY - size.height - gap, width: size.width, height: size.height),
            CGRect(x: overlay.midX - size.width / 2, y: overlay.maxY + gap, width: size.width, height: size.height)
        ]
        if let fitting = candidates.first(where: { visible.insetBy(dx: gap, dy: gap).contains($0) }) { return fitting }
        return clamped(CGRect(x: overlay.midX - size.width / 2, y: overlay.midY - size.height / 2,
                              width: size.width, height: size.height), to: visible)
    }

    public static func clamped(_ frame: CGRect, to visible: CGRect, inset: CGFloat = 12) -> CGRect {
        let area = visible.insetBy(dx: inset, dy: inset)
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        return CGRect(x: max(area.minX, min(frame.minX, area.maxX - size.width)),
                      y: max(area.minY, min(frame.minY, area.maxY - size.height)),
                      width: size.width, height: size.height)
    }
}
