import AppKit
import Combine
import ThumperCore

struct OverlayPreferences: Codable, Equatable {
    var visible = true
    var locked = false
    var alwaysInFront = true
    var glassBackground = false
    var backgroundStyle = "Subtle"
    var backgroundOpacity = 0.18
    var overlaySortField: ProcessSortField = .name
    var overlaySortAscending = true
    var fontSize: Double = 13
    var opacity: Double = 1
    var ink = "White"
    var interval: Double = 1
    var displayID: UInt32?
    var originX: Double?
    var originY: Double?
    var showHeaders = true
    var showGPU = true
    var showThreads = true
    var showPorts = true
    var showPID = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case visible, locked, alwaysInFront, glassBackground, fontSize, opacity, ink, interval
        case displayID, originX, originY, showHeaders, showGPU, showThreads, showPorts, showPID
        case backgroundStyle, backgroundOpacity, overlaySortField, overlaySortAscending
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        visible = try values.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        locked = try values.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        alwaysInFront = try values.decodeIfPresent(Bool.self, forKey: .alwaysInFront) ?? true
        glassBackground = try values.decodeIfPresent(Bool.self, forKey: .glassBackground) ?? false
        backgroundStyle = try values.decodeIfPresent(String.self, forKey: .backgroundStyle) ?? (glassBackground ? "Liquid Glass" : "Subtle")
        backgroundOpacity = try values.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.18
        overlaySortField = try values.decodeIfPresent(ProcessSortField.self, forKey: .overlaySortField) ?? .name
        overlaySortAscending = try values.decodeIfPresent(Bool.self, forKey: .overlaySortAscending) ?? true
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        ink = try values.decodeIfPresent(String.self, forKey: .ink) ?? "White"
        interval = try values.decodeIfPresent(Double.self, forKey: .interval) ?? 1
        displayID = try values.decodeIfPresent(UInt32.self, forKey: .displayID)
        originX = try values.decodeIfPresent(Double.self, forKey: .originX)
        originY = try values.decodeIfPresent(Double.self, forKey: .originY)
        showHeaders = try values.decodeIfPresent(Bool.self, forKey: .showHeaders) ?? true
        showGPU = try values.decodeIfPresent(Bool.self, forKey: .showGPU) ?? true
        showThreads = try values.decodeIfPresent(Bool.self, forKey: .showThreads) ?? true
        showPorts = try values.decodeIfPresent(Bool.self, forKey: .showPorts) ?? true
        showPID = try values.decodeIfPresent(Bool.self, forKey: .showPID) ?? true
    }

    mutating func validate() {
        fontSize = [11.0, 13, 16, 19].contains(fontSize) ? fontSize : 13
        interval = [0.5, 1.0, 2.0, 5.0].contains(interval) ? interval : 1
        opacity = opacity.isFinite ? min(1, max(0.35, opacity)) : 1
        ink = ["White", "Dark", "Mint"].contains(ink) ? ink : "White"
        backgroundStyle = ["Subtle", "Text only", "Liquid Glass"].contains(backgroundStyle) ? backgroundStyle : "Subtle"
        backgroundOpacity = backgroundOpacity.isFinite ? min(0.8, max(0, backgroundOpacity)) : 0.18
        if originX?.isFinite == false { originX = nil }
        if originY?.isFinite == false { originY = nil }
    }
}

struct DisplayOption: Identifiable {
    let id: UInt32
    let name: String
}

struct OverlayRow: Identifiable {
    let tracked: TrackedProcess
    let process: ProcessRecord?
    let ports: Int?
    let samplingFailed: Bool
    var id: ProcessIdentity { tracked.id }
    var name: String { process?.name ?? tracked.name }
    var status: String? { process == nil ? (samplingFailed ? "Unavailable" : "Exited") : nil }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var processes: [ProcessRecord] = []
    @Published private(set) var ports: [ProcessIdentity: Int] = [:]
    @Published private(set) var tracked: [TrackedProcess] = []
    @Published private(set) var trackingPattern = ""
    @Published var highlightedProcess: ProcessIdentity?
    @Published var preferences = OverlayPreferences() { didSet { save() } }
    @Published private(set) var displays: [DisplayOption] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var sampleError: String?
    @Published private(set) var portError: String?
    @Published var pickerVisible = false
    @Published var filterFocusRequest = 0

