import XCTest
@testable import AIUsageMonitor

final class MeterKindTests: XCTestCase {
    func testMeterTaxonomyIsClosedAndStable() {
        XCTAssertEqual(MeterKind.allCases, [
            .claudeSession,
            .claudeWeekAll,
            .claudeWeekFable,
            .claudeWeekSonnet,
            .claudeWeekHaiku,
            .codexSession,
            .codexWeek
        ])
        XCTAssertEqual(MeterKind.allCases.count, 7)
    }

    func testMeterMetadataMapsToExpectedProvidersAndWindows() {
        let claudeMeters = MeterKind.allCases.filter { $0.provider == .claude }
        let codexMeters = MeterKind.allCases.filter { $0.provider == .codex }

        XCTAssertEqual(claudeMeters.count, 5)
        XCTAssertEqual(codexMeters.count, 2)
        XCTAssertEqual(MeterKind.claudeSession.window, .rollingFiveHours)
        XCTAssertEqual(MeterKind.codexSession.window, .rollingFiveHours)
        XCTAssertEqual(MeterKind.claudeWeekFable.window, .weekly)
        XCTAssertEqual(MeterKind.codexWeek.window, .weekly)
    }
}
