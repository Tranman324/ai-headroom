import Darwin
import Foundation

enum ClaudeCLIFailure: Error, Equatable, Sendable {
    case executableUnavailable
    case processFailed
    case malformedStatus
}

struct ClaudeAuthenticationStatus: Equatable, Sendable {
    var loggedIn: Bool
    var authMethod: String?
    var subscriptionType: String?

    var usesClaudeAIAuthentication: Bool {
        loggedIn && authMethod?.caseInsensitiveCompare("claude.ai") == .orderedSame
    }
}

protocol ClaudeCLICommunicating: Sendable {
    func authenticationStatus() async throws -> ClaudeAuthenticationStatus
    func startClaudeAIAuthentication() async throws
}

protocol ClaudeUsageCacheReading: Sendable {
    func readUsageCache() async throws -> ClaudeUsageCache?
    func invalidateUsageCache() async throws
}

protocol ClaudeStatusLineInstalling: Sendable {
    func isInstalled() async -> Bool
    func install() async throws
}

struct ClaudeCLIRuntime: Equatable, Sendable {
    var executableURL: URL
    var argumentPrefix: [String]
}

protocol ClaudeCLIRuntimeLocating: Sendable {
    func runtime() -> ClaudeCLIRuntime?
}

struct ClaudeCLIRuntimeLocator: ClaudeCLIRuntimeLocating {
    private let candidateExecutablePaths: [String]
    private let isExecutable: @Sendable (String) -> Bool
    private let isTrustedExecutable: @Sendable (URL) -> Bool

    init(
        candidateExecutablePaths: [String] = Self.defaultCandidateExecutablePaths,
        isExecutable: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.isExecutableFile(atPath: path)
        },
        isTrustedExecutable: @escaping @Sendable (URL) -> Bool = { url in
            ProviderExecutableTrust.satisfies(
                ProviderExecutableTrust.anthropicRequirement,
                executableURL: url
            )
        }
    ) {
        self.candidateExecutablePaths = candidateExecutablePaths
        self.isExecutable = isExecutable
        self.isTrustedExecutable = isTrustedExecutable
    }

    func runtime() -> ClaudeCLIRuntime? {
        if let path = candidateExecutablePaths.first(where: { path in
            isExecutable(path) && isTrustedExecutable(URL(fileURLWithPath: path))
        }) {
            return ClaudeCLIRuntime(
                executableURL: URL(fileURLWithPath: path).resolvingSymlinksInPath(),
                argumentPrefix: []
            )
        }
        return nil
    }

    private static var defaultCandidateExecutablePaths: [String] {
        let homeDirectory = NSHomeDirectory()
        return [
            "\(homeDirectory)/.local/bin/claude",
            "\(homeDirectory)/.claude/bin/claude",
            "\(homeDirectory)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
    }
}

