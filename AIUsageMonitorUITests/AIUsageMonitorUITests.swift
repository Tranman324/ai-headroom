import XCTest

final class AIUsageMonitorUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testFixturePopoverWritesCriticalSevenMeterScreenshotEvidence() throws {
        let directory = evidenceDirectory(named: "critical")
        let app = launchFixture(scenario: "critical", historyExpanded: true, screenshotDirectory: directory)
        defer { app.terminate() }

        let metadata = try metadata(named: "critical", in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("popover-critical.png").path))
        XCTAssertTrue(metadata.contains("content_points: 320x520"))
        XCTAssertTrue(metadata.contains("status_band: critical"))
        XCTAssertTrue(metadata.contains("hottest_percent: 91"))
        XCTAssertTrue(metadata.contains("navigation: list history-expanded"))
        XCTAssertTrue(metadata.contains("meter_order: claudeSession,claudeWeekAll,claudeWeekFable,claudeWeekSonnet,claudeWeekHaiku,codexSession,codexWeek"))
        XCTAssertGreaterThanOrEqual(pixelSize(from: metadata).width, 320)
        XCTAssertGreaterThanOrEqual(pixelSize(from: metadata).height, 520)
    }

    func testFixturePopoverWritesProviderHealthAndNoDataEvidence() throws {
        let staleDirectory = evidenceDirectory(named: "stale")
        let staleApp = launchFixture(scenario: "stale", historyExpanded: false, screenshotDirectory: staleDirectory)
        let staleMetadata = try metadata(named: "stale", in: staleDirectory)
        XCTAssertTrue(staleMetadata.contains("provider_health: claude=stale,codex=fresh"))
        XCTAssertTrue(staleMetadata.contains("meter_order: claudeSession,claudeWeekAll,claudeWeekFable,claudeWeekSonnet,claudeWeekHaiku,codexSession,codexWeek"))
        staleApp.terminate()

        let errorDirectory = evidenceDirectory(named: "error")
        let errorApp = launchFixture(scenario: "error", historyExpanded: false, screenshotDirectory: errorDirectory)
        let errorMetadata = try metadata(named: "error", in: errorDirectory)
        XCTAssertTrue(errorMetadata.contains("provider_health: claude=errored,codex=fresh"))
        XCTAssertTrue(errorMetadata.contains("meter_order: claudeSession,claudeWeekAll,claudeWeekFable,claudeWeekSonnet,claudeWeekHaiku,codexSession,codexWeek"))
        errorApp.terminate()

        let noDataDirectory = evidenceDirectory(named: "no-data")
        let noDataApp = launchFixture(scenario: "no-data", historyExpanded: false, screenshotDirectory: noDataDirectory)
        let noDataMetadata = try metadata(named: "no-data", in: noDataDirectory)
        XCTAssertTrue(noDataMetadata.contains("status_band: normal"))
        XCTAssertTrue(noDataMetadata.contains("hottest_percent: --"))
        XCTAssertTrue(noDataMetadata.contains("meter_order: "))
        XCTAssertTrue(noDataMetadata.contains("no_data_providers: claude,codex"))
        XCTAssertFalse(noDataMetadata.contains("hottest_percent: 0"))
        noDataApp.terminate()
    }

    private func launchFixture(
        scenario: String,
        historyExpanded: Bool,
        screenshotDirectory: URL
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--fixture-scenario",
            scenario,
            "--ui-smoke-window",
            "--screenshot-directory",
            screenshotDirectory.path,
            "--terminate-after-screenshot"
        ]
        if historyExpanded {
            app.launchArguments.append("--history-expanded")
        }
        app.launch()
        return app
    }

    private func evidenceDirectory(named name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-usage-monitor-ui-\(name)-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func metadata(named scenario: String, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("popover-\(scenario).txt")
        XCTAssertTrue(waitForFile(at: url, timeout: 8), "Expected metadata at \(url.path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func waitForFile(at url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func pixelSize(from metadata: String) -> (width: Int, height: Int) {
        guard let line = metadata.split(separator: "\n").first(where: { $0.hasPrefix("pixels: ") }) else {
            return (0, 0)
        }
        let size = line.replacingOccurrences(of: "pixels: ", with: "").split(separator: "x")
        guard size.count == 2,
              let width = Int(size[0]),
              let height = Int(size[1]) else {
            return (0, 0)
        }
        return (width, height)
    }
}
