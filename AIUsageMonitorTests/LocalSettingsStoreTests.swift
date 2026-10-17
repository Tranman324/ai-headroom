import Darwin
import XCTest
@testable import AIUsageMonitor

final class LocalSettingsStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
        try super.tearDownWithError()
    }

    func testMissingSettingsRecoverToDefaultsAndCreateRestrictiveRoot() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)

        let settings = try await store.loadSettings()

        XCTAssertEqual(settings, .defaults)
        try assertMode(0o700, at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.settingsFileURL.path))
    }

    func testSaveAndLoadRoundTripUsesRestrictiveSettingsFile() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        let settings = MonitorSettings(
            pollingInterval: try PollingInterval(minutes: 10),
            alertThreshold: try AlertThreshold(percentage: 95),
            historyRetention: try HistoryRetention(days: 365),
            alertPauseExpiration: UsageMonitorFixtures.baseDate.addingTimeInterval(600),
            launchAtLogin: true
        )

        try await store.saveSettings(settings)
        let loaded = try await store.loadSettings()

        XCTAssertEqual(loaded, settings)
        try assertMode(0o700, at: root)
        try assertMode(0o600, at: store.settingsFileURL)
    }

    func testSettingsBoundsAndInvalidValues() throws {
        XCTAssertNoThrow(try PollingInterval(minutes: 1))
        XCTAssertNoThrow(try PollingInterval(minutes: 10))
        XCTAssertThrowsError(try PollingInterval(minutes: 0))
        XCTAssertThrowsError(try PollingInterval(minutes: 11))

        for threshold in stride(from: 50, through: 95, by: 5) {
            XCTAssertNoThrow(try AlertThreshold(percentage: Double(threshold)))
        }
        XCTAssertThrowsError(try AlertThreshold(percentage: 45))
        XCTAssertThrowsError(try AlertThreshold(percentage: 52))
        XCTAssertThrowsError(try AlertThreshold(percentage: 100))

        XCTAssertNoThrow(try HistoryRetention(days: 1))
        XCTAssertNoThrow(try HistoryRetention(days: 365))
        XCTAssertThrowsError(try HistoryRetention(days: 0))
        XCTAssertThrowsError(try HistoryRetention(days: 366))
    }

    func testUnknownAdditiveFieldsAreIgnored() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = """
        {
          "pollingInterval": { "minutes": 1, "future": "ignored" },
          "alertThreshold": { "percentage": 50, "future": "ignored" },
          "historyRetention": { "days": 1, "future": "ignored" },
          "alertPauseExpiration": null,
          "launchAtLogin": true,
          "future": { "ignored": true }
        }
        """
        try json.write(to: store.settingsFileURL, atomically: false, encoding: .utf8)

        let settings = try await store.loadSettings()

        XCTAssertEqual(settings.pollingInterval.minutes, 1)
        XCTAssertEqual(settings.alertThreshold.percentage, 50)
        XCTAssertEqual(settings.historyRetention.days, 1)
        XCTAssertTrue(settings.launchAtLogin)
    }

    func testInvalidOrCorruptedSettingsRecoverToDefaultsWithoutOverwritingEvidence() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalidJSON = """
        {
          "pollingInterval": { "minutes": 99 },
          "alertThreshold": { "percentage": 80 },
          "historyRetention": { "days": 30 },
          "alertPauseExpiration": null,
          "launchAtLogin": false
        }
        """
        try invalidJSON.write(to: store.settingsFileURL, atomically: false, encoding: .utf8)

        let invalidRecovered = try await store.loadSettings()
        let invalidEvidence = try String(contentsOf: store.settingsFileURL, encoding: .utf8)

        XCTAssertEqual(invalidRecovered, .defaults)
        XCTAssertEqual(invalidEvidence, invalidJSON)

        try "not-json".write(to: store.settingsFileURL, atomically: false, encoding: .utf8)
        let corruptedRecovered = try await store.loadSettings()
        let corruptedEvidence = try String(contentsOf: store.settingsFileURL, encoding: .utf8)

        XCTAssertEqual(corruptedRecovered, .defaults)
        XCTAssertEqual(corruptedEvidence, "not-json")
    }

    func testInterruptedReplacementRemnantsAreRemovedDuringRecovery() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remnant = root.appendingPathComponent(".settings.json.interrupted.tmp")
        try "stale".write(to: remnant, atomically: false, encoding: .utf8)
        // A remnant from an interrupted write is older than any replacement still in progress.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-LocalPersistence.abandonedTemporaryFileAge - 60)],
            ofItemAtPath: remnant.path
        )

        _ = try await store.loadSettings()

        XCTAssertFalse(FileManager.default.fileExists(atPath: remnant.path))
        try assertMode(0o700, at: root)
    }

    func testAReplacementStillInProgressIsNotDeletedByAnotherWritersRecovery() async throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // For example the status-line bridge or a diagnostics run writing at the same moment.
        let inFlight = root.appendingPathComponent(".claude-usage.json.\(UUID().uuidString).tmp")
        try "partial".write(to: inFlight, atomically: false, encoding: .utf8)

        _ = try await makeStore(root: root).loadSettings()

        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.path))
    }

    func testAtomicReplacementRepairsBroadenedSettingsFilePermissions() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)

        try await store.saveSettings(.defaults)
        XCTAssertEqual(chmod(store.settingsFileURL.path, 0o644), 0)
        XCTAssertThrowsError(try requireMode(0o600, at: store.settingsFileURL))

        let updated = MonitorSettings(alertThreshold: try AlertThreshold(percentage: 85), launchAtLogin: true)
        try await store.saveSettings(updated)

        let loaded = try await store.loadSettings()
        XCTAssertEqual(loaded, updated)
        try assertMode(0o600, at: store.settingsFileURL)
        let remnants = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix(".settings.json") && $0.hasSuffix(".tmp")
        }
        XCTAssertTrue(remnants.isEmpty)
    }

    private func makeStore(root: URL) -> LocalSettingsStore {
        LocalSettingsStore(rootProvider: FixedStorageRootProvider(storageRoot: root))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsageMonitorSettingsTests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }

    private func assertMode(_ expectedMode: mode_t, at url: URL) throws {
        XCTAssertEqual(try LocalPersistence.permissions(of: url), expectedMode, url.path)
    }

    private func requireMode(_ expectedMode: mode_t, at url: URL) throws {
        let actualMode = try LocalPersistence.permissions(of: url)
        guard actualMode == expectedMode else {
            throw ModeMismatchError(expected: expectedMode, actual: actualMode)
        }
    }
}

private struct ModeMismatchError: Error {
    var expected: mode_t
    var actual: mode_t
}
