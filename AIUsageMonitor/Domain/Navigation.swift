import Foundation

enum MeterDetailRoute: Codable, Equatable, Sendable {
    case list
    case detail(MeterKind)
}

struct AppNavigationState: Codable, Equatable, Sendable {
    var meterRoute: MeterDetailRoute
    var isSettingsPresented: Bool
    var isHistoryExpanded: Bool

    init(
        meterRoute: MeterDetailRoute = .list,
        isSettingsPresented: Bool = false,
        isHistoryExpanded: Bool = false
    ) {
        self.meterRoute = meterRoute
        self.isSettingsPresented = isSettingsPresented
        self.isHistoryExpanded = isHistoryExpanded
    }
}

enum AppIntentCommand: Codable, Equatable, Sendable {
    case refresh
    case openSettings
    case closeSettings
    case showMeterDetail(MeterKind)
    case backFromMeterDetail
    case setHistoryExpanded(Bool)
    case pauseAlertsForOneHour
    case setLaunchAtLogin(Bool)
    case quit
}
