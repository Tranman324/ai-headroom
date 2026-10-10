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
        try appendRawLine(#"{"schemaVersion":1,"recordKind":"providerFailure","timestamp":1e999,"provider":"claude","error":{"code":"unknown","displayMessage":"ignored"}}"#, to: store.historyFileURL)
        try appendRawLine(#"{"schemaVersion":1,"recordKind":"providerFailure","timestamp":"NaN","provider":"claude","error":{"code":"unknown","displayMessage":"ignored"}}"#, to: store.historyFileURL)
        try await store.appendProviderSnapshot(laterProvider, capturedAt: UsageMonitorFixtures.warningSnapshot.capturedAt)

        let records = try await store.records(since: .distantPast)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.timestamp), [
            UsageMonitorFixtures.normalSnapshot.capturedAt,
            UsageMonitorFixtures.warningSnapshot.capturedAt
        ])
    }

    func testInvalidUTF8LineIsolatedAcrossReadsReconstructionAndPruning() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        let firstTimestamp = UsageMonitorFixtures.baseDate
        let laterTimestamp = UsageMonitorFixtures.baseDate.addingTimeInterval(2)
        let claude = try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude))
        let codex = try XCTUnwrap(UsageMonitorFixtures.warningSnapshot.provider(.codex))

        try await store.appendProviderSnapshot(claude, capturedAt: firstTimestamp)
        var malformedLine = Data(#"{"schemaVersion":1,"recordKind":"providerFailure","timestamp":"2025-01-01T00:00:01Z","provider":"claude","error":{"code":"unavailable","displayMessage":""#.utf8)
        malformedLine.append(0xFF)
        malformedLine.append(contentsOf: Data(#""}}"#.utf8))
        malformedLine.append(0x0A)
        try appendRawData(malformedLine, to: store.historyFileURL)
        try await store.appendProviderSnapshot(codex, capturedAt: laterTimestamp)

        let allRecords = try await store.records(since: .distantPast)
        let rangeRecords = try await store.records(since: laterTimestamp)
        let latest = try await store.latestUsableProviderSnapshots()

        XCTAssertEqual(allRecords.map(\.timestamp), [firstTimestamp, laterTimestamp])
        XCTAssertEqual(rangeRecords.map(\.timestamp), [laterTimestamp])
        XCTAssertEqual(latest[.claude], claude)
        XCTAssertEqual(latest[.codex], codex)

        try await store.prune(olderThan: laterTimestamp)

        let retainedRecords = try await store.records(since: .distantPast)
        XCTAssertEqual(retainedRecords.map(\.timestamp), [laterTimestamp])
        XCTAssertFalse(try Data(contentsOf: store.historyFileURL).contains(0xFF))
        try assertMode(0o700, at: root)
        try assertMode(0o600, at: store.historyFileURL)
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

    func testExactTimestampRoundTripsAndRespectsRangeBoundaries() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        let timestamp = Date(timeIntervalSince1970: 1_735_689_600.123456)
        let persistedSnapshot = snapshot(at: timestamp, kind: .claudeSession, percent: 20)

        try await store.append(persistedSnapshot)

        let allRecords = try await store.records(since: .distantPast)
        let includedRecords = try await store.records(since: timestamp)
        let excludedRecords = try await store.records(
            since: Date(timeIntervalSince1970: timestamp.timeIntervalSince1970.nextUp)
        )

        XCTAssertEqual(allRecords.count, 1)
        XCTAssertEqual(try XCTUnwrap(allRecords.first).timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970)
        XCTAssertEqual(includedRecords.map(\.timestamp), [timestamp])
        XCTAssertEqual(excludedRecords, [])

        let encodedData = try Data(contentsOf: store.historyFileURL)
        let encodedLine = try XCTUnwrap(encodedData.split(separator: 0x0A).first)
        let encodedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(encodedLine)) as? [String: Any]
        )
        let encodedTimestamp = try XCTUnwrap(encodedObject["capturedAt"] as? NSNumber)
        XCTAssertEqual(encodedTimestamp.doubleValue, timestamp.timeIntervalSince1970)
    }

    func testPruneRetainsFractionalAndExactCutoffRecords() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        let cutoff = Date(timeIntervalSince1970: 1_735_689_600.123456)
        let oldSnapshot = snapshot(
            at: Date(timeIntervalSince1970: cutoff.timeIntervalSince1970.nextDown),
            kind: .codexWeek,
            percent: 10
        )
        let exactCutoffSnapshot = snapshot(at: cutoff, kind: .codexWeek, percent: 20)
        let fractionalSnapshot = snapshot(
            at: Date(timeIntervalSince1970: cutoff.timeIntervalSince1970.nextUp),
            kind: .codexWeek,
            percent: 30
        )

        try await store.append(oldSnapshot)
        try await store.append(exactCutoffSnapshot)
        try await store.append(fractionalSnapshot)
        try await store.prune(olderThan: cutoff)

        let retainedSnapshots = try await store.snapshots(since: .distantPast)

        XCTAssertEqual(retainedSnapshots.map(\.capturedAt), [exactCutoffSnapshot.capturedAt, fractionalSnapshot.capturedAt])
        try assertMode(0o700, at: root)
        try assertMode(0o600, at: store.historyFileURL)
    }

    func testPriorFractionalISO8601CRLFLineStillDecodes() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        try LocalPersistence.ensureRoot(at: root)
        try LocalPersistence.append(
            Data((#"{"error":{"code":"unavailable","displayMessage":"Prior fractional failure"},"provider":"claude","recordKind":"providerFailure","schemaVersion":1,"timestamp":"2025-01-01T00:00:00.500Z"}"# + "\r\n").utf8),
            to: store.historyFileURL
        )

        let records = try await store.records(since: .distantPast)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(records.first).timestamp,
            UsageMonitorFixtures.baseDate.addingTimeInterval(0.5)
        )
    }

    func testLegacyWholeSecondISO8601LineStillDecodes() async throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root)
        try LocalPersistence.ensureRoot(at: root)
        try LocalPersistence.append(
            Data((#"{"error":{"code":"unavailable","displayMessage":"Legacy failure"},"provider":"claude","recordKind":"providerFailure","schemaVersion":1,"timestamp":"2025-01-01T00:00:00Z"}"# + "\n").utf8),
            to: store.historyFileURL
        )

        let records = try await store.records(since: .distantPast)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try XCTUnwrap(records.first).timestamp, UsageMonitorFixtures.baseDate)
        guard case let .providerFailure(failure) = records.first else {
            return XCTFail("Expected legacy provider failure record.")
        }
        XCTAssertEqual(failure.provider, .claude)
        XCTAssertEqual(failure.error.displayMessage, "Legacy failure")
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

    func testPollerProviderRecordsBecomeHistorySnapshotsTheChartCanDraw() async throws {
        // This is what the app actually writes: one record per provider per poll, never a
        // combined record. History used to come back empty because only combined records were read.
        let store = makeStore(root: try temporaryRoot())
        let start = UsageMonitorFixtures.baseDate
        for poll in 0 ..< 6 {
            let capturedAt = start.addingTimeInterval(Double(poll) * 3 * 60)
            try await store.appendProviderSnapshot(
                providerSnapshot(.claude, kinds: [.claudeWeekAll, .claudeWeekFable], percent: 40 + Double(poll), capturedAt: capturedAt),
                capturedAt: capturedAt
            )
            try await store.appendProviderSnapshot(
                providerSnapshot(.codex, kinds: [.codexWeek], percent: 20 + Double(poll), capturedAt: capturedAt),
                capturedAt: capturedAt
            )
        }
        try await store.appendProviderFailure(
            provider: .codex,
            at: start.addingTimeInterval(19 * 60),
            error: SanitizedProviderError(code: .unavailable, displayMessage: "Codex CLI was not found.")
        )

        let snapshots = try await store.snapshots(since: .distantPast)
        let series = UsagePresentation.historySeries(from: snapshots, now: start.addingTimeInterval(20 * 60))

        XCTAssertEqual(snapshots.count, 6, "One snapshot per poll; failures add none")
        XCTAssertEqual(snapshots.first?.providers.map(\.provider), [.claude, .codex])
        XCTAssertEqual(snapshots.map(\.capturedAt), snapshots.map(\.capturedAt).sorted())
        XCTAssertEqual(UsageAnalytics.samples(for: .codexWeek, in: snapshots).map(\.utilization.value), [20, 21, 22, 23, 24, 25])
        XCTAssertEqual(series.map(\.id), [MeterKind.claudeWeekAll.rawValue, MeterKind.claudeWeekFable.rawValue])
    }

    func testStaleAndEmptyProviderSnapshotsAreNotHistorySamples() async throws {
        let store = makeStore(root: try temporaryRoot())
        let capturedAt = UsageMonitorFixtures.baseDate
        let stale = providerSnapshot(.claude, kinds: [.claudeWeekAll], percent: 50, capturedAt: capturedAt)
        try await store.appendProviderSnapshot(
            ProviderUsageSnapshot(
                provider: .claude,
                meters: stale.meters,
                health: .stale(checkedAt: capturedAt, staleSince: capturedAt.addingTimeInterval(-3600))
            ),
            capturedAt: capturedAt
        )
        try await store.appendProviderSnapshot(
            ProviderUsageSnapshot(provider: .codex, meters: [], health: .fresh(checkedAt: capturedAt)),
            capturedAt: capturedAt
        )

        let snapshots = try await store.snapshots(since: .distantPast)

        XCTAssertTrue(snapshots.isEmpty, "A stale fallback repeats an older reading and must not be charted as current")
    }

    func testLegacyCodexWeeklyReadingsLabelledAsSessionAreReadAsWeekly() async throws {
        let store = makeStore(root: try temporaryRoot())
        let capturedAt = UsageMonitorFixtures.baseDate
        let legacyWeekly = UsageMeterSnapshot(
            kind: .codexSession,
            utilization: try UtilizationPercentage(44),
            resetAt: capturedAt.addingTimeInterval(3 * 24 * 60 * 60),
            display: MeterDisplayMetadata(title: "Codex Session", providerName: "Codex", planName: "Pro 5x", windowName: "Rolling 5 hours")
        )
        let realSession = UsageMeterSnapshot(
            kind: .codexSession,
            utilization: try UtilizationPercentage(10),
            resetAt: capturedAt.addingTimeInterval(4 * 60 * 60)
        )
        try await store.appendProviderSnapshot(
            ProviderUsageSnapshot(provider: .codex, meters: [legacyWeekly], health: .fresh(checkedAt: capturedAt)),
            capturedAt: capturedAt
        )
        let later = capturedAt.addingTimeInterval(180)
        try await store.appendProviderSnapshot(
            ProviderUsageSnapshot(provider: .codex, meters: [realSession], health: .fresh(checkedAt: later)),
            capturedAt: later
        )

        let snapshots = try await store.snapshots(since: .distantPast)
        let relabelled = try XCTUnwrap(snapshots.first?.meters.first)

        XCTAssertEqual(relabelled.kind, .codexWeek)
        XCTAssertEqual(relabelled.display.title, "Codex Week")
        XCTAssertEqual(relabelled.display.planName, "Pro 5x")
        XCTAssertEqual(relabelled.utilization.value, 44)
        XCTAssertEqual(snapshots.last?.meters.first?.kind, .codexSession, "A genuine five-hour window keeps its label")
        let latest = try await store.latestUsableProviderSnapshots()
        XCTAssertEqual(latest[.codex]?.meters.first?.kind, .codexSession)
        let onDisk = try String(contentsOf: store.historyFileURL, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("codexWeek"), "Relabelling happens on read; the file stays readable by older builds")
    }

    func testRelabelledLegacyReadingNeverDuplicatesAGenuineWeeklyMeter() {
        let capturedAt = UsageMonitorFixtures.baseDate
        let snapshot = ProviderUsageSnapshot(
            provider: .codex,
            meters: [
                UsageMeterSnapshot(kind: .codexSession, utilization: try! UtilizationPercentage(44), resetAt: capturedAt.addingTimeInterval(3 * 86_400)),
                UsageMeterSnapshot(kind: .codexWeek, utilization: try! UtilizationPercentage(45), resetAt: capturedAt.addingTimeInterval(3 * 86_400))
            ],
            health: .fresh(checkedAt: capturedAt)
        )

        let normalized = HistorySnapshotAssembler.normalizedLegacyMeters(snapshot, capturedAt: capturedAt)

        XCTAssertEqual(normalized.meters.map(\.kind), [.codexWeek])
        XCTAssertEqual(normalized.meters.first?.utilization.value, 45)
    }

    func testLaunchRecoveryRelabelsALegacyWeeklyReading() async throws {
        let store = makeStore(root: try temporaryRoot())
        let capturedAt = UsageMonitorFixtures.baseDate
        try await store.appendProviderSnapshot(
            ProviderUsageSnapshot(
                provider: .codex,
                meters: [UsageMeterSnapshot(
                    kind: .codexSession,
                    utilization: try UtilizationPercentage(44),
                    resetAt: capturedAt.addingTimeInterval(3 * 86_400)
                )],
                health: .fresh(checkedAt: capturedAt)
            ),
            capturedAt: capturedAt
        )

        let latest = try await store.latestUsableProviderSnapshots()

        XCTAssertEqual(latest[.codex]?.meters.map(\.kind), [.codexWeek])
    }

    func testLegacyCombinedRecordsAreRelabelledToo() async throws {
        let store = makeStore(root: try temporaryRoot())
        let capturedAt = UsageMonitorFixtures.baseDate
        try await store.append(CombinedUsageSnapshot(
            capturedAt: capturedAt,
            providers: [ProviderUsageSnapshot(
                provider: .codex,
                meters: [UsageMeterSnapshot(
                    kind: .codexSession,
                    utilization: try UtilizationPercentage(30),
                    resetAt: capturedAt.addingTimeInterval(2 * 86_400)
                )],
                health: .fresh(checkedAt: capturedAt)
            )]
        ))

        let snapshots = try await store.snapshots(since: .distantPast)

        XCTAssertEqual(snapshots.first?.meters.map(\.kind), [.codexWeek])
    }

    func testLegacyReadingsFromTheLastDayOfAWeekAreRelabelledByTheirSharedReset() async throws {
        let store = makeStore(root: try temporaryRoot())
        let weeklyReset = UsageMonitorFixtures.baseDate.addingTimeInterval(3 * 86_400)
        // Early in the week the reading is clearly weekly; six hours before the same reset it
        // looks like a session on its own, but it shares the weekly reset.
        for (offset, percent) in [(-2.5 * 86_400, 40.0), (-6 * 3600, 90.0)] {
            let capturedAt = weeklyReset.addingTimeInterval(offset)
            try await store.appendProviderSnapshot(
                ProviderUsageSnapshot(
                    provider: .codex,
                    meters: [UsageMeterSnapshot(kind: .codexSession, utilization: try UtilizationPercentage(percent), resetAt: weeklyReset)],
                    health: .fresh(checkedAt: capturedAt)
                ),
                capturedAt: capturedAt
            )
        }
        // A genuine five-hour session with its own reset, read between the two weekly readings.
        let genuineSessionAt = weeklyReset.addingTimeInterval(-30 * 3600)
        try await store.appendProviderSnapshot(
            ProviderUsageSnapshot(
                provider: .codex,
                meters: [UsageMeterSnapshot(kind: .codexSession, utilization: try UtilizationPercentage(10), resetAt: genuineSessionAt.addingTimeInterval(4 * 3600))],
                health: .fresh(checkedAt: genuineSessionAt)
            ),
            capturedAt: genuineSessionAt
        )

        let snapshots = try await store.snapshots(since: .distantPast)
        let latest = try await store.latestUsableProviderSnapshots()

        XCTAssertEqual(snapshots.flatMap(\.meters).map(\.kind), [.codexWeek, .codexSession, .codexWeek])
        XCTAssertEqual(latest[.codex]?.meters.map(\.kind), [.codexWeek])
    }

    func testRelabelHorizonBoundary() {
        let capturedAt = UsageMonitorFixtures.baseDate
        func kind(resettingIn interval: TimeInterval) -> MeterKind? {
            HistorySnapshotAssembler.normalizedLegacyMeters(
                ProviderUsageSnapshot(
                    provider: .codex,
                    meters: [UsageMeterSnapshot(
                        kind: .codexSession,
                        utilization: try! UtilizationPercentage(10),
                        resetAt: capturedAt.addingTimeInterval(interval)
                    )],
                    health: .fresh(checkedAt: capturedAt)
                ),
                capturedAt: capturedAt
            ).meters.first?.kind
        }

        XCTAssertEqual(kind(resettingIn: 5 * 3600), .codexSession)
        XCTAssertEqual(kind(resettingIn: 24 * 3600), .codexSession)
        XCTAssertEqual(kind(resettingIn: 24 * 3600 + 60), .codexWeek)
    }

    private func providerSnapshot(_ provider: ProviderID, kinds: [MeterKind], percent: Double, capturedAt: Date) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            provider: provider,
            meters: kinds.map {
                UsageMeterSnapshot(
                    kind: $0,
                    utilization: try! UtilizationPercentage(percent),
                    resetAt: UsageMonitorFixtures.baseDate.addingTimeInterval(3 * 86_400)
                )
            },
            health: .fresh(checkedAt: capturedAt)
        )
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
        try appendRawData(Data((line + "\n").utf8), to: url)
    }

    private func appendRawData(_ data: Data, to url: URL) throws {
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
