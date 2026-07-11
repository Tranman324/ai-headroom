import AppKit
import XCTest

@MainActor
final class AIUsageMonitorUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testCriticalFixtureRendersMetersHistoryAndCriticalPixels() throws {
        let evidence = try runFixture(scenario: "critical", historyExpanded: true)

        assertBaselineBitmap(evidence.bitmap)
        XCTAssertTrue(evidence.metadata.contains("status_band: critical"))
        XCTAssertTrue(evidence.metadata.contains("hottest_percent: 91"))
        XCTAssertTrue(evidence.metadata.contains("history_state: populated"))
        XCTAssertTrue(evidence.metadata.contains("history_series_count: 4"))
        XCTAssertTrue(evidence.metadata.contains("navigation: list history-expanded"))
        XCTAssertTrue(evidence.metadata.contains("meter_order: claudeSession,claudeWeekAll,claudeWeekFable,claudeWeekSonnet,claudeWeekHaiku,codexSession,codexWeek"))
        XCTAssertGreaterThan(evidence.bitmap.luminanceRange(in: .meterRows), 0.35)
        XCTAssertGreaterThan(evidence.bitmap.luminanceRange(in: .populatedHistory), 0.18)
        XCTAssertGreaterThan(evidence.bitmap.pixelCount(near: TestPalette.critical), 100)
        XCTAssertGreaterThan(evidence.bitmap.pixelCount(near: TestPalette.warning), 100)
    }

    func testWarningFixtureRendersWarningAndProviderPixels() throws {
        let evidence = try runFixture(scenario: "warning", historyExpanded: true)

        assertBaselineBitmap(evidence.bitmap)
        XCTAssertTrue(evidence.metadata.contains("status_band: warning"))
        XCTAssertTrue(evidence.metadata.contains("history_state: populated"))
        XCTAssertGreaterThan(evidence.bitmap.pixelCount(near: TestPalette.warning), 100)
        XCTAssertGreaterThan(evidence.bitmap.pixelCount(near: TestPalette.claudeAccent), 100)
        XCTAssertGreaterThan(evidence.bitmap.pixelCount(near: TestPalette.codexAccent), 100)
    }

    func testNormalFixtureRendersBothProviderAccentPixels() throws {
        let evidence = try runFixture(scenario: "normal", historyExpanded: true)

        assertBaselineBitmap(evidence.bitmap)
        XCTAssertTrue(evidence.metadata.contains("status_band: normal"))
        XCTAssertTrue(evidence.metadata.contains("history_state: populated"))
        XCTAssertGreaterThan(evidence.bitmap.pixelCount(near: TestPalette.claudeAccent), 100)
        XCTAssertGreaterThan(evidence.bitmap.pixelCount(near: TestPalette.codexAccent), 100)
    }

    func testStaleFixtureRendersProviderLocalHealthAndNonblankPixels() throws {
        let evidence = try runFixture(scenario: "stale", historyExpanded: false)

        assertBaselineBitmap(evidence.bitmap)
        XCTAssertTrue(evidence.metadata.contains("provider_health: claude=stale,codex=fresh"))
        XCTAssertTrue(evidence.metadata.contains("history_state: populated"))
        XCTAssertGreaterThan(evidence.bitmap.luminanceRange(in: .meterRows), 0.35)
        XCTAssertGreaterThan(evidence.bitmap.pixelCount(near: TestPalette.warning), 100)
    }

    func testErrorFixtureRendersProviderLocalErrorAndNonblankPixels() throws {
        let evidence = try runFixture(scenario: "error", historyExpanded: false)

        assertBaselineBitmap(evidence.bitmap)
        XCTAssertTrue(evidence.metadata.contains("provider_health: claude=errored,codex=fresh"))
        XCTAssertTrue(evidence.metadata.contains("history_state: populated"))
        XCTAssertGreaterThan(evidence.bitmap.luminanceRange(in: .meterRows), 0.35)
        XCTAssertGreaterThan(evidence.bitmap.pixelCount(near: TestPalette.critical), 100)
    }

    func testNoDataFixtureRendersExplicitEmptyHistoryWithoutSeriesPixels() throws {
        let evidence = try runFixture(scenario: "no-data", historyExpanded: true)

        assertBaselineBitmap(evidence.bitmap)
        XCTAssertTrue(evidence.metadata.contains("status_band: normal"))
        XCTAssertTrue(evidence.metadata.contains("hottest_percent: --"))
        XCTAssertTrue(evidence.metadata.contains("meter_order: \n"))
        XCTAssertTrue(evidence.metadata.contains("no_data_providers: claude,codex"))
        XCTAssertTrue(evidence.metadata.contains("history_state: empty"))
        XCTAssertTrue(evidence.metadata.contains("history_series_count: 0"))
        XCTAssertTrue(evidence.metadata.contains("navigation: list history-expanded"))
        XCTAssertFalse(evidence.metadata.contains("hottest_percent: 0"))
        XCTAssertGreaterThan(evidence.bitmap.luminanceRange(in: .emptyHistory), 0.12)
        XCTAssertLessThanOrEqual(evidence.bitmap.pixelCount(near: TestPalette.sonnet, in: .emptyHistory, tolerance: 0.12), 2)
        XCTAssertLessThanOrEqual(evidence.bitmap.pixelCount(near: TestPalette.haiku, in: .emptyHistory, tolerance: 0.12), 2)
    }

    func testEveryMeterRowOpensMatchingDetailAndBackReturnsToList() throws {
        let app = launchInteractiveFixture(scenario: "critical", historyExpanded: false)
        defer { app.terminate() }

        for kind in [
            "claudeSession",
            "claudeWeekAll",
            "claudeWeekFable",
            "claudeWeekSonnet",
            "claudeWeekHaiku",
            "codexSession",
            "codexWeek"
        ] {
            let row = app.buttons["meter-row-\(kind)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Missing row \(kind)")
            row.click()

            XCTAssertTrue(app.otherElements["meter-detail-\(kind)"].waitForExistence(timeout: 5), "Missing detail \(kind)")
            XCTAssertTrue(app.otherElements["usage-popover-root"].exists, "Popover root should stay mounted")

            let back = app.buttons["meter-detail-back-button"]
            XCTAssertTrue(back.waitForExistence(timeout: 5), "Missing back button for \(kind)")
            back.click()
            XCTAssertTrue(app.buttons["meter-row-\(kind)"].waitForExistence(timeout: 5), "Back should restore list for \(kind)")
        }
    }

    func testDetailProjectionFixturesRenderCriticalAndSafeStates() throws {
        let critical = try runFixture(scenario: "pre-reset-exhaustion", historyExpanded: false)
        assertBaselineBitmap(critical.bitmap)
        XCTAssertTrue(critical.metadata.contains("navigation: detail claudeWeekFable range 7d"))
        XCTAssertTrue(critical.metadata.contains("detail_kind: claudeWeekFable"))
        XCTAssertTrue(critical.metadata.contains("projection_state: critical"))
        XCTAssertGreaterThan(critical.detailChartPointCount, 30)
        XCTAssertGreaterThan(critical.bitmap.luminanceRange(in: .detailChart), 0.18)
        let criticalRedPixels = critical.bitmap.pixelCount(near: TestPalette.critical, in: .detailChart, tolerance: 0.22)
        XCTAssertGreaterThan(criticalRedPixels, 2)

        let safe = try runFixture(scenario: "safe-projection", historyExpanded: false)
        assertBaselineBitmap(safe.bitmap)
        XCTAssertTrue(safe.metadata.contains("navigation: detail codexWeek range 7d"))
        XCTAssertTrue(safe.metadata.contains("projection_state: safe"))
        XCTAssertGreaterThan(safe.detailChartPointCount, 30)
        XCTAssertGreaterThan(safe.bitmap.luminanceRange(in: .detailChart), 0.18)
        XCTAssertLessThan(safe.bitmap.pixelCount(near: TestPalette.critical, in: .detailChart, tolerance: 0.22), criticalRedPixels)
    }

    func testRangeSettingsAndNoHistoryFixturesRenderExpectedMetadata() throws {
        let range24 = try runFixture(scenario: "range-24h", historyExpanded: false)
        let range3 = try runFixture(scenario: "range-3d", historyExpanded: false)
        let range7 = try runFixture(scenario: "range-7d", historyExpanded: false)

        XCTAssertTrue(range24.metadata.contains("detail_range: 24h"))
        XCTAssertTrue(range3.metadata.contains("detail_range: 3d"))
        XCTAssertTrue(range7.metadata.contains("detail_range: 7d"))
        XCTAssertLessThan(range24.detailChartPointCount, range7.detailChartPointCount)
        XCTAssertLessThan(range3.detailChartPointCount, range7.detailChartPointCount)

        let settings = try runFixture(scenario: "settings", historyExpanded: false)
        assertBaselineBitmap(settings.bitmap)
        XCTAssertTrue(settings.metadata.contains("navigation: settings"))
        XCTAssertTrue(settings.metadata.contains("settings_polling_minutes: 5"))
        XCTAssertTrue(settings.metadata.contains("settings_alert_threshold: 85"))
        XCTAssertTrue(settings.metadata.contains("settings_history_retention_days: 45"))
        XCTAssertTrue(settings.metadata.contains("settings_launch_at_login: true"))
        XCTAssertGreaterThan(settings.bitmap.luminanceRange(in: .settings), 0.20)

        let noHistory = try runFixture(scenario: "no-history", historyExpanded: true)
        assertBaselineBitmap(noHistory.bitmap)
        XCTAssertTrue(noHistory.metadata.contains("history_state: empty"))
        XCTAssertTrue(noHistory.metadata.contains("history_snapshot_count: 0"))
        XCTAssertTrue(noHistory.metadata.contains("meter_order: claudeSession,claudeWeekAll,claudeWeekFable,claudeWeekSonnet,claudeWeekHaiku,codexSession,codexWeek"))
    }

    private func runFixture(scenario: String, historyExpanded: Bool) throws -> FixtureEvidence {
        let directory = evidenceDirectory(named: scenario)
        let imageURL = directory.appendingPathComponent("popover-\(scenario).png")
        let metadataURL = directory.appendingPathComponent("popover-\(scenario).txt")
        let app = XCUIApplication()
        XCTAssertEqual(app.state, .notRunning, "Each fixture test must begin from a clean application state")

        app.launchArguments = [
            "--fixture-scenario",
            scenario,
            "--ui-smoke-window",
            "--screenshot-directory",
            directory.path,
            "--terminate-after-screenshot"
        ]
        if historyExpanded {
            app.launchArguments.append("--history-expanded")
        }
        app.launch()

        XCTAssertTrue(waitForFile(at: imageURL, timeout: 10), "Expected PNG at \(imageURL.path)")
        XCTAssertTrue(waitForFile(at: metadataURL, timeout: 10), "Expected metadata at \(metadataURL.path)")
        XCTAssertTrue(waitForTermination(of: app, timeout: 10), "Fixture application did not terminate cleanly")

        let metadata = try String(contentsOf: metadataURL, encoding: .utf8)
        let bitmap = try BitmapProbe(url: imageURL)
        let attachment = XCTAttachment(contentsOfFile: imageURL)
        attachment.name = "popover-\(scenario)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return FixtureEvidence(metadata: metadata, bitmap: bitmap)
    }

    private func launchInteractiveFixture(scenario: String, historyExpanded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        XCTAssertEqual(app.state, .notRunning, "Each fixture test must begin from a clean application state")
        app.launchArguments = [
            "--fixture-scenario",
            scenario,
            "--ui-smoke-window"
        ]
        if historyExpanded {
            app.launchArguments.append("--history-expanded")
        }
        app.launch()
        XCTAssertTrue(app.otherElements["usage-popover-root"].waitForExistence(timeout: 5))
        return app
    }

    private func assertBaselineBitmap(
        _ bitmap: BitmapProbe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(bitmap.width, 640, file: file, line: line)
        XCTAssertEqual(bitmap.height, 1040, file: file, line: line)
        XCTAssertGreaterThan(bitmap.quantizedColorCount, 35, file: file, line: line)
        XCTAssertGreaterThan(bitmap.luminanceRange(in: .full), 0.45, file: file, line: line)
        XCTAssertGreaterThan(bitmap.luminanceRange(in: .header), 0.30, file: file, line: line)
    }

    private func evidenceDirectory(named name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-usage-monitor-ui-\(name)-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForFile(at url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func waitForTermination(of app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state == .notRunning {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return app.state == .notRunning
    }
}

private struct FixtureEvidence {
    var metadata: String
    var bitmap: BitmapProbe

    var detailChartPointCount: Int {
        Int(metadataValue("detail_chart_points")) ?? 0
    }

    private func metadataValue(_ key: String) -> String {
        metadata
            .split(separator: "\n")
            .compactMap { line -> String? in
                let prefix = "\(key): "
                guard line.hasPrefix(prefix) else {
                    return nil
                }
                return String(line.dropFirst(prefix.count))
            }
            .first ?? ""
    }
}

private struct BitmapRegion {
    var x: ClosedRange<Double>
    var y: ClosedRange<Double>

    static let full = BitmapRegion(x: 0...1, y: 0...1)
    static let header = BitmapRegion(x: 0.03...0.97, y: 0.01...0.14)
    static let meterRows = BitmapRegion(x: 0.03...0.97, y: 0.12...0.82)
    static let populatedHistory = BitmapRegion(x: 0.03...0.97, y: 0.76...0.99)
    static let emptyHistory = BitmapRegion(x: 0.03...0.97, y: 0.38...0.55)
    static let detailChart = BitmapRegion(x: 0.03...0.97, y: 0.28...0.76)
    static let settings = BitmapRegion(x: 0.03...0.97, y: 0.12...0.92)
}

private struct BitmapProbe {
    private let bitmap: NSBitmapImageRep

    var width: Int { bitmap.pixelsWide }
    var height: Int { bitmap.pixelsHigh }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let bitmap = NSBitmapImageRep(data: data) else {
            throw BitmapProbeError.cannotDecodePNG
        }
        self.bitmap = bitmap
    }

    var quantizedColorCount: Int {
        var colors: Set<Int> = []
        forEachPixel(in: .full, step: 4) { color in
            let red = Int(color.redComponent * 15)
            let green = Int(color.greenComponent * 15)
            let blue = Int(color.blueComponent * 15)
            colors.insert((red << 8) | (green << 4) | blue)
        }
        return colors.count
    }

    func luminanceRange(in region: BitmapRegion) -> CGFloat {
        var minimum: CGFloat = 1
        var maximum: CGFloat = 0
        forEachPixel(in: region, step: 2) { color in
            let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            minimum = min(minimum, luminance)
            maximum = max(maximum, luminance)
        }
        return maximum - minimum
    }

    func pixelCount(
        near expected: NSColor,
        in region: BitmapRegion = .full,
        tolerance: CGFloat = 0.20
    ) -> Int {
        let target = expected.usingColorSpace(.deviceRGB) ?? expected
        var count = 0
        forEachPixel(in: region, step: 2) { color in
            let distance = abs(color.redComponent - target.redComponent)
                + abs(color.greenComponent - target.greenComponent)
                + abs(color.blueComponent - target.blueComponent)
            if distance < tolerance {
                count += 1
            }
        }
        return count
    }

    private func forEachPixel(
        in region: BitmapRegion,
        step: Int,
        body: (NSColor) -> Void
    ) {
        let minX = max(0, min(width - 1, Int(region.x.lowerBound * Double(width))))
        let maxX = max(minX, min(width - 1, Int(region.x.upperBound * Double(width))))
        let minY = max(0, min(height - 1, Int(region.y.lowerBound * Double(height))))
        let maxY = max(minY, min(height - 1, Int(region.y.upperBound * Double(height))))

        for y in stride(from: minY, through: maxY, by: step) {
            for x in stride(from: minX, through: maxX, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                body(color)
            }
        }
    }
}

private enum BitmapProbeError: Error {
    case cannotDecodePNG
}

private enum TestPalette {
    static let claudeAccent = color(0xD97757)
    static let codexAccent = color(0x10A37F)
    static let warning = color(0xE3B341)
    static let critical = color(0xE5484D)
    static let sonnet = color(0xC2A26B)
    static let haiku = color(0x8FA0B8)

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex & 0xFF0000) >> 16) / 255,
            green: CGFloat((hex & 0x00FF00) >> 8) / 255,
            blue: CGFloat(hex & 0x0000FF) / 255,
            alpha: 1
        )
    }
}
