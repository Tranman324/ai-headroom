import AppKit
import XCTest
@testable import AIUsageMonitor

final class UsagePresentationTests: XCTestCase {
    func testUtilizationStatusBoundariesDrivePresentationBands() {
        let expectations: [(Double, UsageStatusBand)] = [
            (0, .normal),
            (69, .normal),
            (70, .warning),
            (89, .warning),
            (90, .critical),
            (100, .critical)
        ]

        for (value, expectedBand) in expectations {
            XCTAssertEqual(UsagePresentation.statusBand(for: value), expectedBand, "Boundary \(value) should map to \(expectedBand)")
        }
    }

    func testNeedleAngleIsBoundedAndMonotonic() {
        XCTAssertEqual(UsagePresentation.needleAngleDegrees(for: -20), -115, accuracy: 0.0001)
        XCTAssertEqual(UsagePresentation.needleAngleDegrees(for: 0), -115, accuracy: 0.0001)
        XCTAssertEqual(UsagePresentation.needleAngleDegrees(for: 100), 115, accuracy: 0.0001)
        XCTAssertEqual(UsagePresentation.needleAngleDegrees(for: 140), 115, accuracy: 0.0001)

        var previous = UsagePresentation.needleAngleDegrees(for: 0)
        for value in stride(from: 1.0, through: 100.0, by: 1.0) {
            let angle = UsagePresentation.needleAngleDegrees(for: value)
            XCTAssertGreaterThanOrEqual(angle, previous, "Needle angle must be monotonic at \(value)")
            previous = angle
        }
    }

    func testBarColorUsesOnlyUtilizationBandAndProviderAccent() {
        let normal = meter(.claudeSession, percent: 69)
        let warning = meter(.claudeSession, percent: 70)
        let critical = meter(.codexWeek, percent: 90)

        XCTAssertTrue(UsagePresentation.barColor(for: normal).isEqual(UsagePalette.claudeAccent))
        XCTAssertTrue(UsagePresentation.barColor(for: warning).isEqual(UsagePalette.warning))
        XCTAssertTrue(UsagePresentation.barColor(for: critical).isEqual(UsagePalette.critical))
    }

    func testStatusItemPresentationReflectsHottestMeterState() {
        let normal = UsagePresentation.statusItem(for: UsageMonitorFixtures.normalSnapshot)
        XCTAssertEqual(normal.band, .normal)
        XCTAssertEqual(normal.percentText, "63%")
        XCTAssertFalse(normal.showsCriticalCapsule)

        let warning = UsagePresentation.statusItem(for: UsageMonitorFixtures.warningSnapshot)
        XCTAssertEqual(warning.band, .warning)
        XCTAssertEqual(warning.percentText, "83%")
        XCTAssertFalse(warning.showsCriticalCapsule)

        let critical = UsagePresentation.statusItem(for: UsageMonitorFixtures.criticalSnapshot)
        XCTAssertEqual(critical.band, .critical)
        XCTAssertEqual(critical.percentText, "91%")
        XCTAssertTrue(critical.showsCriticalCapsule)

        let noData = UsagePresentation.statusItem(for: UsageMonitorFixtures.noDataSnapshot)
        XCTAssertEqual(noData.band, .normal)
        XCTAssertEqual(noData.percentText, "--%")
        XCTAssertNil(noData.utilization)
        XCTAssertFalse(noData.accessibilityLabel.contains("0%"))
    }

    func testExpandedHistorySeriesComeFromStoredSnapshotsAndPreserveResetMarkers() {
        let series = UsagePresentation.historySeries(
            from: UsageMonitorFixtures.expandedHistorySnapshots,
            now: UsageMonitorFixtures.criticalSnapshot.capturedAt
        )

        XCTAssertEqual(series.map(\.id), [
            MeterKind.claudeWeekAll.rawValue,
            MeterKind.claudeWeekFable.rawValue,
            MeterKind.claudeWeekSonnet.rawValue,
            MeterKind.claudeWeekHaiku.rawValue
        ])
        XCTAssertTrue(series.allSatisfy { (30 ... 46).contains($0.points.count) })
        XCTAssertTrue(series.flatMap(\.points).contains { $0.preservesResetDiscontinuity })
        XCTAssertNotEqual(series[0].points.map(\.utilization), series[1].points.map(\.utilization))
        XCTAssertTrue(UsagePresentation.historySeries(from: [], now: UsageMonitorFixtures.criticalSnapshot.capturedAt).isEmpty)
    }