actor ClaudeCLIClient: ClaudeCLICommunicating {
    private let runtimeLocator: any ClaudeCLIRuntimeLocating

    init(runtimeLocator: any ClaudeCLIRuntimeLocating = ClaudeCLIRuntimeLocator()) {
        self.runtimeLocator = runtimeLocator
    }

    func authenticationStatus() async throws -> ClaudeAuthenticationStatus {
        let result = try await run(arguments: ["auth", "status", "--json"], capturesOutput: true)
        guard let output = result.output else {
            throw ClaudeCLIFailure.malformedStatus
        }

        do {
            let status = try JSONDecoder().decode(ClaudeAuthStatusResponse.self, from: output)
            return ClaudeAuthenticationStatus(
                loggedIn: status.loggedIn,
                authMethod: status.authMethod,
                subscriptionType: status.subscriptionType
            )
        } catch {
            if result.terminationStatus == 127 {
                throw ClaudeCLIFailure.executableUnavailable
            }
            throw ClaudeCLIFailure.malformedStatus
        }
    }

    func startClaudeAIAuthentication() async throws {
        let result = try await run(arguments: ["auth", "login", "--claudeai"], capturesOutput: false)
        guard result.terminationStatus == 0 else {
            if result.terminationStatus == 127 {
                throw ClaudeCLIFailure.executableUnavailable
            }
            throw ClaudeCLIFailure.processFailed
        }
    }

    private func run(arguments: [String], capturesOutput: Bool) async throws -> ClaudeProcessResult {
        try Task.checkCancellation()
        guard let runtime = runtimeLocator.runtime() else {
            throw ClaudeCLIFailure.executableUnavailable
        }
        let process = Process()
        let processBox = ClaudeRunningProcess(process)
        let outputPipe = capturesOutput ? Pipe() : nil

        process.executableURL = runtime.executableURL
        process.arguments = runtime.argumentPrefix + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = Self.processEnvironment()

        let terminationStatus = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { completedProcess in
                    continuation.resume(returning: completedProcess.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ClaudeCLIFailure.executableUnavailable)
                }
            }
        } onCancel: {
            processBox.terminate()
        }

        try Task.checkCancellation()
        let output = outputPipe?.fileHandleForReading.readDataToEndOfFile()
        return ClaudeProcessResult(terminationStatus: terminationStatus, output: output)
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let requiredPaths = [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin"
        ]
        let existingPaths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = Array(Set(requiredPaths + existingPaths)).joined(separator: ":")
        return environment
    }
}

private final class ClaudeRunningProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning {
            process.terminate()
        }
    }
}

private struct ClaudeProcessResult {
    var terminationStatus: Int32
    var output: Data?
}

private struct ClaudeAuthStatusResponse: Decodable {
    var loggedIn: Bool
    var authMethod: String?
    var subscriptionType: String?
}

struct ClaudeRateLimitCache: Codable, Equatable, Sendable {
    var usedPercentage: Double
    var resetsAtUnixSeconds: Double

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAtUnixSeconds = "resets_at"
    }
}

struct ClaudeUsageCache: Codable, Equatable, Sendable {
    var capturedAtUnixSeconds: Double
    var fiveHour: ClaudeRateLimitCache?
    var sevenDay: ClaudeRateLimitCache?

    enum CodingKeys: String, CodingKey {
        case capturedAtUnixSeconds = "captured_at"
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeStatusLineInput: Decodable {
    var rateLimits: ClaudeStatusLineRateLimits?

    enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}

private struct ClaudeStatusLineRateLimits: Decodable {
    var fiveHour: ClaudeRateLimitCache?
    var sevenDay: ClaudeRateLimitCache?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

actor ClaudeUsageCacheStore: ClaudeUsageCacheReading {
    static let cacheFileName = "claude-usage.json"

    nonisolated let rootURL: URL
    nonisolated let cacheFileURL: URL

    init(rootProvider: any StorageRootProviding = HomeDirectoryStorageRootProvider()) {
        self.rootURL = rootProvider.storageRoot
        self.cacheFileURL = rootProvider.storageRoot.appendingPathComponent(Self.cacheFileName)
    }

    func readUsageCache() async throws -> ClaudeUsageCache? {
        try LocalPersistence.ensureRoot(at: rootURL)
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else {
            return nil
        }
        guard try LocalPersistence.permissions(of: cacheFileURL) == LocalPersistence.fileMode else {
            throw ProviderClientFailure.credentialInsecure(provider: .claude)
        }
        return try JSONDecoder().decode(ClaudeUsageCache.self, from: Data(contentsOf: cacheFileURL))
    }

    func invalidateUsageCache() async throws {
        try LocalPersistence.ensureRoot(at: rootURL)
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: cacheFileURL)
    }

