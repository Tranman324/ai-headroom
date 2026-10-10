import XCTest
@testable import AIUsageMonitor

@MainActor
final class UsagePollingCoordinatorTests: XCTestCase {
    func testOfflineStartupRecoversHistoryAsStaleWithoutFetching() async throws {
        let history = RecordingHistoryStore(
            latestSnapshots: [.claude: try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude))]
        )
        let provider = RecordingProviderClient(
            provider: .claude,
            results: [.success(try XCTUnwrap(UsageMonitorFixtures.warningSnapshot.provider(.claude)))]
        )
        let store = makeStore(
            providers: [provider],
            historyStore: history,
            connectivityMonitor: ManualConnectivityMonitor(initialState: .offline)
        )

        await store.startMonitoring()

        let claude = try XCTUnwrap(store.snapshot.provider(.claude))
        let fetchCount = await provider.fetchCount()
        let pruneCount = await history.pruneCount()
        XCTAssertEqual(claude.health.kind, .stale)
        XCTAssertEqual(claude.meters.count, 5)
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(pruneCount, 1)
        await store.stopMonitoring()
    }

    func testOfflineStartupWithoutHistoryPublishesNoDataAndDoesNotHammerProviders() async throws {
        let provider = RecordingProviderClient(
            provider: .codex,
            results: [.success(try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.codex)))]
        )
        let store = makeStore(
            providers: [provider],
            historyStore: RecordingHistoryStore(),
            connectivityMonitor: ManualConnectivityMonitor(initialState: .offline)
        )

        await store.startMonitoring()

        let fetchCount = await provider.fetchCount()
        XCTAssertEqual(store.snapshot.provider(.claude)?.health.kind, .noData)
        XCTAssertEqual(store.snapshot.provider(.codex)?.health.kind, .noData)
        XCTAssertEqual(fetchCount, 0)
        await store.stopMonitoring()
    }

    func testManualRefreshWritesProviderLocalSuccessAndFailureHistory() async throws {
        let initialProviders = Dictionary(
            uniqueKeysWithValues: UsageMonitorFixtures.criticalSnapshot.providers.map { ($0.provider, $0) }
        )
        let history = RecordingHistoryStore(latestSnapshots: initialProviders)
        let connectivity = PassiveConnectivityMonitor(initialState: .offline)
        let codexFailure = ProviderClientFailure.rateLimited(provider: .codex)
        let store = makeStore(
            providers: [
                RecordingProviderClient(
                    provider: .claude,
                    results: [.success(try XCTUnwrap(UsageMonitorFixtures.warningSnapshot.provider(.claude)))]
                ),
                RecordingProviderClient(
                    provider: .codex,
                    results: [.failure(codexFailure)]
                )
            ],
            historyStore: history,
            connectivityMonitor: connectivity,
            initialSnapshot: UsageMonitorFixtures.criticalSnapshot
        )

        await store.startMonitoring()
        connectivity.set(.online)
        await store.refresh()

        let claude = try XCTUnwrap(store.snapshot.provider(.claude))
        let codex = try XCTUnwrap(store.snapshot.provider(.codex))
        XCTAssertEqual(claude.health.kind, .fresh)
        XCTAssertEqual(codex.health.kind, .stale)
        XCTAssertEqual(codex.meters, UsageMonitorFixtures.criticalSnapshot.provider(.codex)?.meters)

        let records = await history.appendedRecords()
        XCTAssertEqual(records.count, 2)
        guard case let .providerSnapshot(snapshotRecord) = records.first else {
            return XCTFail("Expected Claude provider snapshot history record.")
        }
        XCTAssertEqual(snapshotRecord.provider, .claude)
        guard case let .providerFailure(failureRecord) = records.last else {
            return XCTFail("Expected Codex provider failure history record.")
        }
        XCTAssertEqual(failureRecord.provider, .codex)
        XCTAssertEqual(failureRecord.error.code, .rateLimited)
        await store.stopMonitoring()
    }

    func testProviderReportedStaleDataKeepsItsMarkerAndReason() async throws {
        let claude = try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude))
        let reason = ProviderClientFailure.usageUnavailable(provider: .claude).sanitizedError
        let staleSince = UsageMonitorFixtures.baseDate.addingTimeInterval(-2 * 60 * 60)
        let staleClaude = ProviderUsageSnapshot(
            provider: .claude,
            meters: claude.meters,
            health: .stale(checkedAt: UsageMonitorFixtures.baseDate, staleSince: staleSince, error: reason)
        )
        let connectivity = PassiveConnectivityMonitor(initialState: .offline)
        let store = makeStore(
            providers: [RecordingProviderClient(provider: .claude, results: [.success(staleClaude)])],
            connectivityMonitor: connectivity
        )

        await store.startMonitoring()
        connectivity.set(.online)
        await store.refresh()

        let published = try XCTUnwrap(store.snapshot.provider(.claude))
        XCTAssertEqual(published.health.kind, .stale)
        XCTAssertEqual(published.health.staleSince, staleSince)
        XCTAssertEqual(published.health.error, reason)
        XCTAssertEqual(published.meters, claude.meters)
        await store.stopMonitoring()
    }

    func testStateUpdatesWhenProviderHistoryAppendFails() async throws {
        let history = RecordingHistoryStore(failingOperations: [.appendProviderSnapshot])
        let connectivity = PassiveConnectivityMonitor(initialState: .offline)
        let store = makeStore(
            providers: [
                RecordingProviderClient(
                    provider: .claude,
                    results: [.success(try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude)))]
                )
            ],
            historyStore: history,
            connectivityMonitor: connectivity
        )

        await store.startMonitoring()
        connectivity.set(.online)
        await store.refresh()

        let failedAppendAttempts = await history.failedAppendAttempts()
        XCTAssertEqual(store.snapshot.provider(.claude)?.health.kind, .fresh)
        XCTAssertEqual(failedAppendAttempts, 1)
        await store.stopMonitoring()
    }

    func testConcurrentManualRefreshesCoalesceWithoutOverlappingPollCycles() async throws {
        let provider = BlockingProviderClient(
            provider: .claude,
            snapshots: [
                try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude)),
                try XCTUnwrap(UsageMonitorFixtures.warningSnapshot.provider(.claude))
            ]
        )
        let connectivity = PassiveConnectivityMonitor(initialState: .offline)
        let store = makeStore(providers: [provider], connectivityMonitor: connectivity)

        await store.startMonitoring()
        connectivity.set(.online)
        let first = Task { @MainActor in
            await store.refresh()
        }
        await provider.waitForFetchCount(1)

        let trailing = (0..<5).map { _ in
            Task { @MainActor in
                await store.refresh()
            }
        }
        let activeFetchCount = await provider.fetchCount()
        XCTAssertEqual(activeFetchCount, 1)
        await provider.releaseOne()
        await provider.waitForFetchCount(2)
        let activeMaxConcurrentFetches = await provider.maxConcurrentFetches()
        XCTAssertEqual(activeMaxConcurrentFetches, 1)
        await provider.releaseOne()

        await first.value
        for task in trailing {
            await task.value
        }
        let finalFetchCount = await provider.fetchCount()
        let finalMaxConcurrentFetches = await provider.maxConcurrentFetches()
        XCTAssertEqual(finalFetchCount, 2)
        XCTAssertEqual(finalMaxConcurrentFetches, 1)
        await store.stopMonitoring()
    }

    func testFailedPollDoesNotRetryImmediately() async throws {
        let provider = RecordingProviderClient(
            provider: .claude,
            results: [.failure(ProviderClientFailure.transport(provider: .claude))]
        )
        let connectivity = PassiveConnectivityMonitor(initialState: .offline)
        let store = makeStore(providers: [provider], connectivityMonitor: connectivity)

        await store.startMonitoring()
        connectivity.set(.online)
        await store.refresh()

        let fetchCount = await provider.fetchCount()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(store.snapshot.provider(.claude)?.health.kind, .errored)
        await store.stopMonitoring()
    }

    func testConnectivityRestoreTriggersOnePollAfterOfflineStartup() async throws {
        let connectivity = ManualConnectivityMonitor(initialState: .offline)
        let provider = RecordingProviderClient(
            provider: .codex,
            results: [.success(try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.codex)))]
        )
        let store = makeStore(
            providers: [provider],
            connectivityMonitor: connectivity
        )

        await store.startMonitoring()
        connectivity.set(.online)
        await provider.waitForFetchCount(1)
        await waitUntil {
            store.snapshot.provider(.codex)?.health.kind == .fresh
        }

        connectivity.set(.online)
        await Task.yield()
        let fetchCount = await provider.fetchCount()
        XCTAssertEqual(store.snapshot.provider(.codex)?.health.kind, .fresh)
        XCTAssertEqual(fetchCount, 1)
        await store.stopMonitoring()
    }

    func testSleepSuspendsIntervalAndWakeTriggersImmediateRefresh() async throws {
        let clock = ManualClock(now: UsageMonitorFixtures.baseDate)
        let lifecycle = ManualLifecycleEvents()
        let provider = RecordingProviderClient(
            provider: .claude,
            results: [
                .success(try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude))),
                .success(try XCTUnwrap(UsageMonitorFixtures.warningSnapshot.provider(.claude)))
            ]
        )
        let store = makeStore(
            providers: [provider],
            clock: clock,
            lifecycleEvents: lifecycle
        )

        await store.startMonitoring()
        var fetchCount = await provider.fetchCount()
        XCTAssertEqual(fetchCount, 1)

        lifecycle.send(.workspaceWillSleep)
        clock.resumeSleepers()
        fetchCount = await provider.fetchCount()
        XCTAssertEqual(fetchCount, 1)

        lifecycle.send(.workspaceDidWake)
        await provider.waitForFetchCount(2)
        XCTAssertEqual(store.snapshot.provider(.claude)?.meters.count, 5)
        await store.stopMonitoring()
    }

    func testCancellationStopsOwnedConnectivityLifecycleAndIntervalWork() async throws {
        let clock = ManualClock(now: UsageMonitorFixtures.baseDate)
        let connectivity = ManualConnectivityMonitor(initialState: .offline)
        let lifecycle = ManualLifecycleEvents()
        let provider = RecordingProviderClient(
            provider: .claude,
            results: [.success(try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude)))]
        )
        let store = makeStore(
            providers: [provider],
            clock: clock,
            connectivityMonitor: connectivity,
            lifecycleEvents: lifecycle
        )

        await store.startMonitoring()
        await store.stopMonitoring()
        connectivity.set(.online)
        lifecycle.send(.workspaceDidWake)
        clock.resumeSleepers()
        await Task.yield()

        let fetchCount = await provider.fetchCount()
        XCTAssertEqual(fetchCount, 0)
    }

    func testStopDuringBlockedSettingsStartupDoesNotInstallOwnedWork() async throws {
        let loadedSettings = MonitorSettings(
            alertThreshold: try AlertThreshold(percentage: 50),
            launchAtLogin: true
        )
        let settingsStore = BlockingFirstSettingsStore(loadResults: [loadedSettings])
        let history = RecordingHistoryStore()
        let clock = ManualClock(now: UsageMonitorFixtures.baseDate.addingTimeInterval(600))
        let connectivity = ManualConnectivityMonitor(initialState: .online)
        let lifecycle = ManualLifecycleEvents()
        let provider = RecordingProviderClient(
            provider: .claude,
            results: [.success(try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude)))]
        )
        let store = makeStore(
            providers: [provider],
            historyStore: history,
            settingsStore: settingsStore,
            clock: clock,
            connectivityMonitor: connectivity,
            lifecycleEvents: lifecycle
        )
        let stoppedSnapshot = store.snapshot
        let stoppedSettings = store.settings

        let startup = Task { @MainActor in
            await store.startMonitoring()
        }
        await settingsStore.waitForLoadCount(1)
        let stopProbe = StopCompletionProbe()
        let stop = Task { @MainActor in
            await stopProbe.markEntered()
            await store.stopMonitoring()
            await stopProbe.markReturned(pruneCount: 0)
        }
        await stopProbe.waitUntilEntered()
        for _ in 0..<20 {
            await Task.yield()
        }
        let returnedBeforeRelease = await stopProbe.hasReturned()
        XCTAssertFalse(returnedBeforeRelease)
        await settingsStore.releaseFirstLoad()
        await stop.value
        await startup.value

        connectivity.set(.offline)
        connectivity.set(.online)
        lifecycle.send(.workspaceDidWake)
        clock.resumeSleepers()
        for _ in 0..<20 {
            await Task.yield()
        }

        let fetchCount = await provider.fetchCount()
        let pruneCount = await history.pruneCount()
        let records = await history.appendedRecords()
        let saveCount = await settingsStore.saveCount()
        XCTAssertEqual(connectivity.activeObserverCount(), 0)
        XCTAssertEqual(lifecycle.activeObserverCount(), 0)
        XCTAssertEqual(clock.activeSleepCount(), 0)
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(pruneCount, 0)
        XCTAssertEqual(records.count, 0)
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(store.snapshot, stoppedSnapshot)
        XCTAssertEqual(store.settings, stoppedSettings)
        XCTAssertEqual(store.launchAtLoginStatus, .disabled)
    }

    func testRestartAfterCancelledStartupOwnsObserversAndPollExactlyOnce() async throws {
        let staleSettings = MonitorSettings(
            alertThreshold: try AlertThreshold(percentage: 50),
            launchAtLogin: true
        )
        let currentSettings = MonitorSettings(
            pollingInterval: try PollingInterval(minutes: 1),
            alertThreshold: try AlertThreshold(percentage: 95)
        )
        let settingsStore = BlockingFirstSettingsStore(loadResults: [staleSettings, currentSettings])
        let history = RecordingHistoryStore()
        let clock = ManualClock(now: UsageMonitorFixtures.baseDate.addingTimeInterval(600))
        let connectivity = ManualConnectivityMonitor(initialState: .online)
        let lifecycle = ManualLifecycleEvents()
        let restartedSnapshot = try XCTUnwrap(UsageMonitorFixtures.warningSnapshot.provider(.claude))
        let provider = RecordingProviderClient(
            provider: .claude,
            results: [.success(restartedSnapshot)]
        )
        let store = makeStore(
            providers: [provider],
            historyStore: history,
            settingsStore: settingsStore,
            clock: clock,
            connectivityMonitor: connectivity,
            lifecycleEvents: lifecycle
        )

        let staleStartup = Task { @MainActor in
            await store.startMonitoring()
        }
        await settingsStore.waitForLoadCount(1)
        let stopProbe = StopCompletionProbe()
        let stop = Task { @MainActor in
            await stopProbe.markEntered()
            await store.stopMonitoring()
            await stopProbe.markReturned(pruneCount: 0)
        }
        await stopProbe.waitUntilEntered()
        for _ in 0..<20 {
            await Task.yield()
        }

        let currentStartup = Task { @MainActor in
            await store.startMonitoring()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        let loadCountBeforeRelease = await settingsStore.loadCount()
        XCTAssertEqual(loadCountBeforeRelease, 1)

        await settingsStore.releaseFirstLoad()
        await stop.value
        await staleStartup.value
        await currentStartup.value
        await waitUntil {
            connectivity.activeObserverCount() == 1
                && lifecycle.activeObserverCount() == 1
                && clock.activeSleepCount() == 1
        }

        for _ in 0..<20 {
            await Task.yield()
        }

        let fetchCount = await provider.fetchCount()
        let pruneCount = await history.pruneCount()
        let records = await history.appendedRecords()
        XCTAssertEqual(connectivity.activeObserverCount(), 1)
        XCTAssertEqual(lifecycle.activeObserverCount(), 1)
        XCTAssertEqual(clock.activeSleepCount(), 1)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(pruneCount, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(store.settings, currentSettings)
        XCTAssertEqual(store.snapshot.provider(.claude)?.meters, restartedSnapshot.meters)

        await store.stopMonitoring()
        await waitUntil {
            connectivity.activeObserverCount() == 0
                && lifecycle.activeObserverCount() == 0
                && clock.activeSleepCount() == 0
        }
        XCTAssertEqual(connectivity.activeObserverCount(), 0)
        XCTAssertEqual(lifecycle.activeObserverCount(), 0)
        XCTAssertEqual(clock.activeSleepCount(), 0)
    }

    func testStopWaitsForBlockedStartupPruneBeforeReturning() async throws {
        let history = BlockingPruneHistoryStore()
        let connectivity = ManualConnectivityMonitor(initialState: .offline)
        let lifecycle = ManualLifecycleEvents()
        let clock = ManualClock(now: UsageMonitorFixtures.baseDate.addingTimeInterval(600))
        let store = makeStore(
            historyStore: history,
            clock: clock,
            connectivityMonitor: connectivity,
            lifecycleEvents: lifecycle
        )
        let stopProbe = StopCompletionProbe()

        let startup = Task { @MainActor in
            await store.startMonitoring()
        }
        await history.waitForPruneStartCount(1)
        let stop = Task { @MainActor in
            await stopProbe.markEntered()
            await store.stopMonitoring()
            await stopProbe.markReturned(pruneCount: history.pruneCompletionCount())
        }
        await stopProbe.waitUntilEntered()
        for _ in 0..<20 {
            await Task.yield()
        }

        let returnedBeforeRelease = await stopProbe.hasReturned()
        let completionsBeforeRelease = await history.pruneCompletionCount()
        XCTAssertFalse(returnedBeforeRelease)
        XCTAssertEqual(completionsBeforeRelease, 0)

        await history.releaseFirstPrune()
        await stop.value
        await startup.value

        let pruneCountAtStopReturn = await stopProbe.pruneCountAtReturn()
        let finalPruneCount = await history.pruneCompletionCount()
        XCTAssertEqual(pruneCountAtStopReturn, 1)
        XCTAssertEqual(finalPruneCount, 1)
        XCTAssertEqual(connectivity.activeObserverCount(), 0)
        XCTAssertEqual(lifecycle.activeObserverCount(), 0)
        XCTAssertEqual(clock.activeSleepCount(), 0)
    }

    func testRestartWaitsForCancelledBlockedStartupBeforeTakingOwnership() async throws {
        let history = BlockingPruneHistoryStore()
        let connectivity = ManualConnectivityMonitor(initialState: .online)
        let lifecycle = ManualLifecycleEvents()
        let clock = ManualClock(now: UsageMonitorFixtures.baseDate.addingTimeInterval(600))
        let restartedSnapshot = try XCTUnwrap(UsageMonitorFixtures.warningSnapshot.provider(.claude))
        let provider = RecordingProviderClient(
            provider: .claude,
            results: [.success(restartedSnapshot)]
        )
        let store = makeStore(
            providers: [provider],
            historyStore: history,
            clock: clock,
            connectivityMonitor: connectivity,
            lifecycleEvents: lifecycle
        )
        let stopProbe = StopCompletionProbe()

        let staleStartup = Task { @MainActor in
            await store.startMonitoring()
        }
        await history.waitForPruneStartCount(1)
        let stop = Task { @MainActor in
            await stopProbe.markEntered()
            await store.stopMonitoring()
            await stopProbe.markReturned(pruneCount: history.pruneCompletionCount())
        }
        await stopProbe.waitUntilEntered()
        for _ in 0..<20 {
            await Task.yield()
        }
        let currentStartup = Task { @MainActor in
            await store.startMonitoring()
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        let pruneStartsBeforeRelease = await history.pruneStartCount()
        let fetchesBeforeRelease = await provider.fetchCount()
        XCTAssertEqual(pruneStartsBeforeRelease, 1)
        XCTAssertEqual(fetchesBeforeRelease, 0)

        await history.releaseFirstPrune()
        await stop.value
        await staleStartup.value
        await currentStartup.value
        await waitUntil {
            connectivity.activeObserverCount() == 1
                && lifecycle.activeObserverCount() == 1
                && clock.activeSleepCount() == 1
        }

        let pruneStartCount = await history.pruneStartCount()
        let pruneCompletionCount = await history.pruneCompletionCount()
        let fetchCount = await provider.fetchCount()
        let records = await history.appendedRecords()
        XCTAssertEqual(pruneStartCount, 2)
        XCTAssertEqual(pruneCompletionCount, 2)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(connectivity.activeObserverCount(), 1)
        XCTAssertEqual(lifecycle.activeObserverCount(), 1)
        XCTAssertEqual(clock.activeSleepCount(), 1)
        XCTAssertEqual(store.snapshot.provider(.claude)?.meters, restartedSnapshot.meters)

        await store.stopMonitoring()
    }

    func testCancellingActivePollDropsLateProviderResultAndHistoryWrite() async throws {
        let history = RecordingHistoryStore()
        let provider = BlockingProviderClient(
            provider: .claude,
            snapshots: [try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude))]
        )
        let connectivity = PassiveConnectivityMonitor(initialState: .offline)
        let store = makeStore(
            providers: [provider],
            historyStore: history,
            connectivityMonitor: connectivity
        )

        await store.startMonitoring()
        connectivity.set(.online)
        let refresh = Task { @MainActor in
            await store.refresh()
        }
        await provider.waitForFetchCount(1)
        await store.stopMonitoring()
        await provider.releaseOne()
        await provider.waitUntilIdle()
        await refresh.value
        for _ in 0..<20 {
            let currentRecords = await history.appendedRecords()
            if !currentRecords.isEmpty {
                break
            }
            await Task.yield()
        }

        let records = await history.appendedRecords()
        XCTAssertEqual(store.snapshot.provider(.claude)?.health.kind, .noData)
        XCTAssertEqual(records.count, 0)
    }

    func testRestartDoesNotOverlapWithCancelledProviderFetch() async throws {
        let history = RecordingHistoryStore()
        let stoppedResult = try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude))
        let restartedResult = try XCTUnwrap(UsageMonitorFixtures.warningSnapshot.provider(.claude))
        let provider = BlockingProviderClient(
            provider: .claude,
            snapshots: [stoppedResult, restartedResult]
        )
        let store = makeStore(providers: [provider], historyStore: history)

        let initialStart = Task { @MainActor in
            await store.startMonitoring()
        }
        await provider.waitForFetchCount(1)
        let stopProbe = StopCompletionProbe()
        let stop = Task { @MainActor in
            await stopProbe.markEntered()
            await store.stopMonitoring()
            await stopProbe.markReturned(pruneCount: 0)
        }
        await stopProbe.waitUntilEntered()
        for _ in 0..<20 {
            await Task.yield()
        }

        let restart = Task { @MainActor in
            await store.startMonitoring()
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        var fetchCount = await provider.fetchCount()
        var currentConcurrentFetches = await provider.currentConcurrentFetches()
        var maxConcurrentFetches = await provider.maxConcurrentFetches()
        let stopReturnedBeforeRelease = await stopProbe.hasReturned()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(currentConcurrentFetches, 1)
        XCTAssertEqual(maxConcurrentFetches, 1)
        XCTAssertFalse(stopReturnedBeforeRelease)

        await provider.releaseOne()
        await stop.value
        await provider.waitForFetchCount(2)
        fetchCount = await provider.fetchCount()
        currentConcurrentFetches = await provider.currentConcurrentFetches()
        maxConcurrentFetches = await provider.maxConcurrentFetches()
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(currentConcurrentFetches, 1)
        XCTAssertEqual(maxConcurrentFetches, 1)

        await provider.releaseOne()
        await provider.waitUntilIdle()
        await initialStart.value
        await restart.value

        let records = await history.appendedRecords()
        XCTAssertEqual(store.snapshot.provider(.claude)?.health.kind, .fresh)
        XCTAssertEqual(store.snapshot.provider(.claude)?.meters, restartedResult.meters)
        XCTAssertEqual(records.count, 1)
        await store.stopMonitoring()
    }

    func testManualRefreshWhileStoppedDoesNoProviderOrHistoryWork() async throws {
        let history = RecordingHistoryStore()
        let connectivity = ManualConnectivityMonitor(initialState: .offline)
        let provider = RecordingProviderClient(
            provider: .claude,
            results: [.success(try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude)))]
        )
        let store = makeStore(
            providers: [provider],
            historyStore: history,
            connectivityMonitor: connectivity
        )

        await store.startMonitoring()
        await store.stopMonitoring()
        let stoppedSnapshot = store.snapshot
        connectivity.set(.online)

        await store.refresh()

        let fetchCount = await provider.fetchCount()
        let records = await history.appendedRecords()
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(records.count, 0)
        XCTAssertEqual(store.snapshot, stoppedSnapshot)
    }

    func testPauseAlertsPersistsExactlyOneHourFromInjectedClockAndKeepsStatusBoundariesFixed() async throws {
        let now = UsageMonitorFixtures.baseDate.addingTimeInterval(42)
        let settingsStore = RecordingSettingsStore()
        let store = makeStore(
            settingsStore: settingsStore,
            clock: FixedClock(now: now)
        )

        try await store.handle(.pauseAlertsForOneHour)

        let savedSettings = await settingsStore.savedSettings()
        XCTAssertEqual(store.settings.alertPauseExpiration, now.addingTimeInterval(60 * 60))
        XCTAssertEqual(savedSettings.last?.alertPauseExpiration, now.addingTimeInterval(60 * 60))
        XCTAssertEqual(UsagePresentation.statusBand(for: 69.9), .normal)
        XCTAssertEqual(UsagePresentation.statusBand(for: 70), .warning)
        XCTAssertEqual(UsagePresentation.statusBand(for: 90), .critical)
    }

    func testLaunchRegistrationPersistsPreferenceOnlyAfterSuccessfulRegistration() async throws {
        let settingsStore = RecordingSettingsStore()
        let loginRegistration = ConfigurableLoginRegistration()
        let store = makeStore(settingsStore: settingsStore, loginRegistration: loginRegistration)

        try await store.handle(.setLaunchAtLogin(true))

        XCTAssertEqual(store.launchAtLoginStatus, .enabled)
        XCTAssertEqual(store.settings.launchAtLogin, true)
        var savedSettings = await settingsStore.savedSettings()
        XCTAssertEqual(savedSettings.last?.launchAtLogin, true)

        loginRegistration.failNext(LoginRegistrationError.requestFailed("register failed"))
        do {
            try await store.handle(.setLaunchAtLogin(false))
            XCTFail("Expected failed launch registration to propagate.")
        } catch {
            XCTAssertEqual(store.launchAtLoginStatus, .failed("register failed"))
        }
        savedSettings = await settingsStore.savedSettings()
        XCTAssertEqual(store.settings.launchAtLogin, true)
        XCTAssertEqual(savedSettings.last?.launchAtLogin, true)
    }

    func testServiceManagementLaunchStatusMapping() {
        XCTAssertEqual(ServiceManagementLoginRegistration.map(.enabled), .enabled)
        XCTAssertEqual(ServiceManagementLoginRegistration.map(.notRegistered), .disabled)
        XCTAssertEqual(ServiceManagementLoginRegistration.map(.requiresApproval), .requiresApproval)
        XCTAssertEqual(ServiceManagementLoginRegistration.map(.notFound), .unavailable)
    }

    private func makeStore(
        providers: [any UsageProviderFetching] = [
            FixtureProviderClient(snapshot: UsageMonitorFixtures.normalSnapshot.provider(.claude)!),
            FixtureProviderClient(snapshot: UsageMonitorFixtures.normalSnapshot.provider(.codex)!)
        ],
        historyStore: any HistoryStoring = RecordingHistoryStore(),
        settingsStore: any SettingsStoring = RecordingSettingsStore(),
        clock: any ClockProviding = ManualClock(now: UsageMonitorFixtures.baseDate.addingTimeInterval(600)),
        connectivityMonitor: any ConnectivityMonitoring = ManualConnectivityMonitor(initialState: .online),
        lifecycleEvents: any AppLifecycleEventProviding = ManualLifecycleEvents(),
        loginRegistration: any LoginRegistering = ConfigurableLoginRegistration(),
        initialSnapshot: CombinedUsageSnapshot = UsageMonitorFixtures.noDataSnapshot
    ) -> UsageMonitorStore {
        UsageMonitorStore(
            dependencies: AppDependencies(
                providers: providers,
                historyStore: historyStore,
                settingsStore: settingsStore,
                clock: clock,
                connectivityMonitor: connectivityMonitor,
                lifecycleEvents: lifecycleEvents,
                loginRegistration: loginRegistration,
                externalURLOpener: NoopExternalURLOpener()
            ),
            initialSnapshot: initialSnapshot
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 100,
        predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if predicate() {
                return
            }
            await Task.yield()
        }
    }
}

