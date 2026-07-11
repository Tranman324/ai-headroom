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

    private func meter(_ kind: MeterKind, percent: Double) -> UsageMeterSnapshot {
        UsageMeterSnapshot(
            kind: kind,
            utilization: try! UtilizationPercentage(percent),
            resetAt: UsageMonitorFixtures.baseDate
        )
    }
}