    static func writeStatusLineInput(
        _ data: Data,
        rootProvider: any StorageRootProviding = HomeDirectoryStorageRootProvider(),
        now: Date = Date()
    ) throws {
        let input = try JSONDecoder().decode(ClaudeStatusLineInput.self, from: data)
        guard let rateLimits = input.rateLimits,
              rateLimits.fiveHour != nil || rateLimits.sevenDay != nil else {
            return
        }
        let cache = ClaudeUsageCache(
            capturedAtUnixSeconds: now.timeIntervalSince1970,
            fiveHour: rateLimits.fiveHour,
            sevenDay: rateLimits.sevenDay
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rootURL = rootProvider.storageRoot
        try LocalPersistence.ensureRoot(at: rootURL)
        try LocalPersistence.atomicWrite(
            encoder.encode(cache),
            to: rootURL.appendingPathComponent(Self.cacheFileName)
        )
    }
}

actor ClaudeStatusLineInstaller: ClaudeStatusLineInstalling {
    static let bridgeArgument = "--claude-statusline"
    static let forwardArgument = "--forward-statusline-input"
    static let legacyConfigurationFileName = "claude-statusline-bridge.json"

    private let settingsURL: URL
    private let executableURL: URL
    private let legacyConfigurationURL: URL

    init(
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json"),
        rootProvider: any StorageRootProviding = HomeDirectoryStorageRootProvider(),
        executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    ) {
        self.settingsURL = settingsURL
        self.executableURL = executableURL
        self.legacyConfigurationURL = rootProvider.storageRoot
            .appendingPathComponent(Self.legacyConfigurationFileName)
    }

    func isInstalled() async -> Bool {
        guard let settings = try? loadSettings(),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return Self.isBridgeCommand(command, executableURL: executableURL)
    }

    func install() async throws {
        var settings = try loadSettings()
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        let currentCommand = statusLine["command"] as? String
        let alreadyInstalled = currentCommand.map {
            Self.isBridgeCommand($0, executableURL: executableURL)
        } ?? false
        let embeddedPreviousCommand = Self.previousCommandToPreserve(currentCommand)
        let legacyPreviousCommand = readLegacyPreviousCommand()
        let previousCommand = embeddedPreviousCommand ?? legacyPreviousCommand
        let needsLegacyMigration = alreadyInstalled
            && embeddedPreviousCommand == nil
            && !(legacyPreviousCommand?.isEmpty ?? true)

        statusLine["type"] = "command"
        if !alreadyInstalled || needsLegacyMigration {
            statusLine["command"] = Self.composedBridgeCommand(
                executableURL: executableURL,
                previousCommand: previousCommand
            )
        }
        settings["statusLine"] = statusLine
        try writeSettings(settings)
        if FileManager.default.fileExists(atPath: legacyConfigurationURL.path) {
            try FileManager.default.removeItem(at: legacyConfigurationURL)
        }
    }

    private func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return [:]
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
        guard let settings = object as? [String: Any] else {
            throw ProviderClientFailure.malformedResponse(provider: .claude)
        }
        return settings
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let directoryURL = settingsURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int(LocalPersistence.rootMode))]
            )
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try LocalPersistence.atomicWrite(data, to: settingsURL)
    }

    private static func bridgeCommand(executableURL: URL) -> String {
        "\(shellQuote(executableURL.path)) \(bridgeArgument)"
    }

    private static func composedBridgeCommand(executableURL: URL, previousCommand: String?) -> String {
        let bridge = bridgeCommand(executableURL: executableURL)
        guard let previousCommand,
              !previousCommand.isEmpty else {
            return bridge
        }
        return "\(bridge) \(forwardArgument) | ( \(previousCommand) )"
    }

    private static func previousCommandToPreserve(_ command: String?) -> String? {
        guard let command, !command.isEmpty else {
            return nil
        }
        guard command.contains(bridgeArgument) else {
            return command
        }
        let marker = "\(forwardArgument) | ( "
        guard let markerRange = command.range(of: marker), command.hasSuffix(" )") else {
            return nil
        }
        return String(command[markerRange.upperBound...].dropLast(2))
    }

    private static func isBridgeCommand(_ command: String, executableURL: URL) -> Bool {
        let bridge = bridgeCommand(executableURL: executableURL)
        return command == bridge || command.hasPrefix("\(bridge) \(forwardArgument) | ( ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func readLegacyPreviousCommand() -> String? {
        guard let data = try? Data(contentsOf: legacyConfigurationURL),
              let configuration = try? JSONDecoder().decode(LegacyBridgeConfiguration.self, from: data) else {
            return nil
        }
        return configuration.previousCommand
    }
}

