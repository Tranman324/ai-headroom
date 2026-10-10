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
        // 32.5 hours at 1.63%/h lands at 12:16 AM; estimates round down so they never run late.
        XCTAssertEqual(card.estimate?.text, "Hits 100% Mon ~12:10 AM, before reset")
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
        // The weekly limit reset 90 minutes ago at 95%; since then usage climbed 0 → 6% at 6%/h.
        // Mixing in the old window's high readings would read as falling usage ("No usage").
        let previousReset = now.addingTimeInterval(-90 * 60)
        let nextReset = now.addingTimeInterval(7 * 3600)
        var history = Scenario.history(.claudeWeekAll, current: 95, perHour: 0, span: 1, now: previousReset.addingTimeInterval(-60), reset: previousReset)
        history += Scenario.history(.claudeWeekAll, current: 6, perHour: 6, span: 1, now: now, reset: nextReset)
        let snapshot = Scenario.snapshot(now: now, claude: [(.claudeWeekAll, 6, nextReset)], codex: [])

        let estimate = ProviderCardPresenter.card(provider: .claude, snapshot: snapshot, history: history, connection: nil, alertThreshold: 80, timeZone: newYork).estimate

        XCTAssertEqual(estimate, UsageEstimatePresentation(tone: .safe, text: "Reaches ~48% by reset", basis: "last 1h"))
    }

    func testShortHorizonUsesOnlyTheLastThreeHours() {
        // Flat at 50% for most of the day, then 50 → 80% in the last 3 hours; resets in 4 hours.
        let reset = now.addingTimeInterval(4 * 3600)
        var history = Scenario.history(.claudeWeekAll, current: 50, perHour: 0, span: 17, now: now.addingTimeInterval(-3 * 3600), reset: reset)
        history += Scenario.history(.claudeWeekAll, current: 80, perHour: 10, span: 3, now: now, reset: reset)
        let snapshot = Scenario.snapshot(now: now, claude: [(.claudeWeekAll, 80, reset)], codex: [])

        let estimate = ProviderCardPresenter.card(provider: .claude, snapshot: snapshot, history: Scenario.mergedByPoll(history), connection: nil, alertThreshold: 80, timeZone: newYork).estimate

        XCTAssertEqual(estimate, UsageEstimatePresentation(tone: .hit, text: "Hits 100% ~5:40 PM, before reset", basis: "last 3h"))
    }

    func testLongHorizonUsesTheLastDayAndNotOlderReadings() {
        // A steep climb 48 to 24 hours ago, then flat for a day; resets in 3 days.
        let reset = now.addingTimeInterval(3 * 86_400)
        var history = Scenario.history(.codexWeek, current: 40, perHour: 1.5, span: 24, now: now.addingTimeInterval(-24 * 3600 - 60), reset: reset)
        history += Scenario.history(.codexWeek, current: 40, perHour: 0, span: 24, now: now, reset: reset)
        let snapshot = Scenario.snapshot(now: now, claude: [], codex: [(.codexWeek, 40, reset)])

        let estimate = ProviderCardPresenter.card(provider: .codex, snapshot: snapshot, history: Scenario.mergedByPoll(history), connection: nil, alertThreshold: 80, timeZone: newYork).estimate

        XCTAssertEqual(estimate, UsageEstimatePresentation(tone: .idle, text: "No usage in the last 24 hours", basis: ""))
    }

    func testBasisNamesTheSpanActuallyObservedAndShortSpansDoNotProject() {
        let reset = now.addingTimeInterval(3 * 86_400)
        func estimate(hours: Double) -> UsageEstimatePresentation? {
            let snapshot = Scenario.snapshot(now: now, claude: [], codex: [(.codexWeek, 47, reset)])
            let history = Scenario.history(.codexWeek, current: 47, perHour: 1.5, span: hours, now: now, reset: reset)
            return ProviderCardPresenter.card(provider: .codex, snapshot: snapshot, history: history, connection: nil, alertThreshold: 80, timeZone: newYork).estimate
        }

        // Two hours of readings cannot honestly forecast a limit three days out.
        XCTAssertEqual(estimate(hours: 2)?.tone, .noData)
        XCTAssertEqual(estimate(hours: 7)?.basis, "last 7h")
        XCTAssertEqual(estimate(hours: 24)?.basis, "last 24h")
    }

    func testASingleOnePercentTickIsNotEnoughToForecast() {
        // Twenty minutes after a reset, 0 → 1%.
        let reset = now.addingTimeInterval(23 * 3600)
        let snapshot = Scenario.snapshot(now: now, claude: [(.claudeWeekAll, 1, reset)], codex: [])
        let history = Scenario.history(.claudeWeekAll, current: 1, perHour: 3, span: 1.0 / 3, now: now, reset: reset)

        let estimate = ProviderCardPresenter.card(provider: .claude, snapshot: snapshot, history: history, connection: nil, alertThreshold: 80, timeZone: newYork).estimate

        XCTAssertEqual(estimate?.tone, .noData)
    }

    func testOneDipDoesNotHideARisingTrend() {
        let reset = now.addingTimeInterval(6 * 3600)
        var history = Scenario.history(.claudeWeekAll, current: 40, perHour: 3.5, span: 3, now: now.addingTimeInterval(-60), reset: reset)
        history.append(Scenario.snapshot(now: now.addingTimeInterval(-30), claude: [(.claudeWeekAll, 39, reset)], codex: []))
        let snapshot = Scenario.snapshot(now: now, claude: [(.claudeWeekAll, 39, reset)], codex: [])

        let estimate = ProviderCardPresenter.card(provider: .claude, snapshot: snapshot, history: history, connection: nil, alertThreshold: 80, timeZone: newYork).estimate

        XCTAssertNotEqual(estimate?.tone, .idle, "A one-point drop at the end of a climb is noise, not idleness")
        XCTAssertEqual(estimate?.basis, "last 3h")
    }

    func testOneGlitchReadingDoesNotDecideThePace() {
        // A climb from 30 to 45% over three hours, but the window's first reading glitched to 46%.
        // Comparing only the first and last readings would call this "No usage".
        let reset = now.addingTimeInterval(6 * 3600)
        var history = Scenario.history(.claudeWeekAll, current: 45, perHour: 5, span: 2.75, now: now, reset: reset)
        history.append(Scenario.snapshot(now: now.addingTimeInterval(-3 * 3600 + 60), claude: [(.claudeWeekAll, 46, reset)], codex: []))
        let snapshot = Scenario.snapshot(now: now, claude: [(.claudeWeekAll, 45, reset)], codex: [])

        let estimate = ProviderCardPresenter.card(provider: .claude, snapshot: snapshot, history: history, connection: nil, alertThreshold: 80, timeZone: newYork).estimate

        XCTAssertNotEqual(estimate?.tone, .idle)
        XCTAssertNotEqual(estimate?.tone, .noData)
    }

    func testEstimateTimesRoundDownAndNameTheDateWhenAWeekAway() {
        let at558 = Date(timeIntervalSince1970: 1_791_669_480) // 5:58 PM
        let sixDaysOut = now.addingTimeInterval(6.5 * 86_400)

        XCTAssertEqual(ProviderCardPresenter.approximateTimeText(at558, now: now, timeZone: newYork), "~5:50 PM")
        XCTAssertEqual(ProviderCardPresenter.approximateTimeText(sixDaysOut, now: now, timeZone: newYork), "Oct 17 ~3:40 AM")
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
        XCTAssertEqual(codex.reasonAction?.command(for: .codex), .showProviderConnections, "Sign-in runs from Connections, which shows the code")

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

    func testResetWordingAcrossTheDayBoundariesAndDaylightSaving() {
        func lead(_ seconds: TimeInterval, from start: Date? = nil) -> String {
            ProviderCardPresenter.resetLead(for: Date(timeIntervalSince1970: seconds), now: start ?? now, timeZone: newYork).lead
        }

        XCTAssertEqual(lead(1_791_665_940), "today 4:59 PM")
        XCTAssertEqual(lead(1_791_666_000), "tonight 5:00 PM")
        XCTAssertEqual(lead(1_791_691_200), "tonight 12:00 AM", "A midnight reset is still tonight")
        XCTAssertEqual(lead(1_791_703_800), "tomorrow 3:30 AM")
        XCTAssertEqual(lead(now.addingTimeInterval(5.9 * 86_400).timeIntervalSince1970), "Fri 1:21 PM")
        XCTAssertEqual(lead(now.addingTimeInterval(6.1 * 86_400).timeIntervalSince1970), "Oct 16 6:09 PM")

        // Clocks fall back on Sun Nov 1 2026: Sat Oct 31 3:00 PM EDT → Mon Nov 2 9:00 AM EST is 43 hours.
        let saturday = Date(timeIntervalSince1970: 1_793_473_200)
        let monday = Date(timeIntervalSince1970: 1_793_628_000)
        let crossing = ProviderCardPresenter.resetLead(for: monday, now: saturday, timeZone: newYork)
        XCTAssertEqual(crossing.lead, "Mon 9:00 AM")
        XCTAssertEqual(crossing.countdown, "1d 19h")
    }

    func testAPassedResetIsNotPresentedAsAFutureDay() {
        let passed = ProviderCardPresenter.resetLead(for: now.addingTimeInterval(-60), now: now, timeZone: newYork)

        XCTAssertEqual(passed.lead, "reset passed")
        XCTAssertNil(passed.countdown)
        let staleSession = ProviderCardPresenter.meterRow(
            UsageMeterSnapshot(kind: .claudeSession, utilization: try! UtilizationPercentage(40), resetAt: now.addingTimeInterval(-60)),
            isPrimary: false,
            now: now,
            alertThreshold: 80,
            timeZone: newYork
        )
        XCTAssertNil(staleSession.trailingText)
    }

    func testStaleReasonDatesAnOldReadingAndSignedOutAccountsGetSignIn() {
        let yesterday = now.addingTimeInterval(-86_400 - 42 * 60)
        let snapshot = Scenario.snapshot(
            now: now,
            claude: [(.claudeWeekAll, 60, Scenario.claudeWeekReset)],
            codex: [],
            claudeHealth: .stale(
                checkedAt: now,
                staleSince: yesterday,
                error: SanitizedProviderError(code: .unauthorized, displayMessage: "Claude authorization is required.")
            )
        )

        let card = ProviderCardPresenter.card(provider: .claude, snapshot: snapshot, history: [], connection: nil, alertThreshold: 80, timeZone: newYork)

        XCTAssertEqual(card.reason, "Last reading Fri 3:03 PM · Claude authorization is required.")
        XCTAssertEqual(card.reasonAction, .signIn)
        XCTAssertEqual(ProviderCardPresentation.ReasonAction.signIn.command(for: .claude), .showProviderConnections)
        XCTAssertEqual(ProviderCardPresentation.ReasonAction.connect.command(for: .codex), .showProviderConnections)
        XCTAssertEqual(ProviderCardPresentation.ReasonAction.retry.command(for: .codex), .refresh)
    }

    func testGlowFollowsTheUsersAlertThresholdAndSkipsModelRows() {
        let built = Scenario.today.build(now: now)
        func card(threshold: Double) -> ProviderCardPresentation {
            ProviderCardPresenter.card(provider: .claude, snapshot: built.snapshot, history: built.history, connection: nil, alertThreshold: threshold, timeZone: newYork)
        }

        XCTAssertEqual(card(threshold: 85).primaryMeter?.glows, true)
        XCTAssertEqual(card(threshold: 90).primaryMeter?.glows, false)
        XCTAssertEqual(card(threshold: 30).modelMeters.first?.glows, false, "Per-model rows never glow")
    }

    func testCreditsOnlyAppearForAHealthyOrStaleCodexAccount() {
        let credits = RateLimitResetCredits(availableCount: 2, credits: [Scenario.oct29])
        var claudeWithCredits = Scenario.today.build(now: now).snapshot
        claudeWithCredits.providers = claudeWithCredits.providers.map {
            ProviderUsageSnapshot(provider: $0.provider, meters: $0.meters, health: $0.health, resetCredits: credits)
        }
        let erroredWithCredits = CombinedUsageSnapshot(capturedAt: now, providers: [ProviderUsageSnapshot(
            provider: .codex,
            meters: [],
            health: .errored(checkedAt: now, error: SanitizedProviderError(code: .unauthorized, displayMessage: "Codex sign-in expired")),
            resetCredits: credits
        )])

        XCTAssertNil(ProviderCardPresenter.card(provider: .claude, snapshot: claudeWithCredits, history: [], connection: nil, alertThreshold: 80, timeZone: newYork).credits)
        XCTAssertNil(ProviderCardPresenter.card(provider: .codex, snapshot: erroredWithCredits, history: [], connection: nil, alertThreshold: 80, timeZone: newYork).credits)
        XCTAssertNotNil(card(.codex, scenario: .codexStale).credits)
    }

    func testShowProviderConnectionsOpensConnectionsFromTheList() async throws {
        let store = await UsageMonitorStore(dependencies: AppCompositionRoot.fixture())

        try await store.handle(.showProviderConnections)

        let navigation = await store.navigation
        XCTAssertTrue(navigation.isSettingsPresented)
        XCTAssertTrue(navigation.isProviderConnectionsPresented)
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

    func testExpiringSoonMeansWithinSevenDays() {
        func presentation(daysAhead: Double) -> ResetCreditsPresentation {
            ProviderCardPresenter.creditsPresentation(
                RateLimitResetCredits(availableCount: 1, credits: [RateLimitResetCredit(title: "Full reset", expiresAt: now.addingTimeInterval(daysAhead * 86_400))]),
                now: now,
                timeZone: newYork
            )
        }

        XCTAssertTrue(presentation(daysAhead: 7).isExpiringSoon)
        XCTAssertEqual(presentation(daysAhead: 7).credits.first?.isExpiringSoon, true)
        XCTAssertFalse(presentation(daysAhead: 8).isExpiringSoon)
        XCTAssertEqual(presentation(daysAhead: 8).credits.first?.isExpiringSoon, false)
        XCTAssertEqual(presentation(daysAhead: 1).credits.first?.detail, "Expires tomorrow · Sun Oct 11, 2026")
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

    func testOneUnreadableCreditKeepsTheCountAndTheOtherCredits() async throws {
        let script = """
        while IFS= read -r line; do
          case "$line" in
            *rateLimits*read*) printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":47,"windowDurationMins":10080,"resetsAt":1791951660},"secondary":null},"rateLimitResetCredits":{"availableCount":2,"credits":[{"status":"available","expiresAt":"soon"},{"status":"available","expiresAt":1793293200,"title":"Full reset"}]}}}' ;;
            *account*read*) printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"prolite"}}}' ;;
            *initialize*) printf '%s\\n' '{"id":1,"result":{}}' ;;
          esac
        done
        """
        let client = CodexAppServerClient(executableURL: URL(fileURLWithPath: "/bin/sh"), executableArguments: ["-c", script])

        let usage = try await client.readUsage()
        await client.shutdown()

        XCTAssertEqual(usage.resetCredits, RateLimitResetCredits(availableCount: 2, credits: [Scenario.oct29]))
    }

    func testCombinedHistoryRecordsDropResetCreditsToo() {
        let snapshot = Scenario.today.build(now: now).snapshot

        XCTAssertNotNil(snapshot.provider(.codex)?.resetCredits)
        XCTAssertNil(CombinedSnapshotHistoryRecord(snapshot: snapshot).snapshot.provider(.codex)?.resetCredits)
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

            let bitmap = try render(makeHost(store, showsCreditList: false))

            XCTAssertEqual(bitmap.size.width, UsagePopoverMetrics.contentWidth)
            XCTAssertGreaterThan(bitmap.size.height, 200, "\(scenario) rendered empty")
            XCTAssertEqual(brightPixelsInSideMargins(bitmap), 0, "\(scenario) pushed content into the popover margins")
            if let directory {
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("popover-\(scenario.rawValue)@2x.png"))
            }
        }
    }

    func testOpenCreditListDrawsOverTheRowsAbove() throws {
        let closed = try render(makeHost(store(.today), showsCreditList: false))
        let open = try render(makeHost(store(.today), showsCreditList: true))

        XCTAssertEqual(open.size, closed.size, "The list floats over the popover instead of growing it")
        XCTAssertGreaterThan(differingPixels(closed, open), 4_000, "The open credit list must actually draw")
        XCTAssertEqual(brightPixelsInSideMargins(open), 0)
        if let directory = evidenceDirectory() {
            let data = try XCTUnwrap(open.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("popover-today-credits-open@2x.png"))
        }
    }

    func testCreditsRowTakesItsOwnLineWheneverCodexReportsCredits() throws {
        let withCredits = try render(makeHost(store(.today), showsCreditList: false))
        let noneLeft = try render(makeHost(store(.codexNoCredits), showsCreditList: false))
        var withoutBlock = Scenario.today.build(now: now)
        withoutBlock.snapshot.providers = withoutBlock.snapshot.providers.map {
            ProviderUsageSnapshot(provider: $0.provider, meters: $0.meters, health: $0.health)
        }
        let unreported = try render(makeHost(store(withoutBlock), showsCreditList: false))

        XCTAssertEqual(noneLeft.size.height, withCredits.size.height, "'No resets left' keeps its row")
        XCTAssertGreaterThan(withCredits.size.height - unreported.size.height, 14, "The credits row must be drawn")
    }

    func testStaleAccountDimsItsMetersAndErrorsCollapse() throws {
        let today = try render(makeHost(store(.today), showsCreditList: false))
        let stale = try render(makeHost(store(.claudeStale), showsCreditList: false))
        let error = try render(makeHost(store(.codexError), showsCreditList: false))

        let fullAmber = pixelCount(near: UsagePalette.warning, in: today)
        XCTAssertGreaterThan(fullAmber, 400, "Today's 87% week bar is amber")
        XCTAssertLessThan(pixelCount(near: UsagePalette.warning, in: stale), fullAmber / 2, "Stale meters must be dimmed")
        XCTAssertGreaterThan(today.size.height - error.size.height, 40, "An errored account collapses to its reason")
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_791_661_500)
    }

    private func store(_ scenario: Scenario) -> UsageMonitorStore {
        store(scenario.build(now: now))
    }

    private func store(_ built: (snapshot: CombinedUsageSnapshot, history: [CombinedUsageSnapshot])) -> UsageMonitorStore {
        UsageMonitorStore(
            dependencies: AppCompositionRoot.fixture(snapshot: built.snapshot, historySnapshots: built.history),
            initialSnapshot: built.snapshot,
            historicalSnapshots: built.history
        )
    }

    private func pixelCount(near color: NSColor, in bitmap: NSBitmapImageRep) -> Int {
        let target = color.usingColorSpace(.deviceRGB) ?? color
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.5 else {
                    continue
                }
                let distance = abs(pixel.redComponent - target.redComponent)
                    + abs(pixel.greenComponent - target.greenComponent)
                    + abs(pixel.blueComponent - target.blueComponent)
                if distance < 0.12 {
                    count += 1
                }
            }
        }
        return count
    }

    private func differingPixels(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<min(lhs.pixelsHigh, rhs.pixelsHigh) {
            for x in 0..<min(lhs.pixelsWide, rhs.pixelsWide) {
                guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.1 {
                    count += 1
                }
            }
        }
        return count
    }

    /// Text that overflows the 292 pt content column lands in the 14 pt side margins.
    private func brightPixelsInSideMargins(_ bitmap: NSBitmapImageRep) -> Int {
        let scale = Double(bitmap.pixelsWide) / bitmap.size.width
        let margin = Int(12 * scale)
        let border = Int(3 * scale)
        var count = 0
        for y in Int(20 * scale)..<(bitmap.pixelsHigh - Int(20 * scale)) {
            for x in Array(border..<margin) + Array((bitmap.pixelsWide - margin)..<(bitmap.pixelsWide - border)) {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if pixel.alphaComponent > 0.5, (pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3 > 0.55 {
                    count += 1
                }
            }
        }
        return count
    }

    /// The window is never ordered on screen; SwiftUI only builds its accessibility tree for
    /// views that are in a window.
    private func makeHost(_ store: UsageMonitorStore, showsCreditList: Bool) throws -> NSHostingView<some View> {
        let host = NSHostingView(rootView: UsagePopoverView(store: store, configuration: .production)
            .environment(\.showsResetCreditListForEvidence, showsCreditList))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: UsagePopoverMetrics.contentWidth, height: 900)
        let height = ceil(host.fittingSize.height)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: UsagePopoverMetrics.contentWidth, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: UsagePopoverMetrics.contentWidth, height: height)
        host.layoutSubtreeIfNeeded()
        offscreenWindows.append(window)
        return host
    }

    private var offscreenWindows: [NSWindow] = []

    override func tearDown() {
        offscreenWindows.forEach { $0.close() }
        offscreenWindows.removeAll()
        super.tearDown()
    }

    private func render(_ host: NSView) throws -> NSBitmapImageRep {
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
    case codexStale
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
        var codexPlan = "Pro 5x"

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
        case .codexStale:
            // The widest header: a long plan name, the STALE pill, and a reset a week away.
            claude = todayClaude
            codex = [(.codexWeek, 47, now.addingTimeInterval(6.8 * 86_400))]
            codexPlan = "Enterprise"
            codexHealth = .stale(
                checkedAt: now,
                staleSince: now.addingTimeInterval(-50 * 60),
                error: SanitizedProviderError(code: .unavailable, displayMessage: "Codex CLI was not found. Install or update it, then refresh.")
            )
        case .claudeStale:
            claude = todayClaude
            codex = todayCodex
            claudeHealth = .stale(
                checkedAt: now,
                staleSince: Date(timeIntervalSince1970: 1_791_658_980),
                error: SanitizedProviderError(code: .unavailable, displayMessage: "claude.ai unreachable")
            )
        }

        let snapshot = Self.snapshot(now: now, claude: claude, codex: codex, claudeHealth: claudeHealth, codexHealth: codexHealth, credits: credits, codexPlan: codexPlan)
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
        credits: RateLimitResetCredits? = RateLimitResetCredits(availableCount: 2, credits: [oct29, nov6]),
        codexPlan: String = "Pro 5x"
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
                meters: meters(codex, plan: codexPlan),
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
