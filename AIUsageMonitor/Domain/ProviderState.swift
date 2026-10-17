import Foundation

enum ProviderHealthKind: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case errored
    case noData
}

enum ProviderErrorCode: String, Codable, Equatable, Sendable {
    case unavailable
    case unauthorized
    case rateLimited
    case malformedResponse
    case unknown
}

struct SanitizedProviderError: Codable, Equatable, Sendable {
    var code: ProviderErrorCode
    var displayMessage: String

    init(code: ProviderErrorCode, displayMessage: String) {
        self.code = code
        self.displayMessage = Self.redacted(displayMessage)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(ProviderErrorCode.self, forKey: .code)
        let displayMessage = try container.decode(String.self, forKey: .displayMessage)
        self.init(code: code, displayMessage: displayMessage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(displayMessage, forKey: .displayMessage)
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case displayMessage
    }

    static func redacted(_ message: String) -> String {
        var sanitized = message
        let replacements = [
            (
                pattern: #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#,
                template: "Bearer [redacted]"
            ),
            (
                pattern: #"(?i)(["']?(?:access[_-]?token|refresh[_-]?token|api[_-]?key)["']?\s*[:=]\s*["']?)[^"',\s}]+(["']?)"#,
                template: "$1[redacted]$2"
            ),
            (
                pattern: #"sk-[A-Za-z0-9]{8,}"#,
                template: "[redacted]"
            )
        ]

        for replacement in replacements {
            let pattern = replacement.pattern
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(sanitized.startIndex ..< sanitized.endIndex, in: sanitized)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: replacement.template
            )
        }

        return sanitized
    }
}

struct ProviderHealth: Codable, Equatable, Sendable {
    var kind: ProviderHealthKind
    var checkedAt: Date?
    var staleSince: Date?
    var error: SanitizedProviderError?

    static func fresh(checkedAt: Date) -> ProviderHealth {
        ProviderHealth(kind: .fresh, checkedAt: checkedAt, staleSince: nil, error: nil)
    }

    static func stale(checkedAt: Date, staleSince: Date, error: SanitizedProviderError? = nil) -> ProviderHealth {
        ProviderHealth(kind: .stale, checkedAt: checkedAt, staleSince: staleSince, error: error)
    }

    static func errored(checkedAt: Date, error: SanitizedProviderError) -> ProviderHealth {
        ProviderHealth(kind: .errored, checkedAt: checkedAt, staleSince: nil, error: error)
    }

    static func noData(checkedAt: Date? = nil) -> ProviderHealth {
        ProviderHealth(kind: .noData, checkedAt: checkedAt, staleSince: nil, error: nil)
    }
}

/// A one-time credit that clears a rate-limit window early (OpenAI Codex "Full reset").
struct RateLimitResetCredit: Codable, Equatable, Sendable {
    var title: String?
    var expiresAt: Date?
}

/// Reset credits still available to redeem. `availableCount` is authoritative; the provider may
/// list fewer credits than that. Credit identifiers are never kept.
struct RateLimitResetCredits: Codable, Equatable, Sendable {
    var availableCount: Int
    var credits: [RateLimitResetCredit]
}

struct ProviderUsageSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: ProviderID { provider }
    var provider: ProviderID
    var meters: [UsageMeterSnapshot]
    var health: ProviderHealth
    /// Live-only detail shown in the popover; history records do not keep it.
    var resetCredits: RateLimitResetCredits?

    init(
        provider: ProviderID,
        meters: [UsageMeterSnapshot],
        health: ProviderHealth,
        resetCredits: RateLimitResetCredits? = nil
    ) {
        self.provider = provider
        self.meters = meters.filter { $0.provider == provider }
        self.health = health
        self.resetCredits = resetCredits
    }

    var hasCurrentData: Bool {
        health.kind == .fresh && !meters.isEmpty
    }

    var hasLastKnownGoodData: Bool {
        !meters.isEmpty
    }
}