private struct LegacyBridgeConfiguration: Decodable {
    var previousCommand: String?
}

enum ClaudeStatusLineBridgeCommand {
    static let maximumInputBytes = 1_048_576

    static func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        forwardsInput: Bool = false,
        rootProvider: any StorageRootProviding = HomeDirectoryStorageRootProvider()
    ) -> Int32 {
        var data = Data()
        do {
            while data.count <= maximumInputBytes {
                let remainingDetectionBytes = maximumInputBytes + 1 - data.count
                guard remainingDetectionBytes > 0,
                      let chunk = try input.read(upToCount: min(64 * 1_024, remainingDetectionBytes)),
                      !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            return 1
        }
        guard data.count <= maximumInputBytes else {
            return 1
        }
        let bridgeStatus: Int32
        do {
            try ClaudeUsageCacheStore.writeStatusLineInput(data, rootProvider: rootProvider)
            bridgeStatus = 0
        } catch {
            bridgeStatus = 1
        }
        if forwardsInput {
            output.write(data)
        }
        return bridgeStatus
    }
}

struct ClaudeUsageProvider: UsageProviderFetching, ProviderAuthenticationManaging, ProviderConnectionChecking {
    let provider: ProviderID = .claude
    private static let freshCacheInterval: TimeInterval = 15 * 60
    private static let maximumCacheAge: TimeInterval = 24 * 60 * 60

    private let cli: any ClaudeCLICommunicating
    private let usageCache: any ClaudeUsageCacheReading
    private let statusLineInstaller: any ClaudeStatusLineInstalling
    private let clock: any ClockProviding

    init(
        cli: any ClaudeCLICommunicating = ClaudeCLIClient(),
        usageCache: any ClaudeUsageCacheReading = ClaudeUsageCacheStore(),
        statusLineInstaller: any ClaudeStatusLineInstalling = ClaudeStatusLineInstaller(),
        clock: any ClockProviding = SystemClock()
    ) {
        self.cli = cli
        self.usageCache = usageCache
        self.statusLineInstaller = statusLineInstaller
        self.clock = clock
    }

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        let authentication = try await readAuthenticationStatus()
        guard authentication.usesClaudeAIAuthentication else {
            throw ProviderClientFailure.authenticationRequired(provider: provider)
        }
        guard let cache = try await usageCache.readUsageCache() else {
            return ProviderUsageSnapshot(provider: provider, meters: [], health: .noData(checkedAt: clock.now))
        }
        let capturedAt = Date(timeIntervalSince1970: cache.capturedAtUnixSeconds)
        let cacheAge = clock.now.timeIntervalSince(capturedAt)
        guard cache.capturedAtUnixSeconds.isFinite,
              cacheAge >= -60,
              cacheAge <= Self.maximumCacheAge else {
            return ProviderUsageSnapshot(provider: provider, meters: [], health: .noData(checkedAt: clock.now))
        }

        let planName = planDisplayName(for: authentication.subscriptionType)
        let meters = [
            try meter(kind: .claudeSession, limit: cache.fiveHour, planName: planName),
            try meter(kind: .claudeWeekAll, limit: cache.sevenDay, planName: planName)
        ].compactMap { $0 }
        guard !meters.isEmpty else {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }

