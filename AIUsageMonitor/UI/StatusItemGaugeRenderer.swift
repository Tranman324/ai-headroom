import AppKit

enum StatusItemGaugeRenderer {
    static let size = NSSize(width: 18, height: 14)

    static func image(utilization: Double, color: NSColor) -> NSImage {
        let boundedUtilization = min(100, max(0, utilization))
        let image = NSImage(size: size, flipped: false) { _ in
            drawGauge(utilization: boundedUtilization, color: color)
            return true
        }
        image.cacheMode = .never
        image.isTemplate = false
        return image
    }

    private static func drawGauge(utilization: Double, color: NSColor) {
        let center = NSPoint(x: 9, y: 3)
        let radius: CGFloat = 7
        let needleAngle = UsagePresentation.needleAngleDegrees(for: utilization)
        let gaugeAngle = 90 - needleAngle

        let track = NSBezierPath()
        track.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: 180,
            clockwise: false
        )
        track.lineWidth = 1.8
        track.lineCapStyle = .round
        NSColor.labelColor.withAlphaComponent(0.58).setStroke()
        track.stroke()

        if utilization > 0 {
            let activeTrack = NSBezierPath()
            activeTrack.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 180,
                endAngle: gaugeAngle,
                clockwise: true
            )
            activeTrack.lineWidth = 1.8
            activeTrack.lineCapStyle = .round
            color.setStroke()
            activeTrack.stroke()
        }

        let radians = gaugeAngle * .pi / 180
        let needleEnd = NSPoint(
            x: center.x + cos(radians) * 5.2,
            y: center.y + sin(radians) * 5.2
        )
        let needleColor = NSColor.labelColor.withAlphaComponent(0.94)
        let needle = NSBezierPath()
        needle.move(to: center)
        needle.line(to: needleEnd)
        needle.lineWidth = 1.4
        needle.lineCapStyle = .round
        needleColor.setStroke()
        needle.stroke()

        let hub = NSBezierPath(ovalIn: NSRect(
            x: center.x - 1.35,
            y: center.y - 1.35,
            width: 2.7,
            height: 2.7
        ))
        needleColor.setFill()
        hub.fill()
    }
}
