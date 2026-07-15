import XCTest
@testable import AIUsageMonitor

@MainActor
final class UsageMonitorStoreTests: XCTestCase {
    func testRefreshRetainsFailedProviderMetersAndUpdatesHealthyPeer() async throws {
        let initialSnapshot = UsageMonitorFixtures.criticalSnapshot
        let updatedCodex = UsageMonitorFixtures.normalSnapshot.provider(.codex)!
        let connectivity = PassiveConnectivityMonitor(initialState: .offline)
        let dependencies = TestDependencyFactory.make(
            providers: [
                SequencedProviderClient(provider: .claude, results: [.failure(TestProviderError.unavailable)]),
                SequencedProviderClient(provider: .codex, results: [.success(updatedCodex)])
            ],
            historyStore: InMemoryHistoryStore(initialSnapshots: [initialSnapshot]),
            clock: ManualClock(now: UsageMonitorFixtures.baseDate.addingTimeInterval(12_345)),
            connectivityMonitor: connectivity
        )
        let store = UsageMonitorStore(dependencies: dependencies, initialSnapshot: initialSnapshot)

        await store.startMonitoring()
        connectivity.set(.online)
        await store.refresh()

        let claude = try XCTUnwrap(store.snapshot.provider(.claude))
        let codex = try XCTUnwrap(store.snapshot.provider(.codex))
        XCTAssertEqual(claude.health.kind, .stale)
        XCTAssertEqual(claude.health.staleSince, initialSnapshot.provider(.claude)?.health.checkedAt)
        XCTAssertNotNil(claude.health.error)
        XCTAssertEqual(claude.meters, initialSnapshot.provider(.claude)?.meters)
        XCTAssertEqual(codex.health.kind, .fresh)
        XCTAssertEqual(codex.meters, updatedCodex.meters)
        await store.stopMonitoring()
    }

    func testRefreshFailureWithoutPriorDataStaysProviderLocalAndEmpty() async throws {
        let updatedCodex = UsageMonitorFixtures.normalSnapshot.provider(.codex)!
        let connectivity = PassiveConnectivityMonitor(initialState: .offline)
        let dependencies = TestDependencyFactory.make(
            providers: [
                SequencedProviderClient(provider: .claude, results: [.failure(TestProviderError.unavailable)]),
                SequencedProviderClient(provider: .codex, results: [.success(updatedCodex)])
            ],
            clock: ManualClock(now: UsageMonitorFixtures.baseDate.addingTimeInterval(12_345)),
            connectivityMonitor: connectivity
        )
        let store = UsageMonitorStore(dependencies: dependencies, initialSnapshot: UsageMonitorFixtures.noDataSnapshot)

        await store.startMonitoring()
        connectivity.set(.online)
        await store.refresh()

        let claude = try XCTUnwrap(store.snapshot.provider(.claude))
        let codex = try XCTUnwrap(store.snapshot.provider(.codex))
        XCTAssertEqual(claude.health.kind, .errored)
        XCTAssertTrue(claude.meters.isEmpty)
        XCTAssertEqual(codex.health.kind, .fresh)
        XCTAssertEqual(codex.meters, updatedCodex.meters)
        await store.stopMonitoring()
    }

    func testDependencyFetchNormalizesProviderResults() async throws {
        let rogueSnapshot = ProviderUsageSnapshot(
            provider: .claude,
            meters: UsageMonitorFixtures.allMeterSnapshots,
            health: .fresh(checkedAt: UsageMonitorFixtures.baseDate)
        )
        let dependencies = TestDependencyFactory.make(
            providers: [
                SequencedProviderClient(provider: .codex, results: [.success(rogueSnapshot)])
            ]
        )

        let snapshot = await dependencies.fetchAllProviderSnapshots()
        let codex = try XCTUnwrap(snapshot.provider(.codex))

        XCTAssertEqual(codex.provider, .codex)
        XCTAssertTrue(codex.meters.allSatisfy { $0.provider == .codex })
    }

    func testAsyncCommandsAwaitInjectedServices() async throws {
        let settingsStore = RecordingSettingsStore()
        let loginRegistration = RecordingLoginRegistration()
        let dependencies = TestDependencyFactory.make(
            settingsStore: settingsStore,
            loginRegistration: loginRegistration
        )
        let store = UsageMonitorStore(dependencies: dependencies)
        let expiration = UsageMonitorFixtures.baseDate.addingTimeInterval(12_345 + 60 * 60)

        try await store.handle(.pauseAlertsForOneHour)
        try await store.handle(.setLaunchAtLogin(true))

        let savedSettings = await settingsStore.savedSettings()
        let requestedLoginValues = await loginRegistration.requestedValues()
        XCTAssertEqual(savedSettings.count, 2)
        XCTAssertEqual(savedSettings.first?.alertPauseExpiration, expiration)
        XCTAssertEqual(savedSettings.last?.launchAtLogin, true)
        XCTAssertEqual(requestedLoginValues, [true])
    }

