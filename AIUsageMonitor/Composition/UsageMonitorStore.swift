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
    @Published private(set) var historicalSnapshots: [CombinedUsageSnapshot]
    @Published private(set) var historyLoadState: HistoryLoadState
    @Published var navigation: AppNavigationState

    private let dependencies: AppDependencies

    init(
        dependencies: AppDependencies,
        initialSnapshot: CombinedUsageSnapshot = UsageMonitorFixtures.noDataSnapshot,
        settings: MonitorSettings = .defaults,
        historicalSnapshots: [CombinedUsageSnapshot] = [],
        navigation: AppNavigationState = AppNavigationState()
    ) {
        self.dependencies = dependencies
        self.snapshot = initialSnapshot
        self.settings = settings
        self.historicalSnapshots = historicalSnapshots
        self.historyLoadState = .idle
        self.navigation = navigation
    }

    func refresh() async {
        snapshot = await dependencies.fetchAllProviderSnapshots(previousSnapshot: snapshot)
    }

    func loadSettings() async throws {
        settings = try await dependencies.settingsStore.loadSettings()
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
        case let .showMeterDetail(kind):
            navigation.meterRoute = .detail(kind)
        case .backFromMeterDetail:
            navigation.meterRoute = .list
        case let .setMeterDetailRange(range):
            navigation.detailRange = range
        case let .setHistoryExpanded(isExpanded):
            navigation.isHistoryExpanded = isExpanded
        case let .setPollingInterval(interval):
            settings.pollingInterval = interval
            try await dependencies.settingsStore.saveSettings(settings)
        case let .setAlertThreshold(threshold):
            settings.alertThreshold = threshold
            try await dependencies.settingsStore.saveSettings(settings)
        case let .setHistoryRetention(retention):
            settings.historyRetention = retention
            try await dependencies.settingsStore.saveSettings(settings)
        case let .pauseAlerts(expiration):
            settings.alertPauseExpiration = expiration
            try await dependencies.settingsStore.saveSettings(settings)
        case let .setLaunchAtLogin(isEnabled):
            settings.launchAtLogin = isEnabled
            try await dependencies.loginRegistration.setLaunchAtLoginEnabled(isEnabled)
            try await dependencies.settingsStore.saveSettings(settings)
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }
}
