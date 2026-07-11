import Foundation

enum AppCompositionRoot {
    static func production() -> AppDependencies {
        AppDependencies(
            providers: [
                ClaudeUsageProvider(),
                CodexUsageProvider()
            ],
            historyStore: LocalHistoryStore(),
            settingsStore: LocalSettingsStore(),
            clock: SystemClock(),
            connectivityMonitor: StaticConnectivityMonitor(state: .online),
            lifecycleEvents: NoopLifecycleEvents(),
            loginRegistration: UnsupportedLoginRegistration()
        )
    }

    static func fixture(snapshot: CombinedUsageSnapshot = UsageMonitorFixtures.criticalSnapshot) -> AppDependencies {
        let providers = ProviderID.allCases.compactMap { provider -> FixtureProviderClient? in
            guard let providerSnapshot = snapshot.provider(provider) else {
                return nil
            }
            return FixtureProviderClient(snapshot: providerSnapshot)
        }

        return AppDependencies(
            providers: providers,
            historyStore: InMemoryHistoryStore(initialSnapshots: [snapshot]),
            settingsStore: InMemorySettingsStore(initialSettings: .defaults),
            clock: FixedClock(now: snapshot.capturedAt),
            connectivityMonitor: StaticConnectivityMonitor(state: .online),
            lifecycleEvents: NoopLifecycleEvents(),
            loginRegistration: UnsupportedLoginRegistration()
        )
    }
}
