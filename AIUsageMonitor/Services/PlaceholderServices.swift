import Foundation

struct PlaceholderProviderClient: UsageProviderFetching {
    let provider: ProviderID

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(provider: provider, meters: [], health: .noData())
    }
}

struct FixtureProviderClient: UsageProviderFetching {
    let snapshot: ProviderUsageSnapshot

    var provider: ProviderID {
        snapshot.provider
    }

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        snapshot
    }
}

actor InMemoryHistoryStore: HistoryStoring {
    private var storedSnapshots: [CombinedUsageSnapshot]

    init(initialSnapshots: [CombinedUsageSnapshot] = []) {
        self.storedSnapshots = initialSnapshots
    }

    func append(_ snapshot: CombinedUsageSnapshot) async throws {
        storedSnapshots.append(snapshot)
    }

    func snapshots(since startDate: Date) async throws -> [CombinedUsageSnapshot] {
        storedSnapshots.filter { $0.capturedAt >= startDate }
    }

    func prune(olderThan cutoffDate: Date) async throws {
        storedSnapshots.removeAll { $0.capturedAt < cutoffDate }
    }
}

actor InMemorySettingsStore: SettingsStoring {
    private var currentSettings: MonitorSettings

    init(initialSettings: MonitorSettings) {
        self.currentSettings = initialSettings
    }

    func loadSettings() async throws -> MonitorSettings {
        currentSettings
    }

    func saveSettings(_ settings: MonitorSettings) async throws {
        currentSettings = settings
    }
}

struct FixedClock: ClockProviding {
    let now: Date

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
    }
}

struct SystemClock: ClockProviding {
    var now: Date {
        Date()
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct StaticConnectivityMonitor: ConnectivityMonitoring {
    let state: ConnectivityState

    var currentState: ConnectivityState {
        get async { state }
    }

    func states() -> AsyncStream<ConnectivityState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }
}

struct NoopLifecycleEvents: AppLifecycleEventProviding {
    func events() -> AsyncStream<AppLifecycleEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

struct UnsupportedLoginRegistration: LoginRegistering {
    func isLaunchAtLoginEnabled() async throws -> Bool {
        false
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) async throws {}
}
