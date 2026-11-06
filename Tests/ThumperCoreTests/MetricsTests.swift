import CoreGraphics
import Foundation
import XCTest
@testable import ThumperCore

final class MetricsTests: XCTestCase {
    func testOverlayResizesAwayFromNearestEdgesInEveryCorner() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for x: CGFloat in [100, 800] {
            for y: CGFloat in [50, 650] {
                let original = CGRect(x: x, y: y, width: 300, height: 100)
                var placement = OverlayPlacement(frame: original, on: screen)
                placement.resize(to: CGSize(width: 500, height: 250), on: screen)
                if x == 100 { XCTAssertEqual(placement.frame.minX, original.minX) }
                else { XCTAssertEqual(placement.frame.maxX, original.maxX) }
                if y == 50 { XCTAssertEqual(placement.frame.minY, original.minY) }
                else { XCTAssertEqual(placement.frame.maxY, original.maxY) }
                XCTAssertTrue(screen.contains(placement.frame))
                placement.resize(to: original.size, on: screen)
                XCTAssertEqual(placement.frame, original)
            }
        }
    }

    func testOverlayKeepsItsAnchorWhenGrowthCrossesTheScreenMidpoint() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let original = CGRect(x: 500, y: 500, width: 300, height: 100)
        var placement = OverlayPlacement(frame: original, on: screen)
        placement.resize(to: CGSize(width: 650, height: 500), on: screen)
        placement.resize(to: CGSize(width: 200, height: 80), on: screen)
        XCTAssertEqual(placement.frame.maxX, original.maxX)
        XCTAssertEqual(placement.frame.maxY, original.maxY)
    }

    func testOverlayRestoresItsAnchorAfterClampingAndRelaunch() throws {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let original = CGRect(x: 500, y: 500, width: 300, height: 100)
        var placement = OverlayPlacement(frame: original, on: screen)
        placement.resize(to: CGSize(width: 5000, height: 5000), on: screen)
        XCTAssertTrue(screen.contains(placement.frame))
        var restored = try JSONDecoder().decode(OverlayPlacement.self, from: JSONEncoder().encode(placement))
        XCTAssertTrue(restored.isValid)
        restored.resize(to: original.size, on: screen)
        XCTAssertEqual(restored.frame, original)
    }

    func testOverlayAnchorsUseTheSelectedMonitorWithNegativeCoordinates() {
        let screen = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let original = CGRect(x: -500, y: -100, width: 300, height: 60)
        var placement = OverlayPlacement(frame: original, on: screen)
        placement.resize(to: CGSize(width: 800, height: 300), on: screen)
        XCTAssertEqual(placement.frame.maxX, original.maxX)
        XCTAssertEqual(placement.frame.maxY, original.maxY)
        XCTAssertTrue(screen.contains(placement.frame))
    }

    func testPickerOpensBesideOverlayAndStaysOnItsMonitor() {
        let screen = CGRect(x: 2000, y: -500, width: 1920, height: 1080)
        let overlay = CGRect(x: 2100, y: 200, width: 548, height: 300)
        let size = CGSize(width: 790, height: 650)
        let frame = OverlayGeometry.pickerFrame(size: size, near: overlay, on: screen)
        XCTAssertEqual(frame.minX, overlay.maxX + 12)
        XCTAssertEqual(frame.maxY, overlay.maxY)
        XCTAssertTrue(screen.contains(frame))
        let centered = OverlayGeometry.pickerFrame(size: size, near: nil, on: screen)
        XCTAssertEqual(centered.midX, screen.midX)
        XCTAssertEqual(centered.midY, screen.midY)
    }

    func testOverlaySortingIsNumericReversibleAndKeepsMissingValuesLast() {
        func value(_ pid: Int32, _ cpu: Double?) -> ProcessSortValues {
            ProcessSortValues(id: ProcessIdentity(pid: pid, startedAtMicroseconds: 1), name: "codex", cpu: cpu, gpu: nil, threads: Int(pid), ports: Int(pid) * 10)
        }
        let values = [value(1, 2), value(2, 100), value(3, nil), value(4, 10), value(5, 10)]
        let descending = values.sorted { ProcessOrdering.precedes($0, $1, by: .cpu, ascending: false) }
        XCTAssertEqual(descending.map(\.id.pid), [2, 4, 5, 1, 3])
        let ascending = values.sorted { ProcessOrdering.precedes($0, $1, by: .cpu, ascending: true) }
        XCTAssertEqual(ascending.map(\.id.pid), [1, 4, 5, 2, 3])
        let ports = values.sorted { ProcessOrdering.precedes($0, $1, by: .ports, ascending: false) }
        XCTAssertEqual(ports.map(\.id.pid), [5, 4, 3, 2, 1])
    }

    func testRegexTracksEveryInstanceIncludingNewProcesses() throws {
        let pattern = try ProcessPattern("WindowServer|mentat|codex")
        func record(_ pid: Int32, _ name: String) -> ProcessRecord {
            ProcessRecord(id: ProcessIdentity(pid: pid, startedAtMicroseconds: UInt64(pid)), name: name,
                          executable: "", uid: 501, cpuPercent: nil, gpuPercent: nil, threads: nil, residentBytes: nil)
        }
        let initial = [record(1, "WindowServer"), record(2, "mentat"), record(3, "Codex"), record(4, "codex"), record(5, "Finder")]
        XCTAssertEqual(Set(pattern.select(from: initial).map(\.id.pid)), [1, 2, 3, 4])
        let later = initial.filter { $0.id.pid != 3 } + [record(6, "Codex Helper")]
        XCTAssertEqual(Set(pattern.select(from: later).map(\.id.pid)), [1, 2, 4, 6])
    }

    func testRegexValidationAnchorsAndUnicode() throws {
        XCTAssertThrowsError(try ProcessPattern("WindowServer|["))
        XCTAssertFalse(try ProcessPattern("").matches("WindowServer"))
        XCTAssertTrue(try ProcessPattern("^(codex|mentat)$").matches("CODEX"))
        XCTAssertFalse(try ProcessPattern("^codex$").matches("codex helper"))
        XCTAssertTrue(try ProcessPattern("工具|codex").matches("🛠 工具"))
    }

    func testCPUPercentUsesOneCoreAndCanExceed100() {
        XCTAssertEqual(CounterSample.percent(current: 3_500_000_000, previous: 500_000_000, elapsed: 2_000_000_000), 150)
        XCTAssertEqual(CounterSample.percent(current: 42, previous: 42, elapsed: 1_000_000_000), 0)
    }

    func testMissingResetAndZeroDurationCountersAreUnavailable() {
        XCTAssertNil(CounterSample.percent(current: 100, previous: nil, elapsed: 100))
        XCTAssertNil(CounterSample.percent(current: nil, previous: 100, elapsed: 100))
        XCTAssertNil(CounterSample.percent(current: 50, previous: 100, elapsed: 100))
        XCTAssertNil(CounterSample.percent(current: 100, previous: 50, elapsed: 0))
    }

    func testPIDReuseDoesNotMatchSavedSelection() throws {
        let old = ProcessIdentity(pid: 100, startedAtMicroseconds: 1_000_000)
        let new = ProcessIdentity(pid: 100, startedAtMicroseconds: 2_000_000)
        XCTAssertNotEqual(old, new)
        let process = ProcessRecord(id: old, name: "Editor", executable: "/Applications/Editor.app/Contents/MacOS/Editor", uid: 501,
                                    cpuPercent: 15, gpuPercent: nil, threads: 9, residentBytes: 100)
        let tracked = TrackedProcess(process)
        let restored = try JSONDecoder().decode(TrackedProcess.self, from: JSONEncoder().encode(tracked))
        XCTAssertEqual(restored, tracked)
        XCTAssertFalse(Set([restored.id]).contains(new))
    }

    func testUnavailableIsNotDisplayedAsZero() {
        XCTAssertEqual(MetricFormat.percent(nil), "—")
        XCTAssertEqual(MetricFormat.percent(.nan), "—")
        XCTAssertEqual(MetricFormat.percent(.infinity), "—")
        XCTAssertEqual(MetricFormat.percent(0), "0.0")
        XCTAssertEqual(MetricFormat.percent(201.25), "201.2")
        XCTAssertEqual(MetricFormat.count(nil), "—")
    }

    func testProtectedProcessMetricsUseSecondTopSample() {
        let output = """
        PID %CPU #TH #PORTS
        1 0.0 8/1 39
        Processes: 2 total
        PID %CPU #TH #PORTS
        1 12.5 9/2 40+
        2 150.1 5 20-
        """
        let parsed = TopMetricsParser.parse(output)
        XCTAssertEqual(parsed[1]?.cpuPercent, 12.5)
        XCTAssertEqual(parsed[1]?.threads, 9)
        XCTAssertEqual(parsed[1]?.ports, 40)
        XCTAssertEqual(parsed[2]?.cpuPercent, 150.1)
        XCTAssertTrue(TopMetricsParser.parse("123 4.0 10 20").isEmpty)
    }

    func testGPUCombinesStableClientsAndKeepsIdleZero() {
        let process = ProcessIdentity(pid: 100, startedAtMicroseconds: 10)
        let idle = ProcessIdentity(pid: 101, startedAtMicroseconds: 10)
        var tracker = GPUUsageTracker()
        XCTAssertTrue(tracker.sample([
            GPUClientSample(registryID: 1, process: process, queueTimes: [100_000_000, 50_000_000]),
            GPUClientSample(registryID: 2, process: process, queueTimes: [200_000_000]),
            GPUClientSample(registryID: 3, process: idle, queueTimes: [])
        ], at: 1_000_000_000).isEmpty)
        let rates = tracker.sample([
            GPUClientSample(registryID: 1, process: process, queueTimes: [300_000_000, 150_000_000]),
            GPUClientSample(registryID: 2, process: process, queueTimes: [300_000_000]),
            GPUClientSample(registryID: 3, process: idle, queueTimes: [])
        ], at: 2_000_000_000)
        XCTAssertEqual(rates[process], 40)
        XCTAssertEqual(rates[idle], 0)
    }

    func testGPUQueueChurnResetAndPIDReuseDoNotProduceSpikes() {
        let old = ProcessIdentity(pid: 100, startedAtMicroseconds: 10)
        let new = ProcessIdentity(pid: 100, startedAtMicroseconds: 20)
        var tracker = GPUUsageTracker()
        _ = tracker.sample([GPUClientSample(registryID: 1, process: old, queueTimes: [1_000])], at: 1_000)
        XCTAssertTrue(tracker.sample([GPUClientSample(registryID: 1, process: old, queueTimes: [1_500, 300])], at: 2_000).isEmpty)
        XCTAssertTrue(tracker.sample([GPUClientSample(registryID: 1, process: old, queueTimes: [100, 600])], at: 3_000).isEmpty)
        XCTAssertTrue(tracker.sample([GPUClientSample(registryID: 1, process: new, queueTimes: [200, 800])], at: 4_000).isEmpty)
        XCTAssertTrue(tracker.sample([GPUClientSample(registryID: 2, process: new, queueTimes: [9_000])], at: 5_000).isEmpty)
    }

    func testOverlayClampsToMonitorWithNegativeCoordinates() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let frame = CGRect(x: 100, y: 1000, width: 500, height: 120)
        let clamped = OverlayGeometry.clamped(frame, to: screen)
        XCTAssertEqual(clamped.maxX, -12)
        XCTAssertEqual(clamped.maxY, 868)
        XCTAssertTrue(screen.contains(clamped))
    }

    func testOverlayFitsSmallDisplays() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let result = OverlayGeometry.clamped(CGRect(x: 700, y: -50, width: 1200, height: 900), to: screen)
        XCTAssertEqual(result, CGRect(x: 12, y: 12, width: 776, height: 576))
    }
}
