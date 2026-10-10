import AppKit
import Darwin
import Foundation

enum ClaudeUsageSourcePreference: String, CaseIterable, Sendable {
    /// Ask the Claude Code CLI for live limits, then fall back to the status-line cache.
    case automatic
    /// Read only the cache written by the Claude Code status line.
    case statusLine
}

protocol ProviderRuntimeOverriding: Sendable {
    var claudeExecutablePath: String? { get }
    var codexExecutablePath: String? { get }
    var claudeUsageSource: ClaudeUsageSourcePreference { get }
}

/// Recovery switches set with `defaults write com.jeremytran.aiusagemonitor <key> <value>`,
/// so a relocated CLI or a misbehaving usage source can be handled without a rebuild.
/// Override paths are still subject to the publisher signature check.
struct UserDefaultsProviderRuntimeOverrides: ProviderRuntimeOverriding {
    static let claudeExecutablePathKey = "ClaudeExecutablePath"
    static let codexExecutablePathKey = "CodexExecutablePath"
    static let claudeUsageSourceKey = "ClaudeUsageSource"

    /// Nil reads the app's own defaults domain; tests pass a private suite.
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    var claudeExecutablePath: String? {
        path(forKey: Self.claudeExecutablePathKey)
    }

    var codexExecutablePath: String? {
        path(forKey: Self.codexExecutablePathKey)
    }

    var claudeUsageSource: ClaudeUsageSourcePreference {
        rawValue(forKey: Self.claudeUsageSourceKey)
            .flatMap(ClaudeUsageSourcePreference.init(rawValue:)) ?? .automatic
    }

    func rawValue(forKey key: String) -> String? {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        guard let value = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value
    }

    private func path(forKey key: String) -> String? {
        rawValue(forKey: key).map { ($0 as NSString).expandingTildeInPath }
    }
}

struct FixedProviderRuntimeOverrides: ProviderRuntimeOverriding {
    var claudeExecutablePath: String?
    var codexExecutablePath: String?
    var claudeUsageSource: ClaudeUsageSourcePreference

    init(
        claudeExecutablePath: String? = nil,
        codexExecutablePath: String? = nil,
        claudeUsageSource: ClaudeUsageSourcePreference = .automatic
    ) {
        self.claudeExecutablePath = claudeExecutablePath
        self.codexExecutablePath = codexExecutablePath
        self.claudeUsageSource = claudeUsageSource
    }
}

struct ProviderExecutableCandidate: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case unavailable
        case untrusted
        case trusted
    }

    var path: String
    var status: Status
}

enum ProviderExecutableSelection {
    /// Checks candidates in order. Signature checks are skipped after the first trusted
    /// match unless `inspectAll` is set, which diagnostics use to report every path.
    static func inspect(
        paths: [String],
        isExecutable: (String) -> Bool,
        isTrustedExecutable: (URL) -> Bool,
        inspectAll: Bool
    ) -> [ProviderExecutableCandidate] {
        var candidates: [ProviderExecutableCandidate] = []
        var foundTrusted = false
        for path in paths {
            guard inspectAll || !foundTrusted else {
                break
            }
            guard isExecutable(path) else {
                candidates.append(ProviderExecutableCandidate(path: path, status: .unavailable))
                continue
            }
            let trusted = isTrustedExecutable(URL(fileURLWithPath: path))
            candidates.append(ProviderExecutableCandidate(path: path, status: trusted ? .trusted : .untrusted))
            foundTrusted = foundTrusted || trusted
        }
        return candidates
    }

    static func firstTrustedURL(in candidates: [ProviderExecutableCandidate]) -> URL? {
        candidates.first { $0.status == .trusted }
            .map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() }
    }
}

/// Install locations are re-scanned on every lookup so an app update that moves a CLI,
/// or a newly installed editor extension, is picked up without relaunching.
enum ProviderExecutableDiscovery {
    static let chatGPTBundleIdentifiers = ["com.openai.codex", "com.openai.chat"]

