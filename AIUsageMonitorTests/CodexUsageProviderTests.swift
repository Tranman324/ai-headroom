import XCTest
@testable import AIUsageMonitor

final class CodexUsageProviderTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_783_756_800)

    func testFetchMapsAppServerWindowsAndChatGPTPlan() async throws {
        let appServer = StubCodexAppServer(
            usage: CodexAppServerUsage(
                planType: "prolite",
                primaryWindow: CodexAppServerUsageWindow(
                    usedPercent: 21,
                    windowDurationMinutes: 300,
                    resetsAtUnixSeconds: 1_783_782_000
                ),
                secondaryWindow: CodexAppServerUsageWindow(
                    usedPercent: 68.5,
                    windowDurationMinutes: 10_080,
                    resetsAtUnixSeconds: 1_783_987_000
                )
            )
        )
        let provider = CodexUsageProvider(
            appServer: appServer,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.health, .fresh(checkedAt: checkedAt))
        XCTAssertEqual(snapshot.meters.map(\.kind), [.codexSession, .codexWeek])
        XCTAssertEqual(snapshot.meters.map(\.utilization.value), [21, 68.5])
        XCTAssertEqual(snapshot.meters.map(\.resetAt), [
            Date(timeIntervalSince1970: 1_783_782_000),
            Date(timeIntervalSince1970: 1_783_987_000)
        ])
        XCTAssertEqual(snapshot.meters.map(\.display.planName), ["Pro 5x", "Pro 5x"])
    }

    func testFetchAllowsMissingSecondaryWindow() async throws {
        let appServer = StubCodexAppServer(
            usage: CodexAppServerUsage(
                planType: "enterprise",
                primaryWindow: CodexAppServerUsageWindow(
                    usedPercent: 42,
                    windowDurationMinutes: 10_080,
                    resetsAtUnixSeconds: 1_783_987_000
                ),
                secondaryWindow: nil
            )
        )
        let provider = CodexUsageProvider(appServer: appServer, clock: FixedClock(now: checkedAt))

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.meters.map(\.kind), [.codexSession])
        XCTAssertEqual(snapshot.meters.first?.display.planName, "Enterprise")
    }

    func testAuthenticationRequiredRemainsProviderLocal() async {
        let provider = CodexUsageProvider(
            appServer: StubCodexAppServer(readFailure: .authenticationRequired),
            clock: FixedClock(now: checkedAt)
        )

        await assertFailure(from: provider, expected: .authenticationRequired(provider: .codex))
    }

    func testMissingRuntimeIsReportedWithoutCredentialFallback() async {
        let provider = CodexUsageProvider(
            appServer: StubCodexAppServer(readFailure: .executableUnavailable),
            clock: FixedClock(now: checkedAt)
        )

        await assertFailure(from: provider, expected: .runtimeUnavailable(provider: .codex))
    }

    func testMalformedRateLimitDataFailsLocally() async {
        let provider = CodexUsageProvider(
            appServer: StubCodexAppServer(
                usage: CodexAppServerUsage(
                    planType: "plus",
                    primaryWindow: CodexAppServerUsageWindow(
                        usedPercent: 101,
                        windowDurationMinutes: 300,
                        resetsAtUnixSeconds: 1_783_782_000
                    ),
                    secondaryWindow: nil
                )
            ),
            clock: FixedClock(now: checkedAt)
        )

        await assertFailure(from: provider, expected: .malformedResponse(provider: .codex))
    }

    func testStartAuthenticationReturnsDeviceCodeChallengeWithoutPersistingCredentials() async throws {
        let challenge = ProviderAuthenticationChallenge(
            provider: .codex,
            authorizationURL: try XCTUnwrap(URL(string: "https://auth.openai.example/device")),
            userCode: "TEST-1234"
        )
        let appServer = StubCodexAppServer(authenticationChallenge: challenge)
        let provider = CodexUsageProvider(appServer: appServer, clock: FixedClock(now: checkedAt))

        let result = try await provider.startAuthentication()
        let startCount = await appServer.authenticationStartCount()

        XCTAssertEqual(result, .challenge(challenge))
        XCTAssertEqual(startCount, 1)
    }

    func testConnectionStatusUsesAccountInsteadOfAnActiveLoginChallenge() async {
        let provider = CodexUsageProvider(
            appServer: StubCodexAppServer(
                account: CodexAppServerAccount(type: "chatgpt", planType: "pro")
            ),
            clock: FixedClock(now: checkedAt)
        )

        let status = await provider.connectionStatus()

        XCTAssertEqual(status.state, .connected)
        XCTAssertEqual(status.planName, "Pro 20x")
        XCTAssertTrue(status.usageSyncEnabled == true)
    }

    func testConnectionStatusDistinguishesDisconnectedAndUnavailable() async {
        let disconnected = CodexUsageProvider(
            appServer: StubCodexAppServer(account: nil),
            clock: FixedClock(now: checkedAt)
        )
        let unavailable = CodexUsageProvider(
            appServer: StubCodexAppServer(readFailure: .executableUnavailable),
            clock: FixedClock(now: checkedAt)
        )

        let disconnectedStatus = await disconnected.connectionStatus()
        let unavailableStatus = await unavailable.connectionStatus()

        XCTAssertEqual(disconnectedStatus.state, .disconnected)
        XCTAssertEqual(unavailableStatus.state, .unavailable)
    }

    func testRuntimeLocatorPrefersAnInstalledCodexExecutable() throws {
        let runtime = try XCTUnwrap(CodexAppServerRuntimeLocator(
            candidateExecutablePaths: ["/missing/codex", "/Applications/ChatGPT.app/Contents/Resources/codex"],
            isExecutable: { path in path == "/Applications/ChatGPT.app/Contents/Resources/codex" },
            isTrustedExecutable: { _ in true }
        ).runtime())

        XCTAssertEqual(runtime.executableURL.path, "/Applications/ChatGPT.app/Contents/Resources/codex")
        XCTAssertEqual(runtime.arguments, ["app-server", "--stdio"])
    }

    func testRuntimeLocatorRejectsUntrustedCodexExecutable() {
        let runtime = CodexAppServerRuntimeLocator(
            candidateExecutablePaths: ["/tmp/codex"],
            isExecutable: { _ in true },
            isTrustedExecutable: { _ in false }
        ).runtime()

        XCTAssertNil(runtime)
    }

    func testAppServerClientUsesStdioRateLimitContract() async throws {
        let script = """
        while IFS= read -r line; do
          case "$line" in
            *rateLimits*read*) printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1783782000},"secondary":null}}}' ;;
            *account*read*) printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"}}}' ;;
            *initialize*) printf '%s\\n' '{"id":1,"result":{}}' ;;
          esac
        done
        """
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            executableArguments: ["-c", script]
        )

        let usage: CodexAppServerUsage
        do {
            usage = try await client.readUsage()
        } catch {
            await client.shutdown()
            throw error
        }
        await client.shutdown()

        XCTAssertEqual(usage.planType, "plus")
        XCTAssertEqual(usage.primaryWindow.usedPercent, 25)
        XCTAssertEqual(usage.primaryWindow.windowDurationMinutes, 300)
        XCTAssertEqual(usage.primaryWindow.resetsAtUnixSeconds, 1_783_782_000)
        XCTAssertNil(usage.secondaryWindow)
    }

    func testAppServerClientUsesProviderOwnedDeviceCodeLoginContract() async throws {
        let script = """
        while IFS= read -r line; do
          case "$line" in
            *account*login*start*) printf '%s\\n' '{"id":2,"result":{"type":"chatgptDeviceCode","verificationUrl":"https://auth.openai.example/device","userCode":"LIVE-1234"}}' ;;
            *initialize*) printf '%s\\n' '{"id":1,"result":{}}' ;;
          esac
        done
        """
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            executableArguments: ["-c", script]
        )

        let challenge: ProviderAuthenticationChallenge
        do {
            challenge = try await client.startChatGPTAuthentication()
        } catch {
            await client.shutdown()
            throw error
        }
        await client.shutdown()

        XCTAssertEqual(challenge.provider, .codex)
        XCTAssertEqual(challenge.authorizationURL.absoluteString, "https://auth.openai.example/device")
        XCTAssertEqual(challenge.userCode, "LIVE-1234")
    }

    func testAppServerClientTimesOutNonresponsiveRequests() async {
        let script = """
        while IFS= read -r line; do
          case "$line" in
            *initialize*) printf '%s\\n' '{"id":1,"result":{}}' ;;
          esac
        done
        """
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            executableArguments: ["-c", script],
            requestTimeout: .milliseconds(20)
        )

        do {
            _ = try await client.readAccount()
            XCTFail("Expected the nonresponsive request to time out")
        } catch let failure as CodexAppServerFailure {
            XCTAssertEqual(failure, .requestFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await client.shutdown()
    }

    private func assertFailure(
        from provider: CodexUsageProvider,
        expected: ProviderClientFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.fetchUsageSnapshot()
            XCTFail("Expected provider failure", file: file, line: line)
        } catch let failure as ProviderClientFailure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private actor StubCodexAppServer: CodexAppServerCommunicating {
    private let account: CodexAppServerAccount?
    private let usage: CodexAppServerUsage?
    private let readFailure: CodexAppServerFailure?
    private let challenge: ProviderAuthenticationChallenge?
    private var starts = 0

    init(
        account: CodexAppServerAccount? = nil,
        usage: CodexAppServerUsage? = nil,
        readFailure: CodexAppServerFailure? = nil,
        authenticationChallenge: ProviderAuthenticationChallenge? = nil
    ) {
        self.account = account ?? usage.map {
            CodexAppServerAccount(type: "chatgpt", planType: $0.planType)
        }
        self.usage = usage
        self.readFailure = readFailure
        self.challenge = authenticationChallenge
    }

    func readAccount() async throws -> CodexAppServerAccount? {
        if let readFailure {
            throw readFailure
        }
        return account
    }

    func readUsage() async throws -> CodexAppServerUsage {
        if let readFailure {
            throw readFailure
        }
        guard let usage else {
            throw CodexAppServerFailure.malformedResponse
        }
        return usage
    }

    func startChatGPTAuthentication() async throws -> ProviderAuthenticationChallenge {
        starts += 1
        guard let challenge else {
            throw CodexAppServerFailure.requestFailed
        }
        return challenge
    }

    func authenticationStartCount() -> Int {
        starts
    }
}
