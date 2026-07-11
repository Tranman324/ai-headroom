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

    static func redacted(_ message: String) -> String {
        var sanitized = message
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,
            #"(?i)(access[_-]?token|refresh[_-]?token|api[_-]?key)\s*[:=]\s*[^,\s]+"#,
            #"sk-[A-Za-z0-9]{8,}"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(sanitized.startIndex ..< sanitized.endIndex, in: sanitized)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: "[redacted]"
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

struct ProviderUsageSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: ProviderID { provider }
    var provider: ProviderID
    var meters: [UsageMeterSnapshot]
    var health: ProviderHealth

    init(provider: ProviderID, meters: [UsageMeterSnapshot], health: ProviderHealth) {
        self.provider = provider
        self.meters = meters.filter { $0.provider == provider }
        self.health = health
    }

    var hasCurrentData: Bool {
        health.kind == .fresh && !meters.isEmpty
    }

    var hasLastKnownGoodData: Bool {
        !meters.isEmpty
    }
}
