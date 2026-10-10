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

        func command(for provider: ProviderID) -> AppIntentCommand {
            switch self {
            case .retry:
                return .refresh
            case .signIn, .connect:
                return .startProviderAuthentication(provider)
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
    /// Recent pace for limits resetting within a day, daily pace for longer horizons.
    static let shortPaceWindow: TimeInterval = 3 * 60 * 60
    static let longPaceWindow: TimeInterval = 24 * 60 * 60
    static let minimumPaceSpan: TimeInterval = 20 * 60
    static let expiringSoonDays = 7

    static func card(
        provider: ProviderID,
        snapshot: CombinedUsageSnapshot,
        history: [CombinedUsageSnapshot],
        connection: ProviderConnectionStatus?,
        alertThreshold: Double,
        timeZone: TimeZone = .current
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
            let since = health.staleSince.map { "Last reading \(timeText($0, timeZone: timeZone))" } ?? "Last known values"
            card.reason = "\(since) · \(health.error?.displayMessage ?? "showing last known values")"
            card.reasonAction = .retry
        case .fresh, .noData:
            break
        }

        let ordered = (provider == .claude ? UsageMeterOrder.claude : UsageMeterOrder.codex)
            .compactMap { kind in meters.first { $0.kind == kind } }
        let modelKinds: Set<MeterKind> = [.claudeWeekFable, .claudeWeekSonnet, .claudeWeekHaiku]
        let mainMeters = ordered.filter { !modelKinds.contains($0.kind) }
        let primary = mainMeters.first { $0.kind.window == .weekly } ?? mainMeters.first
        let row = { (meter: UsageMeterSnapshot) in
            meterRow(meter, isPrimary: meter.kind == primary?.kind, alertThreshold: alertThreshold, timeZone: timeZone)
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
        let trailing = !isPrimary && !isModelRow && meter.kind.window == .rollingFiveHours
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
            glows: value >= alertThreshold,
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

    /// "tonight 8:00 PM" + "4h 15m", "Wed 12:21 AM" + "3d 8h".
    static func resetLead(for resetAt: Date, now: Date, timeZone: TimeZone) -> (lead: String, countdown: String) {
        let calendar = gregorian(timeZone)
        let time = timeText(resetAt, timeZone: timeZone)
        let lead: String
        if calendar.isDate(resetAt, inSameDayAs: now) {
            lead = calendar.component(.hour, from: resetAt) >= 17 ? "tonight \(time)" : "today \(time)"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(resetAt, inSameDayAs: tomorrow) {
            lead = "tomorrow \(time)"
        } else if resetAt.timeIntervalSince(now) < 6 * 24 * 60 * 60 {
            lead = format(resetAt, "EEE h:mm a", timeZone: timeZone)
        } else {
            lead = format(resetAt, "MMM d h:mm a", timeZone: timeZone)
        }
        return (lead, countdown(max(0, resetAt.timeIntervalSince(now))))
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

    /// Projects the meter at its recent pace: the last 3 hours when the limit resets within a day,
    /// otherwise the last 24 hours, using only readings from the current reset window.
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
        let window = untilReset <= longPaceWindow ? shortPaceWindow : longPaceWindow
        let basis = window == shortPaceWindow ? "last 3h" : "last 24h"
        let samples = UsageAnalytics.samples(
            for: meter.kind,
            in: UsagePresentation.mergedSnapshots(history, current: current)
        )
        .filter {
            UsageAnalytics.isSameResetWindow($0.resetAt, meter.resetAt)
                && $0.capturedAt >= now.addingTimeInterval(-window)
                && $0.capturedAt <= now
        }
        guard let first = samples.first,
              let last = samples.last,
              last.capturedAt.timeIntervalSince(first.capturedAt) >= minimumPaceSpan else {
            return UsageEstimatePresentation(tone: .noData, text: "Estimate available after a few readings", basis: "")
        }

        let increase = last.utilization.value - first.utilization.value
        guard increase > 0 else {
            let span = window == shortPaceWindow ? "3 hours" : "24 hours"
            return UsageEstimatePresentation(tone: .idle, text: "No usage in the last \(span)", basis: "")
        }

        let pointsPerSecond = increase / last.capturedAt.timeIntervalSince(first.capturedAt)
        let secondsToLimit = (100 - value) / pointsPerSecond
        let limitAt = now.addingTimeInterval(secondsToLimit)
        if limitAt < meter.resetAt {
            return UsageEstimatePresentation(
                tone: .hit,
                text: "Hits 100% \(approximateTimeText(limitAt, now: now, timeZone: timeZone)), before reset",
                basis: basis
            )
        }

        let atReset = min(99, value + pointsPerSecond * max(0, untilReset))
        return UsageEstimatePresentation(
            tone: atReset >= 90 ? .close : .safe,
            text: "Reaches ~\(Int(atReset.rounded()))% by reset",
            basis: basis
        )
    }

    /// "~6:30 PM" today, "Mon ~12:20 AM" on another day, rounded to ten minutes.
    static func approximateTimeText(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 600).rounded() * 600)
        let time = "~\(timeText(rounded, timeZone: timeZone))"
        if gregorian(timeZone).isDate(rounded, inSameDayAs: now) {
            return time
        }
        return "\(format(rounded, "EEE", timeZone: timeZone)) \(time)"
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
