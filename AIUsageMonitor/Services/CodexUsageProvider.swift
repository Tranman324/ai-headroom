import Foundation

struct CodexUsageProvider: UsageProviderFetching {
    let provider: ProviderID = .codex

    private let authStore: any CodexAuthFileManaging
    private let transport: any ProviderHTTPTransporting
    private let clock: any ClockProviding
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!

    init(
        authStore: any CodexAuthFileManaging = CodexAuthFileStore(),
        transport: any ProviderHTTPTransporting = URLSessionProviderHTTPTransport(),
        clock: any ClockProviding = SystemClock()
    ) {
        self.authStore = authStore
        self.transport = transport
        self.clock = clock
    }

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        let authDocument = try await authStore.readAuthDocument()
        switch try await fetchUsage(with: authDocument) {
        case let .snapshot(snapshot):
            return snapshot
        case .unauthorized:
            let rotatedDocument = try await refresh(authDocument)
            switch try await fetchUsage(with: rotatedDocument) {
            case let .snapshot(snapshot):
                return snapshot
            case .unauthorized:
                throw ProviderClientFailure.unauthorized(provider: provider)
            }
        }
    }

    private func fetchUsage(with authDocument: CodexAuthDocument) async throws -> CodexUsageFetchOutcome {
        let request = ProviderHTTPRequest(
            method: "GET",
            url: usageURL,
            headers: [
                "Authorization": "Bearer \(authDocument.accessToken)",
                "chatgpt-account-id": authDocument.accountID
            ]
        )

        let response: ProviderHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw ProviderClientFailure.transport(provider: provider)
        }

        switch response.statusCode {
        case 200 ..< 300:
            return .snapshot(try decodeUsageSnapshot(from: response.data))
        case 401, 403:
            return .unauthorized
        case 429:
            throw ProviderClientFailure.rateLimited(provider: provider)
        default:
            throw ProviderClientFailure.httpStatus(provider: provider, statusCode: response.statusCode)
        }
    }

    private func refresh(_ authDocument: CodexAuthDocument) async throws -> CodexAuthDocument {
        let request = ProviderHTTPRequest(
            method: "POST",
            url: refreshURL,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded"
            ],
            body: formBody([
                ("client_id", "app_EMoamEEZ73f0CkXaXp7hrann"),
                ("grant_type", "refresh_token"),
                ("refresh_token", authDocument.refreshToken),
                ("scope", "openid profile email")
            ])
        )

        let response: ProviderHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw ProviderClientFailure.refreshFailed(provider: provider)
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            if [400, 401, 403].contains(response.statusCode) {
                throw ProviderClientFailure.unauthorized(provider: provider)
            }
            throw ProviderClientFailure.refreshFailed(provider: provider)
        }

        let refreshResponse: CodexRefreshResponse
        do {
            refreshResponse = try JSONDecoder().decode(CodexRefreshResponse.self, from: response.data)
        } catch {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }

        let accessToken = refreshResponse.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }

        return try await authStore.rotateTokens(
            in: authDocument,
            accessToken: accessToken,
            refreshToken: refreshResponse.refreshToken
        )
    }

    private func decodeUsageSnapshot(from data: Data) throws -> ProviderUsageSnapshot {
        do {
            let usage = try ProviderJSON.decoder().decode(CodexUsageResponse.self, from: data)
            let planName = try planDisplayName(for: usage.planType)
            // The live API sends `secondary_window: null` when only the primary
            // (weekly) window applies, so the weekly meter is optional. Emit the
            // session meter always and append the weekly meter only when present,
            // degrading gracefully rather than failing the whole poll. The UI
            // looks meters up by kind, so an omitted meter is handled cleanly.
            var meters = [
                try meter(kind: .codexSession, window: usage.rateLimit.primaryWindow, planName: planName)
            ]
            if let secondaryWindow = usage.rateLimit.secondaryWindow {
                meters.append(try meter(kind: .codexWeek, window: secondaryWindow, planName: planName))
            }
            return ProviderUsageSnapshot(
                provider: provider,
                meters: meters,
                health: .fresh(checkedAt: clock.now)
            )
        } catch let failure as ProviderClientFailure {
            throw failure
        } catch {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }
    }

    private func meter(kind: MeterKind, window: CodexUsageWindow, planName: String) throws -> UsageMeterSnapshot {
        do {
            guard window.resetAtUnixSeconds.isFinite,
                  window.resetAtUnixSeconds >= 0,
                  window.resetAtUnixSeconds <= Date.distantFuture.timeIntervalSince1970,
                  window.limitWindowSeconds.isFinite,
                  window.limitWindowSeconds > 0 else {
                throw ProviderClientFailure.malformedResponse(provider: provider)
            }

            var display = MeterDisplayMetadata(kind: kind)
            display.planName = planName
            return UsageMeterSnapshot(
                kind: kind,
                utilization: try UtilizationPercentage(window.usedPercent),
                resetAt: Date(timeIntervalSince1970: window.resetAtUnixSeconds),
                display: display
            )
        } catch {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }
    }

    private func planDisplayName(for planType: String) throws -> String {
        switch planType {
        case "plus":
            return "Plus"
        case "prolite":
            return "Pro 5x"
        case "pro":
            return "Pro 20x"
        case "business":
            return "Business"
        default:
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }
    }

    private func formBody(_ fields: [(String, String)]) -> Data {
        fields
            .map { "\(formEscape($0.0))=\(formEscape($0.1))" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }

    private func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private enum CodexUsageFetchOutcome {
    case snapshot(ProviderUsageSnapshot)
    case unauthorized
}

private struct CodexUsageResponse: Decodable {
    var rateLimit: CodexRateLimit
    var planType: String

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case planType = "plan_type"
    }
}

private struct CodexRateLimit: Decodable {
    var primaryWindow: CodexUsageWindow
    // Optional: the live API returns `secondary_window: null` (and may omit the
    // key entirely). Synthesized decoding maps both null and a missing key to
    // nil, so the weekly meter is simply skipped instead of throwing.
    var secondaryWindow: CodexUsageWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexUsageWindow: Decodable {
    var usedPercent: Double
    var resetAtUnixSeconds: Double
    var limitWindowSeconds: Double

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAtUnixSeconds = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }
}

private struct CodexRefreshResponse: Decodable {
    var accessToken: String
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}
