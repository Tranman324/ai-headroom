import Darwin
import XCTest
@testable import AIUsageMonitor

final class CodexUsageProviderTests: XCTestCase {
    private let accessToken = "fake-codex-access-token"
    private let alternateAccessToken = "fake-codex-access-token-with-new-length"
    private let refreshToken = "fake-codex-refresh-token"
    private let rotatedRefreshToken = "fake-codex-rotated-refresh-token"
    private let accountID = "fake-codex-account-id"
    private let checkedAt = Date(timeIntervalSince1970: 1_783_756_800)

    func testAllPlansAndBothUsageWindowsMapCorrectly() async throws {
        let plans = [
            ("plus", "Plus"),
            ("prolite", "Pro 5x"),
            ("pro", "Pro 20x"),
            ("business", "Business")
        ]

        for (planType, displayName) in plans {
            let fileSystem = RecordingCodexAuthFileSystem(data: authJSON())
            let transport = RecordingProviderHTTPTransport(responses: [
                .success(ProviderHTTPResponse(statusCode: 200, data: usageJSON(planType: planType)))
            ])
            let provider = CodexUsageProvider(
                authStore: CodexAuthFileStore(homeDirectory: homeDirectory, fileSystem: fileSystem),
                transport: transport,
                clock: FixedClock(now: checkedAt)
            )

            let snapshot = try await provider.fetchUsageSnapshot()
            let requests = await transport.requests
            let encodedSnapshot = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))