    func testDetailPresentationUsesHistoryForCriticalProjectionAndStats() throws {
        let detail = try XCTUnwrap(UsagePresentation.detailPresentation(
            kind: .claudeWeekFable,
            snapshot: UsageMonitorFixtures.criticalSnapshot,
            historicalSnapshots: UsageMonitorFixtures.preResetExhaustionHistory,
            range: .sevenDays
        ))

        XCTAssertEqual(detail.kind, .claudeWeekFable)
        XCTAssertEqual(detail.title, "Claude Week Fable")
        XCTAssertEqual(detail.range, .sevenDays)
        XCTAssertTrue(detail.showsRangeSelector)
        XCTAssertEqual(detail.bannerTone, .critical)
        XCTAssertEqual(detail.projection?.isCritical, true)
        XCTAssertEqual(detail.stats.map(\.label), ["BURN", "USED", "RESETS"])
        XCTAssertEqual(detail.stats[1].value, "83%")
        XCTAssertGreaterThan(detail.points.count, 30)
        XCTAssertTrue(detail.points.contains { $0.preservesResetDiscontinuity })
    }

    func testSafeProjectionDoesNotUseCriticalTone() throws {
        let detail = try XCTUnwrap(UsagePresentation.detailPresentation(
            kind: .codexWeek,
            snapshot: UsageMonitorFixtures.safeProjectionSnapshot,
            historicalSnapshots: UsageMonitorFixtures.safeProjectionHistory,
            range: .sevenDays
        ))

        XCTAssertEqual(detail.bannerTone, .safe)
        XCTAssertEqual(detail.projection?.isCritical, false)
        XCTAssertFalse(detail.bannerText.lowercased().contains("hit 100%"))
    }

    func testWeeklyRangesChangeChartWindowAndSessionHidesSelector() throws {
        let weeklyRanges = MeterDetailRange.allCases.map { range in
            UsagePresentation.detailPresentation(
                kind: .claudeWeekFable,
                snapshot: UsageMonitorFixtures.criticalSnapshot,
                historicalSnapshots: UsageMonitorFixtures.preResetExhaustionHistory,
                range: range
            )
        }
        let unwrapped = try weeklyRanges.map { try XCTUnwrap($0) }

        XCTAssertEqual(unwrapped.map(\.range), MeterDetailRange.allCases)
        XCTAssertLessThan(unwrapped[0].points.count, unwrapped[2].points.count)
        for detail in unwrapped {
            let firstPoint = try XCTUnwrap(detail.points.first)
            XCTAssertGreaterThanOrEqual(
                firstPoint.capturedAt,
                UsageMonitorFixtures.criticalSnapshot.capturedAt.addingTimeInterval(-detail.range.duration)
            )
        }

        let session = try XCTUnwrap(UsagePresentation.detailPresentation(
            kind: .claudeSession,
            snapshot: UsageMonitorFixtures.criticalSnapshot,
            historicalSnapshots: UsageMonitorFixtures.preResetExhaustionHistory,
            range: .sevenDays
        ))
        XCTAssertEqual(session.range, .twentyFourHours)
        XCTAssertFalse(session.showsRangeSelector)
    }

    private func meter(_ kind: MeterKind, percent: Double) -> UsageMeterSnapshot {
        UsageMeterSnapshot(
            kind: kind,
            utilization: try! UtilizationPercentage(percent),
            resetAt: UsageMonitorFixtures.baseDate
        )
    }
}
