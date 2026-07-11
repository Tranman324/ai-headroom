import Foundation
import AppKit
import SwiftUI

@MainActor
final class UsageMonitorStore: ObservableObject {
    @Published private(set) var snapshot: CombinedUsageSnapshot
    @Published private(set) var settings: MonitorSettings
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginRegistrationStatus
    @Published var navigation: AppNavigationState

    private let dependencies: AppDependencies
    private var coordinator: UsagePollingCoordinator?

    init(
        dependencies: AppDependencies,
        initialSnapshot: CombinedUsageSnapshot = UsageMonitorFixtures.noDataSnapshot,
        settings: MonitorSettings = .defaults,
        navigation: AppNavigationState = AppNavigationState(),
        launchAtLoginStatus: LaunchAtLoginRegistrationStatus = .disabled
    ) {
        self.dependencies = dependencies
        self.snapshot = initialSnapshot
        self.settings = settings
        self.navigation = navigation
        self.launchAtLoginStatus = launchAtLoginStatus
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
        case .pauseAlertsForOneHour:
            var updatedSettings = settings
            updatedSettings.alertPauseExpiration = dependencies.clock.now.addingTimeInterval(60 * 60)
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
}
