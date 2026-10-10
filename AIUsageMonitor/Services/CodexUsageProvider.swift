import Foundation

protocol CodexAppServerCommunicating: Sendable {
    func readAccount() async throws -> CodexAppServerAccount?
    func readUsage() async throws -> CodexAppServerUsage
    func startChatGPTAuthentication() async throws -> ProviderAuthenticationChallenge
}

struct CodexAppServerAccount: Equatable, Sendable {
    var type: String
    var planType: String?
}

struct CodexAppServerUsage: Equatable, Sendable {
    var planType: String?
    var primaryWindow: CodexAppServerUsageWindow?
    var secondaryWindow: CodexAppServerUsageWindow?
}

struct CodexAppServerUsageWindow: Equatable, Sendable {
    var usedPercent: Double
    var windowDurationMinutes: Double?
    var resetsAtUnixSeconds: Double?
}

struct CodexUsageProvider: UsageProviderFetching, ProviderAuthenticationManaging, ProviderConnectionChecking {
    let provider: ProviderID = .codex
    /// Windows up to a day long are the rolling session limit; longer ones are the weekly limit.
    static let sessionWindowUpperBoundMinutes: Double = 24 * 60

    private let appServer: any CodexAppServerCommunicating
    private let clock: any ClockProviding

    init(
        appServer: any CodexAppServerCommunicating = CodexAppServerClient(),
        clock: any ClockProviding = SystemClock()
    ) {
        self.appServer = appServer
        self.clock = clock
    }

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        do {
            let usage = try await appServer.readUsage()
            let meters = try meters(for: usage, planName: planDisplayName(for: usage.planType))
            return ProviderUsageSnapshot(
                provider: provider,
                meters: meters,
                health: meters.isEmpty ? .noData(checkedAt: clock.now) : .fresh(checkedAt: clock.now)
            )
        } catch let failure as CodexAppServerFailure {
            throw providerFailure(for: failure)
        } catch let failure as ProviderClientFailure {
            throw failure
        } catch {
            throw ProviderClientFailure.runtimeUnavailable(provider: provider)
        }
    }

    func startAuthentication() async throws -> ProviderAuthenticationResult {
        do {
            return .challenge(try await appServer.startChatGPTAuthentication())
        } catch let failure as CodexAppServerFailure {
            throw providerFailure(for: failure)
        } catch let failure as ProviderClientFailure {
            throw failure
        } catch {
            throw ProviderClientFailure.runtimeUnavailable(provider: provider)
        }
    }

    func connectionStatus() async -> ProviderConnectionStatus {
        do {
            guard let account = try await appServer.readAccount(), account.type == "chatgpt" else {
                return ProviderConnectionStatus(
                    provider: provider,
                    state: .disconnected,
                    planName: nil,
                    usageSyncEnabled: nil,
                    detail: "Sign in with ChatGPT to read Codex limits."
                )
            }
            return ProviderConnectionStatus(
                provider: provider,
                state: .connected,
                planName: planDisplayName(for: account.planType),
                usageSyncEnabled: true,
                detail: "Usage sync enabled"
            )
        } catch {
            return ProviderConnectionStatus(
                provider: provider,
                state: .unavailable,
                planName: nil,
                usageSyncEnabled: nil,
                detail: (error as? CodexAppServerFailure) == .executableNotFound
                    ? "Codex CLI was not found."
                    : "Codex CLI is unavailable."
            )
        }
    }

    private func providerFailure(for failure: CodexAppServerFailure) -> ProviderClientFailure {
        switch failure {
        case .authenticationRequired:
            return .authenticationRequired(provider: provider)
        case .malformedResponse:
            return .malformedResponse(provider: provider)
        case .executableNotFound:
            return .executableNotFound(provider: provider)
        case .executableUnavailable, .processUnavailable, .requestFailed:
            return .runtimeUnavailable(provider: provider)
        }
    }

    /// Classifies each window by its length rather than its position: Codex has reported the
    /// weekly limit as `primary` with no `secondary`, which is not a five-hour session.
    private func meters(for usage: CodexAppServerUsage, planName: String) throws -> [UsageMeterSnapshot] {
        let windows: [(window: CodexAppServerUsageWindow, positionalKind: MeterKind)] = [
            usage.primaryWindow.map { ($0, MeterKind.codexSession) },
            usage.secondaryWindow.map { ($0, MeterKind.codexWeek) }
        ].compactMap { $0 }

        var metersByKind: [MeterKind: UsageMeterSnapshot] = [:]
        for (window, positionalKind) in windows {
            let kind = try meterKind(for: window, positionalKind: positionalKind)
            guard let meter = try meter(kind: kind, window: window, planName: planName) else {
                continue
            }
            // Two windows of the same length: keep the fuller one, since it limits first.
            if let existing = metersByKind[kind], existing.utilization >= meter.utilization {
                continue
            }
            metersByKind[kind] = meter
        }
        return MeterKind.allCases.compactMap { metersByKind[$0] }
    }

    private func meterKind(
        for window: CodexAppServerUsageWindow,
        positionalKind: MeterKind
    ) throws -> MeterKind {
        guard let duration = window.windowDurationMinutes else {
            return positionalKind
        }
        guard duration.isFinite, duration > 0 else {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }
        return duration <= Self.sessionWindowUpperBoundMinutes ? .codexSession : .codexWeek
    }

    private func meter(
        kind: MeterKind,
        window: CodexAppServerUsageWindow,
        planName: String
    ) throws -> UsageMeterSnapshot? {
        guard window.usedPercent.isFinite else {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }
        guard let resetsAt = window.resetsAtUnixSeconds else {
            return nil
        }
        guard resetsAt.isFinite,
              resetsAt >= 0,
              resetsAt <= Date.distantFuture.timeIntervalSince1970 else {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }

        do {
            var display = MeterDisplayMetadata(kind: kind)
            display.planName = planName
            return UsageMeterSnapshot(
                kind: kind,
                utilization: try UtilizationPercentage(window.usedPercent),
                resetAt: Date(timeIntervalSince1970: resetsAt),
                display: display
            )
        } catch {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }
    }

    private func planDisplayName(for planType: String?) -> String {
        switch planType?.lowercased() {
        case "plus":
            return "Plus"
        case "prolite":
            return "Pro 5x"
        case "pro":
            return "Pro 20x"
        case "business":
            return "Business"
        case "enterprise":
            return "Enterprise"
        default:
            return "ChatGPT"
        }
    }
}