    func testSettingsCommandsPersistThroughInjectedSettingsStore() async throws {
        let settingsStore = RecordingSettingsStore()
        let dependencies = TestDependencyFactory.make(settingsStore: settingsStore)
        let store = UsageMonitorStore(dependencies: dependencies)

        try await store.handle(.setPollingInterval(try PollingInterval(minutes: 7)))
        try await store.handle(.setAlertThreshold(try AlertThreshold(percentage: 90)))
        try await store.handle(.setHistoryRetention(try HistoryRetention(days: 120)))

        let savedSettings = await settingsStore.savedSettings()
        XCTAssertEqual(savedSettings.count, 3)
        XCTAssertEqual(savedSettings[0].pollingInterval.minutes, 7)
        XCTAssertEqual(savedSettings[1].alertThreshold.percentage, 90)
        XCTAssertEqual(savedSettings[2].historyRetention.days, 120)
        XCTAssertEqual(store.settings.pollingInterval.minutes, 7)
        XCTAssertEqual(store.settings.alertThreshold.percentage, 90)
        XCTAssertEqual(store.settings.historyRetention.days, 120)
    }

    func testProviderAuthenticationUsesInjectedProviderAndExternalURLOpener() async throws {
        let challenge = ProviderAuthenticationChallenge(
            provider: .codex,
            authorizationURL: try XCTUnwrap(URL(string: "https://auth.openai.example/device")),
            userCode: "TEST-1234"
        )
        let provider = AuthenticatingTestProvider(challenge: challenge)
        let urlOpener = RecordingExternalURLOpener()
        let dependencies = TestDependencyFactory.make(
            providers: [provider],
            externalURLOpener: urlOpener
        )
        let store = UsageMonitorStore(dependencies: dependencies)

        try await store.handle(.openSettings)
        try await store.handle(.openProviderConnections)
        try await store.handle(.startProviderAuthentication(.codex))
        let startCount = await provider.authenticationStartCount()
        let openedURLs = await urlOpener.openedURLs()

        XCTAssertTrue(store.navigation.isProviderConnectionsPresented)
        XCTAssertEqual(store.providerAuthenticationChallenge, challenge)
        XCTAssertNil(store.providerConnectionError)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(openedURLs, [challenge.authorizationURL])
    }

