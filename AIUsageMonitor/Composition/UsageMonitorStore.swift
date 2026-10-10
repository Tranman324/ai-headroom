import Foundation
import AppKit
import SwiftUI

enum HistoryLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class UsageMonitorStore: ObservableObject {
    @Published private(set) var snapshot: CombinedUsageSnapshot
    @Published private(set) var settings: MonitorSettings
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginRegistrationStatus
    @Published private(set) var historicalSnapshots: [CombinedUsageSnapshot]
    @Published private(set) var historyLoadState: HistoryLoadState
    @Published private(set) var providerAuthenticationChallenge: ProviderAuthenticationChallenge?
    @Published private(set) var providerConnectionError: SanitizedProviderError?
    @Published private(set) var providerConnectionStatuses: [ProviderID: ProviderConnectionStatus]
    @Published private(set) var authenticatingProviders: Set<ProviderID>
    @Published var navigation: AppNavigationState

    private let dependencies: AppDependencies
    private let authenticationObservationInterval: Duration
    private let authenticationObservationLimit: Int
    private var coordinator: UsagePollingCoordinator?
    private var authenticationObservationTask: Task<Void, Never>?
    private var providerAuthenticationTask: Task<Void, Never>?
    private var providerAuthenticationTaskToken: UUID?

    init(
        dependencies: AppDependencies,
        initialSnapshot: CombinedUsageSnapshot = UsageMonitorFixtures.noDataSnapshot,
        settings: MonitorSettings = .defaults,
        historicalSnapshots: [CombinedUsageSnapshot] = [],
        navigation: AppNavigationState = AppNavigationState(),
        launchAtLoginStatus: LaunchAtLoginRegistrationStatus = .disabled,
        authenticationObservationInterval: Duration = .seconds(2),
        authenticationObservationLimit: Int = 150
    ) {
        self.dependencies = dependencies
        self.snapshot = initialSnapshot
        self.settings = settings
        self.historicalSnapshots = historicalSnapshots
        self.historyLoadState = .idle
        self.providerAuthenticationChallenge = nil
        self.providerConnectionError = nil
        self.providerConnectionStatuses = Self.initialConnectionStatuses(from: initialSnapshot)
        self.authenticatingProviders = []
        self.navigation = navigation
        self.launchAtLoginStatus = launchAtLoginStatus
        self.authenticationObservationInterval = authenticationObservationInterval
        self.authenticationObservationLimit = authenticationObservationLimit
        self.coordinator = UsagePollingCoordinator(
            dependencies: dependencies,
            initialSnapshot: initialSnapshot,
            initialSettings: settings,
            publishSnapshot: { [weak self] snapshot in
                self?.snapshot = snapshot
            },
            publishSettings: { [weak self] settings in
                self?.settings = settings
            },
            publishLaunchStatus: { [weak self] status in
                self?.launchAtLoginStatus = status
            }
        )
    }

    func startMonitoring() async {
        await coordinator?.start()
    }

    func stopMonitoring() async {
        await coordinator?.cancel()
    }

    func refresh() async {
        await coordinator?.requestPoll(.manual)
    }

    func loadSettings() async throws {
        let loadedSettings = try await dependencies.settingsStore.loadSettings()
        settings = loadedSettings
        await coordinator?.replaceSettings(loadedSettings)
    }

    func loadHistory(since startDate: Date) async {
        historyLoadState = .loading

        do {
            let snapshots = try await dependencies.historyStore.snapshots(since: startDate)
            try Task.checkCancellation()
            historicalSnapshots = snapshots
            historyLoadState = .loaded
        } catch is CancellationError {
            historyLoadState = .idle
        } catch {
            historicalSnapshots = []
            historyLoadState = .failed("History unavailable")
        }
    }

