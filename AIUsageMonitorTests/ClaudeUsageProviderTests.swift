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
            cli: StubClaudeCLI(statuses: [loggedInStatus], usage: .failure(.usageRequestRejected)),
            usageCache: StubClaudeUsageCache(cache: cache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            overrides: automaticSource,
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
            overrides: statusLineSource,
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
            overrides: automaticSource,
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
            overrides: automaticSource,
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
            overrides: statusLineSource,
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
            overrides: automaticSource,
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

    func testReconnectWhileConnectedDoesNotReloginOrDropUsage() async throws {
        let cli = StubClaudeCLI(statuses: [loggedInStatus])
        let installer = StubClaudeStatusLineInstaller(installed: true)
        let cache = StubClaudeUsageCache(cache: nil)
        let provider = ClaudeUsageProvider(
            cli: cli,
            usageCache: cache,
            statusLineInstaller: installer,
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        let result = try await provider.startAuthentication()
        let loginStartCount = await cli.loginStartCount()
        let invalidationCount = await cache.invalidationCount()

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(loginStartCount, 0)
        XCTAssertEqual(invalidationCount, 0)
    }

    func testSigningInInvalidatesUsageFromThePreviousClaudeAccount() async throws {
        let signedOutStatus = ClaudeAuthenticationStatus(
            loggedIn: false,
            authMethod: nil,
            subscriptionType: nil
        )
        let cli = StubClaudeCLI(statuses: [signedOutStatus, loggedInStatus])
        let installer = StubClaudeStatusLineInstaller(installed: true)
        let cache = StubClaudeUsageCache(cache: nil)
        let provider = ClaudeUsageProvider(
            cli: cli,
            usageCache: cache,
            statusLineInstaller: installer,
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        _ = try await provider.startAuthentication()
        let loginStartCount = await cli.loginStartCount()
        let invalidationCount = await cache.invalidationCount()

        XCTAssertEqual(loginStartCount, 1)
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
            overrides: statusLineSource,
            clock: FixedClock(now: checkedAt)
        )
        let expiredProvider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus]),
            usageCache: StubClaudeUsageCache(cache: expiredCache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            overrides: statusLineSource,
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
            overrides: automaticSource,
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
            overrides: statusLineSource,
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
            overrides: automaticSource,
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

    func testLiveUsageMapsSessionWeeklyAndModelMetersFromCLI() async throws {
        let cli = StubClaudeCLI(statuses: [loggedInStatus], usage: .success(ClaudeUsageLimits(
            subscriptionType: "max",
            fiveHour: window(32, resetsIn: 60 * 60),
            sevenDay: window(81, resetsIn: 3 * 24 * 60 * 60),
            sevenDaySonnet: window(12, resetsIn: 3 * 24 * 60 * 60),
            modelScoped: [
                ClaudeModelUsageLimit(displayName: "Fable", window: window(34, resetsIn: 3 * 24 * 60 * 60)),
                ClaudeModelUsageLimit(displayName: "Opus", window: window(50, resetsIn: 3 * 24 * 60 * 60))
            ]
        )))
        let staleCache = ClaudeUsageCache(
            capturedAtUnixSeconds: checkedAt.timeIntervalSince1970,
            fiveHour: ClaudeRateLimitCache(usedPercentage: 1, resetsAtUnixSeconds: checkedAt.addingTimeInterval(60).timeIntervalSince1970),
            sevenDay: nil
        )
        let provider = ClaudeUsageProvider(
            cli: cli,
            usageCache: StubClaudeUsageCache(cache: staleCache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: false),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.health, .fresh(checkedAt: checkedAt))
        XCTAssertEqual(snapshot.meters.map(\.kind), [.claudeSession, .claudeWeekAll, .claudeWeekFable, .claudeWeekSonnet])
        XCTAssertEqual(snapshot.meters.map(\.utilization.value), [32, 81, 34, 12])
        XCTAssertEqual(snapshot.meters.first?.resetAt, checkedAt.addingTimeInterval(60 * 60))
        XCTAssertEqual(Set(snapshot.meters.map(\.display.planName)), ["Max"])
    }

    func testLiveUsageFailureFallsBackToFreshStatusLineCache() async throws {
        let cli = StubClaudeCLI(statuses: [loggedInStatus], usage: .failure(.usageRequestTimedOut))
        let cache = ClaudeUsageCache(
            capturedAtUnixSeconds: checkedAt.addingTimeInterval(-5 * 60).timeIntervalSince1970,
            fiveHour: ClaudeRateLimitCache(usedPercentage: 12, resetsAtUnixSeconds: checkedAt.addingTimeInterval(60 * 60).timeIntervalSince1970),
            sevenDay: ClaudeRateLimitCache(usedPercentage: 57, resetsAtUnixSeconds: checkedAt.addingTimeInterval(2 * 24 * 60 * 60).timeIntervalSince1970)
        )
        let provider = ClaudeUsageProvider(
            cli: cli,
            usageCache: StubClaudeUsageCache(cache: cache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()
        let usageReads = await cli.usageReadCount()

        XCTAssertEqual(usageReads, 1)
        XCTAssertEqual(snapshot.health, .fresh(checkedAt: checkedAt.addingTimeInterval(-5 * 60)))
        XCTAssertEqual(snapshot.meters.map(\.utilization.value), [12, 57])
    }

    func testLiveUsageFailureWithStaleCacheExplainsWhyLiveDataIsMissing() async throws {
        let capturedAt = checkedAt.addingTimeInterval(-2 * 60 * 60)
        let cache = ClaudeUsageCache(
            capturedAtUnixSeconds: capturedAt.timeIntervalSince1970,
            fiveHour: ClaudeRateLimitCache(usedPercentage: 12, resetsAtUnixSeconds: checkedAt.addingTimeInterval(60 * 60).timeIntervalSince1970),
            sevenDay: nil
        )
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus], usage: .failure(.usageRequestFailed)),
            usageCache: StubClaudeUsageCache(cache: cache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.health, .stale(
            checkedAt: checkedAt,
            staleSince: capturedAt,
            error: ProviderClientFailure.usageUnavailable(provider: .claude).sanitizedError
        ))
        XCTAssertEqual(snapshot.meters.map(\.kind), [.claudeSession])
    }

    func testLiveUsageFailureWithoutCacheIsAnErrorNotSilentNoData() async {
        for failure: ClaudeCLIFailure in [.usageRequestRejected, .usageRequestFailed, .usageRequestTimedOut, .usageUnavailable] {
            let provider = ClaudeUsageProvider(
                cli: StubClaudeCLI(statuses: [loggedInStatus], usage: .failure(failure)),
                usageCache: StubClaudeUsageCache(cache: nil),
                statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
                overrides: automaticSource,
                clock: FixedClock(now: checkedAt)
            )

            await assertFetchFails(provider, with: .usageUnavailable(provider: .claude))
        }
    }

    func testMissingClaudeCLIIsReportedAsNotFound() async {
        let provider = ClaudeUsageProvider(
            cli: ThrowingStatusClaudeCLI(failure: .executableNotFound),
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        await assertFetchFails(provider, with: .executableNotFound(provider: .claude))
        let status = await provider.connectionStatus()
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.detail, "Claude Code CLI was not found.")
        XCTAssertEqual(
            ProviderClientFailure.executableNotFound(provider: .claude).sanitizedError.code,
            .unavailable
        )
    }

    func testLiveUsageClampsOverrunAndSkipsEmptyOrExpiredWindows() async throws {
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus], usage: .success(ClaudeUsageLimits(
                fiveHour: ClaudeUsageLimitWindow(utilization: nil, resetsAt: checkedAt.addingTimeInterval(60)),
                sevenDay: window(103.5, resetsIn: 24 * 60 * 60),
                sevenDaySonnet: window(40, resetsIn: -60),
                modelScoped: [ClaudeModelUsageLimit(displayName: "Fable", window: ClaudeUsageLimitWindow(utilization: 5, resetsAt: nil))]
            ))),
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: false),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.meters.map(\.kind), [.claudeWeekAll])
        XCTAssertEqual(snapshot.meters.map(\.utilization.value), [100])
    }

    func testLiveUsageWithNoUsableWindowsAndNoCacheIsNoData() async throws {
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus], usage: .success(ClaudeUsageLimits())),
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: false),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.health, .noData(checkedAt: checkedAt))
    }

    func testNegativeLiveUtilizationIsMalformedWhenNoFallbackExists() async {
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus], usage: .success(ClaudeUsageLimits(
                fiveHour: window(-1, resetsIn: 60 * 60)
            ))),
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: false),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        await assertFetchFails(provider, with: .malformedResponse(provider: .claude))
    }

    func testStatusLineSourceOverrideNeverRunsLiveUsage() async throws {
        let cli = StubClaudeCLI(statuses: [loggedInStatus], usage: .success(ClaudeUsageLimits(
            fiveHour: window(99, resetsIn: 60 * 60)
        )))
        let provider = ClaudeUsageProvider(
            cli: cli,
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            overrides: statusLineSource,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()
        let usageReads = await cli.usageReadCount()

        XCTAssertEqual(usageReads, 0)
        XCTAssertEqual(snapshot.health, .noData(checkedAt: checkedAt))
    }

    func testConnectionStatusWithLiveUsageDoesNotRequireStatusLineBridge() async {
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus]),
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: false),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        let status = await provider.connectionStatus()

        XCTAssertEqual(status.state, .connected)
        XCTAssertEqual(status.usageSyncEnabled, true)
        XCTAssertEqual(status.detail, "Usage sync enabled")
    }

    func testLiveUsageWithNoUsableWindowsUsesAFreshStatusLineCache() async throws {
        let cache = ClaudeUsageCache(
            capturedAtUnixSeconds: checkedAt.timeIntervalSince1970,
            fiveHour: ClaudeRateLimitCache(usedPercentage: 12, resetsAtUnixSeconds: checkedAt.addingTimeInterval(60 * 60).timeIntervalSince1970),
            sevenDay: nil
        )
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus], usage: .success(ClaudeUsageLimits(
                fiveHour: ClaudeUsageLimitWindow(utilization: nil, resetsAt: nil)
            ))),
            usageCache: StubClaudeUsageCache(cache: cache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.health, .fresh(checkedAt: checkedAt))
        XCTAssertEqual(snapshot.meters.map(\.utilization.value), [12])
    }

    func testLiveFailureIsReportedEvenWhenTheFallbackCacheIsMalformed() async {
        // The live source is primary, so its failure is what the menu shows; a bad cache
        // is reported by --diagnose instead of replacing the live error.
        let malformedCache = ClaudeUsageCache(
            capturedAtUnixSeconds: checkedAt.timeIntervalSince1970,
            fiveHour: ClaudeRateLimitCache(usedPercentage: 101, resetsAtUnixSeconds: checkedAt.addingTimeInterval(60 * 60).timeIntervalSince1970),
            sevenDay: nil
        )
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus], usage: .failure(.usageRequestTimedOut)),
            usageCache: StubClaudeUsageCache(cache: malformedCache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        await assertFetchFails(provider, with: .usageUnavailable(provider: .claude))
    }

    func testStatusLineCacheWhoseWindowsHaveAllResetIsNoDataNotMalformed() async throws {
        let cache = ClaudeUsageCache(
            capturedAtUnixSeconds: checkedAt.addingTimeInterval(-6 * 60 * 60).timeIntervalSince1970,
            fiveHour: ClaudeRateLimitCache(usedPercentage: 90, resetsAtUnixSeconds: checkedAt.addingTimeInterval(-60).timeIntervalSince1970),
            sevenDay: nil
        )
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus]),
            usageCache: StubClaudeUsageCache(cache: cache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            overrides: statusLineSource,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.health, .noData(checkedAt: checkedAt))
    }

    func testCancellingAFetchStopsTheCLIAndDoesNotFallBackToTheCache() async throws {
        let pidURL = temporaryDirectory().appendingPathExtension("pid")
        let script = """
        if [ "$1 $2 $3" = "auth status --json" ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}'
          exit 0
        fi
        echo $$ > "\(pidURL.path)"
        while IFS= read -r line; do :; done
        """
        let freshCache = ClaudeUsageCache(
            capturedAtUnixSeconds: checkedAt.timeIntervalSince1970,
            fiveHour: ClaudeRateLimitCache(usedPercentage: 12, resetsAtUnixSeconds: checkedAt.addingTimeInterval(60 * 60).timeIntervalSince1970),
            sevenDay: nil
        )
        let provider = ClaudeUsageProvider(
            cli: scriptedClient(script, timeout: .seconds(30)),
            usageCache: StubClaudeUsageCache(cache: freshCache),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: true),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        let fetch = Task { try await provider.fetchUsageSnapshot() }
        var processID: pid_t?
        for _ in 0 ..< 500 where processID == nil {
            processID = (try? String(contentsOf: pidURL, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if processID == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let runningProcessID = try XCTUnwrap(processID, "The usage CLI never started")
        fetch.cancel()

        do {
            let snapshot = try await fetch.value
            XCTFail("A cancelled poll must not be turned into a result: \(snapshot.health.kind)")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        var stillRunning = true
        for _ in 0 ..< 100 where stillRunning {
            stillRunning = kill(runningProcessID, 0) == 0
            if stillRunning {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertFalse(stillRunning, "A cancelled poll must not leave the CLI running")
    }

    func testMalformedPerModelWindowDoesNotHideTheCoreLimits() async throws {
        let provider = ClaudeUsageProvider(
            cli: StubClaudeCLI(statuses: [loggedInStatus], usage: .success(ClaudeUsageLimits(
                fiveHour: window(30, resetsIn: 60 * 60),
                sevenDay: window(60, resetsIn: 24 * 60 * 60),
                sevenDaySonnet: window(-5, resetsIn: 24 * 60 * 60),
                modelScoped: [ClaudeModelUsageLimit(displayName: "Fable", window: window(-1, resetsIn: 24 * 60 * 60))]
            ))),
            usageCache: StubClaudeUsageCache(cache: nil),
            statusLineInstaller: StubClaudeStatusLineInstaller(installed: false),
            overrides: automaticSource,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.meters.map(\.kind), [.claudeSession, .claudeWeekAll])
    }

    func testCLIClientLetsTheCLIExitOnItsOwnAfterAnswering() async throws {
        let markerURL = temporaryDirectory().appendingPathExtension("exited")
        let script = """
        while IFS= read -r line; do
          case "$line" in
            *get_usage*) printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"\(ClaudeCLIClient.usageRequestID)","response":{"rate_limits":{}}}}' ;;
            *initialize*) printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"\(ClaudeCLIClient.initializeRequestID)","response":{}}}' ;;
          esac
        done
        sleep 0.3
        : > "\(markerURL.path)"
        """
        let client = ClaudeCLIClient(
            runtimeLocator: FixedClaudeRuntimeLocator(value: ClaudeCLIRuntime(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                argumentPrefix: ["-c", script, "claude-test"]
            )),
            usageTimeout: .seconds(10),
            usageExitGracePeriod: .seconds(3)
        )

        _ = try await client.readUsageLimits()

        var exitedCleanly = false
        for _ in 0 ..< 100 where !exitedCleanly {
            exitedCleanly = FileManager.default.fileExists(atPath: markerURL.path)
            if !exitedCleanly {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertTrue(exitedCleanly, "The CLI must be allowed to finish its own writes after answering")
    }

    func testCLIClientForceKillsACLIThatIgnoresTermination() async throws {
        let pidURL = temporaryDirectory().appendingPathExtension("pid")
        let script = """
        trap '' TERM
        echo $$ > "\(pidURL.path)"
        while :; do sleep 0.1; done
        """
        let client = scriptedClient(script, timeout: .milliseconds(300))

        await assertUsageReadFails(client, with: .usageRequestTimedOut)

        let pidText = try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let processID = try XCTUnwrap(pid_t(pidText))
        var stillRunning = true
        for _ in 0 ..< 300 where stillRunning {
            stillRunning = kill(processID, 0) == 0
            if stillRunning {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertFalse(stillRunning, "A CLI that ignores SIGTERM must still be stopped")
    }

    func testCLIClientReportsAnExitPromptlyEvenIfAChildKeepsOutputOpen() async {
        let client = scriptedClient("( sleep 15 ) & exit 2", timeout: .seconds(30))
        let started = ContinuousClock.now

        await assertUsageReadFails(client, with: .usageRequestFailed)

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testStatusLineBridgeSurvivesAPreviousCommandThatDoesNotReadItsInput() throws {
        let root = temporaryDirectory().appendingPathComponent("state", isDirectory: true)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        inputPipe.fileHandleForWriting.write(Data(
            #"{"rate_limits":{"five_hour":{"used_percentage":9,"resets_at":1783782000}}}"#.utf8
        ))
        inputPipe.fileHandleForWriting.closeFile()
        // The forwarded-to command already exited, and SIGPIPE may be ignored by inheritance.
        try outputPipe.fileHandleForReading.close()
        let previousHandler = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previousHandler) }

        let status = ClaudeStatusLineBridgeCommand.run(
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            forwardsInput: true,
            rootProvider: FixedStorageRootProvider(storageRoot: root)
        )

        XCTAssertEqual(status, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(ClaudeUsageCacheStore.cacheFileName).path
        ))
    }

    func testModelNamesMapToWeeklyMeterKinds() {
        XCTAssertEqual(ClaudeUsageProvider.weeklyMeterKind(forModelNamed: "Fable"), .claudeWeekFable)
        XCTAssertEqual(ClaudeUsageProvider.weeklyMeterKind(forModelNamed: "Claude Sonnet"), .claudeWeekSonnet)
        XCTAssertEqual(ClaudeUsageProvider.weeklyMeterKind(forModelNamed: "haiku"), .claudeWeekHaiku)
        XCTAssertNil(ClaudeUsageProvider.weeklyMeterKind(forModelNamed: "Opus"))
    }

    func testUsageDecoderReadsTheLiveCLIResponseShape() throws {
        // Shape captured from Claude Code 2.1.226 `get_usage`, with personal values replaced.
        let data = Data(
            """
            {
              "session": {"total_cost_usd": 0, "total_api_duration_ms": 0, "total_duration_ms": 0,
                          "total_lines_added": 0, "total_lines_removed": 0, "model_usage": {}},
              "subscription_type": "max",
              "rate_limits_available": true,
              "rate_limits": {
                "five_hour": {"utilization": 22, "resets_at": "2026-10-10T19:20:00.536580+00:00",
                              "limit_dollars": null, "used_dollars": null, "remaining_dollars": null, "locked_reason": null},
                "seven_day": {"utilization": 79.5, "resets_at": "2026-10-11T00:00:00Z"},
                "seven_day_opus": null,
                "seven_day_sonnet": {"utilization": "not-a-number", "resets_at": 1791676800},
                "model_scoped": [
                  {"display_name": "Fable", "utilization": 32, "resets_at": 1791676800},
                  {"utilization": 9},
                  {"display_name": "Haiku", "utilization": null, "resets_at": null}
                ],
                "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null}
              },
              "behaviors": null
            }
            """.utf8
        )

        let limits = try ClaudeCLIClient.decodeUsageLimits(data)

        XCTAssertEqual(limits.subscriptionType, "max")
        XCTAssertEqual(limits.fiveHour?.utilization, 22)
        XCTAssertEqual(limits.fiveHour?.resetsAt?.timeIntervalSince1970 ?? 0, 1_791_660_000.536, accuracy: 0.01)
        XCTAssertEqual(limits.sevenDay, ClaudeUsageLimitWindow(utilization: 79.5, resetsAt: Date(timeIntervalSince1970: 1_791_676_800)))
        XCTAssertNil(limits.sevenDaySonnet, "A malformed optional per-model window is skipped, not fatal")
        XCTAssertEqual(limits.modelScoped, [
            ClaudeModelUsageLimit(displayName: "Fable", window: ClaudeUsageLimitWindow(utilization: 32, resetsAt: Date(timeIntervalSince1970: 1_791_676_800))),
            ClaudeModelUsageLimit(displayName: "Haiku", window: ClaudeUsageLimitWindow(utilization: nil, resetsAt: nil))
        ])
    }

    func testUsageDecoderRejectsMissingOrMalformedCoreLimits() {
        let cases: [(String, ClaudeCLIFailure)] = [
            (#"{"subscription_type": null, "rate_limits_available": false, "rate_limits": null}"#, .usageUnavailable),
            (#"{"subscription_type": "max"}"#, .usageUnavailable),
            (#"{"rate_limits": {"five_hour": {"utilization": "high", "resets_at": null}}}"#, .malformedUsage),
            (#"{"rate_limits": {"seven_day": {"utilization": 5, "resets_at": "next tuesday"}}}"#, .malformedUsage),
            (#"[]"#, .malformedUsage)
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try ClaudeCLIClient.decodeUsageLimits(Data(json.utf8)), json) { error in
                XCTAssertEqual(error as? ClaudeCLIFailure, expected, json)
            }
        }
    }

    func testCLIClientReadsUsageThroughHardenedControlProtocol() async throws {
        let script = """
        # The exact argument list matters: print-mode stream-json output requires --verbose,
        # and safe mode plus no persistence keep hooks, MCP servers, and history out of polling.
        [ "$*" = "-p --input-format stream-json --output-format stream-json --verbose --safe-mode --no-session-persistence --strict-mcp-config" ] || exit 64
        while IFS= read -r line; do
          case "$line" in
            *get_usage*)
              printf '%s\\n' 'not json' '{"type":"system","subtype":"status"}'
              printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{}}}'
              printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"\(ClaudeCLIClient.usageRequestID)","response":{"subscription_type":"max","rate_limits":{"five_hour":{"utilization":41,"resets_at":"2026-10-10T19:20:00Z"},"seven_day":null}}}}' ;;
            *initialize*)
              printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"\(ClaudeCLIClient.initializeRequestID)","response":{"commands":[]}}}' ;;
          esac
        done
        """
        let client = scriptedClient(script)

        let limits = try await client.readUsageLimits()

        XCTAssertEqual(limits.subscriptionType, "max")
        XCTAssertEqual(limits.fiveHour?.utilization, 41)
        XCTAssertNil(limits.sevenDay)
    }

    func testCLIClientReportsRejectedUsageRequest() async {
        let script = """
        while IFS= read -r line; do
          case "$line" in
            *get_usage*) printf '%s\\n' '{"type":"control_response","response":{"subtype":"error","request_id":"\(ClaudeCLIClient.usageRequestID)","error":"Unsupported control request subtype: get_usage"}}' ;;
            *initialize*) printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"\(ClaudeCLIClient.initializeRequestID)","response":{}}}' ;;
          esac
        done
        """

        await assertUsageReadFails(scriptedClient(script), with: .usageRequestRejected)
    }

    func testCLIClientReportsCLIThatExitsBeforeAnswering() async {
        await assertUsageReadFails(scriptedClient("echo 'error: unknown option' >&2; exit 2"), with: .usageRequestFailed)
    }

    func testCLIClientTimesOutAndStopsAHungCLI() async throws {
        let pidURL = temporaryDirectory().appendingPathExtension("pid")
        let script = """
        echo $$ > "\(pidURL.path)"
        while IFS= read -r line; do :; done
        """
        let client = scriptedClient(script, timeout: .milliseconds(300))

        await assertUsageReadFails(client, with: .usageRequestTimedOut)

        let pidText = try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let processID = try XCTUnwrap(pid_t(pidText))
        var stillRunning = true
        for _ in 0 ..< 100 where stillRunning {
            stillRunning = kill(processID, 0) == 0
            if stillRunning {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertFalse(stillRunning, "A timed-out CLI must not be left running")
    }

    func testCLIClientWithoutTrustedExecutableReportsNotFound() async {
        let client = ClaudeCLIClient(runtimeLocator: ClaudeCLIRuntimeLocator(
            candidateExecutablePaths: ["/missing/claude"],
            isExecutable: { _ in false },
            isTrustedExecutable: { _ in true }
        ))

        await assertUsageReadFails(client, with: .executableNotFound)
        do {
            _ = try await client.authenticationStatus()
            XCTFail("Expected a missing executable")
        } catch {
            XCTAssertEqual(error as? ClaudeCLIFailure, .executableNotFound)
        }
    }

    private func window(_ utilization: Double, resetsIn interval: TimeInterval) -> ClaudeUsageLimitWindow {
        ClaudeUsageLimitWindow(utilization: utilization, resetsAt: checkedAt.addingTimeInterval(interval))
    }

    private func scriptedClient(_ script: String, timeout: Duration = .seconds(10)) -> ClaudeCLIClient {
        ClaudeCLIClient(
            runtimeLocator: FixedClaudeRuntimeLocator(value: ClaudeCLIRuntime(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                argumentPrefix: ["-c", script, "claude-test"]
            )),
            usageTimeout: timeout,
            usageExitGracePeriod: .milliseconds(200)
        )
    }

    private func assertUsageReadFails(
        _ client: ClaudeCLIClient,
        with expected: ClaudeCLIFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.readUsageLimits()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ClaudeCLIFailure, expected, file: file, line: line)
        }
    }

    private func assertFetchFails(
        _ provider: ClaudeUsageProvider,
        with expected: ProviderClientFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.fetchUsageSnapshot()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ProviderClientFailure, expected, file: file, line: line)
        }
    }

    private var automaticSource: FixedProviderRuntimeOverrides {
        FixedProviderRuntimeOverrides(claudeUsageSource: .automatic)
    }

    private var statusLineSource: FixedProviderRuntimeOverrides {
        FixedProviderRuntimeOverrides(claudeUsageSource: .statusLine)
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
    private let usage: Result<ClaudeUsageLimits, ClaudeCLIFailure>
    private var loginStarts = 0
    private var usageReads = 0

    init(
        statuses: [ClaudeAuthenticationStatus],
        usage: Result<ClaudeUsageLimits, ClaudeCLIFailure> = .failure(.usageRequestRejected)
    ) {
        self.statuses = statuses
        self.usage = usage
    }

    func readUsageLimits() async throws -> ClaudeUsageLimits {
        usageReads += 1
        return try usage.get()
    }

    func usageReadCount() -> Int {
        usageReads
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

private struct ThrowingStatusClaudeCLI: ClaudeCLICommunicating {
    let failure: ClaudeCLIFailure

    func authenticationStatus() async throws -> ClaudeAuthenticationStatus {
        throw failure
    }

    func startClaudeAIAuthentication() async throws {
        throw failure
    }

    func readUsageLimits() async throws -> ClaudeUsageLimits {
        throw failure
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
