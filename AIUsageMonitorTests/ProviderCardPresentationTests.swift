import AppKit
import SwiftUI
import XCTest
@testable import AIUsageMonitor

/// Covers the "Popover — live, switch account states" design: reset in the header, pace estimate
/// under the Week bar, Codex reset credits, and the stale / error / not-connected states.
final class ProviderCardPresentationTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    /// Sat Oct 10 2026, 3:45 PM in New York, the moment the design's real data was taken.
    private let now = Date(timeIntervalSince1970: 1_791_661_500)
    private let claudeWeekReset = Date(timeIntervalSince1970: 1_791_676_800) // tonight 8:00 PM
    private let claudeSessionReset = Date(timeIntervalSince1970: 1_791_678_000) // 8:20 PM
    private let codexWeekReset = Date(timeIntervalSince1970: 1_791_951_660) // Wed 12:21 AM

    // MARK: - Reset wording

    func testResetLeadUsesPlainWordsAndACountdown() {
        let cases: [(TimeInterval, String, String)] = [
            (1_791_676_800, "tonight 8:00 PM", "4h 15m"),
            (1_791_664_200, "today 4:30 PM", "45m"),
            (1_791_723_600, "tomorrow 9:00 AM", "17h 15m"),
            (1_791_951_660, "Wed 12:21 AM", "3d 8h"),
            (1_792_501_200, "Oct 20 9:00 AM", "9d 17h")
        ]
        for (reset, lead, countdown) in cases {
            let result = ProviderCardPresenter.resetLead(for: Date(timeIntervalSince1970: reset), now: now, timeZone: newYork)
            XCTAssertEqual(result.lead, lead)
            XCTAssertEqual(result.countdown, countdown)
        }
    }

    // MARK: - Pace estimate

    func testEstimateWarnsWhenTheLimitArrivesBeforeTheReset() {
        let card = card(.claude, scenario: .today)

        XCTAssertEqual(card.estimate?.tone, .hit)
        XCTAssertEqual(card.estimate?.text, "Hits 100% ~6:20 PM, before reset")
        XCTAssertEqual(card.estimate?.basis, "last 3h")
    }

    func testEstimateForAWeekAwayResetUsesDailyPaceAndNamesTheDay() {
        let card = card(.codex, scenario: .today)

        XCTAssertEqual(card.estimate?.tone, .hit)
        XCTAssertEqual(card.estimate?.text, "Hits 100% Mon ~12:20 AM, before reset")
        XCTAssertEqual(card.estimate?.basis, "last 24h")
    }

    func testEstimateCloseSafeIdleAndNoDataStates() {
        XCTAssertEqual(card(.claude, scenario: .warning).estimate?.tone, .close)
        XCTAssertEqual(card(.claude, scenario: .warning).estimate?.text, "Reaches ~94% by reset")
        XCTAssertEqual(card(.claude, scenario: .safe).estimate?.tone, .safe)
        XCTAssertEqual(card(.claude, scenario: .safe).estimate?.text, "Reaches ~43% by reset")
        XCTAssertEqual(card(.claude, scenario: .idle).estimate, UsageEstimatePresentation(tone: .idle, text: "No usage in the last 3 hours", basis: ""))
        XCTAssertEqual(card(.codex, scenario: .idle).estimate, UsageEstimatePresentation(tone: .noData, text: "Estimate available after a few readings", basis: ""))
    }

    func testEstimateIgnoresReadingsFromThePreviousWindow() {
        // Readings before the last reset belong to another window and must not feed the pace.
        let previousReset = now.addingTimeInterval(-3600)
        var history = Scenario.history(.claudeWeekAll, current: 10, perHour: 0, span: 0.5, now: now, reset: claudeWeekReset)
        history += Scenario.history(.claudeWeekAll, current: 99, perHour: 30, span: 2, now: now.addingTimeInterval(-3700), reset: previousReset)
        let snapshot = Scenario.snapshot(now: now, claude: [(.claudeWeekAll, 10, claudeWeekReset)], codex: [])

        let estimate = ProviderCardPresenter.card(
            provider: .claude,
            snapshot: snapshot,
            history: history,
            connection: nil,
            alertThreshold: 80,
            timeZone: newYork
        ).estimate

        XCTAssertEqual(estimate?.tone, .idle)
    }

    func testAMeterAtTheLimitSaysSoUntilReset() {
        let snapshot = Scenario.snapshot(now: now, claude: [(.claudeWeekAll, 100, claudeWeekReset)], codex: [])

        let estimate = ProviderCardPresenter.card(provider: .claude, snapshot: snapshot, history: [], connection: nil, alertThreshold: 80, timeZone: newYork).estimate

        XCTAssertEqual(estimate, UsageEstimatePresentation(tone: .hit, text: "At 100% until reset", basis: ""))
    }

    // MARK: - Card layout

    func testHealthyCardLeadsWithTheWeeklyResetAndKeepsSessionTimeOnItsRow() {
        let claude = card(.claude, scenario: .today)

        XCTAssertEqual(claude.state, .normal)
        XCTAssertEqual(claude.title, "CLAUDE")
        XCTAssertEqual(claude.planBadge, "MAX")
        XCTAssertEqual(claude.resetLead, "tonight 8:00 PM")
        XCTAssertEqual(claude.resetCountdown, "4h 15m")
        XCTAssertEqual(claude.leadingMeters.map(\.label), ["Session"])
        XCTAssertEqual(claude.leadingMeters.first?.trailingText, "8:20 PM")
        XCTAssertEqual(claude.primaryMeter?.label, "Week · All models")
        XCTAssertNil(claude.primaryMeter?.trailingText, "The weekly reset lives in the header")
        XCTAssertEqual(claude.modelMeters.map(\.label), ["Fable"])
        XCTAssertTrue(claude.modelMeters.allSatisfy(\.isModelRow))
        XCTAssertNil(claude.credits, "Claude has no reset credits")

        let codex = card(.codex, scenario: .today)
        XCTAssertEqual(codex.planBadge, "PRO 5X")
        XCTAssertEqual(codex.resetLead, "Wed 12:21 AM")
        XCTAssertEqual(codex.resetCountdown, "3d 8h")
        XCTAssertEqual(codex.primaryMeter?.label, "Week")
        XCTAssertTrue(codex.leadingMeters.isEmpty)
    }

    func testMeterColoursAndGlowFollowTheBands() throws {
        let claude = card(.claude, scenario: .today)
        let week = try XCTUnwrap(claude.primaryMeter)
        let session = try XCTUnwrap(claude.leadingMeters.first)

        XCTAssertEqual(week.percentText, "87%")
        XCTAssertEqual(week.fillColor, UsagePalette.warning)
        XCTAssertEqual(week.percentColor, UsagePalette.warning)
        XCTAssertTrue(week.glows, "87% is above the 80% alert threshold")
        XCTAssertEqual(session.fillColor, UsagePalette.claudeAccent)
        XCTAssertEqual(session.percentColor, UsagePalette.primaryText)
        XCTAssertFalse(session.glows)
        XCTAssertEqual(card(.claude, scenario: .critical).primaryMeter?.fillColor, UsagePalette.critical)
    }

    func testStaleCardDimsMetersPausesTheEstimateAndKeepsTheReset() {
        let claude = card(.claude, scenario: .claudeStale)

        XCTAssertEqual(claude.state, .stale)
        XCTAssertEqual(claude.meterOpacity, 0.55)
        XCTAssertEqual(claude.reason, "Last reading 3:03 PM · claude.ai unreachable")
        XCTAssertEqual(claude.reasonAction, .retry)
        XCTAssertEqual(claude.estimate, UsageEstimatePresentation(tone: .paused, text: "Estimate paused", basis: "stale"))
        XCTAssertEqual(claude.resetLead, "tonight 8:00 PM")
    }

    func testErrorCardCollapsesToItsReasonAndFix() {
        let codex = card(.codex, scenario: .codexError)

        XCTAssertEqual(codex.state, .error)
        XCTAssertFalse(codex.showsMeters)
        XCTAssertEqual(codex.reason, "Codex sign-in expired")
        XCTAssertEqual(codex.reasonAction, .signIn)
        XCTAssertEqual(codex.reasonAction?.command(for: .codex), .startProviderAuthentication(.codex))

        let unavailable = ProviderCardPresenter.card(
            provider: .codex,
            snapshot: Scenario.snapshot(now: now, claude: [], codex: [], codexHealth: .errored(
                checkedAt: now,
                error: SanitizedProviderError(code: .unavailable, displayMessage: "Codex CLI was not found. Install or update it, then refresh.")
            )),
            history: [],
            connection: nil,
            alertThreshold: 80,
            timeZone: newYork
        )
        XCTAssertEqual(unavailable.reasonAction, .retry)
        XCTAssertEqual(unavailable.reasonAction?.command(for: .codex), .refresh)
    }

    func testDisconnectedAndEmptyAccountsAreOneQuietRow() {
        let snapshot = Scenario.snapshot(now: now, claude: [], codex: [])
        let disconnected = ProviderCardPresenter.card(
            provider: .codex,
            snapshot: snapshot,
            history: [],
            connection: ProviderConnectionStatus(provider: .codex, state: .disconnected, planName: nil, usageSyncEnabled: nil, detail: nil),
            alertThreshold: 80,
            timeZone: newYork
        )
        let unknown = ProviderCardPresenter.card(provider: .codex, snapshot: snapshot, history: [], connection: nil, alertThreshold: 80, timeZone: newYork)

        XCTAssertEqual(disconnected.state, .notConnected)
        XCTAssertEqual(disconnected.reason, "Not connected")
        XCTAssertEqual(disconnected.reasonAction, .connect)
        XCTAssertNil(disconnected.resetLead)
        XCTAssertEqual(unknown.reason, "No usage data yet")
        XCTAssertEqual(unknown.reasonAction, .retry)
    }

    // MARK: - Reset credits

    func testCreditsShowCountNextExpiryAndPerCreditDetail() throws {
        let credits = try XCTUnwrap(card(.codex, scenario: .today).credits)

        XCTAssertEqual(credits.countText, "2 resets")
        XCTAssertEqual(credits.expiryText, "expires Oct 29")
        XCTAssertFalse(credits.isExpiringSoon)
        XCTAssertEqual(credits.credits.map(\.title), ["Full reset", "Full reset"])
        XCTAssertEqual(credits.credits.map(\.dateText), ["Oct 29", "Nov 6"])
        XCTAssertEqual(credits.credits.first?.detail, "Expires in 19 days · Thu Oct 29, 2026")
    }

    func testCreditExpiringWithinAWeekIsFlaggedAndZeroCreditsSaySo() throws {
        let soon = try XCTUnwrap(card(.codex, scenario: .warning).credits)
        XCTAssertEqual(soon.countText, "1 reset")
        XCTAssertEqual(soon.expiryText, "expires Oct 14")
        XCTAssertTrue(soon.isExpiringSoon)
        XCTAssertEqual(soon.credits.first?.detail, "Expires in 4 days · Wed Oct 14, 2026")

        let none = try XCTUnwrap(card(.codex, scenario: .codexNoCredits).credits)
        XCTAssertEqual(none.countText, "No resets left")
        XCTAssertEqual(none.expiryText, "")
        XCTAssertFalse(none.hasCredits)
    }

    func testCreditCountComesFromTheAvailableCountEvenWhenTheListIsShort() {
        let presentation = ProviderCardPresenter.creditsPresentation(
            RateLimitResetCredits(availableCount: 3, credits: [RateLimitResetCredit(title: "Full reset", expiresAt: Date(timeIntervalSince1970: 1_793_293_200))]),
            now: now,
            timeZone: newYork
        )

        XCTAssertEqual(presentation.countText, "3 resets")
        XCTAssertEqual(presentation.credits.count, 1)
    }

    // MARK: - Data plumbing

    func testCodexClientReadsResetCreditsWithoutKeepingIdentifiers() async throws {
        let script = """
        while IFS= read -r line; do
          case "$line" in
            *rateLimits*read*) printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":47,"windowDurationMins":10080,"resetsAt":1791951660},"secondary":null},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"secret-credit-b","resetType":"codexRateLimits","status":"available","grantedAt":1791417609,"expiresAt":1793988000,"title":"Full reset"},{"id":"secret-credit-a","resetType":"codexRateLimits","status":"available","grantedAt":1790710580,"expiresAt":1793293200,"title":"Full reset"},{"id":"secret-credit-c","resetType":"codexRateLimits","status":"redeemed","grantedAt":1790000000,"expiresAt":1791000000,"title":"Full reset"}]}}}' ;;
            *account*read*) printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"prolite"}}}' ;;
            *initialize*) printf '%s\\n' '{"id":1,"result":{}}' ;;
          esac
        done
        """
        let client = CodexAppServerClient(executableURL: URL(fileURLWithPath: "/bin/sh"), executableArguments: ["-c", script])

        let usage = try await client.readUsage()
        await client.shutdown()

        XCTAssertEqual(usage.resetCredits, RateLimitResetCredits(availableCount: 2, credits: [
            RateLimitResetCredit(title: "Full reset", expiresAt: Date(timeIntervalSince1970: 1_793_293_200)),
            RateLimitResetCredit(title: "Full reset", expiresAt: Date(timeIntervalSince1970: 1_793_988_000))
        ]))
        XCTAssertFalse(String(describing: usage).contains("secret-credit"))
    }

    func testMalformedResetCreditsDoNotHideTheLimits() async throws {
        let script = """
        while IFS= read -r line; do
          case "$line" in
            *rateLimits*read*) printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":47,"windowDurationMins":10080,"resetsAt":1791951660},"secondary":null},"rateLimitResetCredits":{"availableCount":"two"}}}' ;;
            *account*read*) printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"prolite"}}}' ;;
            *initialize*) printf '%s\\n' '{"id":1,"result":{}}' ;;
          esac
        done
        """
        let client = CodexAppServerClient(executableURL: URL(fileURLWithPath: "/bin/sh"), executableArguments: ["-c", script])

        let usage = try await client.readUsage()
        await client.shutdown()

        XCTAssertEqual(usage.primaryWindow?.usedPercent, 47)
        XCTAssertNil(usage.resetCredits)
    }

    func testCodexProviderCarriesCreditsAndHistoryRecordsDropThem() async throws {
        let credits = RateLimitResetCredits(availableCount: 1, credits: [RateLimitResetCredit(title: "Full reset", expiresAt: now)])
        let snapshot = try await CodexUsageProvider(
            appServer: CreditsAppServer(usage: CodexAppServerUsage(
                planType: "prolite",
                primaryWindow: CodexAppServerUsageWindow(usedPercent: 47, windowDurationMinutes: 10_080, resetsAtUnixSeconds: codexWeekReset.timeIntervalSince1970),
                secondaryWindow: nil,
                resetCredits: credits
            )),
            clock: FixedClock(now: now)
        ).fetchUsageSnapshot()

        XCTAssertEqual(snapshot.resetCredits, credits)
        XCTAssertNil(
            ProviderSnapshotHistoryRecord(capturedAt: now, snapshot: snapshot).snapshot.resetCredits,
            "Reset credits are live-only and are not written to history"
        )
    }

    // MARK: - Helpers

    private func card(_ provider: ProviderID, scenario: Scenario) -> ProviderCardPresentation {
        let built = scenario.build(now: now)
        return ProviderCardPresenter.card(
            provider: provider,
            snapshot: built.snapshot,
            history: built.history,
            connection: nil,
            alertThreshold: 80,
            timeZone: newYork
        )
    }
}

