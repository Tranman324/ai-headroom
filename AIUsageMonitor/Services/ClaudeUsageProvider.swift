import Foundation
import Security

protocol ClaudeCredentialReading: Sendable {
    func credentialData() async throws -> Data
}

struct KeychainClaudeCredentialReader: ClaudeCredentialReading {
    static let service = "Claude Code-credentials"

    let account: String

    init(account: String = NSUserName()) {
        self.account = account
    }

    var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
    }

    func credentialData() async throws -> Data {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            throw ProviderClientFailure.credentialUnavailable(provider: .claude)
        }
        guard status == errSecSuccess else {
            throw ProviderClientFailure.credentialUnreadable(provider: .claude)
        }
        guard let data = result as? Data else {
            throw ProviderClientFailure.credentialUnreadable(provider: .claude)
        }
        return data
    }
}

struct ClaudeUsageProvider: UsageProviderFetching {
    let provider: ProviderID = .claude

    private let credentialReader: any ClaudeCredentialReading
    private let transport: any ProviderHTTPTransporting
    private let clock: any ClockProviding
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    init(
        credentialReader: any ClaudeCredentialReading = KeychainClaudeCredentialReader(),
        transport: any ProviderHTTPTransporting = URLSessionProviderHTTPTransport(),
        clock: any ClockProviding = SystemClock()
    ) {
        self.credentialReader = credentialReader
        self.transport = transport
        self.clock = clock
    }

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        let credentialData: Data
        do {
            credentialData = try await credentialReader.credentialData()
        } catch let failure as ProviderClientFailure {
            throw failure
        } catch {
            throw ProviderClientFailure.credentialUnreadable(provider: provider)
        }

        let accessToken = try decodeAccessToken(from: credentialData)
        let request = ProviderHTTPRequest(
            method: "GET",
            url: usageURL,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "anthropic-beta": "oauth-2025-04-20"
            ]
        )

        let response: ProviderHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw ProviderClientFailure.transport(provider: provider)
        }

        try validateStatus(response.statusCode)

        do {
            let usage = try ProviderJSON.decoder().decode(ClaudeUsageResponse.self, from: response.data)
            let meters = try mapUsage(usage)
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

    private func decodeAccessToken(from data: Data) throws -> String {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProviderClientFailure.malformedCredential(provider: provider)
        }

        guard let envelope = object as? [String: Any],
              let oauth = envelope["claudeAiOauth"] as? [String: Any] else {
            throw ProviderClientFailure.malformedCredential(provider: provider)
        }
        guard let token = oauth["accessToken"] as? String else {
            throw ProviderClientFailure.missingCredentialValue(provider: provider)
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw ProviderClientFailure.missingCredentialValue(provider: provider)
        }
        return trimmedToken
    }

    private func validateStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200 ..< 300:
            return
        case 401, 403:
            throw ProviderClientFailure.unauthorized(provider: provider)
        case 429:
            throw ProviderClientFailure.rateLimited(provider: provider)
        default:
            throw ProviderClientFailure.httpStatus(provider: provider, statusCode: statusCode)
        }
    }

    private func mapUsage(_ usage: ClaudeUsageResponse) throws -> [UsageMeterSnapshot] {
        let limitsByKind = Dictionary(grouping: usage.limits, by: { limitKind(for: $0.scope.model.displayName) })
        let requiredLimits: [(MeterKind, ClaudeUsageLimit?)] = [
            (.claudeWeekFable, limitsByKind[.claudeWeekFable]?.first),
            (.claudeWeekSonnet, limitsByKind[.claudeWeekSonnet]?.first),
            (.claudeWeekHaiku, limitsByKind[.claudeWeekHaiku]?.first)
        ]

        var meters: [UsageMeterSnapshot] = [
            try meter(kind: .claudeSession, window: usage.fiveHour),
            try meter(kind: .claudeWeekAll, window: usage.sevenDay)
        ]

        for (kind, window) in requiredLimits {
            guard let window else {
                throw ProviderClientFailure.malformedResponse(provider: provider)
            }
            meters.append(try meter(kind: kind, utilization: window.utilization, resetAt: window.resetAt))
        }

        return meters
    }

    private func meter(kind: MeterKind, window: ClaudeUsageWindow) throws -> UsageMeterSnapshot {
        try meter(kind: kind, utilization: window.utilization, resetAt: window.resetAt)
    }

    private func meter(kind: MeterKind, utilization: Double, resetAt: Date) throws -> UsageMeterSnapshot {
        do {
            return UsageMeterSnapshot(
                kind: kind,
                utilization: try UtilizationPercentage(utilization),
                resetAt: resetAt
            )
        } catch {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }
    }

    private func limitKind(for displayName: String) -> MeterKind? {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("fable") {
            return .claudeWeekFable
        }
        if normalized.contains("sonnet") {
            return .claudeWeekSonnet
        }
        if normalized.contains("haiku") {
            return .claudeWeekHaiku
        }
        return nil
    }
}

private struct ClaudeUsageResponse: Decodable {
    var fiveHour: ClaudeUsageWindow
    var sevenDay: ClaudeUsageWindow
    var limits: [ClaudeUsageLimit]

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }
}

private struct ClaudeUsageWindow: Decodable {
    var utilization: Double
    var resetAt: Date

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetAt = "resets_at"
    }
}

private struct ClaudeUsageLimit: Decodable {
    var utilization: Double
    var resetAt: Date
    var scope: ClaudeUsageScope

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetAt = "resets_at"
        case scope
    }
}

private struct ClaudeUsageScope: Decodable {
    var model: ClaudeUsageModel
}

private struct ClaudeUsageModel: Decodable {
    var displayName: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}
