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

    private init(unsafeMinutes minutes: Int) {
        self.minutes = minutes
    }
}

struct AlertThreshold: Codable, Equatable, Sendable {
    static let defaultValue = AlertThreshold(unsafePercentage: 80)

    let percentage: Double

    init(percentage: Double) throws {
        guard percentage.isFinite, (0.0 ... 100.0).contains(percentage) else {
            throw UsageDomainError.invalidAlertThreshold(percentage)
        }
        self.percentage = percentage
    }

    private init(unsafePercentage percentage: Double) {
        self.percentage = percentage
    }
}

struct HistoryRetention: Codable, Equatable, Sendable {
    static let defaultValue = HistoryRetention(unsafeDays: 30)

    let days: Int

    init(days: Int) throws {
        guard days > 0 else {
            throw UsageDomainError.invalidHistoryRetention(days)
        }
        self.days = days
    }

    private init(unsafeDays days: Int) {
        self.days = days
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
