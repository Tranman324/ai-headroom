import Foundation

enum ProviderID: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }
}

enum MeterWindow: String, Codable, Equatable, Sendable {
    case rollingFiveHours
    case weekly

    var displayName: String {
        switch self {
        case .rollingFiveHours:
            return "Rolling 5 hours"
        case .weekly:
            return "Weekly"
        }
    }
}

enum MeterKind: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case claudeSession
    case claudeWeekAll
    case claudeWeekFable
    case claudeWeekSonnet
    case claudeWeekHaiku
    case codexSession
    case codexWeek

    var id: String { rawValue }

    var provider: ProviderID {
        switch self {
        case .claudeSession, .claudeWeekAll, .claudeWeekFable, .claudeWeekSonnet, .claudeWeekHaiku:
            return .claude
        case .codexSession, .codexWeek:
            return .codex
        }
    }

    var window: MeterWindow {
        switch self {
        case .claudeSession, .codexSession:
            return .rollingFiveHours
        case .claudeWeekAll, .claudeWeekFable, .claudeWeekSonnet, .claudeWeekHaiku, .codexWeek:
            return .weekly
        }
    }

    var displayName: String {
        switch self {
        case .claudeSession:
            return "Claude Session"
        case .claudeWeekAll:
            return "Claude Week"
        case .claudeWeekFable:
            return "Claude Week Fable"
        case .claudeWeekSonnet:
            return "Claude Week Sonnet"
        case .claudeWeekHaiku:
            return "Claude Week Haiku"
        case .codexSession:
            return "Codex Session"
        case .codexWeek:
            return "Codex Week"
        }
    }

    var planDisplayName: String {
        switch self {
        case .claudeSession:
            return "Claude rolling window"
        case .claudeWeekAll:
            return "All Claude models"
        case .claudeWeekFable:
            return "Fable"
        case .claudeWeekSonnet:
            return "Sonnet"
        case .claudeWeekHaiku:
            return "Haiku"
        case .codexSession:
            return "Codex rolling window"
        case .codexWeek:
            return "Codex weekly"
        }
    }
}

enum UsageStatusBand: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical

    static let warningLowerBound = 70.0
    static let criticalLowerBound = 90.0
}

enum UsageDomainError: Error, Equatable {
    case invalidUtilization(Double)
    case providerMismatch(expected: ProviderID, actual: ProviderID)
    case invalidPollingInterval(Int)
    case invalidAlertThreshold(Double)
    case invalidHistoryRetention(Int)
}

struct UtilizationPercentage: Codable, Equatable, Comparable, Sendable {
    let value: Double

    init(_ value: Double) throws {
        guard value.isFinite, (0.0 ... 100.0).contains(value) else {
            throw UsageDomainError.invalidUtilization(value)
        }
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Double.self, forKey: .value)
        try self.init(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey {
        case value
    }

    var statusBand: UsageStatusBand {
        if value >= UsageStatusBand.criticalLowerBound {
            return .critical
        }
        if value >= UsageStatusBand.warningLowerBound {
            return .warning
        }
        return .normal
    }

    static func < (lhs: UtilizationPercentage, rhs: UtilizationPercentage) -> Bool {
        lhs.value < rhs.value
    }
}

struct MeterDisplayMetadata: Codable, Equatable, Sendable {
    var title: String
    var providerName: String
    var planName: String
    var windowName: String

    init(
        title: String,
        providerName: String,
        planName: String,
        windowName: String
    ) {
        self.title = title
        self.providerName = providerName
        self.planName = planName
        self.windowName = windowName
    }

    init(kind: MeterKind) {
        self.init(
            title: kind.displayName,
            providerName: kind.provider.displayName,
            planName: kind.planDisplayName,
            windowName: kind.window.displayName
        )
    }
}

struct UsageMeterSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: MeterKind { kind }
    var provider: ProviderID
    var kind: MeterKind
    var utilization: UtilizationPercentage
    var resetAt: Date
    var display: MeterDisplayMetadata

    init(
        kind: MeterKind,
        utilization: UtilizationPercentage,
        resetAt: Date,
        display: MeterDisplayMetadata? = nil
    ) {
        self.provider = kind.provider
        self.kind = kind
        self.utilization = utilization
        self.resetAt = resetAt
        self.display = display ?? MeterDisplayMetadata(kind: kind)
    }

    init(
        provider: ProviderID,
        kind: MeterKind,
        utilization: UtilizationPercentage,
        resetAt: Date,
        display: MeterDisplayMetadata? = nil
    ) throws {
        guard provider == kind.provider else {
            throw UsageDomainError.providerMismatch(expected: kind.provider, actual: provider)
        }
        self.provider = provider
        self.kind = kind
        self.utilization = utilization
        self.resetAt = resetAt
        self.display = display ?? MeterDisplayMetadata(kind: kind)
    }
}

struct CombinedUsageSnapshot: Codable, Equatable, Sendable {
    var capturedAt: Date
    var providers: [ProviderUsageSnapshot]

    init(capturedAt: Date, providers: [ProviderUsageSnapshot]) {
        self.capturedAt = capturedAt
        self.providers = providers
    }

    func provider(_ id: ProviderID) -> ProviderUsageSnapshot? {
        providers.first { $0.provider == id }
    }

    var meters: [UsageMeterSnapshot] {
        providers.flatMap(\.meters)
    }

    var hottestMeter: UsageMeterSnapshot? {
        meters.max { $0.utilization < $1.utilization }
    }

    var hottestBand: UsageStatusBand {
        hottestMeter?.utilization.statusBand ?? .normal
    }
}