    func testDeviceCodeAuthenticationObservesConnectedAccountAndClearsChallenge() async throws {
        let challenge = ProviderAuthenticationChallenge(
            provider: .codex,
            authorizationURL: try XCTUnwrap(URL(string: "https://auth.openai.example/device")),
            userCode: "TEST-1234"
        )
        let provider = AuthenticatingTestProvider(challenge: challenge)
        let dependencies = TestDependencyFactory.make(providers: [provider])
        let store = UsageMonitorStore(
            dependencies: dependencies,
            authenticationObservationInterval: .milliseconds(1),
            authenticationObservationLimit: 10
        )

        try await store.handle(.openProviderConnections)
        try await store.handle(.startProviderAuthentication(.codex))
        for _ in 0 ..< 20 where store.providerAuthenticationChallenge != nil {
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertNil(store.providerAuthenticationChallenge)
        XCTAssertNil(store.providerConnectionError)
        XCTAssertEqual(store.providerConnectionStatuses[.codex]?.state, .connected)
    }

    func testDeviceCodeAuthenticationTimeoutClearsChallengeAndReportsRetry() async throws {
        let challenge = ProviderAuthenticationChallenge(
            provider: .codex,
            authorizationURL: try XCTUnwrap(URL(string: "https://auth.openai.example/device")),
            userCode: "TEST-1234"
        )
        let provider = AuthenticatingTestProvider(challenge: challenge, completesAuthentication: false)
        let dependencies = TestDependencyFactory.make(providers: [provider])
        let store = UsageMonitorStore(
            dependencies: dependencies,
            authenticationObservationInterval: .milliseconds(1),
            authenticationObservationLimit: 1
        )

        try await store.handle(.openProviderConnections)
        try await store.handle(.startProviderAuthentication(.codex))
        for _ in 0 ..< 20 where store.providerAuthenticationChallenge != nil {
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertNil(store.providerAuthenticationChallenge)
        XCTAssertEqual(store.providerConnectionError?.code, .unauthorized)
        XCTAssertEqual(store.providerConnectionStatuses[.codex]?.state, .disconnected)
    }

    func testProviderManagedAuthenticationCompletesWithoutAnAppOwnedURL() async throws {
        let provider = ProviderManagedAuthenticationTestProvider()
        let urlOpener = RecordingExternalURLOpener()
        let dependencies = TestDependencyFactory.make(
            providers: [provider],
            externalURLOpener: urlOpener
        )
        let store = UsageMonitorStore(dependencies: dependencies)

        try await store.handle(.openProviderConnections)
        XCTAssertEqual(store.providerConnectionStatuses[.claude]?.state, .disconnected)

        try await store.handle(.startProviderAuthentication(.claude))
        let startCount = await provider.authenticationStartCount()
        let openedURLs = await urlOpener.openedURLs()

        XCTAssertEqual(store.providerConnectionStatuses[.claude]?.state, .connected)
        XCTAssertNil(store.providerAuthenticationChallenge)
        XCTAssertNil(store.providerConnectionError)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(openedURLs, [])
    }

    func testClosingConnectionsCancelsProviderOwnedAuthenticationProcess() async throws {
        let provider = CancellableAuthenticationTestProvider()
        let dependencies = TestDependencyFactory.make(providers: [provider])
        let store = UsageMonitorStore(dependencies: dependencies)

        try await store.handle(.openProviderConnections)
        let authenticationTask = Task { @MainActor in
            try await store.handle(.startProviderAuthentication(.claude))
        }
        await provider.waitUntilAuthenticationStarted()
        try await store.handle(.closeProviderConnections)
        try await authenticationTask.value
        let wasCancelled = await provider.wasCancelled()

        XCTAssertTrue(wasCancelled)
        XCTAssertTrue(store.authenticatingProviders.isEmpty)
        XCTAssertNil(store.providerConnectionError)
    }

    func testHistoryLoadingUsesInjectedHistoryStore() async throws {
        let historyStore = InMemoryHistoryStore(initialSnapshots: UsageMonitorFixtures.expandedHistorySnapshots)
        let dependencies = TestDependencyFactory.make(historyStore: historyStore)
        let store = UsageMonitorStore(
            dependencies: dependencies,
            initialSnapshot: UsageMonitorFixtures.criticalSnapshot
        )

        await store.loadHistory(since: UsageMonitorFixtures.criticalSnapshot.capturedAt.addingTimeInterval(-UsagePresentation.historyLookback))

        XCTAssertEqual(store.historyLoadState, .loaded)
        XCTAssertFalse(store.historicalSnapshots.isEmpty)
        XCTAssertLessThanOrEqual(store.historicalSnapshots.first?.capturedAt ?? .distantFuture, UsageMonitorFixtures.criticalSnapshot.capturedAt)
    }

    func testCommandCancellationIsCallerOwned() async throws {
        let settingsStore = CancellableSettingsStore()
        let dependencies = TestDependencyFactory.make(settingsStore: settingsStore)
        let store = UsageMonitorStore(dependencies: dependencies)

        let task = Task { @MainActor in
            try await store.handle(.pauseAlertsForOneHour)
        }
        await settingsStore.waitUntilSaveStarted()
        task.cancel()

        do {
            try await task.value
            XCTFail("Cancellation should propagate to the caller-owned task.")
        } catch is CancellationError {
            let wasCancelled = await settingsStore.wasCancelled()
            XCTAssertTrue(wasCancelled)
        }
    }
}

actor SequencedProviderClient: UsageProviderFetching {
    nonisolated let provider: ProviderID
    private var results: [Result<ProviderUsageSnapshot, Error>]

    init(provider: ProviderID, results: [Result<ProviderUsageSnapshot, Error>]) {
        self.provider = provider
        self.results = results
    }

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        let result = results.isEmpty ? .failure(TestProviderError.unavailable) : results.removeFirst()
        return try result.get()
    }
}

private actor AuthenticatingTestProvider:
    UsageProviderFetching,
    ProviderAuthenticationManaging,
    ProviderConnectionChecking
{
    nonisolated let provider: ProviderID = .codex
    private let challenge: ProviderAuthenticationChallenge
    private let completesAuthentication: Bool
    private var starts = 0
    private var authenticationStarted = false

    init(challenge: ProviderAuthenticationChallenge, completesAuthentication: Bool = true) {
        self.challenge = challenge
        self.completesAuthentication = completesAuthentication
    }

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(provider: provider, meters: [], health: .noData())
    }

    func startAuthentication() async throws -> ProviderAuthenticationResult {
        starts += 1
        authenticationStarted = true
        return .challenge(challenge)
    }

    func connectionStatus() async -> ProviderConnectionStatus {
        let isConnected = authenticationStarted && completesAuthentication
        return ProviderConnectionStatus(
            provider: provider,
            state: isConnected ? .connected : .disconnected,
            planName: isConnected ? "Pro 20x" : nil,
            usageSyncEnabled: isConnected,
            detail: isConnected ? "Usage sync enabled" : "Sign in with ChatGPT to read Codex limits."
        )
    }