            XCTAssertEqual(snapshot.provider, .codex)
            XCTAssertEqual(snapshot.health.kind, .fresh)
            XCTAssertEqual(snapshot.health.checkedAt, checkedAt)
            XCTAssertEqual(snapshot.meters.map(\.provider), [.codex, .codex])
            XCTAssertEqual(snapshot.meters.map(\.kind), [.codexSession, .codexWeek])
            XCTAssertEqual(snapshot.meters.map(\.display.planName), [displayName, displayName])
            XCTAssertEqual(snapshot.meters.map(\.utilization.value), [21, 68])
            XCTAssertEqual(snapshot.meters.map(\.resetAt), [
                date("2026-07-11T15:00:00Z"),
                date("2026-07-18T15:00:00Z")
            ])
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.method, "GET")
            XCTAssertEqual(requests.first?.url.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
            XCTAssertEqual(requests.first?.headers["Authorization"]?.hasPrefix("Bearer "), true)
            XCTAssertEqual(requests.first?.headers["Authorization"]?.count, "Bearer ".count + accessToken.count)
            XCTAssertTrue(requests.first?.headers["chatgpt-account-id"] == accountID)
            XCTAssertFalse(encodedSnapshot.contains(accessToken))
            XCTAssertFalse(encodedSnapshot.contains(refreshToken))
            XCTAssertFalse(encodedSnapshot.contains(String(data: authJSON(), encoding: .utf8)!))
        }
    }

    func testUnauthorizedUsageRefreshesOnceRotatesTokensPreservesUnknownFieldsAndRetries() async throws {
        let fileSystem = RecordingCodexAuthFileSystem(data: authJSON(includeUnknownFields: true), permissions: 0o600)
        let transport = RecordingProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 401, data: secretBody())),
            .success(ProviderHTTPResponse(statusCode: 200, data: refreshJSON(accessToken: alternateAccessToken, refreshToken: rotatedRefreshToken))),
            .success(ProviderHTTPResponse(statusCode: 200, data: usageJSON(planType: "pro")))
        ])
        let provider = CodexUsageProvider(
            authStore: CodexAuthFileStore(homeDirectory: homeDirectory, fileSystem: fileSystem),
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()
        let requests = await transport.requests
        let replacements = await fileSystem.replacements
        let storedJSON = try JSONDecoder().decode(ProviderJSONValue.self, from: try XCTUnwrap(replacements.first?.data))
        let refreshBody = try XCTUnwrap(String(data: try XCTUnwrap(requests[1].body), encoding: .utf8))

        XCTAssertEqual(snapshot.meters.map(\.kind), [.codexSession, .codexWeek])
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "GET"])
        XCTAssertEqual(requests.map(\.url.absoluteString), [
            "https://chatgpt.com/backend-api/wham/usage",
            "https://auth.openai.com/oauth/token",
            "https://chatgpt.com/backend-api/wham/usage"
        ])
        XCTAssertEqual(requests[1].headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertTrue(refreshBody.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
        XCTAssertTrue(refreshBody.contains("grant_type=refresh_token"))
        XCTAssertTrue(refreshBody.contains("refresh_token="))
        XCTAssertTrue(refreshBody.contains("scope=openid%20profile%20email"))
        XCTAssertEqual(requests[2].headers["Authorization"]?.count, "Bearer ".count + alternateAccessToken.count)
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(replacements.first?.url, authURL)
        XCTAssertEqual(replacements.first?.metadata.permissions, 0o600)
        XCTAssertEqual(replacements.first?.metadata.ownerID, getuid())
        XCTAssertEqual(replacements.first?.metadata.groupID, getgid())
        XCTAssertTrue(storedJSON.string(at: ["tokens", "access_token"]) == alternateAccessToken)
        XCTAssertTrue(storedJSON.string(at: ["tokens", "refresh_token"]) == rotatedRefreshToken)
        XCTAssertTrue(storedJSON.string(at: ["tokens", "account_id"]) == accountID)
        XCTAssertEqual(storedJSON.string(at: ["tokens", "unknown_token_key"]), "token metadata")
        XCTAssertEqual(storedJSON.string(at: ["profile", "name"]), "kept")
    }

    func testRefreshWithoutRotatedRefreshTokenPreservesExistingRefreshToken() async throws {
        let fileSystem = RecordingCodexAuthFileSystem(data: authJSON())
        let transport = RecordingProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 401, data: secretBody())),
            .success(ProviderHTTPResponse(statusCode: 200, data: refreshJSON(accessToken: alternateAccessToken, refreshToken: nil))),
            .success(ProviderHTTPResponse(statusCode: 200, data: usageJSON(planType: "plus")))
        ])
        let provider = CodexUsageProvider(
            authStore: CodexAuthFileStore(homeDirectory: homeDirectory, fileSystem: fileSystem),
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        _ = try await provider.fetchUsageSnapshot()
        let replacements = await fileSystem.replacements
        let storedJSON = try JSONDecoder().decode(ProviderJSONValue.self, from: try XCTUnwrap(replacements.first?.data))

        XCTAssertTrue(storedJSON.string(at: ["tokens", "access_token"]) == alternateAccessToken)
        XCTAssertTrue(storedJSON.string(at: ["tokens", "refresh_token"]) == refreshToken)
        XCTAssertTrue(storedJSON.string(at: ["tokens", "account_id"]) == accountID)
    }

    func testRepeatedNormalPollsRereadCanonicalFile() async throws {
        let fileSystem = RecordingCodexAuthFileSystem(data: authJSON())
        let transport = RecordingProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 200, data: usageJSON(planType: "plus"))),
            .success(ProviderHTTPResponse(statusCode: 200, data: usageJSON(planType: "plus")))
        ])
        let provider = CodexUsageProvider(
            authStore: CodexAuthFileStore(homeDirectory: homeDirectory, fileSystem: fileSystem),
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        _ = try await provider.fetchUsageSnapshot()
        await fileSystem.setData(authJSON(accessToken: alternateAccessToken))
        _ = try await provider.fetchUsageSnapshot()

        let readCount = await fileSystem.secureReadCount
        let requests = await transport.requests
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].headers["Authorization"]?.count, "Bearer ".count + accessToken.count)
        XCTAssertEqual(requests[1].headers["Authorization"]?.count, "Bearer ".count + alternateAccessToken.count)
    }

    func testDescriptorBoundReadCannotSubstituteBytesAfterValidation() async throws {
        let fileSystem = RecordingCodexAuthFileSystem(data: authJSON())
        await fileSystem.swapCanonicalDataAfterNextSecureRead(
            authJSON(accessToken: alternateAccessToken)
        )
        let transport = RecordingProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 200, data: usageJSON()))
        ])
        let provider = CodexUsageProvider(
            authStore: CodexAuthFileStore(homeDirectory: homeDirectory, fileSystem: fileSystem),
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        _ = try await provider.fetchUsageSnapshot()

        let secureReadCount = await fileSystem.secureReadCount
        let requests = await transport.requests
        XCTAssertEqual(secureReadCount, 1)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].headers["Authorization"]?.count, "Bearer ".count + accessToken.count)
        XCTAssertNotEqual(requests[0].headers["Authorization"]?.count, "Bearer ".count + alternateAccessToken.count)
    }

    func testMalformedAuthAndAPIFieldsFailWithSanitizedErrors() async {
        await assertProviderFailure(
            fileSystem: RecordingCodexAuthFileSystem(data: authJSON(), exists: false),
            responses: [],
            code: .unavailable,
            disallowing: [accessToken, refreshToken]
        )
        await assertProviderFailure(
            fileSystem: RecordingCodexAuthFileSystem(data: authJSON(), permissions: 0o644),
            responses: [],
            code: .unavailable,
            disallowing: [accessToken, refreshToken]
        )
        await assertProviderFailure(
            fileSystem: RecordingCodexAuthFileSystem(data: Data("{".utf8)),
            responses: [],
            code: .malformedResponse,
            disallowing: [accessToken, refreshToken]
        )
        await assertProviderFailure(
            fileSystem: RecordingCodexAuthFileSystem(data: Data(#"{"tokens":{"access_token":"fake-codex-access-token"}}"#.utf8)),
            responses: [],
            code: .malformedResponse,
            disallowing: [accessToken, refreshToken]
        )
        await assertProviderFailure(
            fileSystem: RecordingCodexAuthFileSystem(data: authJSON()),
            responses: [.success(ProviderHTTPResponse(statusCode: 200, data: usageJSON(missingSecondaryWindow: true)))],
            code: .malformedResponse,
            disallowing: [accessToken, refreshToken, String(data: usageJSON(missingSecondaryWindow: true), encoding: .utf8)!]
        )
        await assertProviderFailure(
            fileSystem: RecordingCodexAuthFileSystem(data: authJSON()),
            responses: [.success(ProviderHTTPResponse(statusCode: 200, data: usageJSON(planType: "enterprise"))) ],
            code: .malformedResponse,
            disallowing: [accessToken, refreshToken]
        )
        await assertProviderFailure(
            fileSystem: RecordingCodexAuthFileSystem(data: authJSON()),
            responses: [.success(ProviderHTTPResponse(statusCode: 200, data: usageJSON(primaryReset: "not-a-date"))) ],
            code: .malformedResponse,
            disallowing: [accessToken, refreshToken, String(data: usageJSON(primaryReset: "not-a-date"), encoding: .utf8)!]
        )
    }

    func testRefreshFailuresAndSecondUnauthorizedDoNotLoop() async {
        await assertRefreshFailure(
            responses: [
                .success(ProviderHTTPResponse(statusCode: 401, data: secretBody())),
                .success(ProviderHTTPResponse(statusCode: 500, data: secretBody()))
            ],
            code: .unavailable,
            expectedRequestCount: 2,
            expectedReplacementCount: 0
        )
        await assertRefreshFailure(
            responses: [
                .success(ProviderHTTPResponse(statusCode: 401, data: secretBody())),
                .success(ProviderHTTPResponse(statusCode: 200, data: Data(#"{"refresh_token":"fake-codex-rotated-refresh-token"}"#.utf8)))
            ],
            code: .malformedResponse,
            expectedRequestCount: 2,
            expectedReplacementCount: 0
        )

        let writeFailingFileSystem = RecordingCodexAuthFileSystem(data: authJSON())
        await writeFailingFileSystem.setReplaceFailureEnabled(true)
        await assertRefreshFailure(
            fileSystem: writeFailingFileSystem,
            responses: [
                .success(ProviderHTTPResponse(statusCode: 401, data: secretBody())),
                .success(ProviderHTTPResponse(statusCode: 200, data: refreshJSON(accessToken: alternateAccessToken, refreshToken: rotatedRefreshToken)))
            ],
            code: .unavailable,
            expectedRequestCount: 2,
            expectedReplacementCount: 1
        )

        await assertRefreshFailure(
            responses: [
                .success(ProviderHTTPResponse(statusCode: 401, data: secretBody())),
                .success(ProviderHTTPResponse(statusCode: 200, data: refreshJSON(accessToken: alternateAccessToken, refreshToken: rotatedRefreshToken))),
                .success(ProviderHTTPResponse(statusCode: 401, data: secretBody()))
            ],
            code: .unauthorized,
            expectedRequestCount: 3,
            expectedReplacementCount: 1
        )
    }

    func testLocalAuthFilesystemReplacementPreservesPermissionsAndCleansTemporaryFiles() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString)", isDirectory: true)
        let codexDirectory = temporaryHome.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let authURL = codexDirectory.appendingPathComponent("auth.json")
        let preservedGroupID = try XCTUnwrap(alternateSupplementaryGroup())
        try authJSON(includeUnknownFields: true).write(to: authURL)
        XCTAssertEqual(chown(authURL.path, getuid(), preservedGroupID), 0)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        defer {
            try? fileManager.removeItem(at: temporaryHome)
        }

        let store = CodexAuthFileStore(homeDirectory: temporaryHome, fileSystem: LocalCodexAuthFileSystem())
        let document = try await store.readAuthDocument()
        let originalMetadata = document.metadata
        _ = try await store.rotateTokens(in: document, accessToken: alternateAccessToken, refreshToken: nil)

        let updatedFile = try await LocalCodexAuthFileSystem().secureRead(at: authURL)
        let updatedJSON = try JSONDecoder().decode(ProviderJSONValue.self, from: updatedFile.data)
        let remainingFiles = try fileManager.contentsOfDirectory(atPath: codexDirectory.path)

        XCTAssertTrue(updatedJSON.string(at: ["tokens", "access_token"]) == alternateAccessToken)
        XCTAssertTrue(updatedJSON.string(at: ["tokens", "refresh_token"]) == refreshToken)
        XCTAssertEqual(updatedJSON.string(at: ["profile", "name"]), "kept")
        XCTAssertEqual(updatedFile.metadata, originalMetadata)
        XCTAssertEqual(updatedFile.metadata.ownerID, getuid())
        XCTAssertEqual(updatedFile.metadata.groupID, preservedGroupID)
        XCTAssertNotEqual(updatedFile.metadata.groupID, getgid())
        XCTAssertEqual(updatedFile.metadata.permissions, 0o600)
        XCTAssertEqual(updatedFile.metadata.permissions & 0o077, 0)
        XCTAssertEqual(remainingFiles, ["auth.json"])
    }

    func testLocalSecureReadRejectsSymlinkPermissiveAndNonRegularFiles() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("codex-secure-read-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryRoot)
        }

        let permissiveURL = temporaryRoot.appendingPathComponent("permissive.json")
        let symlinkURL = temporaryRoot.appendingPathComponent("auth.json")
        let directoryURL = temporaryRoot.appendingPathComponent("auth-directory", isDirectory: true)
        try authJSON().write(to: permissiveURL)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: permissiveURL.path)
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: permissiveURL)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)

        do {
            _ = try await LocalCodexAuthFileSystem().secureRead(at: permissiveURL)
            XCTFail("Expected permissive auth file rejection.")
        } catch CodexAuthFileSystemError.insecureFile {
        } catch {
            XCTFail("Expected insecure-file failure for permissive auth file.")
        }

        do {
            _ = try await LocalCodexAuthFileSystem().secureRead(at: symlinkURL)
            XCTFail("Expected symlink auth file rejection.")
        } catch CodexAuthFileSystemError.insecureFile {
        } catch {
            XCTFail("Expected insecure-file failure for symlink auth file.")
        }

        do {
            _ = try await LocalCodexAuthFileSystem().secureRead(at: directoryURL)
            XCTFail("Expected non-regular auth file rejection.")
        } catch CodexAuthFileSystemError.insecureFile {
        } catch {
            XCTFail("Expected insecure-file failure for non-regular auth file.")
        }
    }

    func testOwnershipPreservationFailureLeavesCanonicalDocumentUntouched() async throws {
        let originalData = authJSON(includeUnknownFields: true)
        let fileSystem = RecordingCodexAuthFileSystem(data: originalData)
        await fileSystem.setOwnershipPreservationFailureEnabled(true)
        let store = CodexAuthFileStore(homeDirectory: homeDirectory, fileSystem: fileSystem)
        let document = try await store.readAuthDocument()

        do {
            _ = try await store.rotateTokens(
                in: document,
                accessToken: alternateAccessToken,
                refreshToken: rotatedRefreshToken
            )
            XCTFail("Expected credential persistence failure.")
        } catch let failure as ProviderClientFailure {
            XCTAssertEqual(failure, .credentialPersistence(provider: .codex))
        } catch {
            XCTFail("Expected sanitized provider failure.")
        }

        let canonicalData = await fileSystem.currentData
        let replacements = await fileSystem.replacements
        XCTAssertEqual(canonicalData, originalData)
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(replacements.first?.metadata, document.metadata)
    }

    private func assertRefreshFailure(
        fileSystem: RecordingCodexAuthFileSystem? = nil,
        responses: [Result<ProviderHTTPResponse, Error>],
        code: ProviderErrorCode,
        expectedRequestCount: Int,
        expectedReplacementCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let fileSystem = fileSystem ?? RecordingCodexAuthFileSystem(data: authJSON())
        let transport = RecordingProviderHTTPTransport(responses: responses)
        let provider = CodexUsageProvider(
            authStore: CodexAuthFileStore(homeDirectory: homeDirectory, fileSystem: fileSystem),
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        await assertProviderFailure(from: provider, code: code, disallowing: [
            accessToken,
            refreshToken,
            alternateAccessToken,
            rotatedRefreshToken,
            String(data: secretBody(), encoding: .utf8)!
        ], file: file, line: line)

        let requests = await transport.requests
        let replacements = await fileSystem.replacements
        XCTAssertEqual(requests.count, expectedRequestCount, file: file, line: line)
        XCTAssertEqual(replacements.count, expectedReplacementCount, file: file, line: line)
    }

    private func assertProviderFailure(
        fileSystem: RecordingCodexAuthFileSystem,
        responses: [Result<ProviderHTTPResponse, Error>],
        code: ProviderErrorCode,
        disallowing forbiddenFragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let provider = CodexUsageProvider(
            authStore: CodexAuthFileStore(homeDirectory: homeDirectory, fileSystem: fileSystem),
            transport: RecordingProviderHTTPTransport(responses: responses),
            clock: FixedClock(now: checkedAt)
        )
        await assertProviderFailure(from: provider, code: code, disallowing: forbiddenFragments, file: file, line: line)
    }

    private func assertProviderFailure(
        from provider: CodexUsageProvider,
        code: ProviderErrorCode,
        disallowing forbiddenFragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.fetchUsageSnapshot()
            XCTFail("Expected provider failure.", file: file, line: line)
        } catch let failure as ProviderClientFailure {
            let description = failure.localizedDescription
            XCTAssertEqual(failure.code, code, file: file, line: line)
            for fragment in forbiddenFragments where !fragment.isEmpty {
                XCTAssertFalse(description.contains(fragment), file: file, line: line)
            }
        } catch {
            XCTFail("Expected sanitized provider failure.", file: file, line: line)
        }
    }

    private var homeDirectory: URL {
        URL(fileURLWithPath: "/tmp/fake-codex-home", isDirectory: true)
    }

    private var authURL: URL {
        homeDirectory.appendingPathComponent(".codex", isDirectory: true).appendingPathComponent("auth.json")
    }

    private func authJSON(
        accessToken: String? = nil,
        refreshToken: String? = nil,
        accountID: String? = nil,
        includeUnknownFields: Bool = false
    ) -> Data {
        let accessToken = accessToken ?? self.accessToken
        let refreshToken = refreshToken ?? self.refreshToken
        let accountID = accountID ?? self.accountID
        let unknownTokenFields = includeUnknownFields ? #","unknown_token_key":"token metadata""# : ""
        let unknownTopLevel = includeUnknownFields ? #","profile":{"name":"kept"}"# : ""
        return Data("""
        {
          "tokens": {
            "access_token": "\(accessToken)",
            "refresh_token": "\(refreshToken)",
            "account_id": "\(accountID)"\(unknownTokenFields)
          }\(unknownTopLevel)
        }
        """.utf8)
    }

    private func usageJSON(
        planType: String = "plus",
        primaryReset: String = "2026-07-11T15:00:00Z",
        missingSecondaryWindow: Bool = false
    ) -> Data {
        let secondaryWindow = missingSecondaryWindow ? "" : """
        ,
            "secondary_window": {
              "utilization": 68,
              "resets_at": "2026-07-18T15:00:00Z",
              "unknown_nested": true
            }
        """

        return Data("""
        {
          "rate_limit": {
            "primary_window": {
              "utilization": 21,
              "resets_at": "\(primaryReset)",
              "unknown_nested": true
            }\(secondaryWindow)
          },
          "plan_type": "\(planType)",
          "unknown_top": { "kept": true }
        }
        """.utf8)
    }

    private func refreshJSON(accessToken: String, refreshToken: String?) -> Data {
        let refreshFragment = refreshToken.map { #","refresh_token":"\#($0)""# } ?? ""
        return Data(#"{"access_token":"\#(accessToken)"\#(refreshFragment),"unknown":"kept"}"#.utf8)
    }

    private func secretBody() -> Data {
        Data(#"{"access_token":"fake-codex-access-token","refresh_token":"fake-codex-refresh-token"}"#.utf8)
    }

    private func date(_ rawValue: String) -> Date {
        ProviderJSON.parseISO8601(rawValue)!
    }

    private func alternateSupplementaryGroup() -> gid_t? {
        let count = getgroups(0, nil)
        guard count > 0 else {
            return nil
        }
        var groups = [gid_t](repeating: 0, count: Int(count))
        let loadedCount = groups.withUnsafeMutableBufferPointer { buffer in
            getgroups(count, buffer.baseAddress)
        }
        guard loadedCount == count else {
            return nil
        }
        return groups.first { $0 != getgid() }
    }
}

private struct CodexAuthReplacement: Equatable, Sendable {
    var url: URL
    var data: Data
    var metadata: CodexAuthFileMetadata
}

private actor RecordingCodexAuthFileSystem: CodexAuthFileSystem {
    private var exists: Bool
    private var data: Data
    private var metadata: CodexAuthFileMetadata
    private var dataToSwapAfterSecureRead: Data?
    private var shouldFailReplace = false
    private var shouldFailOwnershipPreservation = false
    private(set) var secureReadCount = 0
    private(set) var replacements: [CodexAuthReplacement] = []

    init(
        data: Data,
        permissions: UInt16 = 0o600,
        ownerID: uid_t = getuid(),
        groupID: gid_t = getgid(),
        exists: Bool = true
    ) {
        self.exists = exists
        self.data = data
        self.metadata = CodexAuthFileMetadata(
            ownerID: ownerID,
            groupID: groupID,
            permissions: permissions
        )
    }

    var currentData: Data {
        data
    }

    func setData(_ data: Data) {
        self.data = data
    }

    func swapCanonicalDataAfterNextSecureRead(_ data: Data) {
        dataToSwapAfterSecureRead = data
    }

    func setReplaceFailureEnabled(_ isEnabled: Bool) {
        shouldFailReplace = isEnabled
    }

    func setOwnershipPreservationFailureEnabled(_ isEnabled: Bool) {
        shouldFailOwnershipPreservation = isEnabled
    }

    func secureRead(at url: URL) async throws -> CodexSecureAuthFile {
        secureReadCount += 1
        guard exists else {
            throw CodexAuthFileSystemError.notFound
        }
        guard metadata.permissions & 0o077 == 0 else {
            throw CodexAuthFileSystemError.insecureFile
        }
        let file = CodexSecureAuthFile(data: data, metadata: metadata)
        if let dataToSwapAfterSecureRead {
            data = dataToSwapAfterSecureRead
            self.dataToSwapAfterSecureRead = nil
        }
        return file
    }

    func replaceItem(
        at url: URL,
        with data: Data,
        preserving metadata: CodexAuthFileMetadata
    ) async throws {
        replacements.append(CodexAuthReplacement(url: url, data: data, metadata: metadata))
        if shouldFailOwnershipPreservation || shouldFailReplace {
            throw URLError(.cannotWriteToFile)
        }
        self.data = data
        self.metadata = metadata
    }
}

private actor RecordingProviderHTTPTransport: ProviderHTTPTransporting {
    private(set) var requests: [ProviderHTTPRequest] = []
    private var responses: [Result<ProviderHTTPResponse, Error>]

    init(responses: [Result<ProviderHTTPResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return try responses.removeFirst().get()
    }
}
