import AppKit
import Foundation

struct StatusItemPresentation {
    var percentText: String
    var accessibilityLabel: String
    var utilization: Double?
    var band: UsageStatusBand
    var iconColor: NSColor
    var textColor: NSColor
    var backgroundColor: NSColor?
    var showsCriticalCapsule: Bool
}

enum UsageMeterOrder {
    static let claude: [MeterKind] = [
        .claudeSession,
        .claudeWeekAll,
        .claudeWeekFable,
        .claudeWeekSonnet,
        .claudeWeekHaiku
    ]

    static let codex: [MeterKind] = [
        .codexSession,
        .codexWeek
    ]
}

enum UsagePresentation {
    static func statusBand(for utilization: Double) -> UsageStatusBand {
        if utilization >= UsageStatusBand.criticalLowerBound {
            return .critical
        }
        if utilization >= UsageStatusBand.warningLowerBound {
            return .warning
        }
        return .normal
    }

    static func needleAngleDegrees(for utilization: Double) -> Double {
        let bounded = min(100, max(0, utilization))
        return -115 + (bounded / 100) * 230
    }

    static func barColor(for meter: UsageMeterSnapshot) -> NSColor {
        switch meter.utilization.statusBand {
        case .normal:
            return UsagePalette.accent(for: meter.provider)
        case .warning:
            return UsagePalette.warning
        case .critical:
            return UsagePalette.critical
        }
    }

    static func statusItem(for snapshot: CombinedUsageSnapshot) -> StatusItemPresentation {
        guard let hottestMeter = snapshot.hottestMeter else {
            return StatusItemPresentation(
                percentText: "--%",
                accessibilityLabel: "AI Usage no data",
                utilization: nil,
                band: .normal,
                iconColor: NSColor.white.withAlphaComponent(0.78),
                textColor: NSColor.white.withAlphaComponent(0.82),
                backgroundColor: nil,
                showsCriticalCapsule: false
            )
        }

        let utilization = hottestMeter.utilization.value
        let band = hottestMeter.utilization.statusBand
        let percentText = "\(Int(round(utilization)))%"

        switch band {
        case .normal:
            return StatusItemPresentation(
                percentText: percentText,
                accessibilityLabel: "AI Usage \(percentText), normal",
                utilization: utilization,
                band: band,
                iconColor: NSColor.white.withAlphaComponent(0.78),
                textColor: NSColor.white.withAlphaComponent(0.88),
                backgroundColor: nil,
                showsCriticalCapsule: false
            )
        case .warning:
            return StatusItemPresentation(
                percentText: percentText,
                accessibilityLabel: "AI Usage \(percentText), warning",
                utilization: utilization,
                band: band,
                iconColor: UsagePalette.warning,
                textColor: UsagePalette.warning,
                backgroundColor: nil,
                showsCriticalCapsule: false
            )
        case .critical:
            return StatusItemPresentation(
                percentText: percentText,
                accessibilityLabel: "AI Usage \(percentText), critical",
                utilization: utilization,
                band: band,
                iconColor: UsagePalette.critical,
                textColor: UsagePalette.critical,
                backgroundColor: UsagePalette.critical.withAlphaComponent(0.18),
                showsCriticalCapsule: true
            )
        }
    }

    static func compactLabel(for kind: MeterKind) -> String {
        switch kind {
        case .claudeSession, .codexSession:
            return "Session"
        case .claudeWeekAll:
            return "Week All Models"
        case .claudeWeekFable:
            return "Fable"
        case .claudeWeekSonnet:
            return "Sonnet"
        case .claudeWeekHaiku:
            return "Haiku"
        case .codexWeek:
            return "Week"
        }
    }

    static func resetLabel(for meter: UsageMeterSnapshot, capturedAt: Date) -> String {
        let remaining = max(0, meter.resetAt.timeIntervalSince(capturedAt))
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60

        if remaining >= day {
            return "resets in \(Int(ceil(remaining / day)))d"
        }
        if remaining >= hour {
            return "resets in \(Int(ceil(remaining / hour)))h"
        }
        let minutes = max(1, Int(ceil(remaining / 60)))
        return "resets in \(minutes)m"
    }
}