    func handle(_ command: AppIntentCommand) async throws {
        switch command {
        case .refresh:
            await refresh()
        case .openSettings:
            navigation.isSettingsPresented = true
        case .closeSettings:
            navigation.isSettingsPresented = false
            navigation.isProviderConnectionsPresented = false
            providerAuthenticationChallenge = nil
            providerConnectionError = nil
            authenticationObservationTask?.cancel()
            authenticationObservationTask = nil
            cancelProviderAuthentication()
        case .showProviderConnections:
            navigation.isSettingsPresented = true
            navigation.isProviderConnectionsPresented = true
            providerAuthenticationChallenge = nil
            providerConnectionError = nil
            await refreshProviderConnections()
        case .openProviderConnections:
            navigation.isProviderConnectionsPresented = true
            providerAuthenticationChallenge = nil
            providerConnectionError = nil
            await refreshProviderConnections()
        case .closeProviderConnections:
            navigation.isProviderConnectionsPresented = false
            providerAuthenticationChallenge = nil
            providerConnectionError = nil
            authenticationObservationTask?.cancel()
            authenticationObservationTask = nil
            cancelProviderAuthentication()
        case let .startProviderAuthentication(provider):
            await runProviderAuthentication(provider)
        case let .showMeterDetail(kind):
            navigation.meterRoute = .detail(kind)
        case .backFromMeterDetail:
            navigation.meterRoute = .list
        case let .setMeterDetailRange(range):
            navigation.detailRange = range
        case let .setHistoryExpanded(isExpanded):
            navigation.isHistoryExpanded = isExpanded
        case .pauseAlertsForOneHour:
            var updatedSettings = settings
            updatedSettings.alertPauseExpiration = dependencies.clock.now.addingTimeInterval(60 * 60)
            try await dependencies.settingsStore.saveSettings(updatedSettings)
            settings = updatedSettings
            await coordinator?.replaceSettings(updatedSettings)
        case let .setPollingInterval(interval):
            var updatedSettings = settings
            updatedSettings.pollingInterval = interval
            try await dependencies.settingsStore.saveSettings(updatedSettings)
            settings = updatedSettings
            await coordinator?.replaceSettings(updatedSettings)
        case let .setAlertThreshold(threshold):
            var updatedSettings = settings
            updatedSettings.alertThreshold = threshold
            try await dependencies.settingsStore.saveSettings(updatedSettings)
            settings = updatedSettings
            await coordinator?.replaceSettings(updatedSettings)
        case let .setHistoryRetention(retention):
            var updatedSettings = settings
            updatedSettings.historyRetention = retention
            try await dependencies.settingsStore.saveSettings(updatedSettings)
            settings = updatedSettings
            await coordinator?.replaceSettings(updatedSettings)
        case let .setLaunchAtLogin(isEnabled):
            try await coordinator?.setLaunchAtLoginEnabled(isEnabled)
            var updatedSettings = settings
            updatedSettings.launchAtLogin = isEnabled
            try await dependencies.settingsStore.saveSettings(updatedSettings)
            settings = updatedSettings
            await coordinator?.replaceSettings(updatedSettings)
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    private func runProviderAuthentication(_ provider: ProviderID) async {
        providerAuthenticationTask?.cancel()
        let token = UUID()
        providerAuthenticationTaskToken = token
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performProviderAuthentication(provider)
        }
        providerAuthenticationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if providerAuthenticationTaskToken == token {
            providerAuthenticationTask = nil
            providerAuthenticationTaskToken = nil
        }
    }

    private func performProviderAuthentication(_ provider: ProviderID) async {
        guard let authentication = dependencies.providerAuthentication(for: provider) else {
            providerConnectionError = SanitizedProviderError(
                code: .unavailable,
                displayMessage: "\(provider.displayName) sign-in is not available."
            )
            return
        }

        authenticatingProviders.insert(provider)
        providerConnectionError = nil
        defer {
            authenticatingProviders.remove(provider)
        }

        do {
            switch try await authentication.startAuthentication() {
            case let .challenge(challenge):
                providerAuthenticationChallenge = challenge
                providerConnectionStatuses[provider] = .checking(provider)
                await dependencies.externalURLOpener.open(challenge.authorizationURL)
                observeAuthenticationCompletion(for: provider)
            case .completed:
                providerAuthenticationChallenge = nil
                await refreshProviderConnection(provider)
                await refresh()
            }
        } catch is CancellationError {
            return
        } catch let failure as ProviderClientFailure {
            providerConnectionError = failure.sanitizedError
        } catch {
            providerConnectionError = SanitizedProviderError(
                code: .unavailable,
                displayMessage: "Unable to start \(provider.displayName) sign-in."
            )
        }
    }

    private func cancelProviderAuthentication() {
        providerAuthenticationTask?.cancel()
        providerAuthenticationTask = nil
        providerAuthenticationTaskToken = nil
        authenticatingProviders.removeAll()
    }

    private func refreshProviderConnections() async {
        for provider in ProviderID.allCases {
            providerConnectionStatuses[provider] = .checking(provider)
        }
        await withTaskGroup(of: ProviderConnectionStatus.self) { group in
            for provider in ProviderID.allCases {
                guard let checker = dependencies.providerConnectionChecking(for: provider) else {
                    group.addTask {
                        ProviderConnectionStatus(
                            provider: provider,
                            state: .unavailable,
                            planName: nil,
                            usageSyncEnabled: nil,
                            detail: "Connection status is unavailable."
                        )
                    }
                    continue
                }
                group.addTask {
                    await checker.connectionStatus()
                }
            }
            for await status in group {
                providerConnectionStatuses[status.provider] = status
            }
        }
    }

    private func refreshProviderConnection(_ provider: ProviderID) async {
        guard let checker = dependencies.providerConnectionChecking(for: provider) else {
            providerConnectionStatuses[provider] = ProviderConnectionStatus(
                provider: provider,
                state: .unavailable,
                planName: nil,
                usageSyncEnabled: nil,
                detail: "Connection status is unavailable."
            )
            return
        }
        providerConnectionStatuses[provider] = .checking(provider)
        providerConnectionStatuses[provider] = await checker.connectionStatus()
    }

    private func observeAuthenticationCompletion(for provider: ProviderID) {
        authenticationObservationTask?.cancel()
        let observationInterval = authenticationObservationInterval
        let observationLimit = authenticationObservationLimit
        authenticationObservationTask = Task { @MainActor [weak self] in
            for _ in 0 ..< observationLimit {
                do {
                    try await Task.sleep(for: observationInterval)
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                await self.refreshProviderConnection(provider)
                if self.providerConnectionStatuses[provider]?.state == .connected {
                    self.providerAuthenticationChallenge = nil
                    await self.refresh()
                    return
                }
            }
            guard let self else {
                return
            }
            guard self.providerAuthenticationChallenge?.provider == provider else {
                return
            }
            self.providerAuthenticationChallenge = nil
            self.providerConnectionError = SanitizedProviderError(
                code: .unauthorized,
                displayMessage: "\(provider.displayName) sign-in did not complete. Try again."
            )
        }
    }

    private static func initialConnectionStatuses(
        from snapshot: CombinedUsageSnapshot
    ) -> [ProviderID: ProviderConnectionStatus] {
        Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { provider in
            guard let providerSnapshot = snapshot.provider(provider),
                  !providerSnapshot.meters.isEmpty else {
                return (provider, .unknown(provider))
            }
            return (
                provider,
                ProviderConnectionStatus(
                    provider: provider,
                    state: .connected,
                    planName: providerSnapshot.meters.first?.display.planName,
                    usageSyncEnabled: true,
                    detail: "Usage sync enabled"
                )
            )
        })
    }
}
