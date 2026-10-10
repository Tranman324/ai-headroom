import AppKit
import XCTest
@testable import AIUsageMonitor

@MainActor
final class StatusItemGaugeRendererTests: XCTestCase {
    func testGlyphIsATemplateThatRedrawsAtDestinationScale() {
        let image = StatusItemGaugeRenderer.glyphImage(utilization: 5)

        XCTAssertTrue(image.isTemplate, "The menu bar must tint the glyph exactly like its own icons")
        XCTAssertEqual(image.size, StatusItemGaugeRenderer.glyphSize)
        XCTAssertTrue(
            image.representations.contains { $0 is NSCustomImageRep },
            "The status gauge must redraw for the destination scale instead of baking one bitmap"
        )
    }

    func testGlyphArcStaysVisibleAcrossItsWidthAndReachesTheTopHalfAtOneAndTwoX() throws {
        for scale in [1, 2] {
            let bitmap = try XCTUnwrap(renderOnClear(StatusItemGaugeRenderer.glyphImage(utilization: 5), scale: scale))
            let thirdWidth = bitmap.pixelsWide / 3
            for (index, third) in [0..<thirdWidth, thirdWidth..<(thirdWidth * 2), (thirdWidth * 2)..<bitmap.pixelsWide].enumerated() {
                XCTAssertGreaterThan(
                    inkPixels(in: bitmap, xRange: third, yRange: 0..<bitmap.pixelsHigh).count,
                    0,
                    "Gauge third \(index) vanished at \(scale)x"
                )
            }
            XCTAssertGreaterThan(
                inkPixels(in: bitmap, xRange: 0..<bitmap.pixelsWide, yRange: 0..<(bitmap.pixelsHigh / 2)).count,
                0,
                "The gauge crown must reach the top half of the glyph at \(scale)x"
            )
        }
    }

    func testNeedleSweepsFromLeftToRightAsUtilizationRises() throws {
        let centroids = try [0.0, 25, 50, 75, 100].map { utilization -> Double in
            let bitmap = try XCTUnwrap(renderOnClear(StatusItemGaugeRenderer.glyphImage(utilization: utilization), scale: 2))
            let ink = inkPixels(in: bitmap, xRange: 0..<bitmap.pixelsWide, yRange: 0..<bitmap.pixelsHigh)
            return Double(ink.map(\.x).reduce(0, +)) / Double(max(1, ink.count))
        }

        // The arc is symmetric, so the ink centroid moves only with the needle.
        for (lower, higher) in zip(centroids, centroids.dropFirst()) {
            XCTAssertLessThan(lower, higher, "Needle must move right as utilization rises: \(centroids)")
        }
    }

    func testNoDataGlyphDrawsNoNeedle() throws {
        let noData = try XCTUnwrap(renderOnClear(StatusItemGaugeRenderer.glyphImage(utilization: nil), scale: 2))
        let half = try XCTUnwrap(renderOnClear(StatusItemGaugeRenderer.glyphImage(utilization: 50), scale: 2))

        XCTAssertLessThan(
            inkPixels(in: noData, xRange: 0..<noData.pixelsWide, yRange: 0..<noData.pixelsHigh).count,
            inkPixels(in: half, xRange: 0..<half.pixelsWide, yRange: 0..<half.pixelsHigh).count
        )
    }

    func testCriticalCapsuleIsSaturatedRedWithWhiteGaugeAndText() throws {
        let image = StatusItemGaugeRenderer.criticalCapsuleImage(utilization: 91, text: "91%")
        let bitmap = try XCTUnwrap(renderOnClear(image, scale: 2))

        var red = 0
        var white = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.9 else {
                    continue
                }
                if pixel.redComponent > 0.8, pixel.greenComponent < 0.45, pixel.blueComponent < 0.45 {
                    red += 1
                } else if pixel.redComponent > 0.9, pixel.greenComponent > 0.9, pixel.blueComponent > 0.9 {
                    white += 1
                }
            }
        }

        XCTAssertFalse(image.isTemplate, "The alert colour must not be replaced by menu-bar tinting")
        XCTAssertEqual(image.size.height, StatusItemGaugeRenderer.capsuleHeight)
        XCTAssertGreaterThan(image.size.width, StatusItemGaugeRenderer.capsuleGlyphSide + 20, "The capsule must fit the percentage")
        XCTAssertGreaterThan(Double(red), Double(bitmap.pixelsWide * bitmap.pixelsHigh) * 0.5, "The capsule must be mostly solid red")
        XCTAssertGreaterThan(white, 60, "The gauge and percentage must be drawn in white")
    }

    private func renderOnClear(_ image: NSImage, scale: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(image.size.width)) * scale,
            pixelsHigh: Int(ceil(image.size.height)) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        bitmap.size = NSSize(width: ceil(image.size.width), height: ceil(image.size.height))
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// Bitmap rows run top-down, so y = 0 is the top of the glyph.
    private func inkPixels(in bitmap: NSBitmapImageRep, xRange: Range<Int>, yRange: Range<Int>) -> [(x: Int, y: Int)] {
        var pixels: [(x: Int, y: Int)] = []
        for y in yRange {
            for x in xRange where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                pixels.append((x, y))
            }
        }
        return pixels
    }
}
