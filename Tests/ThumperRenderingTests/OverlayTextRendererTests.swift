import AppKit
import XCTest
@testable import ThumperRendering

@MainActor
final class OverlayTextRendererTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 256, height: 48)
    private let cell = CGRect(x: 8, y: 4, width: 240, height: 40)

    private func bitmap() throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 48, bitsPerComponent: 8,
                                             bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 48)
        context.scaleBy(x: 1, y: -1)
        return context
    }

    private func visibleColumns(_ context: CGContext) throws -> ClosedRange<Int>? {
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var columns: [Int] = []
        for x in 0..<context.width {
            if (0..<context.height).contains(where: { bytes[$0 * context.bytesPerRow + x * 4 + 3] > 20 }) {
                columns.append(x)
            }
        }
        guard let first = columns.first, let last = columns.last else { return nil }
        return first...last
    }

    private func draw(_ text: String, in rect: CGRect? = nil, font: NSFont? = nil,
                      right: Bool = false, context: CGContext) {
        OverlayTextRenderer.draw(text, in: rect ?? cell,
                                 font: font ?? .monospacedSystemFont(ofSize: 16, weight: .regular),
                                 color: NSColor.white.cgColor, shadowColor: NSColor.clear.cgColor,
                                 rightAligned: right, context: context)
    }

    func testNamesAndMetricsAlignToOppositeEdges() async throws {
        let context = try bitmap()
        draw("codex", context: context)
        let left = try XCTUnwrap(visibleColumns(context))
        context.clear(canvas)
        draw("123.4", right: true, context: context)
        let right = try XCTUnwrap(visibleColumns(context))
        XCTAssertLessThanOrEqual(abs(CGFloat(left.lowerBound) - cell.minX), 3)
        XCTAssertLessThanOrEqual(abs(CGFloat(right.upperBound) - cell.maxX), 3)
        XCTAssertLessThan(left.upperBound, right.lowerBound)
    }

    func testLongNamesTruncateAndTinyCellsDrawNothing() async throws {
        let context = try bitmap()
        let smallCell = CGRect(x: 40, y: 4, width: 70, height: 40)
        draw(String(repeating: "codex helper ", count: 20), in: smallCell, context: context)
        let pixels = try XCTUnwrap(visibleColumns(context))
        XCTAssertGreaterThanOrEqual(CGFloat(pixels.lowerBound), smallCell.minX)
        XCTAssertLessThan(CGFloat(pixels.upperBound), smallCell.maxX)

        for width: CGFloat in [0, 1, -1] {
            context.clear(canvas)
            draw("codex", in: CGRect(x: 0, y: 0, width: width, height: 40), context: context)
            XCTAssertNil(try visibleColumns(context))
        }
        draw("", context: context)
        XCTAssertNil(try visibleColumns(context))
    }

    func testFontFallbackProducesVisibleTextAtEveryOverlaySize() async throws {
        let context = try bitmap()
        for size: CGFloat in [11, 13, 16, 19] {
            for text in ["codex", "—", "PROCESS ▴", "GPU % ▾", "1.5 GB", "工具", "🛠", "cafe\u{301}", "مراقب"] {
                context.clear(canvas)
                let font = NSFont.systemFont(ofSize: size, weight: .medium)
                let width = OverlayTextRenderer.width(text, font: font)
                XCTAssertTrue(width.isFinite && width > 0, text)
                draw(text, font: font, context: context)
                XCTAssertNotNil(try visibleColumns(context), text)
            }
        }
    }

    func testDrawingRestoresTheCallersGraphicsAndTextState() async throws {
        let context = try bitmap()
        let position = CGPoint(x: 13, y: 7)
        context.textMatrix = CGAffineTransform(scaleX: 0.75, y: 0.5)
        context.textPosition = position
        let matrix = context.textMatrix
        let transform = context.ctm
        draw("MEMORY ▾", right: true, context: context)
        XCTAssertEqual(context.ctm, transform)
        XCTAssertEqual(context.textMatrix, matrix)
        XCTAssertEqual(context.textPosition, position)
        // The cell clip must not leak into the following cell/background draw.
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 48))
        XCTAssertEqual(try visibleColumns(context)?.lowerBound, 0)
    }

    func testRepeatedRedrawsWithFontFallbackAndChangingMetrics() async throws {
        let context = try bitmap()
        let names = ["WindowServer", "mentat", "codex", "codex helper", "工具 🛠", "cafe\u{301}", "مراقب"]
        for refresh in 0..<4_000 {
            autoreleasepool {
                let size: CGFloat = [11, 13, 16, 19][refresh % 4]
                let colors = [NSColor.white, NSColor(white: 0.06, alpha: 1), NSColor(srgbRed: 0.48, green: 1, blue: 0.81, alpha: 1)]
                let color = colors[refresh % colors.count].withAlphaComponent(refresh % 2 == 0 ? 1 : 0.35)
                let values = names + ["PROCESS ▴", "GPU % ▾", "MEMORY", "—", "\(refresh).1", "\(refresh).5 MB", "12345"]
                for (index, value) in values.enumerated() {
                    context.clear(canvas)
                    let font = index < names.count ? NSFont.systemFont(ofSize: size, weight: .medium)
                        : NSFont.monospacedSystemFont(ofSize: size * 0.76, weight: .semibold)
                    OverlayTextRenderer.draw(value, in: cell, font: font, color: color.cgColor,
                                             shadowColor: NSColor.black.withAlphaComponent(0.85).cgColor,
                                             rightAligned: index >= names.count, context: context)
                }
            }
        }
        XCTAssertNotNil(try visibleColumns(context))
    }
}
