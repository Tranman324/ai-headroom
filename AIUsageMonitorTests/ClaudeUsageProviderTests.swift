import Darwin
import XCTest
@testable import AIUsageMonitor

final class ClaudeUsageProviderTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_783_756_800)

    func testFetchMapsStatusLineRateLimitsWithoutReadingCredentials() async throws {
        let cache = ClaudeUsageCache(
            capturedAtUnixSeconds: checkedAt.timeIntervalSince1970,
            fiveHour: ClaudeRateLimitCache(usedPercentage: 12, resetsAtUnixSeconds: 1_783_782_000),
            sevenDay: ClaudeRateLimitCache(usedPercentage: 57, resetsAtUnixSeconds: 1_784_419_200)
        )
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus]),
            usageCache: StubClaudeUsageCache(cache: cache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.health, .fresh(checkedAt: checkedAt))
        XCTAssertEqual(snapshot.meters.map(\.kind), [.claudeSession, .claudeWeekAll])
        XCTAssertEqual(snapshot.meters.map(\.utilization.value), [12, 57])
        XCTAssertEqual(snapshot.meters.map(\.display.planName), ["Max", "Max"])
    }

    func testConnectedAccountWithoutStatusLineDataReturnsNoData() async throws {
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus]),
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: false),
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.meters, [])
        XCTAssertEqual(snapshot.health, .noData(checkedAt: checkedAt))
    }

    func testDisconnectedAccountIsReportedAsAuthenticationRequired() async {
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [
                ClaudeAuthenticationStatus(loggedIn: false, authMethod: nil, subscriptionType: nil)
            ]),
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: false),
            clock: FixedClock(now: checkedAt)
        )

        do {
            _ = try await provider.fetchUsageSnapshot()
            XCTFail("Expected authentication failure")
        } catch let failure as ProviderClientFailure {
            XCTAssertEqual(failure, .authenticationRequired(provider: .claude))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAPIKeyLoginDoesNotMasqueradeAsClaudeOAuthConnection() async throws {
        let apiKeyStatus = ClaudeAuthenticationStatus(
            loggedIn: true,
            authMethod: "api_key",
            subscriptionType: nil
        )
        let cli = StubClaudeCLI(statuses: [apiKeyStatus, loggedInStatus])
        let installer = StubClaudeStatusLineInstaller(installed: false)
        let provider = ClaudeUsageProvider(
            cli: cli,
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: installer,
            clock: FixedClock(now: checkedAt)
        )

        let result = try await provider.startAuthentication()
        let loginStartCount = await cli.loginStartCount()
        let isInstalled = await installer.isInstalled()

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(loginStartCount, 1)
        XCTAssertTrue(isInstalled)
    }

    func testMalformedRateLimitFailsLocally() async {
        let cache = ClaudeUsageCache(
            capturedAtUnixSeconds: checkedAt.timeIntervalSince1970,
            fiveHour: ClaudeRateLimitCache(usedPercentage: 101, resetsAtUnixSeconds: 1_783_782_000),
            sevenDay: nil
        )
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus]),
            usageCache: StubClaudeUsageCache(cache: cache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            clock: FixedClock(now: checkedAt)
        )

        do {
            _ = try await provider.fetchUsageSnapshot()
            XCTFail("Expected malformed response")
        } catch let failure as ProviderClientFailure {
            XCTAssertEqual(failure, .malformedResponse(provider: .claude))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnableUsageSyncDoesNotForceReloginForConnectedAccount() async throws {
        let cli = StubClaudeCLI(statuses: [loggedInStatus])
        let installer = StubClaudeStatusLineInstaller(installed: false)
        let cache = StubClaudeUsageCache(cache: nil)
        let provider = ClaudeUsageProvider(
            cli: cli,
            usageCache: cache,
            statusLineInstaller: installer,
            clock: FixedClock(now: checkedAt)
        )

        let result = try await provider.startAuthentication()
        let loginStartCount = await cli.loginStartCount()
        let isInstalled = await installer.isInstalled()
        let invalidationCount = await cache.invalidationCount()

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(loginStartCount, 0)
        XCTAssertTrue(isInstalled)
        XCTAssertEqual(invalidationCount, 0)
    }

    func testReconnectInvalidatesUsageFromThePreviousClaudeAccount() async throws {
        let cli = StubClaudeCLI(statuses: [loggedInStatus, loggedInStatus])
        let installer = StubClaudeStatusLineInstaller(installed: true)
        let cache = StubClaudeUsageCache(cache: nil)
        let provider = ClaudeUsageProvider(
            cli: cli,
            usageCache: cache,
            statusLineInstaller: installer,
            clock: FixedClock(now: checkedAt)
        )

        _ = try await provider.startAuthentication()
        let invalidationCount = await cache.invalidationCount()

        XCTAssertEqual(invalidationCount, 1)
    }

    func testOldUsageCacheIsMarkedStaleThenExpires() async throws {
        let staleCache = ClaudeUsageCache(
            capturedAtUnixSeconds: checkedAt.addingTimeInterval(-60 * 60).timeIntervalSince1970,
            fiveHour: ClaudeRateLimitCache(usedPercentage: 12, resetsAtUnixSeconds: checkedAt.addingTimeInterval(60 * 60).timeIntervalSince1970),
            sevenDay: nil
        )
        let expiredCache = ClaudeUsageCache(
            capturedAtUnixSeconds: checkedAt.addingTimeInterval(-25 * 60 * 60).timeIntervalSince1970,
            fiveHour: ClaudeRateLimitCache(usedPercentage: 12, resetsAtUnixSeconds: checkedAt.addingTimeInterval(60 * 60).timeIntervalSince1970),
            sevenDay: nil
        )
        let staleProvider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus]),
            usageCache: StubClaudeUsageCache(cache: staleCache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            clock: FixedClock(now: checkedAt)
        )
        let expiredProvider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus]),
            usageCache: StubClaudeUsageCache(cache: expiredCache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            clock: FixedClock(now: checkedAt)
        )

        let staleSnapshot = try await staleProvider.fetchUsageSnapshot()
        let expiredSnapshot = try await expiredProvider.fetchUsageSnapshot()

        XCTAssertEqual(staleSnapshot.health.kind, .stale)
        XCTAssertEqual(expiredSnapshot.health.kind, .noData)
        XCTAssertTrue(expiredSnapshot.meters.isEmpty)
    }

    func testDisconnectedAccountUsesClaudeOwnedLoginThenInstallsBridge() async throws {
        let cli = StubClaudeCLI(statuses: [
            ClaudeAuthenticationStatus(loggedIn: false, authMethod: nil, subscriptionType: nil),
            loggedInStatus
        ])
        let installer = StubClaudeStatusLineInstaller(installed: false)
        let provider = ClaudeUsageProvider(
            cli: cli,
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: installer,
            clock: FixedClock(now: checkedAt)
        )

        let result = try await provider.startAuthentication()
        let loginStartCount = await cli.loginStartCount()
        let isInstalled = await installer.isInstalled()

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(loginStartCount, 1)
        XCTAssertTrue(isInstalled)
    }

    func testConnectionStatusSeparatesOAuthFromUsageSync() async {
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus]),
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: false),
            clock: FixedClock(now: checkedAt)
        )

        let status = await provider.connectionStatus()

        XCTAssertEqual(status.state, .connected)
        XCTAssertEqual(status.planName, "Max")
        XCTAssertEqual(status.usageSyncEnabled, false)
        XCTAssertEqual(status.detail, "Enable usage sync to show limits.")
    }

    func testConnectionStatusRejectsNonSubscriptionAuthentication() async {
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [
                ClaudeAuthenticationStatus(loggedIn: true, authMethod: "api_key", subscriptionType: nil)
            ]),
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            clock: FixedClock(now: checkedAt)
        )

        let status = await provider.connectionStatus()

        XCTAssertEqual(status.state, .disconnected)
        XCTAssertNil(status.planName)
        XCTAssertEqual(status.usageSyncEnabled, false)
    }

    func testCLIClientInvokesClaudeOwnedStatusAndLoginCommands() async throws {
        let temporaryRoot = temporaryDirectory()
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let markerURL = temporaryRoot.appendingPathComponent("login-called")
        let script = """
        if [ "$1 $2 $3" = "auth status --json" ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}'
          exit 0
        fi
        if [ "$1 $2" = "auth login" ] && [ "$3" = "--claudeai" ]; then
          : > "\(markerURL.path)"
          exit 0
        fi
        exit 64
        """
        let runtime = ClaudeCLIRuntime(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            argumentPrefix: ["-c", script, "claude-test"]
        )
        let client = ClaudeCLIClient(runtimeLocator: FixedClaudeRuntimeLocator(value: runtime))

        let status = try await client.authenticationStatus()
        try await client.startClaudeAIAuthentication()

        XCTAssertTrue(status.usesClaudeAIAuthentication)
        XCTAssertEqual(status.subscriptionType, "max")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testStatusLineBridgePersistsOnlyRateLimitsWithRestrictivePermissions() throws {
        let root = temporaryDirectory().appendingPathComponent("state", isDirectory: true)
        let input = Data(
            """
            {
              "session_id": "session-test",
              "email": "private@example.com",
              "access_token": "fake-access-token-value",
              "rate_limits": {
                "five_hour": {"used_percentage": 8, "resets_at": 1783782000},
                "seven_day": {"used_percentage": 34, "resets_at": 1784419200},
                "unknown_future_window": {"used_percentage": 2, "resets_at": 1785000000}
              }
            }
            """.utf8
        )

        try ClaudeUsageCacheStore.writeStatusLineInput(
            input,
            rootProvider: FixedStorageRootProvider(storageRoot: root),
            now: checkedAt
        )

        let cacheURL = root.appendingPathComponent(ClaudeUsageCacheStore.cacheFileName)
        let persisted = try Data(contentsOf: cacheURL)
        let text = try XCTUnwrap(String(data: persisted, encoding: .utf8))
        let cache = try JSONDecoder().decode(ClaudeUsageCache.self, from: persisted)
        XCTAssertEqual(cache.fiveHour?.usedPercentage, 8)
        XCTAssertEqual(cache.sevenDay?.usedPercentage, 34)
        XCTAssertFalse(text.contains("private@example.com"))
        XCTAssertFalse(text.contains("fake-access-token-value"))
        XCTAssertFalse(text.contains("session-test"))
        XCTAssertEqual(try LocalPersistence.permissions(of: root), 0o700)
        XCTAssertEqual(try LocalPersistence.permissions(of: cacheURL), 0o600)
    }

    func testStatusLineBridgeCommandForwardsInputWithoutPersistingSecrets() throws {
        let root = temporaryDirectory().appendingPathComponent("state", isDirectory: true)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let rawInput = Data(
            """
            {"access_token":"do-not-persist","rate_limits":{"five_hour":{"used_percentage":9,"resets_at":1783782000}}}
            """.utf8
        )
        inputPipe.fileHandleForWriting.write(rawInput)
        inputPipe.fileHandleForWriting.closeFile()

        let status = ClaudeStatusLineBridgeCommand.run(
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            forwardsInput: true,
            rootProvider: FixedStorageRootProvider(storageRoot: root)
        )
        outputPipe.fileHandleForWriting.closeFile()
        let forwardedInput = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let persisted = try Data(contentsOf: root.appendingPathComponent(ClaudeUsageCacheStore.cacheFileName))

        XCTAssertEqual(status, 0)
        XCTAssertEqual(forwardedInput, rawInput)
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("do-not-persist"))
    }

    func testStatusLineBridgeReadsDelayedPipeChunksThroughEOF() throws {
        let root = temporaryDirectory().appendingPathComponent("state", isDirectory: true)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let firstChunk = Data(
            "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":9,".utf8
        )
        let secondChunk = Data(
            "\"resets_at\":1783782000}}}".utf8
        )
        let rawInput = firstChunk + secondChunk
        let writer = inputPipe.fileHandleForWriting
        DispatchQueue.global().async {
            writer.write(firstChunk)
            usleep(25_000)
            writer.write(secondChunk)
            writer.closeFile()
        }

        let status = ClaudeStatusLineBridgeCommand.run(
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            forwardsInput: true,
            rootProvider: FixedStorageRootProvider(storageRoot: root)
        )
        outputPipe.fileHandleForWriting.closeFile()
        let forwardedInput = outputPipe.fileHandleForReading.readDataToEndOfFile()

        XCTAssertEqual(status, 0)
        XCTAssertEqual(forwardedInput, rawInput)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(ClaudeUsageCacheStore.cacheFileName).path
        ))
    }

    func testStatusLineBridgeRejectsOversizedInputWithoutWritingCache() throws {
        let root = temporaryDirectory().appendingPathComponent("state", isDirectory: true)
        let inputDirectory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: inputDirectory,
            withIntermediateDirectories: true
        )
        let inputURL = inputDirectory.appendingPathComponent("oversized-statusline.json")
        try Data(
            repeating: 0x41,
            count: ClaudeStatusLineBridgeCommand.maximumInputBytes + 1
        ).write(to: inputURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }

        let status = ClaudeStatusLineBridgeCommand.run(
            input: input,
            output: FileHandle.nullDevice,
            rootProvider: FixedStorageRootProvider(storageRoot: root)
        )

        XCTAssertEqual(status, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(ClaudeUsageCacheStore.cacheFileName).path
        ))
    }

    func testCacheReaderRejectsBroadenedPermissionsAndWriterRepairsThem() async throws {
        let root = temporaryDirectory().appendingPathComponent("state", isDirectory: true)
        let rootProvider = FixedStorageRootProvider(storageRoot: root)
        let input = Data(
            """
            {"rate_limits":{"five_hour":{"used_percentage":8,"resets_at":1783782000}}}
            """.utf8
        )
        try ClaudeUsageCacheStore.writeStatusLineInput(input, rootProvider: rootProvider, now: checkedAt)
        let cacheURL = root.appendingPathComponent(ClaudeUsageCacheStore.cacheFileName)
        XCTAssertEqual(chmod(cacheURL.path, 0o644), 0)
        let store = ClaudeUsageCacheStore(rootProvider: rootProvider)

        do {
            _ = try await store.readUsageCache()
            XCTFail("Expected insecure cache permissions to be rejected")
        } catch let failure as ProviderClientFailure {
            XCTAssertEqual(failure, .credentialInsecure(provider: .claude))
        }

        try ClaudeUsageCacheStore.writeStatusLineInput(input, rootProvider: rootProvider, now: checkedAt)
        XCTAssertEqual(try LocalPersistence.permissions(of: cacheURL), 0o600)
        XCTAssertEqual(try LocalPersistence.permissions(of: root), 0o700)
    }

    func testInstallerPreservesUnknownSettingsAndExistingStatusLineCommand() async throws {
        let temporaryRoot = temporaryDirectory()
        let settingsDirectory = temporaryRoot.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        let existingSettings: [String: Any] = [
            "theme": "dark",
            "futureField": ["enabled": true],
            "statusLine": [
                "type": "command",
                "command": "printf existing",
                "padding": 3
            ]
        ]
        try JSONSerialization.data(withJSONObject: existingSettings).write(to: settingsURL)
        let stateRoot = temporaryRoot.appendingPathComponent("state", isDirectory: true)
        let installer = ClaudeStatusLineInstaller(
            settingsURL: settingsURL,
            rootProvider: FixedStorageRootProvider(storageRoot: stateRoot),
            executableURL: URL(fileURLWithPath: "/Applications/AI Usage Monitor.app/Contents/MacOS/AI Usage Monitor")
        )

        try await installer.install()

        let updated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        let statusLine = try XCTUnwrap(updated["statusLine"] as? [String: Any])
        let isInstalled = await installer.isInstalled()
        XCTAssertEqual(updated["theme"] as? String, "dark")
        XCTAssertNotNil(updated["futureField"])
        XCTAssertEqual(statusLine["padding"] as? Int, 3)
        let installedCommand = try XCTUnwrap(statusLine["command"] as? String)
        XCTAssertTrue(installedCommand.contains("--claude-statusline --forward-statusline-input"))
        XCTAssertTrue(installedCommand.contains("printf existing"))
        XCTAssertEqual(installedCommand.components(separatedBy: "printf existing").count - 1, 1)
        XCTAssertTrue(isInstalled)
        XCTAssertEqual(try LocalPersistence.permissions(of: settingsURL), 0o600)
    }

    func testInstallerDoesNotAcceptAnotherExecutableOrSubstringAsInstalled() async throws {
        let temporaryRoot = temporaryDirectory()
        let settingsDirectory = temporaryRoot.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        let staleSettings: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": "'/Volumes/Old/AI Usage Monitor' --claude-statusline --forward-statusline-input | ( printf preserved )"
            ]
        ]
        try JSONSerialization.data(withJSONObject: staleSettings).write(to: settingsURL)
        let stateRoot = temporaryRoot.appendingPathComponent("state", isDirectory: true)
        let installer = ClaudeStatusLineInstaller(
            settingsURL: settingsURL,
            rootProvider: FixedStorageRootProvider(storageRoot: stateRoot),
            executableURL: URL(fileURLWithPath: "/Applications/AI Usage Monitor.app/Contents/MacOS/AI Usage Monitor")
        )

        let wasInstalled = await installer.isInstalled()
        XCTAssertFalse(wasInstalled)
        try await installer.install()

        let updated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        let statusLine = try XCTUnwrap(updated["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(statusLine["command"] as? String)
        let isInstalled = await installer.isInstalled()
        XCTAssertTrue(isInstalled)
        XCTAssertFalse(command.contains("/Volumes/Old"))
        XCTAssertTrue(command.contains("printf preserved"))
    }

    func testInstallerMigratesAndDeletesLegacyCommandCopy() async throws {
        let temporaryRoot = temporaryDirectory()
        let settingsDirectory = temporaryRoot.appendingPathComponent("claude", isDirectory: true)
        let stateRoot = temporaryRoot.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try LocalPersistence.ensureRoot(at: stateRoot)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: [
            "statusLine": [
                "type": "command",
                "command": "'/Volumes/Old/AI Usage Monitor' --claude-statusline"
            ]
        ]).write(to: settingsURL)
        let legacyURL = stateRoot.appendingPathComponent(ClaudeStatusLineInstaller.legacyConfigurationFileName)
        try LocalPersistence.atomicWrite(
            try JSONSerialization.data(withJSONObject: ["previousCommand": "printf legacy-preserved"]),
            to: legacyURL
        )
        let installer = ClaudeStatusLineInstaller(
            settingsURL: settingsURL,
            rootProvider: FixedStorageRootProvider(storageRoot: stateRoot),
            executableURL: URL(fileURLWithPath: "/Applications/AI Usage Monitor.app/Contents/MacOS/AI Usage Monitor")
        )

        try await installer.install()

        let updated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        let statusLine = try XCTUnwrap(updated["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(statusLine["command"] as? String)
        XCTAssertTrue(command.contains("printf legacy-preserved"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testInstallerMigratesLegacyCommandIntoCurrentBareBridge() async throws {
        let temporaryRoot = temporaryDirectory()
        let settingsDirectory = temporaryRoot.appendingPathComponent("claude", isDirectory: true)
        let stateRoot = temporaryRoot.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try LocalPersistence.ensureRoot(at: stateRoot)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        let executableURL = URL(
            fileURLWithPath: "/Applications/AI Usage Monitor.app/Contents/MacOS/AI Usage Monitor"
        )
        try JSONSerialization.data(withJSONObject: [
            "statusLine": [
                "type": "command",
                "command": "'\(executableURL.path)' --claude-statusline"
            ]
        ]).write(to: settingsURL)
        let legacyURL = stateRoot.appendingPathComponent(ClaudeStatusLineInstaller.legacyConfigurationFileName)
        try LocalPersistence.atomicWrite(
            try JSONSerialization.data(withJSONObject: ["previousCommand": "printf same-path-preserved"]),
            to: legacyURL
        )
        let installer = ClaudeStatusLineInstaller(
            settingsURL: settingsURL,
            rootProvider: FixedStorageRootProvider(storageRoot: stateRoot),
            executableURL: executableURL
        )

        try await installer.install()

        let updated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        let statusLine = try XCTUnwrap(updated["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(statusLine["command"] as? String)
        XCTAssertTrue(command.contains("--forward-statusline-input"))
        XCTAssertTrue(command.contains("printf same-path-preserved"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testRuntimeLocatorFindsHomebrewClaudeWithoutFinderPath() throws {
        let runtime = try XCTUnwrap(ClaudeCLIRuntimeLocator(
            candidateExecutablePaths: ["/missing/claude", "/opt/homebrew/bin/claude"],
            isExecutable: { $0 == "/opt/homebrew/bin/claude" },
            isTrustedExecutable: { _ in true }
        ).runtime())

        XCTAssertEqual(
            runtime.executableURL,
            URL(fileURLWithPath: "/opt/homebrew/bin/claude").resolvingSymlinksInPath()
        )
        XCTAssertEqual(runtime.argumentPrefix, [])
    }

    func testRuntimeLocatorRejectsUnsignedClaudeImpersonator() {
        let runtime = ClaudeCLIRuntimeLocator(
            candidateExecutablePaths: ["/tmp/claude"],
            isExecutable: { _ in true },
            isTrustedExecutable: { _ in false }
        ).runtime()

        XCTAssertNil(runtime)
    }

    private var loggedInStatus: ClaudeAuthenticationStatus {
        ClaudeAuthenticationStatus(loggedIn: true, authMethod: "claude.ai", subscriptionType: "max")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor StubClaudeCLI: ClaudeCLICommunicating {
    private var statuses: [ClaudeAuthenticationStatus]
    private var loginStarts = 0

    init(statuses: [ClaudeAuthenticationStatus]) {
        self.statuses = statuses
    }

    func authenticationStatus() async throws -> ClaudeAuthenticationStatus {
        guard !statuses.isEmpty else {
            throw ClaudeCLIFailure.malformedStatus
        }
        if statuses.count == 1 {
            return statuses[0]
        }
        return statuses.removeFirst()
    }

    func startClaudeAIAuthentication() async throws {
        loginStarts += 1
    }

    func loginStartCount() -> Int {
        loginStarts
    }
}

private struct FixedClaudeRuntimeLocator: ClaudeCLIRuntimeLocating {
    let value: ClaudeCLIRuntime

    func runtime() -> ClaudeCLIRuntime? {
        value
    }
}

private actor StubClaudeUsageCache: ClaudeUsageCacheReading {
    private var cache: ClaudeUsageCache?
    private var invalidations = 0

    init(cache: ClaudeUsageCache?) {
        self.cache = cache
    }

    func readUsageCache() async throws -> ClaudeUsageCache? {
        cache
    }

    func invalidateUsageCache() async throws {
        invalidations += 1
        cache = nil
    }

    func invalidationCount() -> Int {
        invalidations
    }
}

private actor StubClaudeStatusLineInstaller: ClaudeStatusLineInstalling {
    private var installed: Bool

    init(installed: Bool) {
        self.installed = installed
    }

    func isInstalled() async -> Bool {
        installed
    }

    func install() async throws {
        installed = true
    }
}
