import XCTest
@testable import AIUsageMonitor

final class FixtureIntegrityTests: XCTestCase {
    func testRepresentativeFixtureValuesCoverEveryMeter() {
        let values = Dictionary(uniqueKeysWithValues: UsageMonitorFixtures.allMeterSnapshots.map { ($0.kind, $0.utilization.value) })

        XCTAssertEqual(values.count, MeterKind.allCases.count)
        XCTAssertEqual(values[.claudeSession], 72)
        XCTAssertEqual(values[.claudeWeekAll], 48)
        XCTAssertEqual(values[.claudeWeekFable], 83)
        XCTAssertEqual(values[.claudeWeekSonnet], 41)
        XCTAssertEqual(values[.claudeWeekHaiku], 12)
        XCTAssertEqual(values[.codexSession], 31)
        XCTAssertEqual(values[.codexWeek], 91)
        XCTAssertTrue(UsageMonitorFixtures.allMeterSnapshots.allSatisfy { $0.resetAt > UsageMonitorFixtures.baseDate })
    }

    func testAggregateFixturesExerciseNormalWarningCriticalAndNoDataStates() {
        XCTAssertEqual(UsageMonitorFixtures.normalSnapshot.hottestBand, .normal)
        XCTAssertEqual(UsageMonitorFixtures.warningSnapshot.hottestBand, .warning)
        XCTAssertEqual(UsageMonitorFixtures.criticalSnapshot.hottestBand, .critical)
        XCTAssertEqual(UsageMonitorFixtures.noDataSnapshot.provider(.claude)?.health.kind, .noData)
        XCTAssertEqual(UsageMonitorFixtures.noDataSnapshot.provider(.codex)?.health.kind, .noData)
        XCTAssertTrue(UsageMonitorFixtures.noDataSnapshot.meters.isEmpty)
    }

    func testFixturesContainNoCredentialShapedSecrets() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([
            UsageMonitorFixtures.normalSnapshot,
            UsageMonitorFixtures.warningSnapshot,
            UsageMonitorFixtures.criticalSnapshot,
            UsageMonitorFixtures.staleLastKnownGoodSnapshot,
            UsageMonitorFixtures.providerErrorOtherHealthySnapshot,
            UsageMonitorFixtures.noDataSnapshot
        ])
        let encoded = String(decoding: data, as: UTF8.self).lowercased()

        XCTAssertFalse(encoded.contains("access_token"))
        XCTAssertFalse(encoded.contains("refresh_token"))
        XCTAssertFalse(encoded.contains("api_key"))
        XCTAssertFalse(encoded.contains("bearer "))
        XCTAssertFalse(encoded.contains("sk-"))
    }
}