    static func claudeCandidatePaths(
        overrides: any ProviderRuntimeOverriding,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> [String] {
        var paths: [String] = []
        if let override = overrides.claudeExecutablePath {
            paths.append(override)
        }
        paths += [
            "\(homeDirectory)/.local/bin/claude",
            "\(homeDirectory)/.claude/bin/claude",
            "\(homeDirectory)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        paths += editorExtensionExecutables(
            prefix: "anthropic.claude-code-",
            relativePath: "resources/native-binary/claude",
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        return deduplicated(paths)
    }

    static func codexCandidatePaths(
        overrides: any ProviderRuntimeOverriding,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        registeredApplicationURLs: [URL] = registeredChatGPTApplicationURLs()
    ) -> [String] {
        var paths: [String] = []
        if let override = overrides.codexExecutablePath {
            paths.append(override)
        }
        let applicationPaths = [
            "/Applications/ChatGPT.app",
            "\(homeDirectory)/Applications/ChatGPT.app",
            "/Applications/Codex.app",
            "\(homeDirectory)/Applications/Codex.app"
        ] + registeredApplicationURLs.map(\.path)
        for applicationPath in deduplicated(applicationPaths) {
            // Current layout first, then the layout used before ChatGPT 26.1007.
            paths.append("\(applicationPath)/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
            paths.append("\(applicationPath)/Contents/Resources/codex")
        }
        paths += [
            "\(homeDirectory)/.local/bin/codex",
            "\(homeDirectory)/.codex/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/lib/node_modules/@openai/codex/vendor/\(rustTargetTriple)/codex/codex",
            "/usr/local/lib/node_modules/@openai/codex/vendor/\(rustTargetTriple)/codex/codex"
        ]
        paths += editorExtensionExecutables(
            prefix: "openai.chatgpt-",
            relativePath: "bin/\(editorBinaryDirectory)/codex",
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        return deduplicated(paths)
    }

    static func registeredChatGPTApplicationURLs() -> [URL] {
        chatGPTBundleIdentifiers.flatMap { identifier in
            NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier)
        }
    }

    /// Returns bundled executables from VS Code-family extension folders, newest version first.
    static func editorExtensionExecutables(
        prefix: String,
        relativePath: String,
        homeDirectory: String,
        fileManager: FileManager
    ) -> [String] {
        let extensionRoots = [
            ".vscode/extensions",
            ".vscode-insiders/extensions",
            ".cursor/extensions",
            ".windsurf/extensions"
        ]
        return extensionRoots.flatMap { root -> [String] in
            let rootPath = "\(homeDirectory)/\(root)"
            guard let names = try? fileManager.contentsOfDirectory(atPath: rootPath) else {
                return []
            }
            return names
                .filter { $0.hasPrefix(prefix) }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(rootPath)/\($0)/\(relativePath)" }
        }
    }

    private static var rustTargetTriple: String {
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #else
        return "x86_64-apple-darwin"
        #endif
    }

    private static var editorBinaryDirectory: String {
        #if arch(arm64)
        return "macos-aarch64"
        #else
        return "macos-x86_64"
        #endif
    }

    private static func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

enum ProcessSignalPolicy {
    /// A CLI that exits while we write to its stdin must surface as a write error, not
    /// terminate this app with SIGPIPE.
    static func ignoreBrokenPipes() {
        _ = ignoreOnce
    }

    private static let ignoreOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
}

struct ProviderDiagnosticsEnvironment: Sendable {
    var overrides: any ProviderRuntimeOverriding
    var defaults: UserDefaultsProviderRuntimeOverrides
    var claudeLocator: ClaudeCLIRuntimeLocator
    var codexLocator: CodexAppServerRuntimeLocator
    var usageCache: any ClaudeUsageCacheReading
    var statusLineInstaller: any ClaudeStatusLineInstalling
    var clock: any ClockProviding

    static func production() -> ProviderDiagnosticsEnvironment {
        let overrides = UserDefaultsProviderRuntimeOverrides()
        return ProviderDiagnosticsEnvironment(
            overrides: overrides,
            defaults: overrides,
            claudeLocator: ClaudeCLIRuntimeLocator(overrides: overrides),
            codexLocator: CodexAppServerRuntimeLocator(overrides: overrides),
            usageCache: ClaudeUsageCacheStore(),
            statusLineInstaller: ClaudeStatusLineInstaller(),
            clock: SystemClock()
        )
    }
}

/// `AI Usage Monitor --diagnose` runs the same discovery and fetch paths as the app and prints
/// a sanitized report: paths, signature status, plan names, and utilization only.
enum ProviderDiagnosticsCommand {
    static let argument = "--diagnose"

    static func runBlocking() -> Int32 {
        let result = DiagnosticsExitStatus()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let status = await run(environment: .production(), output: { print($0) })
            result.set(status)
            semaphore.signal()
        }
        semaphore.wait()
        return result.value
    }

    static func run(
        environment: ProviderDiagnosticsEnvironment,
        output: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        output("AI Usage Monitor diagnostics (version \(version))")
        output("Executable: \(bundle.executableURL?.path ?? CommandLine.arguments[0])")
        output("Recovery overrides (defaults domain \(bundle.bundleIdentifier ?? "unknown")):")
        for key in [
            UserDefaultsProviderRuntimeOverrides.claudeUsageSourceKey,
            UserDefaultsProviderRuntimeOverrides.claudeExecutablePathKey,
            UserDefaultsProviderRuntimeOverrides.codexExecutablePathKey
        ] {
            output("  \(key): \(environment.defaults.rawValue(forKey: key) ?? "(not set)")")
        }
        output("  Claude usage source in effect: \(environment.overrides.claudeUsageSource.rawValue)")

        let claudeHealthy = await diagnoseClaude(environment: environment, output: output)
        let codexHealthy = await diagnoseCodex(environment: environment, output: output)

        output("")
        output("Summary: Claude \(claudeHealthy ? "OK" : "NOT OK"), Codex \(codexHealthy ? "OK" : "NOT OK")")
        return claudeHealthy && codexHealthy ? 0 : 1
    }

    private static func diagnoseClaude(
        environment: ProviderDiagnosticsEnvironment,
        output: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        output("")
        output("Claude")
        let locator = environment.claudeLocator
        report(candidates: locator.inspectCandidates(), output: output)
        guard let runtime = locator.runtime() else {
            output("  Result: no trusted Claude Code CLI found. Install Claude Code, or set ClaudeExecutablePath.")
            return false
        }
        output("  Using: \(runtime.executableURL.path)")

        let cli = ClaudeCLIClient(runtimeLocator: locator)
        do {
            let status = try await cli.authenticationStatus()
            output("  Sign-in: loggedIn=\(status.loggedIn) method=\(status.authMethod ?? "none") plan=\(status.subscriptionType ?? "none")")
        } catch {
            output("  Sign-in: could not read (\(describe(error)))")
        }

        if environment.overrides.claudeUsageSource == .automatic {
            do {
                let limits = try await cli.readUsageLimits()
                output("  Live usage (CLI get_usage): ok")
                for line in describe(limits) {
                    output("    \(line)")
                }
            } catch {
                output("  Live usage (CLI get_usage): failed (\(describe(error)))")
            }
        } else {
            output("  Live usage (CLI get_usage): skipped by ClaudeUsageSource=statusLine")
        }

        let bridgeInstalled = await environment.statusLineInstaller.isInstalled()
        output("  Status-line fallback: bridge \(bridgeInstalled ? "installed" : "not installed")")
        do {
            if let cache = try await environment.usageCache.readUsageCache() {
                let age = environment.clock.now.timeIntervalSince1970 - cache.capturedAtUnixSeconds
                output("    cache age: \(Int(age / 60)) min")
            } else {
                output("    cache: none (written only while Claude Code runs in a terminal)")
            }
        } catch {
            output("    cache: unreadable (\(describe(error)))")
        }

        let provider = ClaudeUsageProvider(
            cli: cli,
            usageCache: environment.usageCache,
            statusLineInstaller: environment.statusLineInstaller,
            overrides: environment.overrides,
            clock: environment.clock
        )
        return await reportSnapshot(from: provider, output: output)
    }

    private static func diagnoseCodex(
        environment: ProviderDiagnosticsEnvironment,
        output: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        output("")
        output("Codex")
        let locator = environment.codexLocator
        report(candidates: locator.inspectCandidates(), output: output)
        guard let runtime = locator.runtime() else {
            output("  Result: no trusted Codex CLI found. Install or update ChatGPT, or set CodexExecutablePath.")
            return false
        }
        output("  Using: \(runtime.executableURL.path)")

        let client = CodexAppServerClient(runtimeLocator: locator)
        let provider = CodexUsageProvider(appServer: client, clock: environment.clock)
        let status = await provider.connectionStatus()
        output("  Account: \(status.state) plan=\(status.planName ?? "none")")
        let healthy = await reportSnapshot(from: provider, output: output)
        await client.shutdown()
        return healthy
    }

    private static func report(
        candidates: [ProviderExecutableCandidate],
        output: @Sendable (String) -> Void
    ) {
        output("  Candidates (first trusted is used):")
        for candidate in candidates {
            let label: String
            switch candidate.status {
            case .trusted:
                label = "trusted    "
            case .untrusted:
                label = "UNTRUSTED  "
            case .unavailable:
                label = "not present"
            }
            output("    \(label) \(candidate.path)")
        }
    }

    private static func reportSnapshot(
        from provider: any UsageProviderFetching,
        output: @Sendable (String) -> Void
    ) async -> Bool {
        do {
            let snapshot = try await provider.fetchUsageSnapshot()
            output("  App result: \(snapshot.health.kind.rawValue), \(snapshot.meters.count) meter(s)")
            for meter in snapshot.meters {
                output("    \(meter.display.title): \(formatPercent(meter.utilization.value)) used, resets \(formatDate(meter.resetAt))")
            }
            return !snapshot.meters.isEmpty
        } catch {
            output("  App result: error (\(describe(error)))")
            return false
        }
    }

    private static func describe(_ limits: ClaudeUsageLimits) -> [String] {
        var lines: [String] = []
        func append(_ name: String, _ window: ClaudeUsageLimitWindow?) {
            guard let window else {
                lines.append("\(name): absent")
                return
            }
            let utilization = window.utilization.map(formatPercent) ?? "n/a"
            let reset = window.resetsAt.map(formatDate) ?? "n/a"
            lines.append("\(name): \(utilization) used, resets \(reset)")
        }
        append("five_hour", limits.fiveHour)
        append("seven_day", limits.sevenDay)
        if let sonnet = limits.sevenDaySonnet {
            append("seven_day_sonnet", sonnet)
        }
        for model in limits.modelScoped {
            append("model \(model.displayName)", model.window)
        }
        return lines
    }

    private static func describe(_ error: any Error) -> String {
        if let failure = error as? ProviderClientFailure {
            return failure.errorDescription ?? "\(failure)"
        }
        if let failure = error as? ClaudeCLIFailure {
            return failure.diagnosticDescription
        }
        if let failure = error as? CodexAppServerFailure {
            return "\(failure)"
        }
        return String(describing: type(of: error))
    }

    private static func formatPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: date)
    }
}

private final class DiagnosticsExitStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32 = 1

    var value: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    func set(_ newValue: Int32) {
        lock.lock()
        status = newValue
        lock.unlock()
    }
}
