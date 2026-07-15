import AppKit
import Foundation
import Network
import Security
import ServiceManagement

enum ProviderExecutableTrust {
    static let anthropicRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"Q6L2SF6YDW\" and identifier \"com.anthropic.claude-code\""
    static let openAIRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and identifier \"codex\""

    static func satisfies(_ requirementText: String, executableURL: URL) -> Bool {
        let resolvedURL = executableURL.resolvingSymlinksInPath() as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(resolvedURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess
    }
}

struct WorkspaceExternalURLOpener: ExternalURLOpening {
    func open(_ url: URL) async {
        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }
}

final class ConnectivityStateHub: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ConnectivityState
    private var continuations: [UUID: AsyncStream<ConnectivityState>.Continuation] = [:]

    init(state: ConnectivityState = .offline) {
        self.state = state
    }

    func currentState() -> ConnectivityState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func update(_ state: ConnectivityState) {
        let activeContinuations: [AsyncStream<ConnectivityState>.Continuation]
        lock.lock()
        self.state = state
        activeContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in activeContinuations {
            continuation.yield(state)
        }
    }

    func stream() -> AsyncStream<ConnectivityState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            add(continuation, id: id)
            continuation.onTermination = { @Sendable _ in
                self.remove(id)
            }
        }
    }

    func finish() {
        lock.lock()
        let continuations = continuations.values
        self.continuations.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.finish()
        }
    }

    private func add(_ continuation: AsyncStream<ConnectivityState>.Continuation, id: UUID) {
        lock.lock()
        continuations[id] = continuation
        let currentState = state
        lock.unlock()
        continuation.yield(currentState)
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

final class NetworkPathConnectivityMonitor: ConnectivityMonitoring, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let hub: ConnectivityStateHub

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        queue: DispatchQueue = DispatchQueue(label: "AIUsageMonitor.NetworkPathConnectivityMonitor")
    ) {
        self.monitor = monitor
        self.queue = queue
        self.hub = ConnectivityStateHub()
        monitor.pathUpdateHandler = { [hub] path in
            let state: ConnectivityState = path.status == .satisfied ? .online : .offline
            Task {
                hub.update(state)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        hub.finish()
    }

    var currentState: ConnectivityState {
        get async {
            hub.currentState()
        }
    }

    func states() -> AsyncStream<ConnectivityState> {
        hub.stream()
    }
}

struct WorkspaceLifecycleEvents: AppLifecycleEventProviding {
    func events() -> AsyncStream<AppLifecycleEvent> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let willSleep = center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(.workspaceWillSleep)
            }
            let didWake = center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(.workspaceDidWake)
            }
            let observation = NotificationObservation(center: center, tokens: [willSleep, didWake])
            continuation.onTermination = { @Sendable _ in
                observation.invalidate()
            }
        }
    }
}

private final class NotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let tokens: [any NSObjectProtocol]
    private let lock = NSLock()
    private var isInvalidated = false

    init(center: NotificationCenter, tokens: [any NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    func invalidate() {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        isInvalidated = true
        lock.unlock()

        for token in tokens {
            center.removeObserver(token)
        }
    }
}

struct ServiceManagementLoginRegistration: LoginRegistering {
    func registrationStatus() async -> LaunchAtLoginRegistrationStatus {
        await MainActor.run {
            Self.map(SMAppService.mainApp.status)
        }
    }

    func isLaunchAtLoginEnabled() async throws -> Bool {
        await registrationStatus().isRegistered
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) async throws {
        do {
            try await MainActor.run {
                let service = SMAppService.mainApp
                if isEnabled {
                    guard service.status != .enabled else {
                        return
                    }
                    try service.register()
                } else {
                    guard service.status != .notRegistered else {
                        return
                    }
                    try service.unregister()
                }
            }
        } catch {
            throw LoginRegistrationError.requestFailed(Self.sanitizedMessage(error))
        }
    }

    static func map(_ status: SMAppService.Status) -> LaunchAtLoginRegistrationStatus {
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    static func sanitizedMessage(_ error: any Error) -> String {
        SanitizedProviderError.redacted(error.localizedDescription)
    }
}

enum LoginRegistrationError: LocalizedError, Equatable, Sendable {
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case let .requestFailed(message):
            return message
        }
    }
}
