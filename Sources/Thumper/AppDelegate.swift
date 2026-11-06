import AppKit
import SwiftUI
import ThumperCore

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var picker: NSPanel!
    private var overlay: OverlayController!
    private var store: AppStore!
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()
        store = AppStore()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = AppBranding.menuBarIcon
            button.toolTip = "Thumper — open controls beside the overlay"
            button.target = self
            button.action = #selector(togglePicker)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Thumper")
        }
        picker = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 790, height: 650),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        picker.title = "Thumper"
        picker.isOpaque = false
        picker.backgroundColor = .clear
        picker.hasShadow = true
        picker.level = .popUpMenu
        picker.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        picker.hidesOnDeactivate = true
        picker.isReleasedWhenClosed = false
        picker.animationBehavior = .none
        picker.contentViewController = GlassPickerController(rootView: PickerView(store: store, dismiss: { [weak self] in self?.closePicker() }))
        overlay = OverlayController(store: store, openPicker: { [weak self] in self?.showPicker(focusFilter: true) })
        store.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.showPicker() }
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "Thumper", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Thumper")
        let quitItem = appMenu.addItem(withTitle: "Quit Thumper", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appItem.submenu = appMenu

        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    @objc private func togglePicker() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
        } else if picker.isVisible {
            closePicker()
        } else {
            showPicker()
        }
    }

    func showPicker(focusFilter: Bool = false) {
        store.refreshDisplays()
        guard let screen = NSScreen.screens.first(where: { $0.displayID == store.preferences.displayID }) ?? NSScreen.main else { return }
        let anchor = (overlay.panel.isVisible || store.preferences.originX != nil) ? overlay.panel.frame : nil
        let frame = OverlayGeometry.pickerFrame(size: NSSize(width: 790, height: 650), near: anchor, on: screen.visibleFrame)
        picker.setFrame(frame, display: true)
        store.pickerVisible = true
        NSApp.activate(ignoringOtherApps: true)
        picker.makeKeyAndOrderFront(nil)
        if focusFilter { store.filterFocusRequest += 1 }
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.closePicker() }
            }
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // Native menus in the picker handle their own clicks. A click
                // on the separate overlay dismisses the picker.
                if event.window === self?.overlay.panel { self?.closePicker() }
                return event
            }
        }
    }

    func closePicker() {
        picker.orderOut(nil)
        store.pickerVisible = false
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }

    func applicationDidResignActive(_ notification: Notification) {
        if store?.pickerVisible == true { closePicker() }
    }

    private func showQuickMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Choose Processes…", action: #selector(openPickerAction), keyEquivalent: "")
        menu.addItem(withTitle: store.preferences.visible ? "Hide Overlay" : "Show Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        let front = menu.addItem(withTitle: "Always in Front", action: #selector(toggleAlwaysInFront), keyEquivalent: "")
        front.state = store.preferences.alwaysInFront ? .on : .off
        menu.addItem(withTitle: store.preferences.locked ? "Unlock Overlay" : "Lock & Click Through", action: #selector(toggleLock), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Thumper", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPickerAction() { DispatchQueue.main.async { [weak self] in self?.showPicker() } }
    @objc private func toggleOverlay() { store.preferences.visible.toggle() }
    @objc private func toggleLock() { store.preferences.locked.toggle() }
    @objc private func toggleAlwaysInFront() { store.preferences.alwaysInFront.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPicker()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        closePicker()
        overlay.stop()
        store.stop()
    }
}
