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
    private var storedRecords: [UsageHistoryRecord]

    init(initialSnapshots: [CombinedUsageSnapshot] = []) {
        self.storedRecords = initialSnapshots.map { .combinedSnapshot(CombinedSnapshotHistoryRecord(snapshot: $0)) }
    }

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
        storedRecords
            .filter { $0.timestamp >= startDate }
            .sorted { lhs, rhs in
                lhs.timestamp < rhs.timestamp
            }
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
        var latestByProvider: [ProviderID: ProviderUsageSnapshot] = [:]
        for record in try await records(since: .distantPast) {
            switch record {
            case let .combinedSnapshot(snapshotRecord):
                for providerSnapshot in snapshotRecord.snapshot.providers where providerSnapshot.hasLastKnownGoodData {
                    latestByProvider[providerSnapshot.provider] = providerSnapshot
                }
            case let .providerSnapshot(snapshotRecord):
                if snapshotRecord.snapshot.hasLastKnownGoodData {
                    latestByProvider[snapshotRecord.provider] = snapshotRecord.snapshot
                }
            case .providerFailure:
                continue
            }
        }
        return latestByProvider
    }

    func prune(olderThan cutoffDate: Date) async throws {
        storedRecords.removeAll { $0.timestamp < cutoffDate }
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
    func registrationStatus() async -> LaunchAtLoginRegistrationStatus {
        .disabled
    }

    func isLaunchAtLoginEnabled() async throws -> Bool {
        false
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) async throws {}
}
