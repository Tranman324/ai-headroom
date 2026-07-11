import Foundation

struct PollingInterval: Codable, Equatable, Sendable {
    static let allowedRange = 1 ... 10
    static let defaultValue = PollingInterval(unsafeMinutes: 3)

    let minutes: Int

    init(minutes: Int) throws {
        guard Self.allowedRange.contains(minutes) else {
            throw UsageDomainError.invalidPollingInterval(minutes)
        }
        self.minutes = minutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minutes = try container.decode(Int.self, forKey: .minutes)
        try self.init(minutes: minutes)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minutes, forKey: .minutes)
    }

    private init(unsafeMinutes minutes: Int) {
        self.minutes = minutes
    }

    private enum CodingKeys: String, CodingKey {
        case minutes
    }
}

struct AlertThreshold: Codable, Equatable, Sendable {
    static let allowedRange = 50 ... 95
    static let step = 5
    static let defaultValue = AlertThreshold(unsafePercentage: 80)

    let percentage: Double

    init(percentage: Double) throws {
        let roundedPercentage = Int(percentage)
        guard percentage.isFinite,
              percentage.rounded() == percentage,
              Self.allowedRange.contains(roundedPercentage),
              roundedPercentage.isMultiple(of: Self.step)
        else {
            throw UsageDomainError.invalidAlertThreshold(percentage)
        }
        self.percentage = percentage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let percentage = try container.decode(Double.self, forKey: .percentage)
        try self.init(percentage: percentage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(percentage, forKey: .percentage)
    }

    private init(unsafePercentage percentage: Double) {
        self.percentage = percentage
    }

    private enum CodingKeys: String, CodingKey {
        case percentage
    }
}

struct HistoryRetention: Codable, Equatable, Sendable {
    static let allowedRange = 1 ... 365
    static let defaultValue = HistoryRetention(unsafeDays: 30)

    let days: Int

    init(days: Int) throws {
        guard Self.allowedRange.contains(days) else {
            throw UsageDomainError.invalidHistoryRetention(days)
        }
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let days = try container.decode(Int.self, forKey: .days)
        try self.init(days: days)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(days, forKey: .days)
    }

    private init(unsafeDays days: Int) {
        self.days = days
    }

    private enum CodingKeys: String, CodingKey {
        case days
    }
}

struct MonitorSettings: Codable, Equatable, Sendable {
    var pollingInterval: PollingInterval
    var alertThreshold: AlertThreshold
    var historyRetention: HistoryRetention
    var alertPauseExpiration: Date?
    var launchAtLogin: Bool

    init(
        pollingInterval: PollingInterval = .defaultValue,
        alertThreshold: AlertThreshold = .defaultValue,
        historyRetention: HistoryRetention = .defaultValue,
        alertPauseExpiration: Date? = nil,
        launchAtLogin: Bool = false
    ) {
        self.pollingInterval = pollingInterval
        self.alertThreshold = alertThreshold
        self.historyRetention = historyRetention
        self.alertPauseExpiration = alertPauseExpiration
        self.launchAtLogin = launchAtLogin
    }

    static let defaults = MonitorSettings()
}
