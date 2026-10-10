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

    func testWeeklyPrimaryWindowWithoutSecondaryIsLabeledWeekly() async throws {
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

        // Codex reports the weekly limit as `primary` with no `secondary`; it is not a 5-hour session.
        XCTAssertEqual(snapshot.meters.map(\.kind), [.codexWeek])
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
        XCTAssertEqual(usage.primaryWindow?.usedPercent, 25)
        XCTAssertEqual(usage.primaryWindow?.windowDurationMinutes, 300)
        XCTAssertEqual(usage.primaryWindow?.resetsAtUnixSeconds, 1_783_782_000)
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

    func testWindowsAreClassifiedByDurationNotPosition() async throws {
        let snapshot = try await fetch(CodexAppServerUsage(
            planType: "plus",
            primaryWindow: CodexAppServerUsageWindow(usedPercent: 70, windowDurationMinutes: 10_080, resetsAtUnixSeconds: 1_783_987_000),
            secondaryWindow: CodexAppServerUsageWindow(usedPercent: 15, windowDurationMinutes: 300, resetsAtUnixSeconds: 1_783_782_000)
        ))

        XCTAssertEqual(snapshot.meters.map(\.kind), [.codexSession, .codexWeek])
        XCTAssertEqual(snapshot.meters.map(\.utilization.value), [15, 70])
    }

    func testWindowsUpToOneDayAreSessionsAndLongerOnesAreWeekly() async throws {
        for (duration, expected) in [(300.0, MeterKind.codexSession), (1_440, .codexSession), (1_441, .codexWeek)] {
            let snapshot = try await fetch(CodexAppServerUsage(
                planType: "plus",
                primaryWindow: CodexAppServerUsageWindow(usedPercent: 10, windowDurationMinutes: duration, resetsAtUnixSeconds: 1_783_782_000),
                secondaryWindow: nil
            ))
            XCTAssertEqual(snapshot.meters.map(\.kind), [expected], "duration \(duration)")
        }
    }

    func testWindowsWithoutDurationFallBackToPosition() async throws {
        let snapshot = try await fetch(CodexAppServerUsage(
            planType: "plus",
            primaryWindow: CodexAppServerUsageWindow(usedPercent: 10, windowDurationMinutes: nil, resetsAtUnixSeconds: 1_783_782_000),
            secondaryWindow: CodexAppServerUsageWindow(usedPercent: 20, windowDurationMinutes: nil, resetsAtUnixSeconds: 1_783_987_000)
        ))

        XCTAssertEqual(snapshot.meters.map(\.kind), [.codexSession, .codexWeek])
        XCTAssertEqual(snapshot.meters.map(\.utilization.value), [10, 20])
    }

    func testWindowsOfTheSameLengthKeepTheFullerOne() async throws {
        let snapshot = try await fetch(CodexAppServerUsage(
            planType: "plus",
            primaryWindow: CodexAppServerUsageWindow(usedPercent: 30, windowDurationMinutes: 10_080, resetsAtUnixSeconds: 1_783_987_000),
            secondaryWindow: CodexAppServerUsageWindow(usedPercent: 55, windowDurationMinutes: 43_200, resetsAtUnixSeconds: 1_785_000_000)
        ))

        XCTAssertEqual(snapshot.meters.map(\.kind), [.codexWeek])
        XCTAssertEqual(snapshot.meters.map(\.utilization.value), [55])
    }

    func testWindowsWithoutResetTimeAreSkipped() async throws {
        let partial = try await fetch(CodexAppServerUsage(
            planType: "plus",
            primaryWindow: CodexAppServerUsageWindow(usedPercent: 0, windowDurationMinutes: 300, resetsAtUnixSeconds: nil),
            secondaryWindow: CodexAppServerUsageWindow(usedPercent: 44, windowDurationMinutes: 10_080, resetsAtUnixSeconds: 1_783_987_000)
        ))
        let empty = try await fetch(CodexAppServerUsage(
            planType: "plus",
            primaryWindow: CodexAppServerUsageWindow(usedPercent: 0, windowDurationMinutes: 300, resetsAtUnixSeconds: nil),
            secondaryWindow: nil
        ))

        XCTAssertEqual(partial.meters.map(\.kind), [.codexWeek])
        XCTAssertEqual(empty.meters, [])
        XCTAssertEqual(empty.health, .noData(checkedAt: checkedAt))
    }

    func testNonPositiveWindowDurationIsMalformed() async {
        let provider = CodexUsageProvider(
            appServer: StubCodexAppServer(usage: CodexAppServerUsage(
                planType: "plus",
                primaryWindow: CodexAppServerUsageWindow(usedPercent: 10, windowDurationMinutes: 0, resetsAtUnixSeconds: 1_783_782_000),
                secondaryWindow: nil
            )),
            clock: FixedClock(now: checkedAt)
        )

        await assertFailure(from: provider, expected: .malformedResponse(provider: .codex))
    }

    func testMissingCodexCLIIsReportedAsNotFound() async {
        let provider = CodexUsageProvider(
            appServer: StubCodexAppServer(readFailure: .executableNotFound),
            clock: FixedClock(now: checkedAt)
        )

        await assertFailure(from: provider, expected: .executableNotFound(provider: .codex))
        let status = await provider.connectionStatus()
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.detail, "Codex CLI was not found.")
        XCTAssertEqual(
            ProviderClientFailure.executableNotFound(provider: .codex).errorDescription,
            "Codex CLI was not found. Install or update it, then refresh."
        )
    }

    func testAppServerClientWithoutTrustedExecutableReportsNotFound() async {
        let client = CodexAppServerClient(runtimeLocator: CodexAppServerRuntimeLocator(
            candidateExecutablePaths: ["/Applications/ChatGPT.app/Contents/Resources/codex"],
            isExecutable: { _ in false },
            isTrustedExecutable: { _ in true }
        ))

        do {
            _ = try await client.readUsage()
            XCTFail("Expected a missing executable")
        } catch {
            XCTAssertEqual(error as? CodexAppServerFailure, .executableNotFound)
        }
        await client.shutdown()
    }

    func testRuntimeLocatorFindsCodexAtTheRelocatedChatGPTPath() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let relocated = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let candidates = ProviderExecutableDiscovery.codexCandidatePaths(
            overrides: FixedProviderRuntimeOverrides(),
            homeDirectory: home,
            registeredApplicationURLs: []
        )
        let runtime = try XCTUnwrap(CodexAppServerRuntimeLocator(
            candidateExecutablePaths: candidates,
            isExecutable: { $0 == relocated },
            isTrustedExecutable: { _ in true }
        ).runtime())

        XCTAssertEqual(runtime.executableURL.path, relocated)
        XCTAssertEqual(runtime.arguments, ["app-server", "--stdio"])
        XCTAssertEqual(runtime.alternateArguments, ["app-server", "--listen", "stdio://"])
    }

    func testAppServerClientRelaunchesAServerThatStaysSilent() async throws {
        let counterURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let script = """
        launches=$(cat "\(counterURL.path)" 2>/dev/null || echo 0)
        launches=$((launches + 1))
        echo "$launches" > "\(counterURL.path)"
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *account*read*)
              if [ "$launches" -gt 1 ]; then
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","planType":"plus"}}}\\n' "$id"
              fi ;;
            *initialize*) printf '{"id":%s,"result":{}}\\n' "$id" ;;
          esac
        done
        """
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            executableArguments: ["-c", script],
            requestTimeout: .milliseconds(400)
        )

        // One timeout is tolerated; the second consecutive one replaces the server.
        for attempt in 1 ... CodexAppServerClient.timeoutsBeforeRestart {
            do {
                _ = try await client.readAccount()
                XCTFail("Expected attempt \(attempt) against the silent app-server to time out")
            } catch {
                XCTAssertEqual(error as? CodexAppServerFailure, .requestFailed)
            }
        }
        let account = try await client.readAccount()
        await client.shutdown()

        XCTAssertEqual(account, CodexAppServerAccount(type: "chatgpt", planType: "plus"))
        XCTAssertEqual(try String(contentsOf: counterURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    func testOneTimedOutRequestDoesNotFailOtherRequestsOrRestartTheServer() async throws {
        let counterURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let script = """
        launches=$(cat "\(counterURL.path)" 2>/dev/null || echo 0)
        echo $((launches + 1)) > "\(counterURL.path)"
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *login*start*) ;;
            *account*read*) sleep 0.5; printf '{"id":%s,"result":{"account":{"type":"chatgpt","planType":"pro"}}}\\n' "$id" ;;
            *initialize*) printf '{"id":%s,"result":{}}\\n' "$id" ;;
          esac
        done
        """
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            executableArguments: ["-c", script],
            requestTimeout: .seconds(1)
        )

        // The sign-in request times out at about 1.0 s while the account read is still being answered.
        let login = Task { try await client.startChatGPTAuthentication() }
        try await Task.sleep(for: .milliseconds(700))
        let account = try await client.readAccount()
        let loginResult = await login.result
        await client.shutdown()

        XCTAssertEqual(account?.planType, "pro")
        XCTAssertThrowsError(try loginResult.get())
        XCTAssertEqual(try String(contentsOf: counterURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    func testRestartForceKillsAnAppServerThatIgnoresTermination() async throws {
        let pidsURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let script = """
        trap '' TERM
        echo $$ >> "\(pidsURL.path)"
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *initialize*) printf '{"id":%s,"result":{}}\\n' "$id" ;;
          esac
        done
        while :; do sleep 0.1; done
        """
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            executableArguments: ["-c", script],
            requestTimeout: .milliseconds(300)
        )

        for _ in 1 ... CodexAppServerClient.timeoutsBeforeRestart {
            _ = try? await client.readAccount()
        }
        let firstText = try String(contentsOf: pidsURL, encoding: .utf8)
        let firstProcessID = try XCTUnwrap(firstText.split(separator: "\n").first.flatMap { pid_t(String($0)) })

        var stillRunning = true
        for _ in 0 ..< 300 where stillRunning {
            stillRunning = kill(firstProcessID, 0) == 0
            if stillRunning {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        await client.shutdown()
        XCTAssertFalse(stillRunning, "A hung app-server that ignores SIGTERM must not be leaked")
    }

    func testConcurrentCallersWaitForTheSameStartupIncludingItsRetry() async throws {
        let script = """
        case " $* " in *" --stdio "*) sleep 0.2; exit 2 ;; esac
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *account*read*) printf '{"id":%s,"result":{"account":{"type":"chatgpt","planType":"plus"}}}\\n' "$id" ;;
            *initialize*) printf '{"id":%s,"result":{}}\\n' "$id" ;;
          esac
        done
        """
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            executableArguments: ["-c", script, "codex-test", "app-server", "--stdio"],
            alternateExecutableArguments: ["-c", script, "codex-test", "app-server", "--listen", "stdio://"]
        )

        async let first = client.readAccount()
        async let second = client.readAccount()
        let accounts = try await [first, second]
        await client.shutdown()

        XCTAssertEqual(accounts.map { $0?.planType }, ["plus", "plus"])
    }

    func testAppServerClientRetriesWithoutStdioFlagWhenStartupExits() async throws {
        let script = """
        case " $* " in *" --stdio "*) exit 2 ;; esac
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *account*read*) printf '{"id":%s,"result":{"account":{"type":"chatgpt","planType":"pro"}}}\\n' "$id" ;;
            *initialize*) printf '{"id":%s,"result":{}}\\n' "$id" ;;
          esac
        done
        """
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            executableArguments: ["-c", script, "codex-test", "app-server", "--stdio"],
            alternateExecutableArguments: ["-c", script, "codex-test", "app-server"]
        )

        let account: CodexAppServerAccount?
        do {
            account = try await client.readAccount()
        } catch {
            await client.shutdown()
            throw error
        }
        await client.shutdown()

        XCTAssertEqual(account?.planType, "pro")
    }

    func testAppServerClientAcceptsMissingPrimaryWindowButNotMissingAllWindows() async throws {
        func client(rateLimits: String) -> CodexAppServerClient {
            let script = """
            while IFS= read -r line; do
              case "$line" in
                *rateLimits*read*) printf '%s\\n' '{"id":3,"result":{"rateLimits":\(rateLimits)}}' ;;
                *account*read*) printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"}}}' ;;
                *initialize*) printf '%s\\n' '{"id":1,"result":{}}' ;;
              esac
            done
            """
            return CodexAppServerClient(executableURL: URL(fileURLWithPath: "/bin/sh"), executableArguments: ["-c", script])
        }

        let secondaryOnly = client(rateLimits: #"{"primary":null,"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1783987000}}"#)
        let usage = try await secondaryOnly.readUsage()
        await secondaryOnly.shutdown()
        XCTAssertNil(usage.primaryWindow)
        XCTAssertEqual(usage.secondaryWindow?.usedPercent, 12)

        let noWindows = client(rateLimits: #"{"primary":null,"secondary":null}"#)
        do {
            _ = try await noWindows.readUsage()
            XCTFail("Expected malformed rate limits")
        } catch {
            XCTAssertEqual(error as? CodexAppServerFailure, .malformedResponse)
        }
        await noWindows.shutdown()
    }

    private func fetch(_ usage: CodexAppServerUsage) async throws -> ProviderUsageSnapshot {
        try await CodexUsageProvider(
            appServer: StubCodexAppServer(usage: usage),
            clock: FixedClock(now: checkedAt)
        ).fetchUsageSnapshot()
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
