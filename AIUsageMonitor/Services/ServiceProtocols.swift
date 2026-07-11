import Foundation

protocol UsageProviderFetching: Sendable {
    var provider: ProviderID { get }
    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot
}

protocol HistoryStoring: Sendable {
    func append(_ snapshot: CombinedUsageSnapshot) async throws
    func appendProviderSnapshot(_ snapshot: ProviderUsageSnapshot, capturedAt: Date) async throws
    func appendProviderFailure(provider: ProviderID, at timestamp: Date, error: SanitizedProviderError) async throws
    func records(since startDate: Date) async throws -> [UsageHistoryRecord]
    func snapshots(since startDate: Date) async throws -> [CombinedUsageSnapshot]
    func latestUsableProviderSnapshots() async throws -> [ProviderID: ProviderUsageSnapshot]
    func prune(olderThan cutoffDate: Date) async throws
}

protocol SettingsStoring: Sendable {
    func loadSettings() async throws -> MonitorSettings
    func saveSettings(_ settings: MonitorSettings) async throws
}

protocol ClockProviding: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

enum ConnectivityState: String, Codable, Equatable, Sendable {
    case online
    case offline
}

protocol ConnectivityMonitoring: Sendable {
    var currentState: ConnectivityState { get async }
    func states() -> AsyncStream<ConnectivityState>
}

enum AppLifecycleEvent: String, Codable, Equatable, Sendable {
    case didFinishLaunching
    case willTerminate
    case didBecomeActive
    case didResignActive
    case workspaceWillSleep
    case workspaceDidWake
}

protocol AppLifecycleEventProviding: Sendable {
    func events() -> AsyncStream<AppLifecycleEvent>
}

protocol LoginRegistering: Sendable {
    func isLaunchAtLoginEnabled() async throws -> Bool
    func setLaunchAtLoginEnabled(_ isEnabled: Bool) async throws
}
