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
        let history = RecordingHistoryStore()
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
            initialSnapshot: UsageMonitorFixtures.criticalSnapshot
        )

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
    }

    func testStateUpdatesWhenProviderHistoryAppendFails() async throws {
        let history = RecordingHistoryStore(failingOperations: [.appendProviderSnapshot])
        let store = makeStore(
            providers: [
                RecordingProviderClient(
                    provider: .claude,
                    results: [.success(try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude)))]
                )
            ],
            historyStore: history
        )

        await store.refresh()

        let failedAppendAttempts = await history.failedAppendAttempts()
        XCTAssertEqual(store.snapshot.provider(.claude)?.health.kind, .fresh)
        XCTAssertEqual(failedAppendAttempts, 1)
    }

    func testConcurrentManualRefreshesCoalesceWithoutOverlappingPollCycles() async throws {
        let provider = BlockingProviderClient(
            provider: .claude,
            snapshots: [
                try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude)),
                try XCTUnwrap(UsageMonitorFixtures.warningSnapshot.provider(.claude))
            ]
        )
        let store = makeStore(providers: [provider])

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
    }

    func testFailedPollDoesNotRetryImmediately() async throws {
        let provider = RecordingProviderClient(
            provider: .claude,
            results: [.failure(ProviderClientFailure.transport(provider: .claude))]
        )
        let store = makeStore(providers: [provider])

        await store.refresh()

        let fetchCount = await provider.fetchCount()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(store.snapshot.provider(.claude)?.health.kind, .errored)
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

    func testCancellingActivePollDropsLateProviderResultAndHistoryWrite() async throws {
        let history = RecordingHistoryStore()
        let provider = BlockingProviderClient(
            provider: .claude,
            snapshots: [try XCTUnwrap(UsageMonitorFixtures.normalSnapshot.provider(.claude))]
        )
        let store = makeStore(
            providers: [provider],
            historyStore: history
        )

        let refresh = Task { @MainActor in
            await store.refresh()
        }
        await provider.waitForFetchCount(1)
        await store.stopMonitoring()
        await refresh.value

        await provider.releaseOne()
        await provider.waitUntilIdle()
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
                loginRegistration: loginRegistration
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
    }

    func appendedRecords() -> [UsageHistoryRecord] {
        storedRecords
    }

    func pruneCount() -> Int {
        prunes
    }

    func failedAppendAttempts() -> Int {
        failedAppends
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
