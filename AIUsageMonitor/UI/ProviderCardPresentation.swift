import AppKit
import Foundation

/// How one account section of the popover reads, following the "Popover — live, switch account
/// states" design: the weekly reset in the header, a pace estimate under the Week bar, and reset
/// credits for Codex.
struct ProviderCardPresentation: Equatable {
    enum State: Equatable {
        case normal
        case stale
        case error
        case notConnected
    }

    enum ReasonAction: Equatable {
        case retry
        case signIn
        case connect

        var title: String {
            switch self {
            case .retry:
                return "Retry"
            case .signIn:
                return "Sign in"
            case .connect:
                return "Connect…"
            }
        }

        /// Sign-in runs from Connections, which shows the device code and progress; starting it
        /// from the usage list would open a browser with nowhere to show the code.
        func command(for provider: ProviderID) -> AppIntentCommand {
            switch self {
            case .retry:
                return .refresh
            case .signIn, .connect:
                return .showProviderConnections
            }
        }
    }

    var provider: ProviderID
    var title: String
    var planBadge: String?
    var state: State
    var resetLead: String?
    var resetCountdown: String?
    var reason: String?
    var reasonAction: ReasonAction?
    var leadingMeters: [MeterRowPresentation]
    var primaryMeter: MeterRowPresentation?
    var estimate: UsageEstimatePresentation?
    var modelMeters: [MeterRowPresentation]
    var credits: ResetCreditsPresentation?

    var showsMeters: Bool {
        state == .normal || state == .stale
    }

    var meterOpacity: Double {
        state == .stale ? 0.55 : 1
    }
}

struct MeterRowPresentation: Equatable, Identifiable {
    var id: MeterKind { kind }
    var kind: MeterKind
    var label: String
    /// Short reset time for rolling session windows; the weekly reset lives in the header.
    var trailingText: String?
    var percentText: String
    var fraction: Double
    var percentColor: NSColor
    var fillColor: NSColor
    var glows: Bool
    var isModelRow: Bool
    var accessibilityLabel: String
}

struct UsageEstimatePresentation: Equatable {
    enum Tone: Equatable {
        case hit
        case close
        case safe
        case idle
        case noData
        case paused
    }

    var tone: Tone
    var text: String
    var basis: String

    var dotColor: NSColor {
        switch tone {
        case .hit:
            return UsagePalette.critical
        case .close, .paused:
            return UsagePalette.warning
        case .safe, .idle, .noData:
            return UsagePalette.faintText
        }
    }

    var textColor: NSColor {
        switch tone {
        case .hit:
            return UsagePalette.criticalText
        case .close:
            return UsagePalette.warning
        case .safe, .idle:
            return UsagePalette.allModels
        case .noData, .paused:
            return UsagePalette.mutedText
        }
    }
}

struct ResetCreditsPresentation: Equatable {
    struct Credit: Equatable {
        var title: String
        var dateText: String
        var isExpiringSoon: Bool
        var detail: String
    }

    var countText: String
    var expiryText: String
    var isExpiringSoon: Bool
    var hasCredits: Bool
    var credits: [Credit]
}

enum ProviderCardPresenter {
    /// Limits resetting within a day are paced over the last 3 hours, longer ones over the last
    /// 24 hours, and each needs enough readings that a single 1% tick cannot drive the estimate.
    static let shortHorizon: TimeInterval = 24 * 60 * 60
    static let shortPaceWindow: TimeInterval = 3 * 60 * 60
    static let longPaceWindow: TimeInterval = 24 * 60 * 60
    static let minimumShortPaceSpan: TimeInterval = 45 * 60
    static let minimumLongPaceSpan: TimeInterval = 6 * 60 * 60
    static let expiringSoonDays = 7