        return ProviderUsageSnapshot(
            provider: provider,
            meters: meters,
            health: cacheAge <= Self.freshCacheInterval
                ? .fresh(checkedAt: capturedAt)
                : .stale(checkedAt: clock.now, staleSince: capturedAt)
        )
    }

    func startAuthentication() async throws -> ProviderAuthenticationResult {
        let status = try await readAuthenticationStatus()
        let bridgeInstalled = await statusLineInstaller.isInstalled()
        var didAuthenticate = false
        if !status.usesClaudeAIAuthentication || bridgeInstalled {
            do {
                try await cli.startClaudeAIAuthentication()
            } catch {
                throw mapCLIFailure(error)
            }
            let refreshedStatus = try await readAuthenticationStatus()
            guard refreshedStatus.usesClaudeAIAuthentication else {
                throw ProviderClientFailure.authenticationRequired(provider: provider)
            }
            didAuthenticate = true
        }

        if didAuthenticate {
            do {
                try await usageCache.invalidateUsageCache()
            } catch {
                throw ProviderClientFailure.credentialPersistence(provider: provider)
            }
        }

        do {
            try await statusLineInstaller.install()
        } catch let failure as ProviderClientFailure {
            throw failure
        } catch {
            throw ProviderClientFailure.credentialPersistence(provider: provider)
        }
        return .completed
    }

    func connectionStatus() async -> ProviderConnectionStatus {
        do {
            let status = try await readAuthenticationStatus()
            guard status.usesClaudeAIAuthentication else {
                return ProviderConnectionStatus(
                    provider: provider,
                    state: .disconnected,
                    planName: nil,
                    usageSyncEnabled: false,
                    detail: "Sign in with your Claude subscription."
                )
            }
            let bridgeInstalled = await statusLineInstaller.isInstalled()
            return ProviderConnectionStatus(
                provider: provider,
                state: .connected,
                planName: planDisplayName(for: status.subscriptionType),
                usageSyncEnabled: bridgeInstalled,
                detail: bridgeInstalled ? "Usage sync enabled" : "Enable usage sync to show limits."
            )
        } catch {
            return ProviderConnectionStatus(
                provider: provider,
                state: .unavailable,
                planName: nil,
                usageSyncEnabled: nil,
                detail: "Claude Code CLI is unavailable."
            )
        }
    }

    private func readAuthenticationStatus() async throws -> ClaudeAuthenticationStatus {
        do {
            return try await cli.authenticationStatus()
        } catch {
            throw mapCLIFailure(error)
        }
    }

    private func mapCLIFailure(_ error: any Error) -> ProviderClientFailure {
        guard let failure = error as? ClaudeCLIFailure else {
            return .runtimeUnavailable(provider: provider)
        }
        switch failure {
        case .malformedStatus:
            return .malformedResponse(provider: provider)
        case .executableUnavailable, .processFailed:
            return .runtimeUnavailable(provider: provider)
        }
    }

    private func meter(
        kind: MeterKind,
        limit: ClaudeRateLimitCache?,
        planName: String
    ) throws -> UsageMeterSnapshot? {
        guard let limit else {
            return nil
        }
        guard limit.usedPercentage.isFinite,
              limit.resetsAtUnixSeconds.isFinite,
              limit.resetsAtUnixSeconds >= 0,
              limit.resetsAtUnixSeconds <= Date.distantFuture.timeIntervalSince1970 else {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }
        guard limit.resetsAtUnixSeconds > clock.now.timeIntervalSince1970 else {
            return nil
        }
        do {
            var display = MeterDisplayMetadata(kind: kind)
            display.planName = planName
            return UsageMeterSnapshot(
                kind: kind,
                utilization: try UtilizationPercentage(limit.usedPercentage),
                resetAt: Date(timeIntervalSince1970: limit.resetsAtUnixSeconds),
                display: display
            )
        } catch {
            throw ProviderClientFailure.malformedResponse(provider: provider)
        }
    }

    private func planDisplayName(for subscriptionType: String?) -> String {
        guard let subscriptionType, !subscriptionType.isEmpty else {
            return "Claude"
        }
        return subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst().lowercased()
    }
}
