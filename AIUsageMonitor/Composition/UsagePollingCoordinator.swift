import Foundation

actor UsagePollingCoordinator {
    enum Trigger: Equatable, Sendable {
        case startup
        case interval
        case manual
        case connectivityRestored
        case workspaceWake
    }

    private struct ProviderPollOutcome: Sendable {
        var provider: ProviderID
        var snapshot: ProviderUsageSnapshot?
        var failure: SanitizedProviderError?
    }

    private let dependencies: AppDependencies
    private let publishSnapshot: @MainActor @Sendable (CombinedUsageSnapshot) -> Void
    private let publishSettings: @MainActor @Sendable (MonitorSettings) -> Void
    private let publishLaunchStatus: @MainActor @Sendable (LaunchAtLoginRegistrationStatus) -> Void

    private var settings: MonitorSettings
    private var currentSnapshot: CombinedUsageSnapshot
    private var started = false
    private var startupGeneration: UInt = 0
    private var isAsleep = false
    private var lastConnectivityState: ConnectivityState = .offline

    private var intervalTask: Task<Void, Never>?
    private var connectivityTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pollInProgress = false
    private var pendingTrigger: Trigger?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        dependencies: AppDependencies,
        initialSnapshot: CombinedUsageSnapshot,
        initialSettings: MonitorSettings,
        publishSnapshot: @escaping @MainActor @Sendable (CombinedUsageSnapshot) -> Void,
        publishSettings: @escaping @MainActor @Sendable (MonitorSettings) -> Void,
        publishLaunchStatus: @escaping @MainActor @Sendable (LaunchAtLoginRegistrationStatus) -> Void
    ) {
        self.dependencies = dependencies
        self.currentSnapshot = initialSnapshot
        self.settings = initialSettings
        self.publishSnapshot = publishSnapshot
        self.publishSettings = publishSettings
        self.publishLaunchStatus = publishLaunchStatus
    }

    func start() async {
        guard !started else {
            return
        }

        started = true
        startupGeneration &+= 1
        let generation = startupGeneration

        let loadedSettings = (try? await dependencies.settingsStore.loadSettings()) ?? .defaults
        guard ownsStartup(generation) else {
            return
        }
        settings = loadedSettings
        await publishSettings(settings)
        guard ownsStartup(generation) else {
            return
        }

        let launchStatus = await dependencies.loginRegistration.registrationStatus()
        guard ownsStartup(generation) else {
            return
        }
        await publishLaunchStatus(launchStatus)
        guard ownsStartup(generation) else {
            return
        }

        await pruneHistory()
        guard ownsStartup(generation) else {
            return
        }

        let recoveredSnapshot = await snapshotRecoveredFromHistory()
        guard ownsStartup(generation) else {
            return
        }
        currentSnapshot = recoveredSnapshot
        await publishSnapshot(recoveredSnapshot)
        guard ownsStartup(generation) else {
            return
        }

        let connectivityState = await dependencies.connectivityMonitor.currentState
        guard ownsStartup(generation) else {
            return
        }
        lastConnectivityState = connectivityState
        startConnectivityObservation()
        startLifecycleObservation()
        restartIntervalLoop()

        if lastConnectivityState == .online {
            await requestPoll(.startup)
        }
    }

    func cancel() {
        started = false
        startupGeneration &+= 1
        intervalTask?.cancel()
        connectivityTask?.cancel()
        lifecycleTask?.cancel()
        pollTask?.cancel()
        intervalTask = nil
        connectivityTask = nil
        lifecycleTask = nil
        pendingTrigger = nil
    }

    func requestPoll(_ trigger: Trigger) async {
        guard started else {
            return
        }
        enqueuePoll(trigger)
        guard pollInProgress else {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func replaceSettings(_ settings: MonitorSettings) {
        self.settings = settings
        if started, !isAsleep {
            restartIntervalLoop()
        }
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) async throws {
        do {
            try await dependencies.loginRegistration.setLaunchAtLoginEnabled(isEnabled)
            let status = await dependencies.loginRegistration.registrationStatus()
            await publishLaunchStatus(status)
        } catch {
            await publishLaunchStatus(.failed(SanitizedProviderError.redacted(error.localizedDescription)))
            throw error
        }
    }

    private func pruneHistory() async {
        let cutoff = dependencies.clock.now.addingTimeInterval(-TimeInterval(settings.historyRetention.days) * 24 * 60 * 60)
        try? await dependencies.historyStore.prune(olderThan: cutoff)
    }

    private func snapshotRecoveredFromHistory() async -> CombinedUsageSnapshot {
        let recovered = (try? await dependencies.historyStore.latestUsableProviderSnapshots()) ?? [:]
        let capturedAt = dependencies.clock.now
        let providers = ProviderID.allCases.map { provider in
            guard let snapshot = recovered[provider], !snapshot.meters.isEmpty else {
                return ProviderUsageSnapshot(provider: provider, meters: [], health: .noData(checkedAt: capturedAt))
            }

            return ProviderUsageSnapshot(
                provider: provider,
                meters: snapshot.meters,
                health: .stale(
                    checkedAt: capturedAt,
                    staleSince: snapshot.health.checkedAt ?? capturedAt,
                    error: snapshot.health.error
                )
            )
        }
        return CombinedUsageSnapshot(capturedAt: capturedAt, providers: providers)
    }

    private func ownsStartup(_ generation: UInt) -> Bool {
        started && startupGeneration == generation
    }

    private func startConnectivityObservation() {
        connectivityTask?.cancel()
        connectivityTask = Task {
            await observeConnectivity()
        }
    }

    private func observeConnectivity() async {
        var previousState = lastConnectivityState
        for await state in dependencies.connectivityMonitor.states() {
            guard !Task.isCancelled else {
                break
            }
            let wasOffline = previousState == .offline
            previousState = state
            lastConnectivityState = state
            if wasOffline, state == .online {
                enqueuePoll(.connectivityRestored)
            }
        }
    }

    private func startLifecycleObservation() {
        lifecycleTask?.cancel()
        lifecycleTask = Task {
            await observeLifecycle()
        }
    }

    private func observeLifecycle() async {
        for await event in dependencies.lifecycleEvents.events() {
            guard !Task.isCancelled else {
                break
            }
            switch event {
            case .workspaceWillSleep:
                isAsleep = true
                intervalTask?.cancel()
                intervalTask = nil
            case .workspaceDidWake:
                isAsleep = false
                if started {
                    restartIntervalLoop()
                }
                enqueuePoll(.workspaceWake)
            case .willTerminate:
                cancel()
            case .didFinishLaunching, .didBecomeActive, .didResignActive:
                continue
            }
        }
    }

    private func restartIntervalLoop() {
        intervalTask?.cancel()
        intervalTask = Task {
            await runIntervalLoop()
        }
    }

    private func runIntervalLoop() async {
        while !Task.isCancelled {
            do {
                try await dependencies.clock.sleep(for: pollIntervalDuration())
            } catch {
                break
            }

            guard !Task.isCancelled, !isAsleep else {
                continue
            }
            enqueuePoll(.interval)
        }
    }

    private func pollIntervalDuration() -> Duration {
        .seconds(Int64(settings.pollingInterval.minutes * 60))
    }

    private func enqueuePoll(_ trigger: Trigger) {
        guard started else {
            return
        }
        if pollInProgress {
            pendingTrigger = mergedPendingTrigger(existing: pendingTrigger, incoming: trigger)
            return
        }

        pollInProgress = true
        pollTask = Task {
            await drainPolls(startingWith: trigger)
        }
    }

    private func mergedPendingTrigger(existing: Trigger?, incoming: Trigger) -> Trigger {
        guard let existing else {
            return incoming
        }
        if existing == .manual || incoming == .manual {
            return .manual
        }
        if existing == .workspaceWake || incoming == .workspaceWake {
            return .workspaceWake
        }
        if existing == .connectivityRestored || incoming == .connectivityRestored {
            return .connectivityRestored
        }
        return incoming
    }

    private func drainPolls(startingWith firstTrigger: Trigger) async {
        var trigger: Trigger? = firstTrigger
        while let currentTrigger = trigger {
            guard !Task.isCancelled else {
                break
            }
            await runPoll(currentTrigger)
            guard !Task.isCancelled else {
                break
            }
            trigger = pendingTrigger
            pendingTrigger = nil
        }

        let restartTrigger = started ? pendingTrigger : nil
        pendingTrigger = nil
        pollInProgress = false
        pollTask = nil

        if let restartTrigger {
            enqueuePoll(restartTrigger)
        } else {
            resumeIdleWaiters()
        }
    }

    private func runPoll(_ trigger: Trigger) async {
        if trigger == .interval, isAsleep {
            return
        }

        let connectivityState = await dependencies.connectivityMonitor.currentState
        lastConnectivityState = connectivityState
        guard connectivityState == .online else {
            return
        }

        let capturedAt = dependencies.clock.now
        let previousSnapshot = currentSnapshot
        let outcomes = await fetchProviderOutcomes(capturedAt: capturedAt)
        guard !Task.isCancelled else {
            return
        }

        var nextProviders = Dictionary(uniqueKeysWithValues: previousSnapshot.providers.map { ($0.provider, $0) })
        for outcome in outcomes.sorted(by: { $0.provider.rawValue < $1.provider.rawValue }) {
            if let snapshot = outcome.snapshot {
                nextProviders[outcome.provider] = snapshot
                try? await dependencies.historyStore.appendProviderSnapshot(snapshot, capturedAt: capturedAt)
            } else if let failure = outcome.failure {
                nextProviders[outcome.provider] = failedSnapshot(
                    provider: outcome.provider,
                    error: failure,
                    previousSnapshot: previousSnapshot,
                    capturedAt: capturedAt
                )
                try? await dependencies.historyStore.appendProviderFailure(
                    provider: outcome.provider,
                    at: capturedAt,
                    error: failure
                )
            }
        }

        let providers = ProviderID.allCases.map { provider in
            nextProviders[provider] ?? ProviderUsageSnapshot(
                provider: provider,
                meters: [],
                health: .noData(checkedAt: capturedAt)
            )
        }
        currentSnapshot = CombinedUsageSnapshot(capturedAt: capturedAt, providers: providers)
        await publishSnapshot(currentSnapshot)
    }

    private func fetchProviderOutcomes(capturedAt: Date) async -> [ProviderPollOutcome] {
        await withTaskGroup(of: ProviderPollOutcome?.self) { group in
            for provider in ProviderID.allCases {
                guard let client = dependencies.providerClient(for: provider) else {
                    continue
                }
                group.addTask {
                    do {
                        let snapshot = try await client.fetchUsageSnapshot()
                        return ProviderPollOutcome(
                            provider: provider,
                            snapshot: ProviderUsageSnapshot(
                                provider: provider,
                                meters: snapshot.meters,
                                health: .fresh(checkedAt: capturedAt)
                            ),
                            failure: nil
                        )
                    } catch {
                        return ProviderPollOutcome(
                            provider: provider,
                            snapshot: nil,
                            failure: Self.sanitizedFailure(for: provider, error: error)
                        )
                    }
                }
            }

            var outcomes: [ProviderPollOutcome] = []
            for await outcome in group {
                if let outcome {
                    outcomes.append(outcome)
                }
            }
            return outcomes
        }
    }

    private func failedSnapshot(
        provider: ProviderID,
        error: SanitizedProviderError,
        previousSnapshot: CombinedUsageSnapshot,
        capturedAt: Date
    ) -> ProviderUsageSnapshot {
        let previousProvider = previousSnapshot.provider(provider)
        guard let previousProvider, !previousProvider.meters.isEmpty else {
            return ProviderUsageSnapshot(
                provider: provider,
                meters: [],
                health: .errored(checkedAt: capturedAt, error: error)
            )
        }

        return ProviderUsageSnapshot(
            provider: provider,
            meters: previousProvider.meters,
            health: .stale(
                checkedAt: capturedAt,
                staleSince: previousProvider.health.staleSince
                    ?? previousProvider.health.checkedAt
                    ?? previousSnapshot.capturedAt,
                error: error
            )
        )
    }

    private static func sanitizedFailure(for provider: ProviderID, error: any Error) -> SanitizedProviderError {
        if let providerFailure = error as? ProviderClientFailure, providerFailure.provider == provider {
            return providerFailure.sanitizedError
        }
        return SanitizedProviderError(
            code: .unknown,
            displayMessage: "Unable to load \(provider.displayName) usage: \(error.localizedDescription)"
        )
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
