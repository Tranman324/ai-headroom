import XCTest
@testable import AIUsageMonitor

final class SettingsTests: XCTestCase {
    func testSettingsDefaultsMatchProductRequirements() {
        let defaults = MonitorSettings.defaults

        XCTAssertEqual(defaults.pollingInterval.minutes, 3)
        XCTAssertEqual(defaults.alertThreshold.percentage, 80)
        XCTAssertEqual(defaults.historyRetention.days, 30)
        XCTAssertNil(defaults.alertPauseExpiration)
        XCTAssertFalse(defaults.launchAtLogin)
    }

    func testPollingIntervalBoundsAreOneThroughTenMinutes() throws {
        XCTAssertNoThrow(try PollingInterval(minutes: 1))
        XCTAssertNoThrow(try PollingInterval(minutes: 10))
        XCTAssertThrowsError(try PollingInterval(minutes: 0))
        XCTAssertThrowsError(try PollingInterval(minutes: 11))
    }

    func testAlertThresholdIsDistinctFromFixedStatusBoundaries() throws {
        XCTAssertEqual(MonitorSettings.defaults.alertThreshold.percentage, 80)
        XCTAssertEqual(try UtilizationPercentage(69.9).statusBand, .normal)
        XCTAssertEqual(try UtilizationPercentage(70).statusBand, .warning)
        XCTAssertEqual(try UtilizationPercentage(89.9).statusBand, .warning)
        XCTAssertEqual(try UtilizationPercentage(90).statusBand, .critical)
    }
}
