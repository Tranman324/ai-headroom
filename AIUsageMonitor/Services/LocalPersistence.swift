import Darwin
import Foundation

protocol StorageRootProviding: Sendable {
    var storageRoot: URL { get }
}

struct HomeDirectoryStorageRootProvider: StorageRootProviding {
    var storageRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai-usage", isDirectory: true)
    }
}

struct FixedStorageRootProvider: StorageRootProviding {
    let storageRoot: URL
}

enum LocalPersistenceError: Error, Equatable {
    case storageRootIsFile(URL)
    case posixFailure(operation: String, path: String, code: Int32)
    case invalidUTF8(URL)
}

actor LocalHistoryStore: HistoryStoring {
    static let historyFileName = "usage-history.jsonl"

    nonisolated let rootURL: URL
    nonisolated let historyFileURL: URL
    private let clock: any ClockProviding
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootProvider: any StorageRootProviding = HomeDirectoryStorageRootProvider(), clock: any ClockProviding = SystemClock()) {
        self.rootURL = rootProvider.storageRoot
        self.historyFileURL = rootProvider.storageRoot.appendingPathComponent(Self.historyFileName, isDirectory: false)
        self.clock = clock
        self.encoder = JSONEncoder.localHistoryEncoder()
        self.decoder = JSONDecoder.localHistoryDecoder()
    }

    func append(_ snapshot: CombinedUsageSnapshot) async throws {
        try appendRecord(.combinedSnapshot(CombinedSnapshotHistoryRecord(snapshot: snapshot)))
    }

    func appendProviderSnapshot(_ snapshot: ProviderUsageSnapshot, capturedAt: Date) async throws {
        try appendRecord(.providerSnapshot(ProviderSnapshotHistoryRecord(capturedAt: capturedAt, snapshot: snapshot)))
    }

    func appendProviderFailure(provider: ProviderID, at timestamp: Date, error: SanitizedProviderError) async throws {
        try appendRecord(.providerFailure(ProviderFailureHistoryRecord(timestamp: timestamp, provider: provider, error: error)))
    }

    func records(since startDate: Date) async throws -> [UsageHistoryRecord] {
        try LocalPersistence.ensureRoot(at: rootURL)
        return try readNumberedRecords()
            .filter { $0.record.timestamp >= startDate }
            .sorted { lhs, rhs in
                if lhs.record.timestamp == rhs.record.timestamp {
                    return lhs.offset < rhs.offset
                }
                return lhs.record.timestamp < rhs.record.timestamp
            }
            .map(\.record)
    }

    func snapshots(since startDate: Date) async throws -> [CombinedUsageSnapshot] {
        try await records(since: startDate).compactMap { record in
            if case let .combinedSnapshot(snapshotRecord) = record {
                return snapshotRecord.snapshot
            }
            return nil
        }
    }

    func latestUsableProviderSnapshots() async throws -> [ProviderID: ProviderUsageSnapshot] {
        var latestByProvider: [ProviderID: ProviderUsageSnapshot] = [:]
        for record in try await records(since: .distantPast) {
            switch record {
            case let .combinedSnapshot(snapshotRecord):
                for providerSnapshot in snapshotRecord.snapshot.providers where providerSnapshot.hasLastKnownGoodData {
                    latestByProvider[providerSnapshot.provider] = providerSnapshot
                }
            case let .providerSnapshot(snapshotRecord):
                if snapshotRecord.snapshot.hasLastKnownGoodData {
                    latestByProvider[snapshotRecord.provider] = snapshotRecord.snapshot
                }
            case .providerFailure:
                continue
            }
        }
        return latestByProvider
    }

    func prune(olderThan cutoffDate: Date) async throws {
        try LocalPersistence.ensureRoot(at: rootURL)
        let retainedRecords = try readNumberedRecords()
            .filter { $0.record.timestamp >= cutoffDate }
            .sorted { lhs, rhs in
                if lhs.record.timestamp == rhs.record.timestamp {
                    return lhs.offset < rhs.offset
                }
                return lhs.record.timestamp < rhs.record.timestamp
            }
            .map(\.record)
        let data = try retainedRecords.reduce(into: Data()) { output, record in
            output.append(try encodeLine(record))
        }
        try LocalPersistence.atomicWrite(data, to: historyFileURL)
    }

    func prune(retaining retention: HistoryRetention) async throws {
        let cutoffDate = clock.now.addingTimeInterval(-TimeInterval(retention.days) * 24 * 60 * 60)
        try await prune(olderThan: cutoffDate)
    }

    private func appendRecord(_ record: UsageHistoryRecord) throws {
        try LocalPersistence.ensureRoot(at: rootURL)
        try LocalPersistence.append(encodeLine(record), to: historyFileURL)
    }

    private func readNumberedRecords() throws -> [NumberedHistoryRecord] {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: historyFileURL)

        var records: [NumberedHistoryRecord] = []
        for (offset, line) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            guard !line.isEmpty else {
                continue
            }
            guard let record = try? decoder.decode(UsageHistoryRecord.self, from: Data(line)) else {
                continue
            }
            records.append(NumberedHistoryRecord(offset: offset, record: record))
        }
        return records
    }

    private func encodeLine(_ record: UsageHistoryRecord) throws -> Data {
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }
}

