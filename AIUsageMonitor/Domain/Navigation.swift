import Foundation

enum MeterDetailRoute: Codable, Equatable, Sendable {
    case list
    case detail(MeterKind)
}

enum MeterDetailRange: String, CaseIterable, Codable, Equatable, Sendable {
    case twentyFourHours = "24h"
    case threeDays = "3d"
    case sevenDays = "7d"

    var duration: TimeInterval {
        switch self {
        case .twentyFourHours:
            return 24 * 60 * 60
        case .threeDays:
            return 3 * 24 * 60 * 60
        case .sevenDays:
            return 7 * 24 * 60 * 60
        }
    }
}

struct AppNavigationState: Codable, Equatable, Sendable {
    var meterRoute: MeterDetailRoute
    var isSettingsPresented: Bool
    var isProviderConnectionsPresented: Bool
    var isHistoryExpanded: Bool
    var detailRange: MeterDetailRange

    init(
        meterRoute: MeterDetailRoute = .list,
        isSettingsPresented: Bool = false,
        isProviderConnectionsPresented: Bool = false,
        isHistoryExpanded: Bool = false,
        detailRange: MeterDetailRange = .sevenDays
    ) {
        self.meterRoute = meterRoute
        self.isSettingsPresented = isSettingsPresented
        self.isProviderConnectionsPresented = isProviderConnectionsPresented
        self.isHistoryExpanded = isHistoryExpanded
        self.detailRange = detailRange
    }
}

enum AppIntentCommand: Codable, Equatable, Sendable {
    case refresh
    case openSettings
    case closeSettings
    case openProviderConnections
    /// Jumps from the usage list straight to Connections, where sign-in shows its code and progress.
    case showProviderConnections
    case closeProviderConnections
    case startProviderAuthentication(ProviderID)
    case showMeterDetail(MeterKind)
    case backFromMeterDetail
    case setMeterDetailRange(MeterDetailRange)
    case setHistoryExpanded(Bool)
    case pauseAlertsForOneHour
    case setPollingInterval(PollingInterval)
    case setAlertThreshold(AlertThreshold)
    case setHistoryRetention(HistoryRetention)
    case setLaunchAtLogin(Bool)
    case quit
}
