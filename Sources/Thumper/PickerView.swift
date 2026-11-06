import AppKit
import ThumperCore
import SwiftUI

private enum ProcessFilter: String, CaseIterable { case all = "All processes", mine = "My processes", tracked = "Matches" }
private enum ProcessSort: String { case name = "Process", cpu = "CPU %", gpu = "GPU %", memory = "Memory", threads = "Threads", ports = "Ports", pid = "PID" }

struct PickerView: View {
    @ObservedObject var store: AppStore
    let dismiss: () -> Void
    @State private var search = ""
    @State private var draftPattern = ""
    @State private var patternError: String?
    @State private var filter: ProcessFilter = .all
    @State private var sort: ProcessSort = .name
    @State private var ascending = true
    @State private var showSettings = false
    @FocusState private var patternFocused: Bool

    private let accent = Color(red: 0.38, green: 0.87, blue: 0.69)

    private var rows: [ProcessRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = store.processes.filter { process in
            let matchesFilter = filter == .all || (filter == .mine && process.uid == getuid()) || (filter == .tracked && store.isTracked(process.id))
            return matchesFilter && (query.isEmpty || process.name.localizedCaseInsensitiveContains(query)
                || String(process.id.pid).contains(query) || process.executable.localizedCaseInsensitiveContains(query))
        }
        return filtered.sorted { left, right in
            if sort == .memory {
                if left.memoryBytes == nil && right.memoryBytes != nil { return false }
                if left.memoryBytes != nil && right.memoryBytes == nil { return true }
            }
            let order: ComparisonResult
            switch sort {
            case .name: order = left.name.localizedStandardCompare(right.name)
            case .cpu: order = compare(left.cpuPercent, right.cpuPercent)
            case .gpu: order = compare(left.gpuPercent, right.gpuPercent)
            case .memory: order = compare(left.memoryBytes.map(Double.init), right.memoryBytes.map(Double.init))
            case .threads: order = compare(left.threads.map(Double.init), right.threads.map(Double.init))
            case .ports: order = compare(store.ports[left.id].map(Double.init), store.ports[right.id].map(Double.init))
            case .pid: order = compare(Double(left.id.pid), Double(right.id.pid))
            }
            if order == .orderedSame { return left.id.pid < right.id.pid }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showSettings {
                settings
            } else {
                processPicker
            }
            footer
        }
        .frame(width: 790, height: 650)
        .background(Color.clear)
        .tint(accent)
        .onAppear {
            draftPattern = store.trackingPattern
            filter = store.trackingPattern.isEmpty ? .all : .tracked
            patternFocused = true
        }
        .onChange(of: store.filterFocusRequest) { _ in
            showSettings = false
            patternFocused = false
            DispatchQueue.main.async { patternFocused = true }
        }
        .onChange(of: store.trackingPattern) { pattern in
            draftPattern = pattern
            patternError = nil
        }
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppBranding.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Thumper").font(.system(size: 19, weight: .semibold))
                Text(showSettings ? "Make the overlay feel at home." : "One expression. Every matching process.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showSettings.toggle()
                if !showSettings { patternFocused = true }
            } label: {
                Label(showSettings ? "Processes" : "Settings", systemImage: showSettings ? "list.bullet" : "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            Button("Done") { if applyPattern() { dismiss() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
    }

    private var processPicker: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(".*").font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
                    TextField("Enter a process-name pattern", text: $draftPattern)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).focused($patternFocused)
                        .accessibilityLabel("Process name regular expression")
                        .onSubmit { _ = applyPattern() }
                        .onChange(of: draftPattern) { _ in patternError = nil }
                    Button("Apply") { _ = applyPattern() }.buttonStyle(.bordered)
                }.padding(12).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                Text(patternError ?? (draftPattern != store.trackingPattern
                    ? "Press Apply to use this expression. Your current filter stays active until then."
                    : "Matches names without case sensitivity. New instances are picked up automatically."))
                    .font(.system(size: 11)).foregroundStyle(patternError == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 24).padding(.bottom, 14)
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search by process name or PID", text: $search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search processes")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                Picker("Process filter", selection: $filter) {
                    ForEach(ProcessFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 320)
            }.padding(.horizontal, 24).padding(.bottom, 14)

            HStack(spacing: 0) {
                Color.clear.frame(width: 30, height: 1)
                sortHeading(.name).frame(maxWidth: .infinity, alignment: .leading)
                sortHeading(.cpu).frame(width: 70, alignment: .trailing)
                sortHeading(.gpu).frame(width: 70, alignment: .trailing)
                sortHeading(.memory).frame(width: 90, alignment: .trailing).help("Physical memory footprint")
                sortHeading(.threads).frame(width: 66, alignment: .trailing)
                sortHeading(.ports).frame(width: 66, alignment: .trailing)
                sortHeading(.pid).frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, 30).padding(.vertical, 10)
            .background(Color.primary.opacity(0.035))

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(rows) { process in processRow(process) }
                }.padding(.vertical, 6).padding(.horizontal, 16)
                if rows.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: filter == .tracked ? "checkmark.circle" : "magnifyingglass").font(.system(size: 27)).foregroundStyle(.secondary)
                        Text(emptyTitle).font(.system(size: 15, weight: .medium))
                        Text(emptyMessage).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.top, 70)
                }
            }
            .frame(maxHeight: .infinity)
            .accessibilityLabel("Running processes")

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle").foregroundStyle(accent.opacity(0.8))
                Text("GPU % uses live GPU-driver timing. — means no reported counter. Mach ports and protected process metrics refresh about every 5 seconds. CPU uses 100% per core.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
    }

    private func processRow(_ process: ProcessRecord) -> some View {
        let selected = store.isTracked(process.id)
        return HStack(spacing: 0) {
                Image(systemName: selected ? "waveform.path" : "minus")
                    .font(.system(size: 13)).foregroundStyle(selected ? accent : Color.secondary.opacity(0.3))
                    .frame(width: 30, alignment: .leading)
                Text(process.name).font(.system(size: 12, weight: selected ? .medium : .regular))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                cell(MetricFormat.percent(process.cpuPercent), width: 70, highlighted: (process.cpuPercent ?? 0) >= 50)
                cell(MetricFormat.percent(process.gpuPercent), width: 70)
                cell(MetricFormat.memory(process.memoryBytes), width: 90)
                cell(MetricFormat.count(process.threads), width: 66)
                cell(MetricFormat.count(store.ports[process.id]), width: 66)
                cell(String(process.id.pid), width: 72, muted: true)
            }
            .padding(.horizontal, 14).frame(height: 32)
            .background(store.highlightedProcess == process.id ? accent.opacity(0.27) : (selected ? accent.opacity(0.08) : Color.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        .onTapGesture { store.highlightedProcess = process.id }
        .help("\(process.executable.isEmpty ? process.name : process.executable)\nPID \(process.id.pid) · \(selected ? "Matches your expression" : "Not matched")")
        .contextMenu {
            Button("Add Name to Expression") {
                let literal = NSRegularExpression.escapedPattern(for: process.name)
                draftPattern = draftPattern.isEmpty ? literal : "(?:\(draftPattern))|(?:\(literal))"
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction { store.highlightedProcess = process.id }
        .accessibilityValue(store.highlightedProcess == process.id ? "Highlighted" : "")
        .accessibilityLabel("\(process.name), PID \(process.id.pid), CPU \(MetricFormat.percent(process.cpuPercent)), GPU \(MetricFormat.percent(process.gpuPercent)), Memory \(MetricFormat.memory(process.memoryBytes)), \(selected ? "tracked" : "not matched")")
    }

    private func cell(_ text: String, width: CGFloat, highlighted: Bool = false, muted: Bool = false) -> some View {
        Text(text).font(.system(size: 12, weight: highlighted ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(highlighted ? accent : (muted || text == "—" ? Color.secondary : Color.primary))
            .frame(width: width, alignment: .trailing)
    }

    private func sortHeading(_ column: ProcessSort) -> some View {
        Button {
            if sort == column { ascending.toggle() }
            else { sort = column; ascending = column == .name || column == .pid }
        } label: {
            HStack(spacing: 3) {
                Text(column.rawValue)
                if sort == column { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(sort == column ? Color.primary : Color.secondary)
        }.buttonStyle(.plain).accessibilityLabel("Sort by \(column.rawValue)")
    }

    private var emptyTitle: String {
        if store.updatedAt == nil { return "Reading processes…" }
        if store.sampleError != nil { return "Process list unavailable" }
        return filter == .tracked && store.trackingPattern.isEmpty ? "Your overlay starts here" : "No matching processes"
    }

    private var emptyMessage: String {
        if let error = store.sampleError { return error }
        return filter == .tracked ? "Apply a regular expression above. Matching processes appear automatically when they start." : "Try a different name or PID."
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingGroup("PLACEMENT") {
                    HStack {
                        Label("Monitor", systemImage: "display")
                        Spacer()
                        Picker("Monitor", selection: Binding(get: { store.preferences.displayID ?? 0 }, set: { store.selectDisplay($0) })) {
                            ForEach(store.displays) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 390)
                    }
                    Divider()
                    Toggle("Always in front", isOn: $store.preferences.alwaysInFront).toggleStyle(.switch)
                        .help("Keep the overlay above other apps, including full-screen spaces.")
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Lock position & click through", isOn: $store.preferences.locked).toggleStyle(.switch)
                            Text("Left-clicks pass through when locked. Right-click the overlay to unlock or edit its filter.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset Position") { store.resetPosition() }
                    }
                }
                settingGroup("APPEARANCE") {
                    HStack {
                        Text("Overlay background")
                        Spacer()
                        Picker("Overlay background", selection: $store.preferences.backgroundStyle) {
                            Text("Subtle").tag("Subtle")
                            Text("Text only").tag("Text only")
                            Text("Liquid Glass").tag("Liquid Glass")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                    }
                    if store.preferences.backgroundStyle == "Subtle" {
                        HStack {
                            Text("Background opacity")
                            Spacer()
                            Slider(value: $store.preferences.backgroundOpacity, in: 0...0.8).frame(width: 225).accessibilityLabel("Background opacity")
                            Text("\(Int(store.preferences.backgroundOpacity * 100))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                        }
                    }
                    Divider()
                    HStack {
                        Text("Text size")
                        Spacer()
                        Picker("Text size", selection: $store.preferences.fontSize) {
                            Text("Small").tag(11.0)
                            Text("Medium").tag(13.0)
                            Text("Large").tag(16.0)
                            Text("Extra large").tag(19.0)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 390)
                    }
                    Divider()
                    HStack {
                        Text("Text color")
                        Spacer()
                        Picker("Text color", selection: $store.preferences.ink) {
                            Text("White").tag("White")
                            Text("Dark").tag("Dark")
                            Text("Mint").tag("Mint")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
                    }
                    Divider()
                    HStack {
                        Text("Text opacity")
                        Spacer()
                        Slider(value: $store.preferences.opacity, in: 0.35...1).frame(width: 225).accessibilityLabel("Text opacity")
                        Text("\(Int(store.preferences.opacity * 100))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                }
                settingGroup("VISIBLE METRICS") {
                    HStack(spacing: 22) {
                        Text("CPU %").foregroundStyle(.secondary)
                        Toggle("GPU %", isOn: $store.preferences.showGPU)
                        Toggle("Memory", isOn: $store.preferences.showMemory)
                        Toggle("Threads", isOn: $store.preferences.showThreads)
                        Toggle("Ports", isOn: $store.preferences.showPorts)
                        Toggle("PID", isOn: $store.preferences.showPID)
                        Spacer()
                    }.toggleStyle(.checkbox)
                    Divider()
                    HStack {
                        Toggle("Column headings", isOn: $store.preferences.showHeaders).toggleStyle(.checkbox)
                        Spacer()
                        Text("Refresh")
                        Picker("Refresh interval", selection: $store.preferences.interval) {
                            Text("0.5 seconds").tag(0.5)
                            Text("1 second").tag(1.0)
                            Text("2 seconds").tag(2.0)
                            Text("5 seconds").tag(5.0)
                        }.labelsHidden().frame(width: 140)
                    }
                    Divider()
                    HStack {
                        Text("Overlay sort")
                        Spacer()
                        Picker("Overlay sort", selection: $store.preferences.overlaySortField) {
                            Text("Process").tag(ProcessSortField.name)
                            Text("CPU %").tag(ProcessSortField.cpu)
                            Text("GPU %").tag(ProcessSortField.gpu)
                            Text("Memory").tag(ProcessSortField.memory)
                            Text("Threads").tag(ProcessSortField.threads)
                            Text("Ports").tag(ProcessSortField.ports)
                            Text("PID").tag(ProcessSortField.pid)
                        }.labelsHidden().frame(width: 130)
                        Toggle("Ascending", isOn: $store.preferences.overlaySortAscending).toggleStyle(.checkbox)
                    }
                }
                Text("Drag the unlocked overlay to place it. Click its column headings to sort; click again to reverse. Your expression and settings are saved. Every matching instance appears automatically and disappears when it exits.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 24).padding(.bottom, 20)
        }.frame(maxHeight: .infinity)
    }

    private func settingGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12, content: content)
                .font(.system(size: 12)).padding(16)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Circle().fill(store.sampleError == nil ? accent : Color.orange).frame(width: 6, height: 6)
                Text("\(store.tracked.count) tracked").font(.system(size: 12, weight: .medium))
                Text("·").foregroundStyle(.tertiary)
                Text(store.sampleError != nil ? "Sampling unavailable" : "\(store.processes.count) processes")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let error = store.portError { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(error) }
                Spacer()
                Toggle("Overlay", isOn: $store.preferences.visible).toggleStyle(.switch).controlSize(.small)
                Menu {
                    Button("Clear Filter") { draftPattern = ""; _ = applyPattern() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 28).help("More options")
                Button("Quit Thumper") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.padding(.horizontal, 24).padding(.vertical, 15)
        }
    }

    private func compare(_ left: Double?, _ right: Double?) -> ComparisonResult {
        let l = left ?? -1, r = right ?? -1
        return l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
    }

    @discardableResult
    private func applyPattern() -> Bool {
        patternError = store.applyPattern(draftPattern)
        guard patternError == nil else { showSettings = false; return false }
        draftPattern = store.trackingPattern
        filter = draftPattern.isEmpty ? .all : .tracked
        search = ""
        return true
    }
}