actor RecordingHistoryStore: HistoryStoring {
    enum Operation: Hashable {
        case appendProviderSnapshot
        case appendProviderFailure
    }

    private var storedRecords: [UsageHistoryRecord]
    private let latestSnapshots: [ProviderID: ProviderUsageSnapshot]
    private let failingOperations: Set<Operation>
    private var prunes = 0
    private var pruneWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var failedAppends = 0

    init(
        records: [UsageHistoryRecord] = [],
        latestSnapshots: [ProviderID: ProviderUsageSnapshot] = [:],
        failingOperations: Set<Operation> = []
    ) {
        self.storedRecords = records
        self.latestSnapshots = latestSnapshots
        self.failingOperations = failingOperations
    }

    func append(_ snapshot: CombinedUsageSnapshot) async throws {
        storedRecords.append(.combinedSnapshot(CombinedSnapshotHistoryRecord(snapshot: snapshot)))
    }

    func appendProviderSnapshot(_ snapshot: ProviderUsageSnapshot, capturedAt: Date) async throws {
        if failingOperations.contains(.appendProviderSnapshot) {
            failedAppends += 1
            throw RecordingHistoryError.writeFailed
        }
        storedRecords.append(.providerSnapshot(ProviderSnapshotHistoryRecord(capturedAt: capturedAt, snapshot: snapshot)))
    }

    func appendProviderFailure(provider: ProviderID, at timestamp: Date, error: SanitizedProviderError) async throws {
        if failingOperations.contains(.appendProviderFailure) {
            failedAppends += 1
            throw RecordingHistoryError.writeFailed
        }
        storedRecords.append(.providerFailure(ProviderFailureHistoryRecord(timestamp: timestamp, provider: provider, error: error)))
    }

    func records(since startDate: Date) async throws -> [UsageHistoryRecord] {
        storedRecords.filter { $0.timestamp >= startDate }
    }

    func snapshots(since startDate: Date) async throws -> [CombinedUsageSnapshot] {
        try await records(since: startDate).compactMap { record in
            if case let .combinedSnapshot(snapshotRecord) = record {
                return snapshotRecord.snapshot
            }
            return nil
        }
    }

    func latestUsableProviderSnapshots() async throws -> [ProviderID: ProviderUsageSnapshot] {
        latestSnapshots
    }

    func prune(olderThan cutoffDate: Date) async throws {
        prunes += 1
        storedRecords.removeAll { $0.timestamp < cutoffDate }
        resumePruneWaiters()
    }

    func appendedRecords() -> [UsageHistoryRecord] {
        storedRecords
    }

    func pruneCount() -> Int {
        prunes
    }

    func waitForPruneCount(_ expectedCount: Int) async {
        if prunes >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            pruneWaiters.append((expectedCount, continuation))
        }
    }

    func failedAppendAttempts() -> Int {
        failedAppends
    }

    private func resumePruneWaiters() {
        let ready = pruneWaiters.filter { prunes >= $0.0 }
        pruneWaiters.removeAll { prunes >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

actor BlockingFirstSettingsStore: SettingsStoring {
    private let loadResults: [MonitorSettings]
    private var loads = 0
    private var saves = 0
    private var firstLoadRelease: CheckedContinuation<Void, Never>?
    private var loadWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(loadResults: [MonitorSettings]) {
        precondition(!loadResults.isEmpty)
        self.loadResults = loadResults
    }

    func loadSettings() async throws -> MonitorSettings {
        loads += 1
        let loadNumber = loads
        resumeLoadWaiters()
        if loadNumber == 1 {
            await withCheckedContinuation { continuation in
                firstLoadRelease = continuation
            }
        }
        return loadResults[min(loadNumber - 1, loadResults.count - 1)]
    }

    func saveSettings(_ settings: MonitorSettings) async throws {
        saves += 1
    }

    func waitForLoadCount(_ expectedCount: Int) async {
        if loads >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            loadWaiters.append((expectedCount, continuation))
        }
    }

    func releaseFirstLoad() {
        firstLoadRelease?.resume()
        firstLoadRelease = nil
    }

    func saveCount() -> Int {
        saves
    }

    func loadCount() -> Int {
        loads
    }

    private func resumeLoadWaiters() {
        let ready = loadWaiters.filter { loads >= $0.0 }
        loadWaiters.removeAll { loads >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

actor BlockingPruneHistoryStore: HistoryStoring {
    private var storedRecords: [UsageHistoryRecord] = []
    private var pruneStarts = 0
    private var pruneCompletions = 0
    private var firstPruneRelease: CheckedContinuation<Void, Never>?
    private var pruneStartWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ snapshot: CombinedUsageSnapshot) async throws {
        storedRecords.append(.combinedSnapshot(CombinedSnapshotHistoryRecord(snapshot: snapshot)))
    }

    func appendProviderSnapshot(_ snapshot: ProviderUsageSnapshot, capturedAt: Date) async throws {
        storedRecords.append(.providerSnapshot(ProviderSnapshotHistoryRecord(capturedAt: capturedAt, snapshot: snapshot)))
    }

    func appendProviderFailure(provider: ProviderID, at timestamp: Date, error: SanitizedProviderError) async throws {
        storedRecords.append(.providerFailure(ProviderFailureHistoryRecord(timestamp: timestamp, provider: provider, error: error)))
    }

    func records(since startDate: Date) async throws -> [UsageHistoryRecord] {
        storedRecords.filter { $0.timestamp >= startDate }
    }

    func snapshots(since startDate: Date) async throws -> [CombinedUsageSnapshot] {
        try await records(since: startDate).compactMap { record in
            if case let .combinedSnapshot(snapshotRecord) = record {
                return snapshotRecord.snapshot
            }
            return nil
        }
    }

    func latestUsableProviderSnapshots() async throws -> [ProviderID: ProviderUsageSnapshot] {
        [:]
    }

    func prune(olderThan cutoffDate: Date) async throws {
        pruneStarts += 1
        let currentStart = pruneStarts
        resumePruneStartWaiters()
        if currentStart == 1 {
            await withCheckedContinuation { continuation in
                firstPruneRelease = continuation
            }
        }
        pruneCompletions += 1
        storedRecords.removeAll { $0.timestamp < cutoffDate }
    }

    func waitForPruneStartCount(_ expectedCount: Int) async {
        if pruneStarts >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            pruneStartWaiters.append((expectedCount, continuation))
        }
    }

    func releaseFirstPrune() {
        firstPruneRelease?.resume()
        firstPruneRelease = nil
    }

    func pruneStartCount() -> Int {
        pruneStarts
    }

    func pruneCompletionCount() -> Int {
        pruneCompletions
    }

    func appendedRecords() -> [UsageHistoryRecord] {
        storedRecords
    }

    private func resumePruneStartWaiters() {
        let ready = pruneStartWaiters.filter { pruneStarts >= $0.0 }
        pruneStartWaiters.removeAll { pruneStarts >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

actor StopCompletionProbe {
    private var entered = false
    private var returned = false
    private var countAtReturn: Int?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func markReturned(pruneCount: Int) {
        returned = true
        countAtReturn = pruneCount
    }

    func hasReturned() -> Bool {
        returned
    }

    func pruneCountAtReturn() -> Int? {
        countAtReturn
    }
}

enum RecordingHistoryError: Error {
    case writeFailed
}

actor RecordingProviderClient: UsageProviderFetching {
    nonisolated let provider: ProviderID
    private var results: [Result<ProviderUsageSnapshot, Error>]
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(provider: ProviderID, results: [Result<ProviderUsageSnapshot, Error>]) {
        self.provider = provider
        self.results = results
    }

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        count += 1
        resumeWaiters()
        let result = results.isEmpty ? .failure(TestProviderError.unavailable) : results.removeFirst()
        return try result.get()
    }

    func fetchCount() -> Int {
        count
    }

    func waitForFetchCount(_ expectedCount: Int) async {
        if count >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((expectedCount, continuation))
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { count >= $0.0 }
        waiters.removeAll { count >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

actor BlockingProviderClient: UsageProviderFetching {
    nonisolated let provider: ProviderID
    private var snapshots: [ProviderUsageSnapshot]
    private var count = 0
    private var inFlight = 0
    private var maxInFlight = 0
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(provider: ProviderID, snapshots: [ProviderUsageSnapshot]) {
        self.provider = provider
        self.snapshots = snapshots
    }

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        count += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        resumeWaiters()
        await withCheckedContinuation { continuation in
            releases.append(continuation)
        }
        inFlight -= 1
        resumeIdleWaitersIfNeeded()
        if snapshots.isEmpty {
            throw TestProviderError.unavailable
        }
        return snapshots.removeFirst()
    }

    func releaseOne() {
        guard !releases.isEmpty else {
            return
        }
        releases.removeFirst().resume()
    }

    func waitForFetchCount(_ expectedCount: Int) async {
        if count >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((expectedCount, continuation))
        }
    }

    func fetchCount() -> Int {
        count
    }

    func maxConcurrentFetches() -> Int {
        maxInFlight
    }

    func currentConcurrentFetches() -> Int {
        inFlight
    }

    func waitUntilIdle() async {
        if inFlight == 0 {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { count >= $0.0 }
        waiters.removeAll { count >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }

    private func resumeIdleWaitersIfNeeded() {
        guard inFlight == 0 else {
            return
        }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

}

final class ManualClock: ClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate: Date
    private var continuations: [CheckedContinuation<Void, any Error>] = []

    init(now: Date) {
        self.currentDate = now
    }

    var now: Date {
        currentNow()
    }

    func sleep(for duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                appendSleeper(continuation)
            }
        } onCancel: {
            self.resumeSleepers(throwing: CancellationError())
        }
    }

    func resumeSleepers(throwing error: (any Error)? = nil) {
        let sleepers = drainSleepers()

        for sleeper in sleepers {
            if let error {
                sleeper.resume(throwing: error)
            } else {
                sleeper.resume()
            }
        }
    }

    func activeSleepCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    private func currentNow() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentDate
    }

    private func appendSleeper(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        continuations.append(continuation)
        lock.unlock()
    }

    private func drainSleepers() -> [CheckedContinuation<Void, any Error>] {
        lock.lock()
        defer { lock.unlock() }
        let sleepers = continuations
        continuations.removeAll()
        return sleepers
    }
}

final class ManualConnectivityMonitor: ConnectivityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ConnectivityState
    private var continuations: [UUID: AsyncStream<ConnectivityState>.Continuation] = [:]

    init(initialState: ConnectivityState) {
        self.state = initialState
    }

    var currentState: ConnectivityState {
        get async {
            currentStateValue()
        }
    }

    func states() -> AsyncStream<ConnectivityState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            let currentState = addContinuation(continuation, id: id)
            continuation.yield(currentState)
            continuation.onTermination = { @Sendable _ in
                self.removeContinuation(id)
            }
        }
    }

    func set(_ newState: ConnectivityState) {
        let activeContinuations = updateState(newState)

        for continuation in activeContinuations {
            continuation.yield(newState)
        }
    }

    func activeObserverCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    private func currentStateValue() -> ConnectivityState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func addContinuation(
        _ continuation: AsyncStream<ConnectivityState>.Continuation,
        id: UUID
    ) -> ConnectivityState {
        lock.lock()
        continuations[id] = continuation
        let currentState = state
        lock.unlock()
        return currentState
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    private func updateState(_ newState: ConnectivityState) -> [AsyncStream<ConnectivityState>.Continuation] {
        lock.lock()
        state = newState
        let activeContinuations = Array(continuations.values)
        lock.unlock()
        return activeContinuations
    }
}

final class PassiveConnectivityMonitor: ConnectivityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ConnectivityState

    init(initialState: ConnectivityState) {
        self.state = initialState
    }

    var currentState: ConnectivityState {
        get async {
            currentStateValue()
        }
    }

    func states() -> AsyncStream<ConnectivityState> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func set(_ newState: ConnectivityState) {
        lock.lock()
        state = newState
        lock.unlock()
    }

    private func currentStateValue() -> ConnectivityState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

final class ManualLifecycleEvents: AppLifecycleEventProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<AppLifecycleEvent>.Continuation] = [:]

    func events() -> AsyncStream<AppLifecycleEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            addContinuation(continuation, id: id)
            continuation.onTermination = { @Sendable _ in
                self.removeContinuation(id)
            }
        }
    }

    func send(_ event: AppLifecycleEvent) {
        let activeContinuations = currentContinuations()

        for continuation in activeContinuations {
            continuation.yield(event)
        }
    }

    func activeObserverCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    private func addContinuation(_ continuation: AsyncStream<AppLifecycleEvent>.Continuation, id: UUID) {
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    private func currentContinuations() -> [AsyncStream<AppLifecycleEvent>.Continuation] {
        lock.lock()
        defer { lock.unlock() }
        return Array(continuations.values)
    }
}

final class ConfigurableLoginRegistration: LoginRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var status: LaunchAtLoginRegistrationStatus = .disabled
    private var nextError: (any Error)?

    func registrationStatus() async -> LaunchAtLoginRegistrationStatus {
        currentStatus()
    }

    func isLaunchAtLoginEnabled() async throws -> Bool {
        await registrationStatus().isRegistered
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) async throws {
        let error = consumeNextError()
        if let error {
            throw error
        }
        updateStatus(isEnabled ? .enabled : .disabled)
    }

    func failNext(_ error: any Error) {
        lock.lock()
        nextError = error
        lock.unlock()
    }

    private func currentStatus() -> LaunchAtLoginRegistrationStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    private func consumeNextError() -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        let error = nextError
        nextError = nil
        return error
    }

    private func updateStatus(_ status: LaunchAtLoginRegistrationStatus) {
        lock.lock()
        self.status = status
        lock.unlock()
    }
}