actor LocalSettingsStore: SettingsStoring {
    static let settingsFileName = "settings.json"

    nonisolated let rootURL: URL
    nonisolated let settingsFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootProvider: any StorageRootProviding = HomeDirectoryStorageRootProvider()) {
        self.rootURL = rootProvider.storageRoot
        self.settingsFileURL = rootProvider.storageRoot.appendingPathComponent(Self.settingsFileName, isDirectory: false)
        self.encoder = JSONEncoder.localSettingsEncoder()
        self.decoder = JSONDecoder.localSettingsDecoder()
    }

    func loadSettings() async throws -> MonitorSettings {
        try LocalPersistence.ensureRoot(at: rootURL)
        guard FileManager.default.fileExists(atPath: settingsFileURL.path) else {
            return .defaults
        }

        do {
            let data = try Data(contentsOf: settingsFileURL)
            return try decoder.decode(MonitorSettings.self, from: data)
        } catch {
            return .defaults
        }
    }

    func saveSettings(_ settings: MonitorSettings) async throws {
        try LocalPersistence.ensureRoot(at: rootURL)
        let data = try encoder.encode(settings)
        try LocalPersistence.atomicWrite(data, to: settingsFileURL)
    }
}

private struct NumberedHistoryRecord {
    var offset: Int
    var record: UsageHistoryRecord
}

enum LocalPersistence {
    static let rootMode: mode_t = S_IRWXU
    static let fileMode: mode_t = S_IRUSR | S_IWUSR

    static func permissions(of url: URL) throws -> mode_t {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = attributes[.posixPermissions] as? NSNumber
        return mode_t(value?.intValue ?? 0) & 0o777
    }

