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
    var primaryWindow: CodexAppServerUsageWindow
    var secondaryWindow: CodexAppServerUsageWindow?
}

struct CodexAppServerUsageWindow: Equatable, Sendable {
    var usedPercent: Double
    var windowDurationMinutes: Double
    var resetsAtUnixSeconds: Double
}

struct CodexUsageProvider: UsageProviderFetching, ProviderAuthenticationManaging, ProviderConnectionChecking {
    let provider: ProviderID = .codex

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
            let planName = planDisplayName(for: usage.planType)
            var meters = [
                try meter(kind: .codexSession, window: usage.primaryWindow, planName: planName)
            ]
            if let secondaryWindow = usage.secondaryWindow {
                meters.append(try meter(kind: .codexWeek, window: secondaryWindow, planName: planName))
            }
            return ProviderUsageSnapshot(
                provider: provider,
                meters: meters,
                health: .fresh(checkedAt: clock.now)
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
                detail: "Codex CLI is unavailable."
            )
        }
    }

    private func providerFailure(for failure: CodexAppServerFailure) -> ProviderClientFailure {
        switch failure {
        case .authenticationRequired:
            return .authenticationRequired(provider: provider)
        case .malformedResponse:
            return .malformedResponse(provider: provider)
        case .executableUnavailable, .processUnavailable, .requestFailed:
            return .runtimeUnavailable(provider: provider)
        }
    }

    private func meter(
        kind: MeterKind,
        window: CodexAppServerUsageWindow,
        planName: String
    ) throws -> UsageMeterSnapshot {
        guard window.usedPercent.isFinite,
              window.windowDurationMinutes.isFinite,
              window.windowDurationMinutes > 0,
              window.resetsAtUnixSeconds.isFinite,
              window.resetsAtUnixSeconds >= 0,
              window.resetsAtUnixSeconds <= Date.distantFuture.timeIntervalSince1970 else {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }

        do {
            var display = MeterDisplayMetadata(kind: kind)
            display.planName = planName
            return UsageMeterSnapshot(
                kind: kind,
                utilization: try UtilizationPercentage(window.usedPercent),
                resetAt: Date(timeIntervalSince1970: window.resetsAtUnixSeconds),
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
