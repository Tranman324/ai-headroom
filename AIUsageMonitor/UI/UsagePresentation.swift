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

struct HistorySparklinePoint: Equatable {
    var capturedAt: Date
    var utilization: Double
    var preservesResetDiscontinuity: Bool
}

struct HistorySparklineSeries: Identifiable, Equatable {
    var id: String
    var title: String
    var color: NSColor
    var isDashed: Bool
    var points: [HistorySparklinePoint]
}

enum ProjectionBannerTone: Equatable {
    case critical
    case safe
    case muted
}

struct DetailProjectionPresentation: Equatable {
    var endDate: Date
    var endUtilization: Double
    var isCritical: Bool
}

struct MeterDetailStat: Equatable {
    var label: String
    var value: String
    var color: NSColor
}

struct MeterDetailPresentation: Equatable {
    var kind: MeterKind
    var providerLabel: String
    var title: String
    var percentText: String
    var percentColor: NSColor
    var resetContext: String
    var resetShortText: String
    var burnText: String
    var bannerText: String
    var bannerTone: ProjectionBannerTone
    var chartColor: NSColor
    var range: MeterDetailRange
    var showsRangeSelector: Bool
    var points: [UsageChartPoint]
    var projection: DetailProjectionPresentation?
    var stats: [MeterDetailStat]
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
    static let historyLookback: TimeInterval = UsageAnalytics.weeklyChartWindow

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
                iconColor: NSColor.labelColor,
                textColor: NSColor.labelColor.withAlphaComponent(0.85),
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
                iconColor: NSColor.labelColor,
                textColor: NSColor.labelColor.withAlphaComponent(0.9),
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

    static func historySeries(
        from snapshots: [CombinedUsageSnapshot],
        now: Date
    ) -> [HistorySparklineSeries] {
        let specs: [(MeterKind, String, NSColor, Bool)] = [
            (.claudeWeekAll, "All models", UsagePalette.allModels, true),
            (.claudeWeekFable, "Fable", UsagePalette.claudeAccent, false),
            (.claudeWeekSonnet, "Sonnet", UsagePalette.sonnet, false),
            (.claudeWeekHaiku, "Haiku", UsagePalette.haiku, false)
        ]

        return specs.compactMap { kind, title, color, isDashed in
            let samples = UsageAnalytics.samples(for: kind, in: snapshots)
            let points = UsageAnalytics.downsample(
                samples: samples,
                kind: kind,
                now: now,
                window: UsageAnalytics.weeklyChartWindow
            )
            guard points.count >= 2 else {
                return nil
            }

            return HistorySparklineSeries(
                id: kind.rawValue,
                title: title,
                color: color,
                isDashed: isDashed,
                points: points.map {
                    HistorySparklinePoint(
                        capturedAt: $0.capturedAt,
                        utilization: $0.utilization.value,
                        preservesResetDiscontinuity: $0.preservesResetDiscontinuity
                    )
                }
            )
        }
    }

    static func detailPresentation(
        kind: MeterKind,
        snapshot: CombinedUsageSnapshot,
        historicalSnapshots: [CombinedUsageSnapshot],
        range: MeterDetailRange
    ) -> MeterDetailPresentation? {
        guard let meter = snapshot.meters.first(where: { $0.kind == kind }) else {
            return nil
        }

        let effectiveRange = kind.window == .rollingFiveHours ? .twentyFourHours : range
        let analyticsSnapshots = mergedSnapshots(historicalSnapshots, current: snapshot)
        let samples = UsageAnalytics.samples(for: kind, in: analyticsSnapshots)
        let points = UsageAnalytics.downsample(
            samples: samples,
            kind: kind,
            now: snapshot.capturedAt,
            window: effectiveRange.duration
        )
        let latestSample = MeterHistorySample(snapshot: meter, capturedAt: snapshot.capturedAt)
        let burnRate = UsageAnalytics.burnRate(for: samples)
        let projection = UsageAnalytics.projection(from: latestSample, burnRate: burnRate)
        let projectionPresentation = projectionPresentation(
            for: meter,
            capturedAt: snapshot.capturedAt,
            burnRate: burnRate,
            projection: projection
        )
        let burnText = burnRateText(burnRate)
        let percentColor = barColor(for: meter)
        let banner = projectionBannerText(projection: projection, burnRate: burnRate)

        return MeterDetailPresentation(
            kind: kind,
            providerLabel: providerLabel(for: kind),
            title: meter.display.title,
            percentText: "\(Int(round(meter.utilization.value)))%",
            percentColor: percentColor,
            resetContext: detailResetText(for: meter, capturedAt: snapshot.capturedAt),
            resetShortText: resetShortText(for: meter, capturedAt: snapshot.capturedAt),
            burnText: burnText,
            bannerText: banner.text,
            bannerTone: banner.tone,
            chartColor: chartColor(for: kind),
            range: effectiveRange,
            showsRangeSelector: kind.window == .weekly,
            points: points,
            projection: projectionPresentation,
            stats: [
                MeterDetailStat(label: "BURN", value: burnText, color: UsagePalette.primaryText),
                MeterDetailStat(label: "USED", value: "\(Int(round(meter.utilization.value)))%", color: percentColor),
                MeterDetailStat(label: "RESETS", value: resetShortText(for: meter, capturedAt: snapshot.capturedAt), color: UsagePalette.primaryText)
            ]
        )
    }