    private let sampler = ProcessSampler()
    private let portSampler = PortSampler()
    private var sampleTask: Task<Void, Never>?
    private var portTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private var byIdentity: [ProcessIdentity: ProcessRecord] = [:]
    private var portDate: Date?
    private var lastPortRequestAt: Date?
    private var supplementalReadings: [ProcessIdentity: SupplementalMetrics] = [:]
    private var restoring = true
    private var pattern = try! ProcessPattern("")
    private(set) var isStopped = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "overlayPreferences"),
           var saved = try? JSONDecoder().decode(OverlayPreferences.self, from: data) {
            saved.validate()
            preferences = saved
        }
        if let saved = defaults.string(forKey: "trackingPattern"), let compiled = try? ProcessPattern(saved) {
            trackingPattern = compiled.text
            pattern = compiled
        }
        restoring = false
        refreshDisplays()
    }

    var overlayRows: [OverlayRow] {
        let rows = tracked.map { OverlayRow(tracked: $0, process: byIdentity[$0.id], ports: ports[$0.id], samplingFailed: sampleError != nil || updatedAt == nil) }
        func values(_ row: OverlayRow) -> ProcessSortValues {
            ProcessSortValues(id: row.id, name: row.name, cpu: row.process?.cpuPercent,
                              gpu: row.process?.gpuPercent, threads: row.process?.threads, ports: row.ports)
        }
        return rows.sorted { ProcessOrdering.precedes(values($0), values($1), by: preferences.overlaySortField, ascending: preferences.overlaySortAscending) }
    }

    func sortOverlay(by field: ProcessSortField) {
        var next = preferences
        if next.overlaySortField == field { next.overlaySortAscending.toggle() }
        else { next.overlaySortField = field; next.overlaySortAscending = field == .name || field == .pid }
        preferences = next
    }

    var liveTrackedCount: Int { tracked.filter { byIdentity[$0.id] != nil }.count }

    func isTracked(_ id: ProcessIdentity) -> Bool { tracked.contains { $0.id == id } }
    func process(for id: ProcessIdentity) -> ProcessRecord? { byIdentity[id] }

    @discardableResult
    func applyPattern(_ text: String) -> String? {
        do {
            let compiled = try ProcessPattern(text)
            pattern = compiled
            trackingPattern = compiled.text
            refreshTracking()
            save()
            return nil
        } catch {
            return "Invalid regular expression. The previous filter is still active."
        }
    }

    private func refreshTracking() {
        let matches = pattern.select(from: processes)
        if matches != tracked { tracked = matches }
        if let highlightedProcess, byIdentity[highlightedProcess] == nil { self.highlightedProcess = nil }
    }

    func start() {
        guard sampleTask == nil else { return }
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let began = Date()
                let snapshot = await sampler.sample()
                guard !Task.isCancelled else { return }
                if let portDate, Date().timeIntervalSince(portDate) > 15 {
                    ports = [:]
                    supplementalReadings = [:]
                }
                processes = snapshot.processes.map { record in
                    guard record.threads == nil, let extra = self.supplementalReadings[record.id] else { return record }
                    return ProcessRecord(id: record.id, name: record.name, executable: record.executable, uid: record.uid,
                                         cpuPercent: extra.cpuPercent, gpuPercent: record.gpuPercent, threads: extra.threads, residentBytes: record.residentBytes)
                }
                byIdentity = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) })
                sampleError = snapshot.error
                updatedAt = snapshot.date
                if snapshot.error == nil { refreshTracking() }
                if portTask == nil && (pickerVisible || (preferences.visible && !tracked.isEmpty))
                    && (lastPortRequestAt == nil || Date().timeIntervalSince(lastPortRequestAt!) >= 5) {
                    refreshPorts()
                }
                let delay = max(0.1, preferences.interval - Date().timeIntervalSince(began))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stop() {
        isStopped = true
        sampleTask?.cancel()
        portTask?.cancel()
        portSampler.stop()
    }

    private func refreshPorts() {
        let identities = processes.map(\.id)
        lastPortRequestAt = Date()
        portTask = Task { [weak self, portSampler] in
            let result = await portSampler.sample(identities: identities)
            guard let self, !Task.isCancelled else { return }
            ports = result.counts
            supplementalReadings = result.readings
            portDate = result.date
            portError = result.error
            portTask = nil
        }
    }

    func refreshDisplays() {
        displays = NSScreen.screens.map {
            DisplayOption(id: $0.displayID, name: "\($0.localizedName) · \(Int($0.frame.width)) × \(Int($0.frame.height))")
        }
        if !displays.contains(where: { $0.id == preferences.displayID }) {
            preferences.displayID = NSScreen.main?.displayID ?? displays.first?.id
            preferences.originX = nil
            preferences.originY = nil
        }
    }

    func selectDisplay(_ id: UInt32) {
        var next = preferences
        next.displayID = id
        next.originX = nil
        next.originY = nil
        preferences = next
    }

    func resetPosition() {
        var next = preferences
        next.originX = nil
        next.originY = nil
        preferences = next
    }

    func rememberPosition(_ origin: CGPoint, displayID: UInt32?) {
        var next = preferences
        next.originX = origin.x
        next.originY = origin.y
        next.displayID = displayID
        preferences = next
    }

    private func save() {
        guard !restoring else { return }
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "overlayPreferences") }
        defaults.set(trackingPattern, forKey: "trackingPattern")
    }
}

extension NSScreen {
    var displayID: UInt32 { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
}
