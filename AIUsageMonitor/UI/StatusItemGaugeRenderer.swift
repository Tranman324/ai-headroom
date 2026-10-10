import AppKit

enum StatusItemGaugeRenderer {
    static let glyphSize = NSSize(width: 16, height: 16)
    /// Matches the menu bar clock so the percentage reads at the same weight as system items.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

    static let capsuleHeight: CGFloat = 20
    static let capsuleCornerRadius: CGFloat = 5.5
    static let capsuleHorizontalPadding: CGFloat = 6
    static let capsuleSpacing: CGFloat = 4
    static let capsuleGlyphSide: CGFloat = 15

    /// Monochrome template gauge. The menu bar tints template images like its own icons, which
    /// keeps the glyph legible on the macOS 26 transparent menu bar over any wallpaper.
    static func glyphImage(utilization: Double?) -> NSImage {
        let boundedUtilization = utilization.map { min(100, max(0, $0)) }
        let image = NSImage(size: glyphSize, flipped: false) { rect in
            drawGauge(in: rect, utilization: boundedUtilization, color: .black)
            return true
        }
        image.cacheMode = .never
        image.isTemplate = true
        return image
    }

    /// Critical state: a filled red capsule with a white gauge and percentage, drawn as one image
    /// so the alert stays saturated instead of being blended into the wallpaper.
    static func criticalCapsuleImage(utilization: Double, text: String) -> NSImage {
        let boundedUtilization = min(100, max(0, utilization))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = NSSize(
            width: ceil(capsuleHorizontalPadding * 2 + capsuleGlyphSide + capsuleSpacing + textSize.width),
            height: capsuleHeight
        )
        let image = NSImage(size: size, flipped: false) { rect in
            UsagePalette.critical.setFill()
            NSBezierPath(roundedRect: rect, xRadius: capsuleCornerRadius, yRadius: capsuleCornerRadius).fill()
            let glyphRect = NSRect(
                x: capsuleHorizontalPadding,
                y: (rect.height - capsuleGlyphSide) / 2,
                width: capsuleGlyphSide,
                height: capsuleGlyphSide
            )
            drawGauge(in: glyphRect, utilization: boundedUtilization, color: .white)
            (text as NSString).draw(
                at: NSPoint(x: glyphRect.maxX + capsuleSpacing, y: (rect.height - textSize.height) / 2),
                withAttributes: attributes
            )
            return true
        }
        image.cacheMode = .never
        image.isTemplate = false
        return image
    }

    /// Follows the prototype's 16-unit glyph: an arc open at the bottom with a needle pivoting
    /// from the bottom centre. The needle sweeps from pointing left (0%) to pointing right (100%).
    private static func drawGauge(in rect: NSRect, utilization: Double?, color: NSColor) {
        let unit = min(rect.width, rect.height) / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        color.setStroke()
        color.setFill()

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: point(8, 6.7),
            radius: 5.9 * unit,
            startAngle: 207,
            endAngle: -27,
            clockwise: true
        )
        arc.lineWidth = 1.7 * unit
        arc.lineCapStyle = .round
        arc.stroke()

        let hub = point(8, 4)
        if let utilization {
            let radians = (90 - UsagePresentation.needleAngleDegrees(for: utilization)) * .pi / 180
            let needle = NSBezierPath()
            needle.move(to: hub)
            needle.line(to: NSPoint(
                x: hub.x + cos(radians) * 4.8 * unit,
                y: hub.y + sin(radians) * 4.8 * unit
            ))
            needle.lineWidth = 1.6 * unit
            needle.lineCapStyle = .round
            needle.stroke()
        }

        let hubRadius = 1.4 * unit
        NSBezierPath(ovalIn: NSRect(
            x: hub.x - hubRadius,
            y: hub.y - hubRadius,
            width: hubRadius * 2,
            height: hubRadius * 2
        )).fill()
    }
}
