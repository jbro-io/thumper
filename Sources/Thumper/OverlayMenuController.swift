import AppKit
import SwiftUI
import ThumperCore

private final class OverlayMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A menu-sized panel provides normal text editing, which NSMenu's custom
/// item views do not support. It opens at the right-click and dismisses like a menu.
@MainActor
final class OverlayMenuController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let store: AppStore
    private let openPicker: () -> Void
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private static let size = NSSize(width: 370, height: 268)

    init(store: AppStore, openPicker: @escaping () -> Void) {
        self.store = store
        self.openPicker = openPicker
        panel = OverlayMenuPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.title = "Thumper Overlay Menu"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
    }

    func show(at point: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        dismiss()
        let view = NSHostingView(rootView: OverlayMenuView(store: store, dismiss: { [weak self] in self?.dismiss() },
            openPicker: { [weak self] in
                self?.dismiss()
                self?.openPicker()
            }))
        view.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = GlassContainer.wrap(view, radius: 14)
        let frame = NSRect(x: point.x, y: point.y - Self.size.height, width: Self.size.width, height: Self.size.height)
        panel.setFrame(OverlayGeometry.clamped(frame, to: screen.visibleFrame), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel,
               (event.window?.level.rawValue ?? 0) < NSWindow.Level.popUpMenu.rawValue {
                self.dismiss()
            }
            return event
        }
    }

    func dismiss() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        outsideMonitor = nil
        localMonitor = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { dismiss() }
}

private struct OverlayMenuView: View {
    @ObservedObject var store: AppStore
    let dismiss: () -> Void
    let openPicker: () -> Void
    @State private var draft: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(store: AppStore, dismiss: @escaping () -> Void, openPicker: @escaping () -> Void) {
        self.store = store
        self.dismiss = dismiss
        self.openPicker = openPicker
        _draft = State(initialValue: store.trackingPattern)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Process filter").font(.system(size: 12, weight: .semibold)).padding(.bottom, 8)
            HStack(spacing: 8) {
                TextField("Enter a process-name pattern", text: $draft)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .accessibilityLabel("Process name regular expression")
                    .onSubmit(apply)
                    .onChange(of: draft) { _ in error = nil }
                Button("Apply", action: apply).keyboardShortcut(.defaultAction)
            }
            Text(error == nil ? "Regular expression · ignores case · tracks every instance" : "Invalid expression. Your current filter is unchanged.")
                .font(.system(size: 10)).foregroundStyle(error == nil ? Color.secondary : Color.orange)
                .frame(height: 28, alignment: .leading)
            Divider().padding(.vertical, 6)
            OverlayMenuAction(title: "Open Process List…", symbol: "list.bullet", action: openPicker)
            OverlayMenuAction(title: store.preferences.locked ? "Unlock Overlay" : "Lock Position & Click Through",
                              symbol: store.preferences.locked ? "lock.open" : "lock") {
                store.preferences.locked.toggle()
                dismiss()
            }
            OverlayMenuAction(title: "Hide Overlay", symbol: "eye.slash") {
                store.preferences.visible = false
                dismiss()
            }
            Divider().padding(.vertical, 6)
            OverlayMenuAction(title: "Quit Thumper", symbol: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 370, height: 268)
        .onAppear { focused = true }
        .onExitCommand(perform: dismiss)
    }

    private func apply() {
        error = store.applyPattern(draft)
        if error == nil { dismiss() }
    }
}

private struct OverlayMenuAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7).frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.primary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
    }
}
