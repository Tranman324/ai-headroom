import XCTest
@testable import AIUsageMonitor

final class ProviderRecoveryTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testCodexCandidatesPutOverrideFirstThenCurrentAndLegacyChatGPTLayouts() {
        let home = makeTemporaryDirectory().path
        let paths = ProviderExecutableDiscovery.codexCandidatePaths(
            overrides: FixedProviderRuntimeOverrides(codexExecutablePath: "/opt/custom/codex"),
            homeDirectory: home,
            registeredApplicationURLs: [
                URL(fileURLWithPath: "/Volumes/Apps/ChatGPT.app"),
                URL(fileURLWithPath: "/Applications/ChatGPT.app")
            ]
        )

        let current = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let legacy = "/Applications/ChatGPT.app/Contents/Resources/codex"
        XCTAssertEqual(paths.first, "/opt/custom/codex")
        XCTAssertLessThan(try XCTUnwrap(paths.firstIndex(of: current)), try XCTUnwrap(paths.firstIndex(of: legacy)))
        XCTAssertTrue(paths.contains("/Volumes/Apps/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
        XCTAssertTrue(paths.contains("\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/codex"))
        XCTAssertEqual(paths.count, Set(paths).count, "Registered copies of a default location are not repeated")
    }

    func testEditorExtensionExecutablesAreListedNewestVersionFirst() throws {
        let home = makeTemporaryDirectory()
        let extensions = home.appendingPathComponent(".vscode/extensions", isDirectory: true)
        for name in [
            "anthropic.claude-code-2.1.9-darwin-arm64",
            "anthropic.claude-code-2.1.296-darwin-arm64",
            "anthropic.claude-code-2.1.10-darwin-arm64",
            "openai.chatgpt-26.1007.21434-darwin-arm64"
        ] {
            try FileManager.default.createDirectory(
                at: extensions.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let paths = ProviderExecutableDiscovery.claudeCandidatePaths(
            overrides: FixedProviderRuntimeOverrides(claudeExecutablePath: "/opt/custom/claude"),
            homeDirectory: home.path
        )

        XCTAssertEqual(paths.first, "/opt/custom/claude")
        XCTAssertEqual(Array(paths.suffix(3)), [
            "\(extensions.path)/anthropic.claude-code-2.1.296-darwin-arm64/resources/native-binary/claude",
            "\(extensions.path)/anthropic.claude-code-2.1.10-darwin-arm64/resources/native-binary/claude",
            "\(extensions.path)/anthropic.claude-code-2.1.9-darwin-arm64/resources/native-binary/claude"
        ])
        XCTAssertLessThan(
            try XCTUnwrap(paths.firstIndex(of: "/opt/homebrew/bin/claude")),
            try XCTUnwrap(paths.firstIndex { $0.contains("anthropic.claude-code-") })
        )
    }

    func testUntrustedCandidateIsSkippedForTheNextTrustedOne() throws {
        let locator = ClaudeCLIRuntimeLocator(
            candidateExecutablePaths: ["/nonexistent/impostor/claude", "/nonexistent/trusted/claude"],
            isExecutable: { _ in true },
            isTrustedExecutable: { $0.path == "/nonexistent/trusted/claude" }
        )

        let runtime = try XCTUnwrap(locator.runtime())

        XCTAssertEqual(runtime.executableURL.path, "/nonexistent/trusted/claude")
        XCTAssertEqual(locator.inspectCandidates().map(\.status), [.untrusted, .trusted])
    }

    func testClaudeOverridePathStillRequiresTheAnthropicSignature() {
        let impostor = "/nonexistent/impostor/claude"
        let locator = ClaudeCLIRuntimeLocator(
            overrides: FixedProviderRuntimeOverrides(claudeExecutablePath: impostor),
            isExecutable: { $0 == impostor },
            isTrustedExecutable: { $0.path != impostor }
        )

        XCTAssertNil(locator.runtime(), "An override must never bypass the signature check")
        XCTAssertEqual(locator.inspectCandidates().first, ProviderExecutableCandidate(path: impostor, status: .untrusted))
    }

    func testCodexOverridePathStillRequiresTheOpenAISignature() {
        let impostor = "/nonexistent/impostor/codex"
        let locator = CodexAppServerRuntimeLocator(
            overrides: FixedProviderRuntimeOverrides(codexExecutablePath: impostor),
            isExecutable: { $0 == impostor },
            isTrustedExecutable: { $0.path != impostor }
        )

        XCTAssertNil(locator.runtime(), "An override must never bypass the signature check")
        XCTAssertEqual(locator.inspectCandidates().first, ProviderExecutableCandidate(path: impostor, status: .untrusted))
    }

    func testTrustedOverridePathIsPreferredOverDefaultLocations() throws {
        let override = "/nonexistent/custom/codex"
        let locator = CodexAppServerRuntimeLocator(
            overrides: FixedProviderRuntimeOverrides(codexExecutablePath: override),
            isExecutable: { _ in true },
            isTrustedExecutable: { _ in true }
        )

        XCTAssertEqual(try XCTUnwrap(locator.runtime()).executableURL.path, override)
    }

    func testSelectionStopsCheckingSignaturesAfterTheFirstTrustedMatch() {
        let checked = CheckedPaths()
        let candidates = ProviderExecutableSelection.inspect(
            paths: ["/missing", "/first", "/second"],
            isExecutable: { $0 != "/missing" },
            isTrustedExecutable: { url in
                checked.append(url.path)
                return true
            },
            inspectAll: false
        )

        XCTAssertEqual(candidates.map(\.status), [.unavailable, .trusted])
        XCTAssertEqual(checked.paths, ["/first"])
    }

    func testLocatorsRediscoverInstallLocationsOnEveryLookup() throws {
        let overrides = MutableOverrides()
        let locator = CodexAppServerRuntimeLocator(
            overrides: overrides,
            isExecutable: { path in path.hasPrefix("/moved/") },
            isTrustedExecutable: { _ in true }
        )

        overrides.codexPath = "/moved/one/codex"
        let first = try XCTUnwrap(locator.runtime())
        overrides.codexPath = "/moved/two/codex"
        let second = try XCTUnwrap(locator.runtime())

        XCTAssertEqual(first.executableURL.path, "/moved/one/codex")
        XCTAssertEqual(second.executableURL.path, "/moved/two/codex")
    }

    func testDefaultsOverridesTrimValuesExpandTildesAndIgnoreUnknownSources() throws {
        let suiteName = "AIUsageMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let overrides = UserDefaultsProviderRuntimeOverrides(suiteName: suiteName)

        XCTAssertNil(overrides.codexExecutablePath)
        XCTAssertEqual(overrides.claudeUsageSource, .automatic)

        defaults.set("  ~/bin/codex \n", forKey: UserDefaultsProviderRuntimeOverrides.codexExecutablePathKey)
        defaults.set("   ", forKey: UserDefaultsProviderRuntimeOverrides.claudeExecutablePathKey)
        defaults.set("statusLine", forKey: UserDefaultsProviderRuntimeOverrides.claudeUsageSourceKey)
        XCTAssertEqual(overrides.codexExecutablePath, "\(NSHomeDirectory())/bin/codex")
        XCTAssertNil(overrides.claudeExecutablePath)
        XCTAssertEqual(overrides.claudeUsageSource, .statusLine)

        defaults.set("status-line-typo", forKey: UserDefaultsProviderRuntimeOverrides.claudeUsageSourceKey)
        XCTAssertEqual(overrides.claudeUsageSource, .automatic, "An unrecognized value must not disable live usage")
    }

    func testDiagnosticsReportsMissingCLIsWithoutLaunchingAnything() async {
        let lines = CollectedLines()
        let overrides = FixedProviderRuntimeOverrides(claudeUsageSource: .statusLine)
        let suiteName = "AIUsageMonitorTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let environment = ProviderDiagnosticsEnvironment(
            overrides: overrides,
            defaults: UserDefaultsProviderRuntimeOverrides(suiteName: suiteName),
            claudeLocator: ClaudeCLIRuntimeLocator(
                candidateExecutablePaths: ["/missing/claude", "/untrusted/claude"],
                isExecutable: { $0 == "/untrusted/claude" },
                isTrustedExecutable: { _ in false }
            ),
            codexLocator: CodexAppServerRuntimeLocator(
                candidateExecutablePaths: ["/missing/codex"],
                isExecutable: { _ in false },
                isTrustedExecutable: { _ in true }
            ),
            usageCache: ClaudeUsageCacheStore(rootProvider: FixedStorageRootProvider(storageRoot: makeTemporaryDirectory())),
            statusLineInstaller: ClaudeStatusLineInstaller(
                settingsURL: makeTemporaryDirectory().appendingPathComponent("settings.json"),
                rootProvider: FixedStorageRootProvider(storageRoot: makeTemporaryDirectory()),
                executableURL: URL(fileURLWithPath: "/Applications/AI Usage Monitor.app/Contents/MacOS/AI Usage Monitor")
            ),
            clock: FixedClock(now: Date(timeIntervalSince1970: 1_783_756_800))
        )

        let status = await ProviderDiagnosticsCommand.run(environment: environment, output: { lines.append($0) })
        let report = lines.joined

        XCTAssertEqual(status, 1)
        XCTAssertTrue(report.contains("Claude usage source in effect: statusLine"))
        XCTAssertTrue(report.contains("not present /missing/claude"))
        XCTAssertTrue(report.contains("UNTRUSTED   /untrusted/claude"))
        XCTAssertTrue(report.contains("no trusted Claude Code CLI found"))
        XCTAssertTrue(report.contains("no trusted Codex CLI found"))
        XCTAssertTrue(report.contains("Summary: Claude NOT OK, Codex NOT OK"))
    }

    func testDiagnosticsSuccessReportShowsMetersButNoAccountDetailsOrSecrets() async {
        let claudeScript = """
        if [ "$1 $2 $3" = "auth status --json" ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"private@example.com","orgId":"org-secret-id"}'
          exit 0
        fi
        while IFS= read -r line; do
          case "$line" in
            *get_usage*) printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"\(ClaudeCLIClient.usageRequestID)","response":{"access_token":"sk-ant-oat01-FAKE","email":"private@example.com","subscription_type":"max","rate_limits":{"five_hour":{"utilization":36,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":81,"resets_at":"2099-01-02T00:00:00Z"}}}}}' ;;
            *initialize*) printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"\(ClaudeCLIClient.initializeRequestID)","response":{"account":{"email":"private@example.com"}}}}' ;;
          esac
        done
        """
        let codexScript = """
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *rateLimits*read*) printf '{"id":%s,"result":{"accountId":"acct-secret-id","rateLimits":{"primary":{"usedPercent":44,"windowDurationMins":10080,"resetsAt":4070908800},"secondary":null}}}\\n' "$id" ;;
            *account*read*) printf '{"id":%s,"result":{"account":{"type":"chatgpt","planType":"prolite","email":"private@example.com"}}}\\n' "$id" ;;
            *initialize*) printf '{"id":%s,"result":{}}\\n' "$id" ;;
          esac
        done
        """
        let lines = CollectedLines()
        let suiteName = "AIUsageMonitorTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let environment = ProviderDiagnosticsEnvironment(
            overrides: FixedProviderRuntimeOverrides(claudeUsageSource: .automatic),
            defaults: UserDefaultsProviderRuntimeOverrides(suiteName: suiteName),
            claudeLocator: ScriptedClaudeLocator(script: claudeScript),
            codexLocator: ScriptedCodexLocator(script: codexScript),
            usageCache: ClaudeUsageCacheStore(rootProvider: FixedStorageRootProvider(storageRoot: makeTemporaryDirectory())),
            statusLineInstaller: ClaudeStatusLineInstaller(
                settingsURL: makeTemporaryDirectory().appendingPathComponent("settings.json"),
                rootProvider: FixedStorageRootProvider(storageRoot: makeTemporaryDirectory()),
                executableURL: URL(fileURLWithPath: "/Applications/AI Usage Monitor.app/Contents/MacOS/AI Usage Monitor")
            ),
            clock: FixedClock(now: Date(timeIntervalSince1970: 1_783_756_800))
        )

        let status = await ProviderDiagnosticsCommand.run(environment: environment, output: { lines.append($0) })
        let report = lines.joined

        XCTAssertEqual(status, 0, report)
        for expected in [
            "Sign-in: loggedIn=true method=claude.ai plan=max",
            "Live usage (CLI get_usage): ok",
            "five_hour: 36% used",
            "Claude Session: 36% used",
            "Claude Week: 81% used",
            "Account: connected plan=Pro 5x",
            "Codex Week: 44% used",
            "Summary: Claude OK, Codex OK"
        ] {
            XCTAssertTrue(report.contains(expected), "Missing \"\(expected)\" in:\n\(report)")
        }
        for forbidden in ["private@example.com", "org-secret-id", "acct-secret-id", "sk-ant", "bearer", "token", "email"] {
            XCTAssertFalse(report.lowercased().contains(forbidden), "Report leaked \"\(forbidden)\":\n\(report)")
        }
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }
}

private struct ScriptedClaudeLocator: ClaudeCLIRuntimeLocating, ProviderExecutableInspecting {
    let script: String