    static func ensureRoot(at rootURL: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
        if exists {
            guard isDirectory.boolValue else {
                throw LocalPersistenceError.storageRootIsFile(rootURL)
            }
        } else {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int(rootMode))]
            )
        }
        try setPermissions(rootMode, at: rootURL)
        try cleanupTemporaryFiles(in: rootURL)
    }

    static func append(_ data: Data, to fileURL: URL) throws {
        let descriptor = Darwin.open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, fileMode)
        guard descriptor >= 0 else {
            throw posixError(operation: "open", path: fileURL.path)
        }
        do {
            if Darwin.fchmod(descriptor, fileMode) != 0 {
                throw posixError(operation: "fchmod", path: fileURL.path)
            }
            try writeAll(data, to: descriptor, path: fileURL.path)
            try syncAndClose(descriptor, path: fileURL.path)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        try setPermissions(fileMode, at: fileURL)
    }

    static func atomicWrite(_ data: Data, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try writeRestrictiveFile(data, to: tempURL)
            if Darwin.rename(tempURL.path, fileURL.path) != 0 {
                throw posixError(operation: "rename", path: fileURL.path)
            }
            try setPermissions(fileMode, at: fileURL)
            try syncDirectory(directoryURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private static func writeRestrictiveFile(_ data: Data, to fileURL: URL) throws {
        let descriptor = Darwin.open(fileURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, fileMode)
        guard descriptor >= 0 else {
            throw posixError(operation: "open", path: fileURL.path)
        }
        do {
            if Darwin.fchmod(descriptor, fileMode) != 0 {
                throw posixError(operation: "fchmod", path: fileURL.path)
            }
            try writeAll(data, to: descriptor, path: fileURL.path)
            try syncAndClose(descriptor, path: fileURL.path)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            var remaining = data.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else {
                    throw posixError(operation: "write", path: path)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private static func syncAndClose(_ descriptor: Int32, path: String) throws {
        if Darwin.fsync(descriptor) != 0 {
            throw posixError(operation: "fsync", path: path)
        }
        if Darwin.close(descriptor) != 0 {
            throw posixError(operation: "close", path: path)
        }
    }

    private static func syncDirectory(_ directoryURL: URL) throws {
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError(operation: "open-directory", path: directoryURL.path)
        }
        do {
            if Darwin.fsync(descriptor) != 0 {
                throw posixError(operation: "fsync-directory", path: directoryURL.path)
            }
            if Darwin.close(descriptor) != 0 {
                throw posixError(operation: "close-directory", path: directoryURL.path)
            }
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func setPermissions(_ mode: mode_t, at url: URL) throws {
        guard Darwin.chmod(url.path, mode) == 0 else {
            throw posixError(operation: "chmod", path: url.path)
        }
        let actualMode = try permissions(of: url)
        guard actualMode == mode else {
            throw LocalPersistenceError.posixFailure(operation: "verify-permissions", path: url.path, code: Int32(actualMode))
        }
    }

    private static func cleanupTemporaryFiles(in rootURL: URL) throws {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents where url.lastPathComponent.hasPrefix(".") && url.lastPathComponent.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func posixError(operation: String, path: String) -> LocalPersistenceError {
        LocalPersistenceError.posixFailure(operation: operation, path: path, code: errno)
    }
}

private extension JSONEncoder {
    static func localHistoryEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let epochSeconds = date.timeIntervalSince1970
            guard epochSeconds.isFinite else {
                throw EncodingError.invalidValue(
                    date,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "History dates must have finite epoch seconds."
                    )
                )
            }
            var container = encoder.singleValueContainer()
            try container.encode(epochSeconds)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func localSettingsEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(PersistenceDateCoding.fractionalISO8601))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static func localHistoryDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let epochSeconds = try? container.decode(Double.self) {
                guard epochSeconds.isFinite else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "History date epoch seconds must be finite."
                    )
                }
                return Date(timeIntervalSince1970: epochSeconds)
            }

            guard
                let value = try? container.decode(String.self),
                let date = PersistenceDateCoding.decodeISO8601(value)
            else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected finite epoch seconds or a compatible ISO-8601 date."
                )
            }
            return date
        }
        return decoder
    }

    static func localSettingsDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = PersistenceDateCoding.decodeISO8601(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 date with optional fractional seconds."
            )
        }
        return decoder
    }
}

private enum PersistenceDateCoding {
    static let fractionalISO8601 = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: TimeZone(secondsFromGMT: 0)!
    )
    static let wholeSecondISO8601 = Date.ISO8601FormatStyle(
        timeZone: TimeZone(secondsFromGMT: 0)!
    )

    static func decodeISO8601(_ value: String) -> Date? {
        if let date = try? fractionalISO8601.parse(value) {
            return date
        }
        return try? wholeSecondISO8601.parse(value)
    }
}
