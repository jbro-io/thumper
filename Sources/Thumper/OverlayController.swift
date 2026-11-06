import AppKit
import Combine
import ThumperCore

private final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let contextMenu: OverlayMenuController
    private let content: OverlayCanvas
    private let store: AppStore
    private var observations: Set<AnyCancellable> = []
    private var adjustingFrame = false
    private var hasGlass = false
    private var globalContextMonitor: Any?
    private var localContextMonitor: Any?
    private var contextMenuPending = false

    init(store: AppStore, openPicker: @escaping () -> Void) {
        self.store = store
        contextMenu = OverlayMenuController(store: store, openPicker: openPicker)
        content = OverlayCanvas(store: store)
        panel = GlassPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Thumper Overlay"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isMovable = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.delegate = self
        content.autoresizingMask = [.width, .height]
        content.onDragFinished = { [weak self] in self?.update() }
        content.onContextMenu = { [weak self] point in self?.contextMenu.show(at: point) }

        // ignoresMouseEvents applies to every mouse button. Observe right-clicks
        // separately so locking the table never removes its unlock menu.
        globalContextMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
            self?.handleLockedContextClick(at: NSEvent.mouseLocation)
        }
        localContextMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self,
                  (event.window?.level.rawValue ?? 0) < NSWindow.Level.popUpMenu.rawValue else { return event }
            return self.handleLockedContextClick(at: NSEvent.mouseLocation) ? nil : event
        }

        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.store.refreshDisplays()
                self?.update()
            }.store(in: &observations)
        update()
    }

    func stop() {
        contextMenu.dismiss()
        if let globalContextMonitor { NSEvent.removeMonitor(globalContextMonitor) }
        if let localContextMonitor { NSEvent.removeMonitor(localContextMonitor) }
        globalContextMonitor = nil
        localContextMonitor = nil
    }

    @discardableResult
    private func handleLockedContextClick(at point: CGPoint) -> Bool {
        guard store.preferences.locked, panel.isVisible, panel.isOnActiveSpace,
              panel.frame.contains(point), !contextMenuPending else { return false }
        contextMenuPending = true
        // Leave the event handler before opening the menu. Activation dismisses
        // any context menu in the underlying app.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.contextMenuPending = false }
            guard self.panel.isVisible, self.store.preferences.locked else { return }
            self.contextMenu.show(at: point)
        }
        return true
    }

    func update() {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == store.preferences.displayID }) ?? NSScreen.main else { return }
        let wantsGlass = store.preferences.backgroundStyle == "Liquid Glass"
        if hasGlass != wantsGlass {
            content.removeFromSuperview()
            panel.contentView = wantsGlass ? GlassContainer.wrap(content, radius: 14, clear: true) : content
            hasGlass = wantsGlass
            panel.hasShadow = hasGlass
        }
        if !content.isDragging {
            let size = content.desiredSize
            let origin: CGPoint
            if let x = store.preferences.originX, let y = store.preferences.originY {
                origin = CGPoint(x: x, y: y)
            } else {
                origin = CGPoint(x: screen.visibleFrame.maxX - size.width - 32,
                                 y: screen.visibleFrame.maxY - size.height - 40)
            }
            var placement = store.preferences.placement
                ?? OverlayPlacement(frame: CGRect(origin: origin, size: size), on: screen.visibleFrame)
            // Keep the last visible size and anchor while no processes match,
            // including the empty sample before the app finishes launching.
            placement.resize(to: store.tracked.isEmpty ? placement.frame.size : size, on: screen.visibleFrame)
            adjustingFrame = true
            if panel.frame != placement.frame { panel.setFrame(placement.frame, display: true) }
            adjustingFrame = false
            if !store.tracked.isEmpty { store.rememberPlacement(placement, displayID: screen.displayID) }
        }
        panel.ignoresMouseEvents = store.preferences.locked
        let level: NSWindow.Level = store.preferences.alwaysInFront ? .floating : .normal
        if panel.level != level { panel.level = level }
        content.needsDisplay = true
        panel.invalidateCursorRects(for: content)
        if store.preferences.visible && !store.tracked.isEmpty {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            panel.orderOut(nil)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !adjustingFrame, let screen = panel.screen else { return }
        store.rememberPlacement(OverlayPlacement(frame: panel.frame, on: screen.visibleFrame), displayID: screen.displayID)
    }
}

@MainActor
private final class OverlayCanvas: NSView {
    private let store: AppStore
    private var dragStart: CGPoint?
    private var dragOrigin: CGPoint?
    private var mouseMoved = false
    private(set) var isDragging = false
    var onDragFinished: (() -> Void)?
    var onContextMenu: ((CGPoint) -> Void)?
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(store: AppStore) {
        self.store = store
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var fontSize: CGFloat { store.preferences.fontSize }
    private var rowHeight: CGFloat { fontSize * 1.9 }
    private var processColumnWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        var width = store.tracked.reduce(CGFloat.zero) { width, process in
            max(width, (process.name as NSString).size(withAttributes: [.font: font]).width)
        }
        if store.preferences.showHeaders {
            let headingFont = NSFont.systemFont(ofSize: fontSize * 0.76, weight: .semibold)
            // Reserve either sort arrow so changing sort order does not resize the column.
            for heading in ["PROCESS ▴", "PROCESS ▾"] {
                width = max(width, (heading as NSString).size(withAttributes: [.font: headingFont]).width)
            }
        }
        // Match the gap removed from the text rectangle when drawing a cell.
        return ceil(width) + 12
    }

