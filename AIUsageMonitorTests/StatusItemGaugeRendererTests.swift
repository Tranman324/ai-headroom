import AppKit
import XCTest
@testable import AIUsageMonitor

@MainActor
final class StatusItemGaugeRendererTests: XCTestCase {
    func testGaugeUsesDestinationScaleDynamicRepresentation() {
        let image = StatusItemGaugeRenderer.image(
            utilization: 5,
            color: UsagePalette.statusAccent
        )

        XCTAssertTrue(
            image.representations.contains { $0 is NSCustomImageRep },
            "The status gauge must redraw for the destination scale instead of baking one bitmap"
        )
    }

    func testLowUtilizationTrackHasReadableContrastAcrossLightAndDarkMenuBarsAtOneAndTwoX() throws {
        let image = StatusItemGaugeRenderer.image(
            utilization: 5,
            color: UsagePalette.statusAccent
        )
        let samples = [
            RenderSample(
                name: "light",
                appearance: try XCTUnwrap(NSAppearance(named: .aqua)),
                background: NSColor(deviceWhite: 0.96, alpha: 1)
            ),
            RenderSample(
                name: "dark",
                appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)),
                background: NSColor(deviceRed: 24.0 / 255, green: 42.0 / 255, blue: 69.0 / 255, alpha: 1)
            )
        ]

        for sample in samples {
            for scale in [1, 2] {
                let bitmap = try XCTUnwrap(render(
                    image: image,
                    background: sample.background,
                    appearance: sample.appearance,
                    scale: scale
                ))
                let thirdWidth = bitmap.pixelsWide / 3
                let thirds = [
                    0..<thirdWidth,
                    thirdWidth..<(thirdWidth * 2),
                    (thirdWidth * 2)..<bitmap.pixelsWide
                ]

                XCTAssertEqual(bitmap.pixelsWide, 18 * scale)
                XCTAssertEqual(bitmap.pixelsHigh, 14 * scale)
                for (index, third) in thirds.enumerated() {
                    XCTAssertGreaterThan(
                        contrastingPixelCount(
                            in: bitmap,
                            background: sample.background,
                            xRange: third
                        ),
                        0,
                        "Gauge third \(index) vanished on the \(sample.name) menu bar at \(scale)x"
                    )
                }
            }
        }
    }

    private func render(
        image: NSImage,
        background: NSColor,
        appearance: NSAppearance,
        scale: Int
    ) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width) * scale,
            pixelsHigh: Int(image.size.height) * scale,
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
        bitmap.size = image.size

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            background.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func contrastingPixelCount(
        in bitmap: NSBitmapImageRep,
        background: NSColor,
        xRange: Range<Int>
    ) -> Int {
        let backgroundRGB = background.usingColorSpace(.deviceRGB) ?? background
        return (0..<bitmap.pixelsHigh).reduce(into: 0) { count, y in
            for x in xRange {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let contrast = abs(pixel.redComponent - backgroundRGB.redComponent)
                    + abs(pixel.greenComponent - backgroundRGB.greenComponent)
                    + abs(pixel.blueComponent - backgroundRGB.blueComponent)
                if contrast > 0.18 {
                    count += 1
                }
            }
        }
    }
}

private struct RenderSample {
    var name: String
    var appearance: NSAppearance
    var background: NSColor
}
