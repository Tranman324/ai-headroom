import Darwin
import Foundation

protocol CodexAuthFileManaging: Sendable {
    func readAuthDocument() async throws -> CodexAuthDocument
    func rotateTokens(
        in document: CodexAuthDocument,
        accessToken: String,
        refreshToken: String?
    ) async throws -> CodexAuthDocument
}

protocol CodexAuthFileSystem: Sendable {
    func fileExists(at url: URL) async -> Bool
    func readData(at url: URL) async throws -> Data
    func permissions(at url: URL) async throws -> UInt16
    func replaceItem(at url: URL, with data: Data, preserving permissions: UInt16) async throws
}

struct CodexAuthDocument: Equatable, Sendable {
    var url: URL
    var json: ProviderJSONValue
    var permissions: UInt16
    var accessToken: String
    var refreshToken: String
    var accountID: String
}

struct CodexAuthFileStore: CodexAuthFileManaging {
    private let authFileURL: URL
    private let fileSystem: any CodexAuthFileSystem

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileSystem: any CodexAuthFileSystem = LocalCodexAuthFileSystem()
    ) {
        self.authFileURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        self.fileSystem = fileSystem
    }

    func readAuthDocument() async throws -> CodexAuthDocument {
        guard await fileSystem.fileExists(at: authFileURL) else {
            throw ProviderClientFailure.credentialUnavailable(provider: .codex)
        }

        let mode: UInt16
        do {
            mode = try await fileSystem.permissions(at: authFileURL)
        } catch {
            throw ProviderClientFailure.credentialUnreadable(provider: .codex)
        }
        guard Self.isRestrictive(mode) else {
            throw ProviderClientFailure.credentialInsecure(provider: .codex)
        }

        let data: Data
        do {
            data = try await fileSystem.readData(at: authFileURL)
        } catch {
            throw ProviderClientFailure.credentialUnreadable(provider: .codex)
        }

        return try Self.decodeDocument(data: data, url: authFileURL, permissions: mode)
    }

    func rotateTokens(
        in document: CodexAuthDocument,
        accessToken: String,
        refreshToken: String?
    ) async throws -> CodexAuthDocument {
        let trimmedAccessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccessToken.isEmpty else {
            throw ProviderClientFailure.malformedResponse(provider: .codex)
        }

        var updatedJSON = document.json
        do {
            try updatedJSON.setString(trimmedAccessToken, at: ["tokens", "access_token"])
            if let refreshToken {
                let trimmedRefreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedRefreshToken.isEmpty {
                    try updatedJSON.setString(trimmedRefreshToken, at: ["tokens", "refresh_token"])
                }
            }
        } catch {
            throw ProviderClientFailure.malformedCredential(provider: .codex)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(updatedJSON)
        } catch {
            throw ProviderClientFailure.credentialPersistence(provider: .codex)
        }

        do {
            try await fileSystem.replaceItem(at: document.url, with: data, preserving: document.permissions)
        } catch {
            throw ProviderClientFailure.credentialPersistence(provider: .codex)
        }

        return try Self.decodeDocument(data: data, url: document.url, permissions: document.permissions)
    }

    private static func decodeDocument(data: Data, url: URL, permissions: UInt16) throws -> CodexAuthDocument {
        let json: ProviderJSONValue
        do {
            json = try JSONDecoder().decode(ProviderJSONValue.self, from: data)
        } catch {
            throw ProviderClientFailure.malformedCredential(provider: .codex)
        }

        guard let accessToken = json.string(at: ["tokens", "access_token"]),
              let refreshToken = json.string(at: ["tokens", "refresh_token"]),
              let accountID = json.string(at: ["tokens", "account_id"]) else {
            throw ProviderClientFailure.missingCredentialValue(provider: .codex)
        }

        let trimmedAccessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRefreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccessToken.isEmpty,
              !trimmedRefreshToken.isEmpty,
              !trimmedAccountID.isEmpty else {
            throw ProviderClientFailure.missingCredentialValue(provider: .codex)
        }

        return CodexAuthDocument(
            url: url,
            json: json,
            permissions: permissions,
            accessToken: trimmedAccessToken,
            refreshToken: trimmedRefreshToken,
            accountID: trimmedAccountID
        )
    }

    private static func isRestrictive(_ mode: UInt16) -> Bool {
        mode & 0o077 == 0
    }
}

struct LocalCodexAuthFileSystem: CodexAuthFileSystem {
    func fileExists(at url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func readData(at url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }

    func permissions(at url: URL) async throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw LocalCodexAuthFileSystemError.missingPermissions
        }
        return UInt16(truncatingIfNeeded: permissions.uint16Value) & 0o777
    }

    func replaceItem(at url: URL, with data: Data, preserving permissions: UInt16) async throws {
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        var shouldCleanUp = true
        defer {
            if shouldCleanUp {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let fd = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else {
            throw LocalCodexAuthFileSystemError.openFailed
        }

        var shouldClose = true
        defer {
            if shouldClose {
                close(fd)
            }
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            var written = 0
            while written < buffer.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: written), buffer.count - written)
                guard result >= 0 else {
                    throw LocalCodexAuthFileSystemError.writeFailed
                }
                written += result
            }
        }

        guard fchmod(fd, mode_t(permissions)) == 0 else {
            throw LocalCodexAuthFileSystemError.chmodFailed
        }
        guard fsync(fd) == 0 else {
            throw LocalCodexAuthFileSystemError.fsyncFailed
        }
        guard close(fd) == 0 else {
            shouldClose = false
            throw LocalCodexAuthFileSystemError.closeFailed
        }
        shouldClose = false

        guard rename(temporaryURL.path, url.path) == 0 else {
            throw LocalCodexAuthFileSystemError.renameFailed
        }
        shouldCleanUp = false
    }
}

private enum LocalCodexAuthFileSystemError: Error {
    case missingPermissions
    case openFailed
    case writeFailed
    case chmodFailed
    case fsyncFailed
    case closeFailed
    case renameFailed
}

enum ProviderJSONValue: Equatable, Sendable, Codable {
    case object([String: ProviderJSONValue])
    case array([ProviderJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let object = try? [String: ProviderJSONValue](from: decoder) {
            self = .object(object)
            return
        }
        if let array = try? [ProviderJSONValue](from: decoder) {
            self = .array(array)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .object(object):
            try object.encode(to: encoder)
        case let .array(array):
            try array.encode(to: encoder)
        case let .string(string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case let .number(number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case let .bool(bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    func string(at path: [String]) -> String? {
        guard !path.isEmpty else {
            return stringValue
        }
        guard case let .object(object) = self,
              let next = object[path[0]] else {
            return nil
        }
        return next.string(at: Array(path.dropFirst()))
    }

    mutating func setString(_ value: String, at path: [String]) throws {
        guard !path.isEmpty else {
            self = .string(value)
            return
        }
        guard case var .object(object) = self else {
            throw ProviderJSONValueError.expectedObject
        }
        if path.count == 1 {
            object[path[0]] = .string(value)
            self = .object(object)
            return
        }
        guard var next = object[path[0]] else {
            throw ProviderJSONValueError.missingPath
        }
        try next.setString(value, at: Array(path.dropFirst()))
        object[path[0]] = next
        self = .object(object)
    }

    var objectValue: [String: ProviderJSONValue]? {
        guard case let .object(object) = self else {
            return nil
        }
        return object
    }

    var stringValue: String? {
        guard case let .string(string) = self else {
            return nil
        }
        return string
    }
}

private enum ProviderJSONValueError: Error {
    case expectedObject
    case missingPath
}
