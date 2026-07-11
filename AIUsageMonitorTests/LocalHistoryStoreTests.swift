import Darwin
import XCTest
@testable import AIUsageMonitor

final class LocalHistoryStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
        try super.tearDownWithError()
    }

    func testAppendCreatesRestrictiveRootAndHistoryFile() async throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o777)]
        )
        let store = makeStore(root: root)

        try await store.append(UsageMonitorFixtures.normalSnapshot)

        try assertMode(0o700, at: root)
        try assertMode(0o600, at: store.historyFileURL)
    }

    func testPermissionNegativeControlFailsWhenHistoryFileIsBroadenedThenAppendRepairsIt() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        try await store.append(UsageMonitorFixtures.normalSnapshot)

        XCTAssertEqual(chmod(store.historyFileURL.path, 0o644), 0)
        XCTAssertThrowsError(try requireMode(0o600, at: store.historyFileURL))

        try await store.append(UsageMonitorFixtures.warningSnapshot)

        try assertMode(0o600, at: store.historyFileURL)
    }

    func testAppendAndReadRoundTripSuccessAndSanitizedProviderFailureRecords() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        let timestamp = UsageMonitorFixtures.baseDate.addingTimeInterval(30)
        let error = SanitizedProviderError(
            code: .unauthorized,
            displayMessage: "Bearer fake-bearer-value access_token=fake-access-token sk-1234567890"
        )

        try await store.append(UsageMonitorFixtures.normalSnapshot)
        try await store.appendProviderFailure(provider: .claude, at: timestamp, error: error)

        let records = try await store.records(since: .distantPast)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(try XCTUnwrap(records.first).timestamp, UsageMonitorFixtures.normalSnapshot.capturedAt)

        guard case let .providerFailure(failureRecord) = records.last else {
            return XCTFail("Expected sanitized provider failure record.")
        }
        XCTAssertEqual(failureRecord.provider, .claude)
        XCTAssertEqual(failureRecord.timestamp, timestamp)
        XCTAssertFalse(failureRecord.error.displayMessage.contains("fake-bearer-value"))
        XCTAssertFalse(failureRecord.error.displayMessage.contains("fake-access-token"))
        XCTAssertFalse(failureRecord.error.displayMessage.contains("sk-1234567890"))

        let encodedHistory = try String(contentsOf: store.historyFileURL, encoding: .utf8)
        XCTAssertFalse(encodedHistory.contains("fake-bearer-value"))
        XCTAssertFalse(encodedHistory.contains("fake-access-token"))
        XCTAssertFalse(encodedHistory.contains("sk-1234567890"))
    }

    func testMalformedPartialAndUnsupportedLinesDoNotHideLaterValidRecords() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        let firstProvider = try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude))
        let laterProvider = try XCTUnwrap(UsageMonitorFixtures.warningSnapshot.provider(.codex))

        try await store.appendProviderSnapshot(firstProvider, capturedAt: UsageMonitorFixtures.normalSnapshot.capturedAt)
        try appendRawLine("not-json", to: store.historyFileURL)
        try appendRawLine(#"{"schemaVersion":99,"recordKind":"providerFailure","timestamp":"2024-01-01T00:00:00Z","provider":"claude","error":{"code":"unknown","displayMessage":"ignored"}}"#, to: store.historyFileURL)
        try appendRawLine(#"{"schemaVersion":1,"recordKind":"providerSnapshot""#, to: store.historyFileURL)
        try await store.appendProviderSnapshot(laterProvider, capturedAt: UsageMonitorFixtures.warningSnapshot.capturedAt)

        let records = try await store.records(since: .distantPast)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.timestamp), [
            UsageMonitorFixtures.normalSnapshot.capturedAt,
            UsageMonitorFixtures.warningSnapshot.capturedAt
        ])
    }

    func testLatestUsableReconstructionStaysProviderLocalAcrossFailuresAndMalformedPeerRecords() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        let claude = try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude))
        let codex = try XCTUnwrap(UsageMonitorFixtures.warningSnapshot.provider(.codex))

        try await store.appendProviderSnapshot(claude, capturedAt: UsageMonitorFixtures.normalSnapshot.capturedAt)
        try await store.appendProviderFailure(
            provider: .claude,
            at: UsageMonitorFixtures.baseDate.addingTimeInterval(300),
            error: SanitizedProviderError(code: .unavailable, displayMessage: "Claude unavailable")
        )
        try appendRawLine(
            #"{"schemaVersion":1,"recordKind":"providerSnapshot","capturedAt":"2025-01-01T00:00:00Z","provider":"claude","snapshot":{"provider":"codex","meters":[],"health":{"kind":"fresh","checkedAt":"2025-01-01T00:00:00Z"}}}"#,
            to: store.historyFileURL
        )
        try await store.appendProviderSnapshot(codex, capturedAt: UsageMonitorFixtures.warningSnapshot.capturedAt)

        let latest = try await store.latestUsableProviderSnapshots()

        XCTAssertEqual(latest[.claude]?.meters.count, claude.meters.count)
        XCTAssertEqual(latest[.claude]?.health.kind, .fresh)
        XCTAssertEqual(latest[.codex]?.meters.count, codex.meters.count)
        XCTAssertEqual(latest[.codex]?.health.kind, .fresh)
    }

    func testPrunePreservesCutoffBoundaryAndRestrictivePermissions() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        let cutoff = UsageMonitorFixtures.baseDate
        let oldSnapshot = snapshot(at: cutoff.addingTimeInterval(-1), kind: .claudeSession, percent: 10)
        let boundarySnapshot = snapshot(at: cutoff, kind: .claudeSession, percent: 20)
        let newSnapshot = snapshot(at: cutoff.addingTimeInterval(1), kind: .claudeSession, percent: 30)

        try await store.append(oldSnapshot)
        try await store.append(boundarySnapshot)
        try await store.append(newSnapshot)
        try await store.prune(olderThan: cutoff)

        let snapshots = try await store.snapshots(since: .distantPast)

        XCTAssertEqual(snapshots.map(\.capturedAt), [boundarySnapshot.capturedAt, newSnapshot.capturedAt])
        try assertMode(0o700, at: root)
        try assertMode(0o600, at: store.historyFileURL)
    }

    func testRetentionPruneUsesClockDerivedCutoff() async throws {
        let root = try temporaryRoot()
        let now = UsageMonitorFixtures.baseDate.addingTimeInterval(40 * UsageMonitorFixtures.oneDay)
        let store = makeStore(root: root, clock: FixedClock(now: now))
        let olderThanThirtyDays = snapshot(at: now.addingTimeInterval(-(30 * UsageMonitorFixtures.oneDay) - 1), kind: .codexWeek, percent: 10)
        let exactBoundary = snapshot(at: now.addingTimeInterval(-(30 * UsageMonitorFixtures.oneDay)), kind: .codexWeek, percent: 20)

        try await store.append(olderThanThirtyDays)
        try await store.append(exactBoundary)
        try await store.prune(retaining: .defaultValue)

        let snapshots = try await store.snapshots(since: .distantPast)

        XCTAssertEqual(snapshots.map(\.capturedAt), [exactBoundary.capturedAt])
    }

    func testPruneRecoversMissingEmptyAndMalformedHistoryWithoutCrashing() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)

        try await store.prune(olderThan: UsageMonitorFixtures.baseDate)
        let missingRecords = try await store.records(since: .distantPast)
        XCTAssertEqual(missingRecords, [])
        try assertMode(0o600, at: store.historyFileURL)

        try appendRawLine("malformed", to: store.historyFileURL)
        try await store.prune(olderThan: UsageMonitorFixtures.baseDate)

        let malformedRecords = try await store.records(since: .distantPast)
        XCTAssertEqual(malformedRecords, [])
        try assertMode(0o600, at: store.historyFileURL)
    }

    private func makeStore(root: URL, clock: any ClockProviding = FixedClock(now: UsageMonitorFixtures.baseDate)) -> LocalHistoryStore {
        LocalHistoryStore(rootProvider: FixedStorageRootProvider(storageRoot: root), clock: clock)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsageMonitorHistoryTests-\(UUID().uuidString)", isDirectory: true)
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

    private func appendRawLine(_ line: String, to url: URL) throws {
        let data = Data((line + "\n").utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func snapshot(at capturedAt: Date, kind: MeterKind, percent: Double) -> CombinedUsageSnapshot {
        let meter = UsageMeterSnapshot(
            kind: kind,
            utilization: try! UtilizationPercentage(percent),
            resetAt: capturedAt.addingTimeInterval(UsageMonitorFixtures.oneDay)
        )
        return CombinedUsageSnapshot(
            capturedAt: capturedAt,
            providers: [
                ProviderUsageSnapshot(provider: kind.provider, meters: [meter], health: .fresh(checkedAt: capturedAt))
            ]
        )
    }
}

private struct ModeMismatchError: Error {
    var expected: mode_t
    var actual: mode_t
}