    func runtime() -> ClaudeCLIRuntime? {
        ClaudeCLIRuntime(executableURL: URL(fileURLWithPath: "/bin/sh"), argumentPrefix: ["-c", script, "claude-test"])
    }

    func inspectCandidates() -> [ProviderExecutableCandidate] {
        [ProviderExecutableCandidate(path: "/bin/sh", status: .trusted)]
    }
}

private struct ScriptedCodexLocator: CodexAppServerRuntimeLocating, ProviderExecutableInspecting {
    let script: String

    func runtime() -> CodexAppServerRuntime? {
        CodexAppServerRuntime(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    }

    func inspectCandidates() -> [ProviderExecutableCandidate] {
        [ProviderExecutableCandidate(path: "/bin/sh", status: .trusted)]
    }
}

private final class MutableOverrides: ProviderRuntimeOverriding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCodexPath: String?

    var codexPath: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedCodexPath
        }
        set {
            lock.lock()
            storedCodexPath = newValue
            lock.unlock()
        }
    }

    var claudeExecutablePath: String? { nil }
    var codexExecutablePath: String? { codexPath }
    var claudeUsageSource: ClaudeUsageSourcePreference { .automatic }
}

private final class CheckedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ path: String) {
        lock.lock()
        storage.append(path)
        lock.unlock()
    }
}

private final class CollectedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }
}
