import AppKit

@MainActor
enum AppBranding {
    static let appIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "Thumper", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return menuBarIcon
    }()

    /// A separate optical design for 18-point use; template rendering follows
    /// the menu bar's light/dark appearance and increased-contrast settings.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // One broad sand ripple stays legible at the menu bar's native size.
            let ripple = NSBezierPath(ovalIn: NSRect(x: 1.75, y: 13.25, width: 14.5, height: 3.75))
            ripple.lineWidth = 1
            ripple.stroke()

            let barrel = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 2.5, width: 7, height: 7), xRadius: 0.8, yRadius: 0.8)
            for x: CGFloat in [6.5, 8.5, 10.5] {
                barrel.append(NSBezierPath(roundedRect: NSRect(x: x, y: 4, width: 1, height: 4), xRadius: 0.5, yRadius: 0.5))
            }
            barrel.windingRule = .evenOdd
            barrel.fill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 1, width: 8, height: 2), xRadius: 0.75, yRadius: 0.75).fill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 9.5, width: 8, height: 1.25), xRadius: 0.4, yRadius: 0.4).fill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 11.5, width: 6, height: 1), xRadius: 0.3, yRadius: 0.3).fill()

            let spike = NSBezierPath()
            spike.move(to: NSPoint(x: 6.5, y: 12.5))
            spike.line(to: NSPoint(x: 11.5, y: 12.5))
            spike.line(to: NSPoint(x: 10, y: 14))
            spike.line(to: NSPoint(x: 9.5, y: 16))
            spike.line(to: NSPoint(x: 8.5, y: 16))
            spike.line(to: NSPoint(x: 8, y: 14))
            spike.close()
            spike.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Thumper"
        return image
    }()
}
