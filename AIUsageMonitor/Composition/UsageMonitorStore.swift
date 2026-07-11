import Foundation
import AppKit
import SwiftUI

@MainActor
final class UsageMonitorStore: ObservableObject {
    @Published private(set) var snapshot: CombinedUsageSnapshot
    @Published private(set) var settings: MonitorSettings
    @Published var navigation: AppNavigationState

    private let dependencies: AppDependencies

    init(
        dependencies: AppDependencies,
        initialSnapshot: CombinedUsageSnapshot = UsageMonitorFixtures.noDataSnapshot,
        settings: MonitorSettings = .defaults,
        navigation: AppNavigationState = AppNavigationState()
    ) {
        self.dependencies = dependencies
        self.snapshot = initialSnapshot
        self.settings = settings
        self.navigation = navigation
    }

    func refresh() async {
        snapshot = await dependencies.fetchAllProviderSnapshots(previousSnapshot: snapshot)
    }

    func loadSettings() async throws {
        settings = try await dependencies.settingsStore.loadSettings()
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
        case let .setHistoryExpanded(isExpanded):
            navigation.isHistoryExpanded = isExpanded
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
