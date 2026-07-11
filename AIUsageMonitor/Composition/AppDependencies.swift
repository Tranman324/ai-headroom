import Foundation

struct AppDependencies: Sendable {
    private var providersByID: [ProviderID: any UsageProviderFetching]

    var historyStore: any HistoryStoring
    var settingsStore: any SettingsStoring
    var clock: any ClockProviding
    var connectivityMonitor: any ConnectivityMonitoring
    var lifecycleEvents: any AppLifecycleEventProviding
    var loginRegistration: any LoginRegistering

    init(
        providers: [any UsageProviderFetching],
        historyStore: any HistoryStoring,
        settingsStore: any SettingsStoring,
        clock: any ClockProviding,
        connectivityMonitor: any ConnectivityMonitoring,
        lifecycleEvents: any AppLifecycleEventProviding,
        loginRegistration: any LoginRegistering
    ) {
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider, $0) })
        self.historyStore = historyStore
        self.settingsStore = settingsStore
        self.clock = clock
        self.connectivityMonitor = connectivityMonitor
        self.lifecycleEvents = lifecycleEvents
        self.loginRegistration = loginRegistration
    }

    var configuredProviders: [ProviderID] {
        ProviderID.allCases.filter { providersByID[$0] != nil }
    }

    func providerClient(for provider: ProviderID) -> (any UsageProviderFetching)? {
        providersByID[provider]
    }

    func fetchAllProviderSnapshots() async -> CombinedUsageSnapshot {
        let snapshots = await withTaskGroup(of: ProviderUsageSnapshot.self) { group in
            for provider in ProviderID.allCases {
                guard let client = providersByID[provider] else {
                    continue
                }
                group.addTask {
                    do {
                        return try await client.fetchUsageSnapshot()
                    } catch {
                        let sanitizedError = SanitizedProviderError(
                            code: .unknown,
                            displayMessage: "Unable to load \(provider.displayName) usage."
                        )
                        return ProviderUsageSnapshot(
                            provider: provider,
                            meters: [],
                            health: .errored(checkedAt: clock.now, error: sanitizedError)
                        )
                    }
                }
            }

            var collected: [ProviderUsageSnapshot] = []
            for await snapshot in group {
                collected.append(snapshot)
            }
            return collected.sorted { $0.provider.rawValue < $1.provider.rawValue }
        }

        return CombinedUsageSnapshot(capturedAt: clock.now, providers: snapshots)
    }
}
