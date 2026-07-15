import Foundation

protocol UsageProviderFetching: Sendable {
    var provider: ProviderID { get }
    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot
}

struct ProviderAuthenticationChallenge: Equatable, Sendable {
    var provider: ProviderID
    var authorizationURL: URL
    var userCode: String?
}

enum ProviderAuthenticationResult: Equatable, Sendable {
    case challenge(ProviderAuthenticationChallenge)
    case completed
}

protocol ProviderAuthenticationManaging: Sendable {
    var provider: ProviderID { get }
    func startAuthentication() async throws -> ProviderAuthenticationResult
}

enum ProviderConnectionState: Equatable, Sendable {
    case unknown
    case checking
    case disconnected
    case connected
    case unavailable
}

struct ProviderConnectionStatus: Equatable, Sendable {
    var provider: ProviderID
    var state: ProviderConnectionState
    var planName: String?
    var usageSyncEnabled: Bool?
    var detail: String?

    static func unknown(_ provider: ProviderID) -> ProviderConnectionStatus {
        ProviderConnectionStatus(
            provider: provider,
            state: .unknown,
            planName: nil,
            usageSyncEnabled: nil,
            detail: nil
        )
    }

    static func checking(_ provider: ProviderID) -> ProviderConnectionStatus {
        ProviderConnectionStatus(
            provider: provider,
            state: .checking,
            planName: nil,
            usageSyncEnabled: nil,
            detail: nil
        )
    }
}

protocol ProviderConnectionChecking: Sendable {
    var provider: ProviderID { get }
    func connectionStatus() async -> ProviderConnectionStatus
}

protocol ExternalURLOpening: Sendable {
    func open(_ url: URL) async
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

enum LaunchAtLoginRegistrationStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
    case failed(String)

    var isRegistered: Bool {
        self == .enabled
    }
}

protocol LoginRegistering: Sendable {
    func registrationStatus() async -> LaunchAtLoginRegistrationStatus
    func isLaunchAtLoginEnabled() async throws -> Bool
    func setLaunchAtLoginEnabled(_ isEnabled: Bool) async throws
}
