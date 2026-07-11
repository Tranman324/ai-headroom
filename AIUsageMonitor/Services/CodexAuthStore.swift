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
    func secureRead(at url: URL) async throws -> CodexSecureAuthFile
    func replaceItem(at url: URL, with data: Data, preserving metadata: CodexAuthFileMetadata) async throws
}

struct CodexAuthFileMetadata: Equatable, Sendable {
    let ownerID: uid_t
    let groupID: gid_t
    let permissions: UInt16
}

struct CodexSecureAuthFile: Equatable, Sendable {
    let data: Data
    let metadata: CodexAuthFileMetadata
}

struct CodexAuthDocument: Equatable, Sendable {
    var url: URL
    var json: ProviderJSONValue
    var metadata: CodexAuthFileMetadata
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
        let file: CodexSecureAuthFile
        do {
            file = try await fileSystem.secureRead(at: authFileURL)
        } catch CodexAuthFileSystemError.notFound {
            throw ProviderClientFailure.credentialUnavailable(provider: .codex)
        } catch CodexAuthFileSystemError.insecureFile {
            throw ProviderClientFailure.credentialInsecure(provider: .codex)
        } catch {
            throw ProviderClientFailure.credentialUnreadable(provider: .codex)
        }
        return try Self.decodeDocument(data: file.data, url: authFileURL, metadata: file.metadata)
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
            try await fileSystem.replaceItem(at: document.url, with: data, preserving: document.metadata)
        } catch {
            throw ProviderClientFailure.credentialPersistence(provider: .codex)
        }

        return try Self.decodeDocument(data: data, url: document.url, metadata: document.metadata)
    }

    private static func decodeDocument(
        data: Data,
        url: URL,
        metadata: CodexAuthFileMetadata
    ) throws -> CodexAuthDocument {
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
            metadata: metadata,
            accessToken: trimmedAccessToken,
            refreshToken: trimmedRefreshToken,
            accountID: trimmedAccountID
        )
    }
}

struct LocalCodexAuthFileSystem: CodexAuthFileSystem {
    func secureRead(at url: URL) async throws -> CodexSecureAuthFile {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT:
                throw CodexAuthFileSystemError.notFound
            case ELOOP:
                throw CodexAuthFileSystemError.insecureFile
            default:
                throw CodexAuthFileSystemError.openFailed
            }
        }
        defer {
            close(descriptor)
        }

        var status = stat()
        while fstat(descriptor, &status) != 0 {
            guard errno == EINTR else {
                throw CodexAuthFileSystemError.statFailed
            }
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw CodexAuthFileSystemError.insecureFile
        }

        let permissions = UInt16(status.st_mode & mode_t(0o777))
        guard Self.isRestrictive(permissions) else {
            throw CodexAuthFileSystemError.insecureFile
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead > 0 {
                data.append(contentsOf: buffer.prefix(bytesRead))
                continue
            }
            if bytesRead == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw CodexAuthFileSystemError.readFailed
        }

        return CodexSecureAuthFile(
            data: data,
            metadata: CodexAuthFileMetadata(
                ownerID: status.st_uid,
                groupID: status.st_gid,
                permissions: permissions
            )
        )
    }

    func replaceItem(
        at url: URL,
        with data: Data,
        preserving metadata: CodexAuthFileMetadata
    ) async throws {
        guard Self.isRestrictive(metadata.permissions) else {
            throw CodexAuthFileSystemError.insecureFile
        }

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
            throw CodexAuthFileSystemError.openFailed
        }

        var shouldClose = true
        defer {
            if shouldClose {
                close(fd)
            }
        }

        guard fchown(fd, metadata.ownerID, metadata.groupID) == 0 else {
            throw CodexAuthFileSystemError.chownFailed
        }
        guard fchmod(fd, mode_t(metadata.permissions)) == 0 else {
            throw CodexAuthFileSystemError.chmodFailed
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            var written = 0
            while written < buffer.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: written), buffer.count - written)
                if result > 0 {
                    written += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                throw CodexAuthFileSystemError.writeFailed
            }
        }

        while fsync(fd) != 0 {
            guard errno == EINTR else {
                throw CodexAuthFileSystemError.fsyncFailed
            }
        }
        shouldClose = false
        guard close(fd) == 0 else {
            throw CodexAuthFileSystemError.closeFailed
        }

        guard rename(temporaryURL.path, url.path) == 0 else {
            throw CodexAuthFileSystemError.renameFailed
        }
        shouldCleanUp = false
    }

    private static func isRestrictive(_ mode: UInt16) -> Bool {
        mode & 0o077 == 0
    }
}

enum CodexAuthFileSystemError: Error {
    case notFound
    case insecureFile
    case openFailed
    case statFailed
    case readFailed
    case chownFailed
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
