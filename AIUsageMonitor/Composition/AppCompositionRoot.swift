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
            connectivityMonitor: NetworkPathConnectivityMonitor(),
            lifecycleEvents: WorkspaceLifecycleEvents(),
            loginRegistration: ServiceManagementLoginRegistration(),
            externalURLOpener: WorkspaceExternalURLOpener()
        )
    }

    static func fixture(
        snapshot: CombinedUsageSnapshot = UsageMonitorFixtures.criticalSnapshot,
        historySnapshots: [CombinedUsageSnapshot]? = nil,
        settings: MonitorSettings = .defaults
    ) -> AppDependencies {
        let providers = ProviderID.allCases.compactMap { provider -> FixtureProviderClient? in
            guard let providerSnapshot = snapshot.provider(provider) else {
                return nil
            }
            return FixtureProviderClient(snapshot: providerSnapshot)
        }

        return AppDependencies(
            providers: providers,
            historyStore: InMemoryHistoryStore(initialSnapshots: historySnapshots ?? [snapshot]),
            settingsStore: InMemorySettingsStore(initialSettings: settings),
            clock: FixedClock(now: snapshot.capturedAt),
            connectivityMonitor: StaticConnectivityMonitor(state: .online),
            lifecycleEvents: NoopLifecycleEvents(),
            loginRegistration: UnsupportedLoginRegistration(),
            externalURLOpener: NoopExternalURLOpener()
        )
    }
}