    private var columns: [(String, CGFloat, ProcessSortField)] {
        let factor = fontSize / 13
        var result: [(String, CGFloat, ProcessSortField)] = [("PROCESS", processColumnWidth, .name), ("CPU %", 66 * factor, .cpu)]
        if store.preferences.showGPU { result.append(("GPU %", 66 * factor, .gpu)) }
        if store.preferences.showThreads { result.append(("THREADS", 72 * factor, .threads)) }
        if store.preferences.showPorts { result.append(("PORTS", 64 * factor, .ports)) }
        if store.preferences.showPID { result.append(("PID", 72 * factor, .pid)) }
        return result
    }

    var desiredSize: CGSize {
        CGSize(width: columns.reduce(0) { $0 + $1.1 } + 20,
               height: CGFloat(max(1, store.tracked.count) + (store.preferences.showHeaders ? 1 : 0)) * rowHeight + 16)
    }

    private var ink: NSColor {
        switch store.preferences.ink {
        case "Dark": return NSColor(white: 0.06, alpha: 1)
        case "Mint": return NSColor(srgbRed: 0.48, green: 1, blue: 0.81, alpha: 1)
        default: return .white
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let columns = self.columns
        let desiredSize = self.desiredSize
        NSGraphicsContext.current?.cgContext.clear(bounds)
        if store.preferences.backgroundStyle == "Subtle" {
            let background: NSColor = store.preferences.ink == "Dark" ? .white : .black
            background.withAlphaComponent(store.preferences.backgroundOpacity).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        let scale = min(1, bounds.width / desiredSize.width, bounds.height / desiredSize.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        var y: CGFloat = 8
        if store.preferences.showHeaders {
            var x: CGFloat = 10
            for (index, column) in columns.enumerated() {
                let sorted = column.2 == store.preferences.overlaySortField
                let heading = column.0 + (sorted ? (store.preferences.overlaySortAscending ? " ▴" : " ▾") : "")
                text(heading, in: CGRect(x: x, y: y + 3, width: column.1 - 12, height: rowHeight),
                     size: fontSize * 0.76, weight: .semibold, right: index > 0, alpha: sorted ? 0.95 : 0.65)
                x += column.1
            }
            y += rowHeight
        }
        var accessibility: [String] = []
        for row in store.overlayRows {
            if store.highlightedProcess == row.id {
                NSColor(srgbRed: 0.28, green: 0.85, blue: 0.66, alpha: 0.3).setFill()
                NSBezierPath(roundedRect: CGRect(x: 4, y: y - 2, width: desiredSize.width - 8, height: rowHeight), xRadius: 5, yRadius: 5).fill()
            }
            var values = [row.name, row.status ?? MetricFormat.percent(row.process?.cpuPercent)]
            if store.preferences.showGPU { values.append(MetricFormat.percent(row.process?.gpuPercent)) }
            if store.preferences.showThreads { values.append(MetricFormat.count(row.process?.threads)) }
            if store.preferences.showPorts { values.append(MetricFormat.count(row.ports)) }
            if store.preferences.showPID { values.append(String(row.id.pid)) }
            var x: CGFloat = 10
            for (index, column) in columns.enumerated() {
                text(values[index], in: CGRect(x: x, y: y, width: column.1 - 12, height: rowHeight),
                     size: fontSize, weight: index == 0 ? .medium : .regular,
                     right: index > 0, alpha: row.status == nil ? 1 : 0.55)
                x += column.1
            }
            accessibility.append("\(row.name), PID \(row.id.pid), CPU \(MetricFormat.percent(row.process?.cpuPercent)) percent, \(row.status ?? "running")")
            y += rowHeight
        }
        setAccessibilityLabel(accessibility.joined(separator: "; "))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func text(_ value: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight,
                      right: Bool, alpha: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = right ? .right : .left
        paragraph.lineBreakMode = .byTruncatingTail
        let shadow = NSShadow()
        shadow.shadowColor = (store.preferences.ink == "Dark" ? NSColor.white : NSColor.black).withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: right ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: ink.withAlphaComponent(alpha * store.preferences.opacity), .paragraphStyle: paragraph, .shadow: shadow
        ]
        (value as NSString).draw(in: rect, withAttributes: attributes)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        if store.preferences.showHeaders { addCursorRect(CGRect(x: 0, y: 0, width: bounds.width, height: rowHeight + 8), cursor: .pointingHand) }
    }
    override func mouseDown(with event: NSEvent) {
        guard !store.preferences.locked else { return }
        dragStart = NSEvent.mouseLocation
        dragOrigin = window?.frame.origin
        mouseMoved = false
        isDragging = true
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let dragOrigin else { return }
        let location = NSEvent.mouseLocation
        if hypot(location.x - dragStart.x, location.y - dragStart.y) > 3 { mouseMoved = true }
        window?.setFrameOrigin(CGPoint(x: dragOrigin.x + location.x - dragStart.x,
                                      y: dragOrigin.y + location.y - dragStart.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        if !mouseMoved {
            let point = convert(event.locationInWindow, from: nil)
            let scale = min(1, bounds.width / desiredSize.width, bounds.height / desiredSize.height)
            if store.preferences.showHeaders, point.y / scale >= 8, point.y / scale < 8 + rowHeight {
                var x: CGFloat = 10
                for column in columns {
                    if (x..<(x + column.1)).contains(point.x / scale) { store.sortOverlay(by: column.2); break }
                    x += column.1
                }
            } else {
                let index = Int(floor((point.y / scale - 8 - (store.preferences.showHeaders ? rowHeight : 0)) / rowHeight))
                let rows = store.overlayRows
                if rows.indices.contains(index) { store.highlightedProcess = rows[index].id }
            }
        }
        dragStart = nil
        dragOrigin = nil
        NSCursor.pop()
        onDragFinished?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(NSEvent.mouseLocation)
    }
}
