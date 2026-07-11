import Foundation

enum UsageHistoryRecordKind: String, Codable, Equatable, Sendable {
    case combinedSnapshot
    case providerSnapshot
    case providerFailure
}

enum UsageHistoryRecord: Equatable, Sendable {
    case combinedSnapshot(CombinedSnapshotHistoryRecord)
    case providerSnapshot(ProviderSnapshotHistoryRecord)
    case providerFailure(ProviderFailureHistoryRecord)

    static let currentSchemaVersion = 1

    var timestamp: Date {
        switch self {
        case let .combinedSnapshot(record):
            return record.capturedAt
        case let .providerSnapshot(record):
            return record.capturedAt
        case let .providerFailure(record):
            return record.timestamp
        }
    }
}

struct CombinedSnapshotHistoryRecord: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var capturedAt: Date
    var snapshot: CombinedUsageSnapshot

    init(snapshot: CombinedUsageSnapshot) {
        self.schemaVersion = UsageHistoryRecord.currentSchemaVersion
        self.capturedAt = snapshot.capturedAt
        self.snapshot = snapshot
    }
}

struct ProviderSnapshotHistoryRecord: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var capturedAt: Date
    var provider: ProviderID
    var snapshot: ProviderUsageSnapshot

    init(capturedAt: Date, snapshot: ProviderUsageSnapshot) {
        self.schemaVersion = UsageHistoryRecord.currentSchemaVersion
        self.capturedAt = capturedAt
        self.provider = snapshot.provider
        self.snapshot = ProviderUsageSnapshot(
            provider: snapshot.provider,
            meters: snapshot.meters,
            health: snapshot.health
        )
    }
}

struct ProviderFailureHistoryRecord: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var timestamp: Date
    var provider: ProviderID
    var error: SanitizedProviderError

    init(timestamp: Date, provider: ProviderID, error: SanitizedProviderError) {
        self.schemaVersion = UsageHistoryRecord.currentSchemaVersion
        self.timestamp = timestamp
        self.provider = provider
        self.error = error
    }
}

extension UsageHistoryRecord: Codable {
    init(from decoder: Decoder) throws {
        let envelope = try HistoryRecordEnvelope(from: decoder)
        guard envelope.schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported history schema version.")
            )
        }

        switch envelope.recordKind {
        case .combinedSnapshot:
            self = .combinedSnapshot(try CombinedSnapshotHistoryRecord(from: decoder))
        case .providerSnapshot:
            self = .providerSnapshot(try ProviderSnapshotHistoryRecord(from: decoder))
        case .providerFailure:
            self = .providerFailure(try ProviderFailureHistoryRecord(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .combinedSnapshot(record):
            try record.encode(to: encoder)
        case let .providerSnapshot(record):
            try record.encode(to: encoder)
        case let .providerFailure(record):
            try record.encode(to: encoder)
        }
    }
}

private struct HistoryRecordEnvelope: Decodable {
    var schemaVersion: Int
    var recordKind: UsageHistoryRecordKind
}

extension CombinedSnapshotHistoryRecord {
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case recordKind
        case capturedAt
        case snapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let recordKind = try container.decode(UsageHistoryRecordKind.self, forKey: .recordKind)
        guard recordKind == .combinedSnapshot else {
            throw DecodingError.dataCorruptedError(forKey: .recordKind, in: container, debugDescription: "Unexpected history record kind.")
        }
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        snapshot = try container.decode(CombinedUsageSnapshot.self, forKey: .snapshot)
        guard snapshot.capturedAt == capturedAt else {
            throw DecodingError.dataCorruptedError(forKey: .capturedAt, in: container, debugDescription: "Snapshot capture time does not match the history record.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(UsageHistoryRecordKind.combinedSnapshot, forKey: .recordKind)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(snapshot, forKey: .snapshot)
    }
}

extension ProviderSnapshotHistoryRecord {
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case recordKind
        case capturedAt
        case provider
        case snapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let recordKind = try container.decode(UsageHistoryRecordKind.self, forKey: .recordKind)
        guard recordKind == .providerSnapshot else {
            throw DecodingError.dataCorruptedError(forKey: .recordKind, in: container, debugDescription: "Unexpected history record kind.")
        }
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        provider = try container.decode(ProviderID.self, forKey: .provider)
        snapshot = try container.decode(ProviderUsageSnapshot.self, forKey: .snapshot)
        guard snapshot.provider == provider else {
            throw DecodingError.dataCorruptedError(forKey: .provider, in: container, debugDescription: "Provider snapshot does not match the record provider.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(UsageHistoryRecordKind.providerSnapshot, forKey: .recordKind)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(provider, forKey: .provider)
        try container.encode(snapshot, forKey: .snapshot)
    }
}

extension ProviderFailureHistoryRecord {
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case recordKind
        case timestamp
        case provider
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let recordKind = try container.decode(UsageHistoryRecordKind.self, forKey: .recordKind)
        guard recordKind == .providerFailure else {
            throw DecodingError.dataCorruptedError(forKey: .recordKind, in: container, debugDescription: "Unexpected history record kind.")
        }
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        provider = try container.decode(ProviderID.self, forKey: .provider)
        error = try container.decode(SanitizedProviderError.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(UsageHistoryRecordKind.providerFailure, forKey: .recordKind)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(provider, forKey: .provider)
        try container.encode(error, forKey: .error)
    }
}
