import Foundation

struct AppDependencies: Sendable {
    private var providersByID: [ProviderID: any UsageProviderFetching]
    private var authenticationByID: [ProviderID: any ProviderAuthenticationManaging]
    private var connectionCheckingByID: [ProviderID: any ProviderConnectionChecking]

    var historyStore: any HistoryStoring
    var settingsStore: any SettingsStoring
    var clock: any ClockProviding
    var connectivityMonitor: any ConnectivityMonitoring
    var lifecycleEvents: any AppLifecycleEventProviding
    var loginRegistration: any LoginRegistering
    var externalURLOpener: any ExternalURLOpening

    init(
        providers: [any UsageProviderFetching],
        historyStore: any HistoryStoring,
        settingsStore: any SettingsStoring,
        clock: any ClockProviding,
        connectivityMonitor: any ConnectivityMonitoring,
        lifecycleEvents: any AppLifecycleEventProviding,
        loginRegistration: any LoginRegistering,
        externalURLOpener: any ExternalURLOpening
    ) {
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider, $0) })
        self.authenticationByID = Dictionary(
            uniqueKeysWithValues: providers.compactMap { provider in
                guard let authentication = provider as? any ProviderAuthenticationManaging else {
                    return nil
                }
                return (authentication.provider, authentication)
            }
        )
        self.connectionCheckingByID = Dictionary(
            uniqueKeysWithValues: providers.compactMap { provider in
                guard let connectionChecking = provider as? any ProviderConnectionChecking else {
                    return nil
                }
                return (connectionChecking.provider, connectionChecking)
            }
        )
        self.historyStore = historyStore
        self.settingsStore = settingsStore
        self.clock = clock
        self.connectivityMonitor = connectivityMonitor
        self.lifecycleEvents = lifecycleEvents
        self.loginRegistration = loginRegistration
        self.externalURLOpener = externalURLOpener
    }

    var configuredProviders: [ProviderID] {
        ProviderID.allCases.filter { providersByID[$0] != nil }
    }

    func providerClient(for provider: ProviderID) -> (any UsageProviderFetching)? {
        providersByID[provider]
    }

    func providerAuthentication(for provider: ProviderID) -> (any ProviderAuthenticationManaging)? {
        authenticationByID[provider]
    }

    func providerConnectionChecking(for provider: ProviderID) -> (any ProviderConnectionChecking)? {
        connectionCheckingByID[provider]
    }

    func fetchAllProviderSnapshots(previousSnapshot: CombinedUsageSnapshot? = nil) async -> CombinedUsageSnapshot {
        let checkedAt = clock.now
        let snapshots = await withTaskGroup(of: ProviderUsageSnapshot.self) { group in
            for provider in ProviderID.allCases {
                guard let client = providersByID[provider] else {
                    continue
                }
                group.addTask {
                    do {
                        let snapshot = try await client.fetchUsageSnapshot()
                        return ProviderUsageSnapshot(
                            provider: provider,
                            meters: snapshot.meters,
                            health: snapshot.health
                        )
                    } catch {
                        return failedProviderSnapshot(
                            provider: provider,
                            error: error,
                            previousSnapshot: previousSnapshot,
                            checkedAt: checkedAt
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

    private func failedProviderSnapshot(
        provider: ProviderID,
        error: any Error,
        previousSnapshot: CombinedUsageSnapshot?,
        checkedAt: Date
    ) -> ProviderUsageSnapshot {
        let sanitizedError: SanitizedProviderError
        if let providerFailure = error as? ProviderClientFailure, providerFailure.provider == provider {
            sanitizedError = providerFailure.sanitizedError
        } else {
            sanitizedError = SanitizedProviderError(
                code: .unknown,
                displayMessage: "Unable to load \(provider.displayName) usage: \(error.localizedDescription)"
            )
        }
        let previousProvider = previousSnapshot?.provider(provider)
        let previousMeters = previousProvider?.meters ?? []

        guard !previousMeters.isEmpty else {
            return ProviderUsageSnapshot(
                provider: provider,
                meters: [],
                health: .errored(checkedAt: checkedAt, error: sanitizedError)
            )
        }

        return ProviderUsageSnapshot(
            provider: provider,
            meters: previousMeters,
            health: .stale(
                checkedAt: checkedAt,
                staleSince: previousProvider?.health.checkedAt ?? previousSnapshot?.capturedAt ?? checkedAt,
                error: sanitizedError
            )
        )
    }
}