    func authenticationStartCount() -> Int {
        starts
    }
}

private actor ProviderManagedAuthenticationTestProvider:
    UsageProviderFetching,
    ProviderAuthenticationManaging,
    ProviderConnectionChecking
{
    nonisolated let provider: ProviderID = .claude
    private var isConnected = false
    private var starts = 0

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(provider: provider, meters: [], health: .noData())
    }

    func startAuthentication() async throws -> ProviderAuthenticationResult {
        starts += 1
        isConnected = true
        return .completed
    }

    func connectionStatus() async -> ProviderConnectionStatus {
        ProviderConnectionStatus(
            provider: provider,
            state: isConnected ? .connected : .disconnected,
            planName: isConnected ? "Max" : nil,
            usageSyncEnabled: isConnected,
            detail: isConnected ? "Usage sync enabled" : "Sign in with your Claude subscription."
        )
    }

    func authenticationStartCount() -> Int {
        starts
    }
}

private actor CancellableAuthenticationTestProvider:
    UsageProviderFetching,
    ProviderAuthenticationManaging,
    ProviderConnectionChecking
{
    nonisolated let provider: ProviderID = .claude
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(provider: provider, meters: [], health: .noData())
    }

    func startAuthentication() async throws -> ProviderAuthenticationResult {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        do {
            try await Task.sleep(for: .seconds(30))
            return .completed
        } catch {
            cancelled = Task.isCancelled
            throw error
        }
    }

    func connectionStatus() async -> ProviderConnectionStatus {
        ProviderConnectionStatus(
            provider: provider,
            state: .disconnected,
            planName: nil,
            usageSyncEnabled: false,
            detail: "Sign in with your Claude subscription."
        )
    }

    func waitUntilAuthenticationStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}

private actor RecordingExternalURLOpener: ExternalURLOpening {
    private var opened: [URL] = []

    func open(_ url: URL) async {
        opened.append(url)
    }

    func openedURLs() -> [URL] {
        opened
    }
}

enum TestProviderError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "usage endpoint unavailable"
    }
}

enum TestDependencyFactory {
    static func make(
        providers: [any UsageProviderFetching] = [
            FixtureProviderClient(snapshot: UsageMonitorFixtures.normalSnapshot.provider(.claude)!),
            FixtureProviderClient(snapshot: UsageMonitorFixtures.normalSnapshot.provider(.codex)!)
        ],
        historyStore: any HistoryStoring = InMemoryHistoryStore(),
        settingsStore: any SettingsStoring = RecordingSettingsStore(),
        clock: any ClockProviding = FixedClock(now: UsageMonitorFixtures.baseDate.addingTimeInterval(12_345)),
        connectivityMonitor: any ConnectivityMonitoring = StaticConnectivityMonitor(state: .online),
        loginRegistration: any LoginRegistering = RecordingLoginRegistration(),
        externalURLOpener: any ExternalURLOpening = NoopExternalURLOpener()
    ) -> AppDependencies {
        AppDependencies(
            providers: providers,
            historyStore: historyStore,
            settingsStore: settingsStore,
            clock: clock,
            connectivityMonitor: connectivityMonitor,
            lifecycleEvents: NoopLifecycleEvents(),
            loginRegistration: loginRegistration,
            externalURLOpener: externalURLOpener
        )
    }
}

actor RecordingSettingsStore: SettingsStoring {
    private var currentSettings: MonitorSettings = .defaults
    private var saved: [MonitorSettings] = []

    func loadSettings() async throws -> MonitorSettings {
        currentSettings
    }

    func saveSettings(_ settings: MonitorSettings) async throws {
        currentSettings = settings
        saved.append(settings)
    }

    func savedSettings() -> [MonitorSettings] {
        saved
    }
}

actor RecordingLoginRegistration: LoginRegistering {
    private var values: [Bool] = []

    func registrationStatus() async -> LaunchAtLoginRegistrationStatus {
        (values.last ?? false) ? .enabled : .disabled
    }

    func isLaunchAtLoginEnabled() async throws -> Bool {
        values.last ?? false
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) async throws {
        values.append(isEnabled)
    }

    func requestedValues() -> [Bool] {
        values
    }
}

actor CancellableSettingsStore: SettingsStoring {
    private var didStart = false
    private var didCancel = false
    private var continuation: CheckedContinuation<Void, Never>?

    func loadSettings() async throws -> MonitorSettings {
        .defaults
    }

    func saveSettings(_ settings: MonitorSettings) async throws {
        didStart = true
        continuation?.resume()
        continuation = nil

        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            didCancel = Task.isCancelled
            throw error
        }
    }

    func waitUntilSaveStarted() async {
        if didStart {
            return
        }

        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func wasCancelled() -> Bool {
        didCancel
    }
}