    static func chartColor(for kind: MeterKind) -> NSColor {
        switch kind {
        case .claudeSession:
            return UsagePalette.claudeAccent
        case .claudeWeekAll:
            return UsagePalette.allModels
        case .claudeWeekFable:
            return UsagePalette.claudeAccent
        case .claudeWeekSonnet:
            return UsagePalette.sonnet
        case .claudeWeekHaiku:
            return UsagePalette.haiku
        case .codexSession, .codexWeek:
            return UsagePalette.codexAccent
        }
    }

    static func mergedSnapshots(
        _ historicalSnapshots: [CombinedUsageSnapshot],
        current snapshot: CombinedUsageSnapshot
    ) -> [CombinedUsageSnapshot] {
        var seenDates = Set<Date>()
        return (historicalSnapshots + [snapshot])
            .sorted { $0.capturedAt < $1.capturedAt }
            .filter { seenDates.insert($0.capturedAt).inserted }
    }

    private static func providerLabel(for kind: MeterKind) -> String {
        switch kind.provider {
        case .claude:
            return "CLAUDE MAX"
        case .codex:
            return "OPENAI CODEX"
        }
    }

    private static func detailResetText(for meter: UsageMeterSnapshot, capturedAt: Date) -> String {
        let remaining = max(0, meter.resetAt.timeIntervalSince(capturedAt))
        if remaining >= 24 * 60 * 60 {
            return "Resets \(absoluteResetText(meter.resetAt))"
        }
        return "Resets \(relativeResetText(remaining))"
    }

    private static func resetShortText(for meter: UsageMeterSnapshot, capturedAt: Date) -> String {
        let remaining = max(0, meter.resetAt.timeIntervalSince(capturedAt))
        if remaining >= 24 * 60 * 60 {
            return absoluteResetText(meter.resetAt)
        }
        return relativeResetText(remaining).replacingOccurrences(of: "in ", with: "")
    }

    private static func relativeResetText(_ remaining: TimeInterval) -> String {
        let hour: TimeInterval = 60 * 60
        if remaining >= hour {
            return "in \(Int(ceil(remaining / hour)))h"
        }
        return "in \(max(1, Int(ceil(remaining / 60))))m"
    }

    private static func absoluteResetText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE h a"
        return formatter.string(from: date)
    }

    private static func burnRateText(_ burnRate: BurnRateResult) -> String {
        switch burnRate.status {
        case .available where burnRate.pointsPerHour > 0:
            return String(format: "%.1f%%/h", burnRate.pointsPerHour)
        case .available:
            return "Flat"
        case .insufficientSamples:
            return "Need data"
        case .nonIncreasingTimestamps:
            return "Need data"
        case .resetDiscontinuity:
            return "Reset crossed"
        case .fallingUtilization:
            return "Falling"
        }
    }

    private static func projectionBannerText(
        projection: UsageProjection?,
        burnRate: BurnRateResult
    ) -> (text: String, tone: ProjectionBannerTone) {
        guard let projection else {
            return ("Projection needs more recent usage history", .muted)
        }

        if projection.occursBeforeReset {
            return ("On pace to hit 100% ≈ \(projectionTimeText(projection.expectedExhaustionAt))", .critical)
        }

        return ("Current pace stays below limit before reset", .safe)
    }

    private static func projectionPresentation(
        for meter: UsageMeterSnapshot,
        capturedAt: Date,
        burnRate: BurnRateResult,
        projection: UsageProjection?
    ) -> DetailProjectionPresentation? {
        guard let projection, burnRate.hasPositiveRate else {
            return nil
        }

        if projection.occursBeforeReset {
            return DetailProjectionPresentation(
                endDate: projection.expectedExhaustionAt,
                endUtilization: 100,
                isCritical: true
            )
        }

        let hoursUntilReset = max(0, meter.resetAt.timeIntervalSince(capturedAt) / 3600)
        let resetUtilization = min(100, meter.utilization.value + burnRate.pointsPerHour * hoursUntilReset)
        return DetailProjectionPresentation(
            endDate: meter.resetAt,
            endUtilization: resetUtilization,
            isCritical: false
        )
    }

    private static func projectionTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