    static func card(
        provider: ProviderID,
        snapshot: CombinedUsageSnapshot,
        history: [CombinedUsageSnapshot],
        connection: ProviderConnectionStatus?,
        alertThreshold: Double,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> ProviderCardPresentation {
        let now = snapshot.capturedAt
        let providerSnapshot = snapshot.provider(provider)
        let meters = providerSnapshot?.meters ?? []
        var card = ProviderCardPresentation(
            provider: provider,
            title: provider == .claude ? "CLAUDE" : "OPENAI CODEX",
            planBadge: (meters.first?.display.planName ?? connection?.planName)?.uppercased(),
            state: .normal,
            resetLead: nil,
            resetCountdown: nil,
            reason: nil,
            reasonAction: nil,
            leadingMeters: [],
            primaryMeter: nil,
            estimate: nil,
            modelMeters: [],
            credits: nil
        )

        guard let providerSnapshot, !meters.isEmpty else {
            if let health = providerSnapshot?.health, health.kind == .errored {
                card.state = .error
                card.reason = health.error?.displayMessage ?? "Unable to refresh usage."
                card.reasonAction = health.error?.code == .unauthorized ? .signIn : .retry
            } else if connection?.state == .disconnected {
                card.state = .notConnected
                card.reason = "Not connected"
                card.reasonAction = .connect
            } else if connection?.state == .unavailable {
                card.state = .error
                card.reason = connection?.detail ?? "\(provider.displayName) CLI is unavailable."
                card.reasonAction = .retry
            } else {
                card.state = .notConnected
                card.reason = "No usage data yet"
                card.reasonAction = .retry
            }
            return card
        }

        let health = providerSnapshot.health
        switch health.kind {
        case .errored:
            card.state = .error
            card.reason = health.error?.displayMessage ?? "Unable to refresh usage."
            card.reasonAction = health.error?.code == .unauthorized ? .signIn : .retry
            return card
        case .stale:
            card.state = .stale
            let since = health.staleSince.map { "Last reading \(momentText($0, now: now, timeZone: timeZone))" } ?? "Last known values"
            card.reason = "\(since) · \(health.error?.displayMessage ?? "showing last known values")"
            // A signed-out account keeps its old readings, so Retry alone could never recover it.
            card.reasonAction = health.error?.code == .unauthorized ? .signIn : .retry
        case .fresh, .noData:
            break
        }

        let ordered = (provider == .claude ? UsageMeterOrder.claude : UsageMeterOrder.codex)
            .compactMap { kind in meters.first { $0.kind == kind } }
        let modelKinds: Set<MeterKind> = [.claudeWeekFable, .claudeWeekSonnet, .claudeWeekHaiku]
        let mainMeters = ordered.filter { !modelKinds.contains($0.kind) }
        let primary = mainMeters.first { $0.kind.window == .weekly } ?? mainMeters.first
        let row = { (meter: UsageMeterSnapshot) in
            meterRow(meter, isPrimary: meter.kind == primary?.kind, now: now, alertThreshold: alertThreshold, timeZone: timeZone)
        }

        card.leadingMeters = mainMeters.filter { $0.kind != primary?.kind }.map(row)
        card.primaryMeter = primary.map(row)
        card.modelMeters = ordered.filter { modelKinds.contains($0.kind) }.map(row)
        if let primary {
            let reset = resetLead(for: primary.resetAt, now: now, timeZone: timeZone)
            card.resetLead = reset.lead
            card.resetCountdown = reset.countdown
            card.estimate = health.kind == .stale
                ? UsageEstimatePresentation(tone: .paused, text: "Estimate paused", basis: "stale")
                : estimate(for: primary, current: snapshot, history: history, timeZone: timeZone)
        }
        if provider == .codex, let credits = providerSnapshot.resetCredits {
            card.credits = creditsPresentation(credits, now: now, timeZone: timeZone)
        }
        return card
    }

    // MARK: - Meter rows

    static func meterRow(
        _ meter: UsageMeterSnapshot,
        isPrimary: Bool,
        now: Date,
        alertThreshold: Double,
        timeZone: TimeZone
    ) -> MeterRowPresentation {
        let value = meter.utilization.value
        let band = meter.utilization.statusBand
        let fill: NSColor
        let percentColor: NSColor
        switch band {
        case .normal:
            fill = UsagePalette.accent(for: meter.provider)
            percentColor = UsagePalette.primaryText
        case .warning:
            fill = UsagePalette.warning
            percentColor = UsagePalette.warning
        case .critical:
            fill = UsagePalette.critical
            percentColor = UsagePalette.critical
        }
        let isModelRow = [.claudeWeekFable, .claudeWeekSonnet, .claudeWeekHaiku].contains(meter.kind)
        let trailing = !isPrimary && !isModelRow && meter.kind.window == .rollingFiveHours && meter.resetAt > now
            ? timeText(meter.resetAt, timeZone: timeZone)
            : nil
        let percentText = "\(Int(value.rounded()))%"
        return MeterRowPresentation(
            kind: meter.kind,
            label: label(for: meter.kind),
            trailingText: trailing,
            percentText: percentText,
            fraction: min(1, max(0, value / 100)),
            percentColor: percentColor,
            fillColor: fill,
            // Per-model rows stay quiet, as in the design; the account's main meters carry the alert.
            glows: !isModelRow && value >= alertThreshold,
            isModelRow: isModelRow,
            accessibilityLabel: "\(label(for: meter.kind)), \(percentText)"
                + (trailing.map { ", resets \($0)" } ?? "")
        )
    }

    static func label(for kind: MeterKind) -> String {
        switch kind {
        case .claudeSession, .codexSession:
            return "Session"
        case .claudeWeekAll:
            return "Week · All models"
        case .codexWeek:
            return "Week"
        case .claudeWeekFable:
            return "Fable"
        case .claudeWeekSonnet:
            return "Sonnet"
        case .claudeWeekHaiku:
            return "Haiku"
        }
    }

    // MARK: - Reset wording

    /// "tonight 8:00 PM" + "4h 15m", "Wed 12:21 AM" + "3d 8h". A reset already passed (only
    /// possible for stale readings) says so instead of naming a weekday that reads as next week.
    static func resetLead(for resetAt: Date, now: Date, timeZone: TimeZone) -> (lead: String, countdown: String?) {
        guard resetAt > now else {
            return ("reset passed", nil)
        }
        return (dayAndTimeText(resetAt, now: now, timeZone: timeZone), countdown(resetAt.timeIntervalSince(now)))
    }

    /// "today 4:30 PM", "tonight 8:00 PM" (including just after midnight), "tomorrow 9:00 AM",
    /// "Wed 12:21 AM" within six days, otherwise "Oct 20 9:00 AM".
    static func dayAndTimeText(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let calendar = gregorian(timeZone)
        let time = timeText(date, timeZone: timeZone)
        let hour = calendar.component(.hour, from: date)
        // The small hours belong to tonight only while that night is still ahead.
        let isComingSmallHours = hour < 3 && date.timeIntervalSince(now) <= 12 * 60 * 60
        if calendar.isDate(date, inSameDayAs: now) {
            return hour >= 17 || isComingSmallHours ? "tonight \(time)" : "today \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return isComingSmallHours ? "tonight \(time)" : "tomorrow \(time)"
        }
        if date.timeIntervalSince(now) < 6 * 24 * 60 * 60 {
            return format(date, "EEE h:mm a", timeZone: timeZone)
        }
        return format(date, "MMM d h:mm a", timeZone: timeZone)
    }

    /// A past moment: "3:03 PM" today, otherwise with its weekday or date.
    static func momentText(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        if gregorian(timeZone).isDate(date, inSameDayAs: now) {
            return timeText(date, timeZone: timeZone)
        }
        if now.timeIntervalSince(date) < 6 * 24 * 60 * 60 {
            return format(date, "EEE h:mm a", timeZone: timeZone)
        }
        return format(date, "MMM d h:mm a", timeZone: timeZone)
    }

    static func countdown(_ remaining: TimeInterval) -> String {
        let minutes = Int(remaining / 60)
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes % 60)m"
        }
        return "\(max(1, minutes))m"
    }

    // MARK: - Pace estimate

    /// Projects the meter at its pace, from readings in the current reset window only. Limits
    /// resetting within a day use the faster of the last-3-hours average and the last 30 minutes,
    /// so a burst after a quiet stretch still warns; longer horizons use the plain last-24-hours
    /// average, which does not drift with the time of day. The basis names the span the pace came
    /// from, and too little data says so rather than extrapolating.
    static func estimate(
        for meter: UsageMeterSnapshot,
        current: CombinedUsageSnapshot,
        history: [CombinedUsageSnapshot],
        timeZone: TimeZone
    ) -> UsageEstimatePresentation {
        let now = current.capturedAt
        let value = meter.utilization.value
        if value >= 100 {
            return UsageEstimatePresentation(tone: .hit, text: "At 100% until reset", basis: "")
        }
        let untilReset = meter.resetAt.timeIntervalSince(now)
        let isShortHorizon = untilReset <= shortHorizon
        let notEnoughData = UsageEstimatePresentation(
            tone: .noData,
            text: isShortHorizon ? "Estimate available after a few readings" : "Estimate available after a few hours of readings",
            basis: ""
        )
        guard untilReset > 0 else {
            return notEnoughData
        }

        let samples = UsageAnalytics.samples(
            for: meter.kind,
            in: UsagePresentation.mergedSnapshots(history, current: current)
        )
        .filter {
            UsageAnalytics.isSameResetWindow($0.resetAt, meter.resetAt)
                && $0.capturedAt >= now.addingTimeInterval(-(isShortHorizon ? shortPaceWindow : longPaceWindow))
                && $0.capturedAt <= now
        }
        switch pace(samples: samples, current: value, now: now, isShortHorizon: isShortHorizon) {
        case .notEnoughData:
            return notEnoughData
        case let .idle(span):
            return UsageEstimatePresentation(tone: .idle, text: "No usage in the last \(durationText(span, style: .long))", basis: "")
        case let .rising(pointsPerSecond, span):
            let basis = "last \(durationText(span, style: .short))"
            let limitAt = now.addingTimeInterval((100 - value) / pointsPerSecond)
            if limitAt < meter.resetAt {
                return UsageEstimatePresentation(
                    tone: .hit,
                    text: "Hits 100% \(approximateTimeText(limitAt, now: now, timeZone: timeZone)), before reset",
                    basis: basis
                )
            }
            let atReset = min(99, value + pointsPerSecond * untilReset)
            return UsageEstimatePresentation(
                tone: atReset >= 90 ? .close : .safe,
                text: "Reaches ~\(Int(atReset.rounded()))% by reset",
                basis: basis
            )
        }
    }

    enum Pace: Equatable {
        case notEnoughData
        case idle(span: TimeInterval)
        case rising(pointsPerSecond: Double, span: TimeInterval)
    }

    static let recentPaceWindow: TimeInterval = 30 * 60
    static let minimumRecentPaceSpan: TimeInterval = 15 * 60

    /// Net change from a robust starting point (the median of the window's first three readings,
    /// so one glitch cannot decide it) to the current reading.
    static func pace(samples: [MeterHistorySample], current: Double, now: Date, isShortHorizon: Bool) -> Pace {
        guard let first = samples.first,
              now.timeIntervalSince(first.capturedAt) >= (isShortHorizon ? minimumShortPaceSpan : minimumLongPaceSpan) else {
            return .notEnoughData
        }
        let opening = samples.prefix(3).sorted { $0.utilization.value < $1.utilization.value }
        let start = opening[opening.count / 2]
        let span = now.timeIntervalSince(start.capturedAt)
        let rise = current - start.utilization.value
        guard span > 0, rise >= 1 else {
            return .idle(span: now.timeIntervalSince(first.capturedAt))
        }

        var best = Pace.rising(pointsPerSecond: rise / span, span: span)
        if isShortHorizon,
           let recentStart = samples.first(where: { $0.capturedAt >= now.addingTimeInterval(-recentPaceWindow) }),
           now.timeIntervalSince(recentStart.capturedAt) >= minimumRecentPaceSpan {
            let recentSpan = now.timeIntervalSince(recentStart.capturedAt)
            let recentRate = (current - recentStart.utilization.value) / recentSpan
            if case let .rising(rate, _) = best, recentRate > rate {
                best = .rising(pointsPerSecond: recentRate, span: recentSpan)
            }
        }
        return best
    }

    enum DurationStyle {
        case short
        case long
    }

    /// "3h" / "3 hours", "45m" / "45 minutes", rounded to the hour from one hour up.
    static func durationText(_ interval: TimeInterval, style: DurationStyle) -> String {
        let minutes = Int((interval / 60).rounded())
        if minutes >= 60 {
            let hours = Int((Double(minutes) / 60).rounded())
            return style == .short ? "\(hours)h" : (hours == 1 ? "1 hour" : "\(hours) hours")
        }
        let rounded = max(5, (minutes / 5) * 5)
        return style == .short ? "\(rounded)m" : "\(rounded) minutes"
    }

    /// "~6:20 PM" today, "Mon ~12:20 AM" within six days, otherwise "Oct 20 ~9:00 AM". Rounded
    /// down to ten minutes so the estimate never lands after the moment it describes; anything
    /// that close is simply "within minutes".
    static func approximateTimeText(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 600).rounded(.down) * 600)
        guard rounded > now else {
            return "within minutes"
        }
        let time = "~\(timeText(rounded, timeZone: timeZone))"
        if gregorian(timeZone).isDate(rounded, inSameDayAs: now) {
            return time
        }
        if rounded.timeIntervalSince(now) < 6 * 24 * 60 * 60 {
            return "\(format(rounded, "EEE", timeZone: timeZone)) \(time)"
        }
        return "\(format(rounded, "MMM d", timeZone: timeZone)) \(time)"
    }

    // MARK: - Reset credits

    static func creditsPresentation(
        _ summary: RateLimitResetCredits,
        now: Date,
        timeZone: TimeZone
    ) -> ResetCreditsPresentation {
        let count = summary.availableCount
        let credits = summary.credits.map { credit -> ResetCreditsPresentation.Credit in
            guard let expiresAt = credit.expiresAt else {
                return ResetCreditsPresentation.Credit(
                    title: credit.title ?? "Reset",
                    dateText: "No expiry",
                    isExpiringSoon: false,
                    detail: "Does not expire"
                )
            }
            let days = daysUntil(expiresAt, now: now, timeZone: timeZone)
            let lead: String
            switch days {
            case ...0:
                lead = "Expires today"
            case 1:
                lead = "Expires tomorrow"
            default:
                lead = "Expires in \(days) days"
            }
            return ResetCreditsPresentation.Credit(
                title: credit.title ?? "Reset",
                dateText: format(expiresAt, "MMM d", timeZone: timeZone),
                isExpiringSoon: days <= expiringSoonDays,
                detail: "\(lead) · \(format(expiresAt, "EEE MMM d, yyyy", timeZone: timeZone))"
            )
        }
        let nextExpiry = summary.credits.compactMap(\.expiresAt).min()
        let nextIsSoon = nextExpiry.map { daysUntil($0, now: now, timeZone: timeZone) <= expiringSoonDays } ?? false
        return ResetCreditsPresentation(
            countText: count == 0 ? "No resets left" : count == 1 ? "1 reset" : "\(count) resets",
            expiryText: count > 0 ? nextExpiry.map { "expires \(format($0, "MMM d", timeZone: timeZone))" } ?? "" : "",
            isExpiringSoon: count > 0 && nextIsSoon,
            hasCredits: count > 0,
            credits: count > 0 ? credits : []
        )
    }

    private static func daysUntil(_ date: Date, now: Date, timeZone: TimeZone) -> Int {
        let calendar = gregorian(timeZone)
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    // MARK: - Formatting

    static func timeText(_ date: Date, timeZone: TimeZone) -> String {
        format(date, "h:mm a", timeZone: timeZone)
    }

    private static func format(_ date: Date, _ pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
