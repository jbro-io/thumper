import AppKit
import CoreText

/// Single-line text in the overlay's flipped coordinate space.
@MainActor
public enum OverlayTextRenderer {
    private static func line(_ value: String, font: NSFont) -> CTLine {
        // Keep the typesetter's attributes immutable and native to Core Text.
        // On macOS 26, NSString.draw's conversion/copying of AppKit attributes
        // raised NSInvalidArgumentException while applying a font. Alignment,
        // truncation, color and shadow are handled separately below instead.
        let attributes = [
            kCTFontAttributeName: font as CTFont,
            kCTForegroundColorFromContextAttributeName: true
        ] as CFDictionary
        let string = CFAttributedStringCreate(nil, value as CFString, attributes)!
        return CTLineCreateWithAttributedString(string)
    }

    public static func width(_ value: String, font: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(value, font: font), nil, nil, nil))
    }

    public static func draw(_ value: String, in rect: CGRect, font: NSFont, color: CGColor,
                     shadowColor: CGColor, rightAligned: Bool, context: CGContext) {
        guard !value.isEmpty, rect.width > 0, rect.height > 0,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return }

        var textLine = line(value, font: font)
        if CTLineGetTypographicBounds(textLine, nil, nil, nil) > rect.width {
            guard let truncated = CTLineCreateTruncatedLine(textLine, rect.width, .end, line("…", font: font)) else { return }
            textLine = truncated
        }

        // Core Text may change both text state and graphics state during drawing.
        let textMatrix = context.textMatrix
        let textPosition = context.textPosition
        context.saveGState()
        defer {
            context.restoreGState()
            context.textMatrix = textMatrix
            context.textPosition = textPosition
        }
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY + font.ascender)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.setTextDrawingMode(.fill)
        context.setFillColor(color)
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: shadowColor)
        context.textPosition = CGPoint(x: CTLineGetPenOffsetForFlush(textLine, rightAligned ? 1 : 0, rect.width), y: 0)
        CTLineDraw(textLine, context)
    }
}
