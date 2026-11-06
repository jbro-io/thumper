import AppKit
import SwiftUI

@MainActor
enum GlassContainer {
    static func wrap(_ content: NSView, radius: CGFloat, clear: Bool = false) -> NSView {
        let container: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = clear ? .clear : .regular
            glass.cornerRadius = radius
            glass.contentView = content
            container = glass
        } else {
            let material = NSVisualEffectView(frame: content.frame)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = radius
            material.layer?.masksToBounds = true
            material.addSubview(content)
            container = material
        }
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.autoresizingMask = [.width, .height]
        return container
    }
}

@MainActor
final class GlassPickerController: NSViewController {
    private let hosting: NSHostingController<PickerView>

    init(rootView: PickerView) {
        hosting = NSHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        hosting.view.frame = NSRect(x: 0, y: 0, width: 790, height: 650)
        addChild(hosting)
        view = GlassContainer.wrap(hosting.view, radius: 22)
        preferredContentSize = NSSize(width: 790, height: 650)
    }
}
