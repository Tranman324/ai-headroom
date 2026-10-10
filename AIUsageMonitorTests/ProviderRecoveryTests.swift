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

    func testOverridePathStillRequiresTheProviderSignature() throws {
        let locator = ClaudeCLIRuntimeLocator(
            candidateExecutablePaths: ["/tmp/impostor/claude", "/opt/homebrew/bin/claude"],
            isExecutable: { _ in true },
            isTrustedExecutable: { $0.path == "/opt/homebrew/bin/claude" }
        )

        let runtime = try XCTUnwrap(locator.runtime())

        XCTAssertEqual(runtime.executableURL.path, URL(fileURLWithPath: "/opt/homebrew/bin/claude").resolvingSymlinksInPath().path)
        XCTAssertEqual(locator.inspectCandidates().map(\.status), [.untrusted, .trusted])
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

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
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