/// Renders every design state through the real popover view. Assertions always run; PNG evidence
/// is written only in evidence-capture mode (see `StatusItemEvidenceTests`).
@MainActor
final class PopoverDesignEvidenceTests: XCTestCase {
    func testEveryDesignStateRendersThroughTheRealPopover() async throws {
        let now = Date(timeIntervalSince1970: 1_791_661_500)
        let directory = evidenceDirectory()
        for scenario in Scenario.allCases {
            let built = scenario.build(now: now)
            let store = UsageMonitorStore(
                dependencies: AppCompositionRoot.fixture(snapshot: built.snapshot, historySnapshots: built.history),
                initialSnapshot: built.snapshot,
                historicalSnapshots: built.history
            )
            if scenario == .codexNotConnected {
                // The connections screen is what refreshes connection state in the app.
                try await store.handle(.openProviderConnections)
                try await store.handle(.closeSettings)
            }

            let bitmap = try render(store)

            XCTAssertEqual(bitmap.size.width, UsagePopoverMetrics.contentWidth)
            XCTAssertGreaterThan(bitmap.size.height, 200, "\(scenario) rendered empty")
            if let directory {
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("popover-\(scenario.rawValue)@2x.png"))
            }
        }
    }

    private func render(_ store: UsageMonitorStore) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: UsagePopoverView(store: store, configuration: .production))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: UsagePopoverMetrics.contentWidth, height: 900)
        let height = ceil(host.fittingSize.height)
        host.frame = NSRect(x: 0, y: 0, width: UsagePopoverMetrics.contentWidth, height: height)
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(host.bounds.width * 2),
            pixelsHigh: Int(host.bounds.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func evidenceDirectory() -> URL? {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(".apm/.capture-popover-evidence").path) else {
            return nil
        }
        let directory = repoRoot.appendingPathComponent(".apm/evidence/popover-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// The design's scenarios, rebuilt as real snapshots plus enough history to drive the estimate.
enum Scenario: String, CaseIterable {
    case today
    case warning
    case critical
    case safe
    case idle
    case claudeStale
    case codexError
    case codexNotConnected
    case codexNoCredits

    static let claudeWeekReset = Date(timeIntervalSince1970: 1_791_676_800)
    static let claudeSessionReset = Date(timeIntervalSince1970: 1_791_678_000)
    static let codexWeekReset = Date(timeIntervalSince1970: 1_791_951_660)
    static let oct29 = RateLimitResetCredit(title: "Full reset", expiresAt: Date(timeIntervalSince1970: 1_793_293_200))
    static let nov6 = RateLimitResetCredit(title: "Full reset", expiresAt: Date(timeIntervalSince1970: 1_793_988_000))
    static let oct14 = RateLimitResetCredit(title: "Full reset", expiresAt: Date(timeIntervalSince1970: 1_791_982_800))

    func build(now: Date) -> (snapshot: CombinedUsageSnapshot, history: [CombinedUsageSnapshot]) {
        typealias Meter = (MeterKind, Double, Date)
        var claude: [Meter] = []
        var codex: [Meter] = []
        var claudeRate = 5.0
        var codexRate = 1.63
        var codexSpan = 24.0
        var claudeHealth: ProviderHealth = .fresh(checkedAt: now)
        var codexHealth: ProviderHealth = .fresh(checkedAt: now)
        var credits = RateLimitResetCredits(availableCount: 2, credits: [Self.oct29, Self.nov6])

        let todayClaude: [Meter] = [(.claudeSession, 13, Self.claudeSessionReset), (.claudeWeekAll, 87, Self.claudeWeekReset), (.claudeWeekFable, 38, Self.claudeWeekReset)]
        let todayCodex: [Meter] = [(.codexWeek, 47, Self.codexWeekReset)]
        switch self {
        case .today, .codexNoCredits, .codexNotConnected, .codexError:
            claude = todayClaude
            codex = todayCodex
            if self == .codexNoCredits {
                credits = RateLimitResetCredits(availableCount: 0, credits: [])
            }
            if self == .codexNotConnected {
                codex = []
                codexHealth = .noData(checkedAt: now)
            }
            if self == .codexError {
                codex = []
                codexHealth = .errored(checkedAt: now, error: SanitizedProviderError(code: .unauthorized, displayMessage: "Codex sign-in expired"))
            }
        case .warning:
            claude = [(.claudeSession, 41, Self.claudeSessionReset), (.claudeWeekAll, 76, Self.claudeWeekReset), (.claudeWeekFable, 52, Self.claudeWeekReset)]
            codex = [(.codexWeek, 72, Self.codexWeekReset)]
            claudeRate = 4.2
            codexRate = 0.26
            credits = RateLimitResetCredits(availableCount: 1, credits: [Self.oct14])
        case .critical:
            claude = [(.claudeSession, 64, Self.claudeSessionReset), (.claudeWeekAll, 93, Self.claudeWeekReset), (.claudeWeekFable, 71, Self.claudeWeekReset)]
            codex = [(.codexWeek, 91, Self.codexWeekReset)]
            claudeRate = 5.0
            codexRate = 2.4
            codexSpan = 3
        case .safe:
            claude = [(.claudeSession, 5, Self.claudeSessionReset), (.claudeWeekAll, 22, Self.claudeWeekReset), (.claudeWeekFable, 9, Self.claudeWeekReset)]
            codex = [(.codexWeek, 30, Self.codexWeekReset)]
            claudeRate = 5.0
            codexRate = 0.2
        case .idle:
            claude = [(.claudeSession, 0, Self.claudeSessionReset), (.claudeWeekAll, 22, Self.claudeWeekReset), (.claudeWeekFable, 9, Self.claudeWeekReset)]
            codex = [(.codexWeek, 5, Self.codexWeekReset)]
            claudeRate = 0
            codexSpan = 0.1
        case .claudeStale:
            claude = todayClaude
            codex = todayCodex
            claudeHealth = .stale(
                checkedAt: now,
                staleSince: Date(timeIntervalSince1970: 1_791_658_980),
                error: SanitizedProviderError(code: .unavailable, displayMessage: "claude.ai unreachable")
            )
        }

        let snapshot = Self.snapshot(now: now, claude: claude, codex: codex, claudeHealth: claudeHealth, codexHealth: codexHealth, credits: credits)
        var history: [CombinedUsageSnapshot] = []
        for (kind, value, reset) in claude where kind.window == .weekly {
            history += Self.history(kind, current: value, perHour: claudeRate, span: 2.5, now: now, reset: reset)
        }
        for (kind, value, reset) in codex {
            history += Self.history(kind, current: value, perHour: codexRate, span: codexSpan, now: now, reset: reset)
        }
        return (snapshot, Self.mergedByPoll(history))
    }

    /// A real poll records every meter at one timestamp; history snapshots must look the same.
    static func mergedByPoll(_ snapshots: [CombinedUsageSnapshot]) -> [CombinedUsageSnapshot] {
        var byTime: [Date: [ProviderID: [UsageMeterSnapshot]]] = [:]
        for snapshot in snapshots {
            for provider in snapshot.providers {
                byTime[snapshot.capturedAt, default: [:]][provider.provider, default: []] += provider.meters
            }
        }
        return byTime.keys.sorted().map { capturedAt in
            CombinedUsageSnapshot(capturedAt: capturedAt, providers: ProviderID.allCases.compactMap { provider in
                byTime[capturedAt]?[provider].map {
                    ProviderUsageSnapshot(provider: provider, meters: $0, health: .fresh(checkedAt: capturedAt))
                }
            })
        }
    }

    static func snapshot(
        now: Date,
        claude: [(MeterKind, Double, Date)],
        codex: [(MeterKind, Double, Date)],
        claudeHealth: ProviderHealth? = nil,
        codexHealth: ProviderHealth? = nil,
        credits: RateLimitResetCredits? = RateLimitResetCredits(availableCount: 2, credits: [oct29, nov6])
    ) -> CombinedUsageSnapshot {
        func meters(_ list: [(MeterKind, Double, Date)], plan: String) -> [UsageMeterSnapshot] {
            list.map { kind, value, reset in
                var display = MeterDisplayMetadata(kind: kind)
                display.planName = plan
                return UsageMeterSnapshot(kind: kind, utilization: try! UtilizationPercentage(value), resetAt: reset, display: display)
            }
        }
        return CombinedUsageSnapshot(capturedAt: now, providers: [
            ProviderUsageSnapshot(
                provider: .claude,
                meters: meters(claude, plan: "Max"),
                health: claudeHealth ?? (claude.isEmpty ? .noData(checkedAt: now) : .fresh(checkedAt: now))
            ),
            ProviderUsageSnapshot(
                provider: .codex,
                meters: meters(codex, plan: "Pro 5x"),
                health: codexHealth ?? (codex.isEmpty ? .noData(checkedAt: now) : .fresh(checkedAt: now)),
                resetCredits: codex.isEmpty ? nil : credits
            )
        ])
    }

    /// Readings every 15 minutes rising at `perHour` points to reach `current` at `now`.
    static func history(_ kind: MeterKind, current: Double, perHour: Double, span hours: Double, now: Date, reset: Date) -> [CombinedUsageSnapshot] {
        let steps = max(1, Int((hours * 4).rounded()))
        return (1 ... steps).map { step in
            let hoursAgo = Double(step) * hours / Double(steps)
            let capturedAt = now.addingTimeInterval(-hoursAgo * 3600)
            let value = max(0, current - perHour * hoursAgo)
            return CombinedUsageSnapshot(capturedAt: capturedAt, providers: [ProviderUsageSnapshot(
                provider: kind.provider,
                meters: [UsageMeterSnapshot(kind: kind, utilization: try! UtilizationPercentage(value), resetAt: reset)],
                health: .fresh(checkedAt: capturedAt)
            )])
        }
    }
}

private struct CreditsAppServer: CodexAppServerCommunicating {
    let usage: CodexAppServerUsage

    func readAccount() async throws -> CodexAppServerAccount? {
        CodexAppServerAccount(type: "chatgpt", planType: usage.planType)
    }

    func readUsage() async throws -> CodexAppServerUsage {
        usage
    }

    func startChatGPTAuthentication() async throws -> ProviderAuthenticationChallenge {
        throw CodexAppServerFailure.requestFailed
    }
}
