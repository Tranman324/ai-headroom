import Darwin
import Foundation

enum ClaudeCLIFailure: Error, Equatable, Sendable {
    case executableNotFound
    case executableUnavailable
    case processFailed
    case malformedStatus
    case usageRequestRejected
    case usageRequestFailed
    case usageRequestTimedOut
    case usageUnavailable
    case malformedUsage

    var diagnosticDescription: String {
        switch self {
        case .executableNotFound:
            return "no trusted Claude Code CLI was found"
        case .executableUnavailable:
            return "the Claude Code CLI could not be launched"
        case .processFailed:
            return "the Claude Code CLI command failed"
        case .malformedStatus:
            return "the Claude Code CLI returned an unreadable sign-in status"
        case .usageRequestRejected:
            return "the Claude Code CLI rejected the get_usage request"
        case .usageRequestFailed:
            return "the Claude Code CLI exited before answering the get_usage request"
        case .usageRequestTimedOut:
            return "the Claude Code CLI did not answer the get_usage request in time"
        case .usageUnavailable:
            return "the Claude Code CLI returned no plan limits"
        case .malformedUsage:
            return "the Claude Code CLI returned usage in an unrecognized format"
        }
    }
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
    func readUsageLimits() async throws -> ClaudeUsageLimits
}

struct ClaudeUsageLimitWindow: Equatable, Sendable {
    var utilization: Double?
    var resetsAt: Date?
}

struct ClaudeModelUsageLimit: Equatable, Sendable {
    var displayName: String
    var window: ClaudeUsageLimitWindow
}

struct ClaudeUsageLimits: Equatable, Sendable {
    var subscriptionType: String?
    var fiveHour: ClaudeUsageLimitWindow?
    var sevenDay: ClaudeUsageLimitWindow?
    var sevenDaySonnet: ClaudeUsageLimitWindow?
    var modelScoped: [ClaudeModelUsageLimit]

    init(
        subscriptionType: String? = nil,
        fiveHour: ClaudeUsageLimitWindow? = nil,
        sevenDay: ClaudeUsageLimitWindow? = nil,
        sevenDaySonnet: ClaudeUsageLimitWindow? = nil,
        modelScoped: [ClaudeModelUsageLimit] = []
    ) {
        self.subscriptionType = subscriptionType
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet
        self.modelScoped = modelScoped
    }
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
    private let candidateExecutablePaths: @Sendable () -> [String]
    private let isExecutable: @Sendable (String) -> Bool
    private let isTrustedExecutable: @Sendable (URL) -> Bool

    init(
        candidateExecutablePaths: [String],
        isExecutable: @escaping @Sendable (String) -> Bool = Self.defaultIsExecutable,
        isTrustedExecutable: @escaping @Sendable (URL) -> Bool = Self.defaultIsTrustedExecutable
    ) {
        self.candidateExecutablePaths = { candidateExecutablePaths }
        self.isExecutable = isExecutable
        self.isTrustedExecutable = isTrustedExecutable
    }

    init(
        overrides: any ProviderRuntimeOverriding = UserDefaultsProviderRuntimeOverrides(),
        isExecutable: @escaping @Sendable (String) -> Bool = Self.defaultIsExecutable,
        isTrustedExecutable: @escaping @Sendable (URL) -> Bool = Self.defaultIsTrustedExecutable
    ) {
        self.candidateExecutablePaths = {
            ProviderExecutableDiscovery.claudeCandidatePaths(overrides: overrides)
        }
        self.isExecutable = isExecutable
        self.isTrustedExecutable = isTrustedExecutable
    }

    func runtime() -> ClaudeCLIRuntime? {
        let candidates = ProviderExecutableSelection.inspect(
            paths: candidateExecutablePaths(),
            isExecutable: isExecutable,
            isTrustedExecutable: isTrustedExecutable,
            inspectAll: false
        )
        return ProviderExecutableSelection.firstTrustedURL(in: candidates).map {
            ClaudeCLIRuntime(executableURL: $0, argumentPrefix: [])
        }
    }

    func inspectCandidates() -> [ProviderExecutableCandidate] {
        ProviderExecutableSelection.inspect(
            paths: candidateExecutablePaths(),
            isExecutable: isExecutable,
            isTrustedExecutable: isTrustedExecutable,
            inspectAll: true
        )
    }

    static let defaultIsExecutable: @Sendable (String) -> Bool = { path in
        FileManager.default.isExecutableFile(atPath: path)
    }

    static let defaultIsTrustedExecutable: @Sendable (URL) -> Bool = { url in
        ProviderExecutableTrust.satisfies(
            ProviderExecutableTrust.anthropicRequirement,
            executableURL: url
        )
    }
}

actor ClaudeCLIClient: ClaudeCLICommunicating {
    /// Print mode with stream-json control messages lets the CLI answer `get_usage` with the
    /// claude.ai plan limits using its own sign-in, without sending a prompt. Safe mode skips
    /// hooks, plugins, and MCP servers, and nothing is written to the session history.
    static let usageArguments = [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--safe-mode",
        "--no-session-persistence",
        "--strict-mcp-config"
    ]
    static let initializeRequestID = "ai-usage-monitor-initialize"
    static let usageRequestID = "ai-usage-monitor-usage"

    private let runtimeLocator: any ClaudeCLIRuntimeLocating
    private let usageTimeout: Duration
    private let usageExitGracePeriod: Duration

    init(
        runtimeLocator: any ClaudeCLIRuntimeLocating = ClaudeCLIRuntimeLocator(),
        usageTimeout: Duration = .seconds(30),
        usageExitGracePeriod: Duration = .seconds(5)
    ) {
        self.runtimeLocator = runtimeLocator
        self.usageTimeout = usageTimeout
        self.usageExitGracePeriod = usageExitGracePeriod
    }

    func readUsageLimits() async throws -> ClaudeUsageLimits {
        try Task.checkCancellation()
        guard let runtime = runtimeLocator.runtime() else {
            throw ClaudeCLIFailure.executableNotFound
        }
        let session: ClaudeControlSession
        do {
            session = try ClaudeControlSession(
                runtime: runtime,
                arguments: Self.usageArguments,
                environment: Self.usageProcessEnvironment(),
                workingDirectory: FileManager.default.temporaryDirectory
            )
        } catch {
            throw ClaudeCLIFailure.executableUnavailable
        }

        let timeout = usageTimeout
        let body: Data
        do {
            body = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Data?.self) { group in
                    group.addTask {
                        try await session.exchange([
                            (id: Self.initializeRequestID, subtype: "initialize"),
                            (id: Self.usageRequestID, subtype: "get_usage")
                        ])
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return nil
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next(), let response = first else {
                        session.terminate()
                        throw ClaudeCLIFailure.usageRequestTimedOut
                    }
                    return response
                }
            } onCancel: {
                session.terminate()
            }
        } catch {
            session.terminate()
            if error is CancellationError {
                throw error
            }
            throw error as? ClaudeCLIFailure ?? ClaudeCLIFailure.usageRequestFailed
        }

        // Closing stdin lets the CLI finish its own config writes and exit on its own.
        session.finish(gracePeriod: usageExitGracePeriod)
        return try Self.decodeUsageLimits(body)
    }

    static func decodeUsageLimits(_ data: Data) throws -> ClaudeUsageLimits {
        let response: ClaudeGetUsageResponse
        do {
            response = try JSONDecoder().decode(ClaudeGetUsageResponse.self, from: data)
        } catch {
            throw ClaudeCLIFailure.malformedUsage
        }
        guard let rateLimits = response.rateLimits else {
            throw ClaudeCLIFailure.usageUnavailable
        }
        return ClaudeUsageLimits(
            subscriptionType: response.subscriptionType,
            fiveHour: rateLimits.fiveHour?.window,
            sevenDay: rateLimits.sevenDay?.window,
            sevenDaySonnet: rateLimits.sevenDaySonnet?.value?.window,
            modelScoped: (rateLimits.modelScoped?.value ?? []).compactMap(\.value).map {
                ClaudeModelUsageLimit(displayName: $0.displayName, window: $0.window)
            }
        )
    }

    private static func usageProcessEnvironment() -> [String: String] {
        var environment = processEnvironment()
        // Markers inherited when the app is launched from a Claude Code session would make
        // the child behave as a nested session.
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        return environment
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
            throw ClaudeCLIFailure.executableNotFound
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

/// One short-lived `claude -p` process speaking stream-json control messages over stdio.
private final class ClaudeControlSession: @unchecked Sendable {
    static let maximumLineBytes = 4 * 1_048_576

    private let process: Process
    private let input: FileHandle
    private let lines: AsyncStream<Data>
    private let linesContinuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var inputClosed = false

    init(
        runtime: ClaudeCLIRuntime,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL
    ) throws {
        ProcessSignalPolicy.ignoreBrokenPipes()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = runtime.executableURL
        process.arguments = runtime.argumentPrefix + arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        var continuation: AsyncStream<Data>.Continuation?
        // Unbounded so a burst of unrelated messages can never evict the control response;
        // each record is capped by ClaudeLineSplitter and the process lives for seconds.
        let lines = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation = $0 }
        guard let linesContinuation = continuation else {
            throw ClaudeCLIFailure.executableUnavailable
        }
        let splitter = ClaudeLineSplitter(maximumLineBytes: Self.maximumLineBytes)
        // The handler runs on a Foundation queue, so no cooperative thread blocks on the pipe.
        // An empty read means the process closed stdout.
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let completeLines = splitter.append(chunk) else {
                handle.readabilityHandler = nil
                linesContinuation.finish()
                return
            }
            for line in completeLines {
                linesContinuation.yield(line)
            }
        }

        // A child that outlives the CLI could hold stdout open; end the session shortly after the
        // CLI itself exits instead of waiting for the full timeout.
        process.terminationHandler = { _ in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                linesContinuation.finish()
            }
        }

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.lines = lines
        self.linesContinuation = linesContinuation
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            linesContinuation.finish()
            throw error
        }
    }

    func exchange(_ requests: [(id: String, subtype: String)]) async throws -> Data {
        var iterator = lines.makeAsyncIterator()
        var lastResponse = Data()
        for request in requests {
            try send([
                "type": "control_request",
                "request_id": request.id,
                "request": ["subtype": request.subtype]
            ])
            lastResponse = try await response(for: request.id, iterator: &iterator)
        }
        return lastResponse
    }

    /// Lets the CLI exit after stdin closes, and only signals it if it outlives the grace period.
    func finish(gracePeriod: Duration) {
        closeInput()
        let components = gracePeriod.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
            terminate()
        }
    }

    func terminate() {
        closeInput()
        if process.isRunning {
            process.terminate()
            let processIdentifier = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [process] in
                if process.isRunning {
                    kill(processIdentifier, SIGKILL)
                }
            }
        }
        linesContinuation.finish()
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            throw ClaudeCLIFailure.usageRequestFailed
        }
    }

    private func response(
        for requestID: String,
        iterator: inout AsyncStream<Data>.Iterator
    ) async throws -> Data {
        while let line = await iterator.next() {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  message["type"] as? String == "control_response",
                  let response = message["response"] as? [String: Any],
                  response["request_id"] as? String == requestID else {
                continue
            }
            guard response["subtype"] as? String == "success" else {
                throw ClaudeCLIFailure.usageRequestRejected
            }
            guard let body = response["response"] else {
                return Data("{}".utf8)
            }
            guard JSONSerialization.isValidJSONObject(body) else {
                throw ClaudeCLIFailure.malformedUsage
            }
            return try JSONSerialization.data(withJSONObject: body)
        }
        try Task.checkCancellation()
        throw ClaudeCLIFailure.usageRequestFailed
    }

    private func closeInput() {
        lock.lock()
        defer { lock.unlock() }
        guard !inputClosed else {
            return
        }
        inputClosed = true
        try? input.close()
    }
}

/// Splits pipe chunks into newline-delimited records. Returns nil once a single record
/// exceeds the size cap, which ends the session instead of buffering without bound.
private final class ClaudeLineSplitter: @unchecked Sendable {
    private let maximumLineBytes: Int
    private var buffer = Data()

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
    }

    func append(_ chunk: Data) -> [Data]? {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex ..< newline]))
            buffer.removeSubrange(buffer.startIndex ... newline)
        }
        guard buffer.count <= maximumLineBytes else {
            return nil
        }
        return lines
    }
}

private struct ClaudeGetUsageResponse: Decodable {
    var subscriptionType: String?
    var rateLimits: ClaudeGetUsageRateLimits?

    enum CodingKeys: String, CodingKey {
        case subscriptionType = "subscription_type"
        case rateLimits = "rate_limits"
    }
}

private struct ClaudeGetUsageRateLimits: Decodable {
    var fiveHour: ClaudeGetUsageWindow?
    var sevenDay: ClaudeGetUsageWindow?
    // Per-model windows are additive extras; one malformed entry must not hide the core limits.
    var sevenDaySonnet: ClaudeLossyDecodable<ClaudeGetUsageWindow>?
    var modelScoped: ClaudeLossyDecodable<[ClaudeLossyDecodable<ClaudeGetUsageModelWindow>]>?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case modelScoped = "model_scoped"
    }
}

private struct ClaudeGetUsageWindow: Decodable {
    var window: ClaudeUsageLimitWindow

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        window = ClaudeUsageLimitWindow(
            utilization: try container.decodeIfPresent(Double.self, forKey: .utilization),
            resetsAt: try ClaudeUsageTimestamp.decode(from: container, forKey: .resetsAt)
        )
    }
}

private struct ClaudeGetUsageModelWindow: Decodable {
    var displayName: String
    var window: ClaudeUsageLimitWindow

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decode(String.self, forKey: .displayName)
        window = ClaudeUsageLimitWindow(
            utilization: try container.decodeIfPresent(Double.self, forKey: .utilization),
            resetsAt: try ClaudeUsageTimestamp.decode(from: container, forKey: .resetsAt)
        )
    }
}

private struct ClaudeLossyDecodable<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private enum ClaudeUsageTimestamp {
    /// Accepts the documented ISO-8601 string and Unix seconds, the format the status line uses.
    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Date? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else {
            return nil
        }
        if let text = try? container.decode(String.self, forKey: key) {
            guard let date = ProviderJSON.parseISO8601(text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Expected an ISO-8601 timestamp."
                )
            }
            return date
        }
        let seconds = try container.decode(Double.self, forKey: key)
        guard seconds.isFinite, seconds >= 0, seconds <= Date.distantFuture.timeIntervalSince1970 else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected Unix seconds."
            )
        }
        return Date(timeIntervalSince1970: seconds)
    }
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
            // A previous status-line command that exits without reading its input closes the
            // pipe; with SIGPIPE ignored (it can be inherited from the parent), that must not abort.
            try? output.write(contentsOf: data)
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
    private let overrides: any ProviderRuntimeOverriding
    private let clock: any ClockProviding

    init(
        cli: any ClaudeCLICommunicating = ClaudeCLIClient(),
        usageCache: any ClaudeUsageCacheReading = ClaudeUsageCacheStore(),
        statusLineInstaller: any ClaudeStatusLineInstalling = ClaudeStatusLineInstaller(),
        overrides: any ProviderRuntimeOverriding = UserDefaultsProviderRuntimeOverrides(),
        clock: any ClockProviding = SystemClock()
    ) {
        self.cli = cli
        self.usageCache = usageCache
        self.statusLineInstaller = statusLineInstaller
        self.overrides = overrides
        self.clock = clock
    }

    func fetchUsageSnapshot() async throws -> ProviderUsageSnapshot {
        let authentication = try await readAuthenticationStatus()
        guard authentication.usesClaudeAIAuthentication else {
            throw ProviderClientFailure.authenticationRequired(provider: provider)
        }
        let planName = planDisplayName(for: authentication.subscriptionType)

        guard overrides.claudeUsageSource == .automatic else {
            return try await cachedSnapshot(planName: planName)
                ?? ProviderUsageSnapshot(provider: provider, meters: [], health: .noData(checkedAt: clock.now))
        }

        let liveFailure: ProviderClientFailure
        do {
            let meters = try liveMeters(from: try await cli.readUsageLimits(), planName: planName)
            if !meters.isEmpty {
                return ProviderUsageSnapshot(provider: provider, meters: meters, health: .fresh(checkedAt: clock.now))
            }
            // The CLI answered but every window is empty; status-line data may still cover it.
            return (try? await cachedSnapshot(planName: planName))
                ?? ProviderUsageSnapshot(provider: provider, meters: [], health: .noData(checkedAt: clock.now))
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ProviderClientFailure {
            liveFailure = failure
        } catch {
            liveFailure = mapCLIFailure(error)
        }

        // Fall back to status-line data, but never hide the live failure behind "no data":
        // an empty fallback surfaces the CLI error so the menu shows why limits are missing.
        guard let fallback = try? await cachedSnapshot(planName: planName) else {
            throw liveFailure
        }
        if fallback.health.kind == .stale, let staleSince = fallback.health.staleSince {
            return ProviderUsageSnapshot(
                provider: provider,
                meters: fallback.meters,
                health: .stale(checkedAt: clock.now, staleSince: staleSince, error: liveFailure.sanitizedError)
            )
        }
        return fallback
    }

    /// Returns nil when the status-line cache is missing, expired, or has no unexpired window.
    private func cachedSnapshot(planName: String) async throws -> ProviderUsageSnapshot? {
        guard let cache = try await usageCache.readUsageCache() else {
            return nil
        }
        let capturedAt = Date(timeIntervalSince1970: cache.capturedAtUnixSeconds)
        let cacheAge = clock.now.timeIntervalSince(capturedAt)
        guard cache.capturedAtUnixSeconds.isFinite,
              cacheAge >= -60,
              cacheAge <= Self.maximumCacheAge else {
            return nil
        }

        let meters = [
            try meter(kind: .claudeSession, limit: cache.fiveHour, planName: planName),
            try meter(kind: .claudeWeekAll, limit: cache.sevenDay, planName: planName)
        ].compactMap { $0 }
        guard !meters.isEmpty else {
            return nil
        }

        return ProviderUsageSnapshot(
            provider: provider,
            meters: meters,
            health: cacheAge <= Self.freshCacheInterval
                ? .fresh(checkedAt: capturedAt)
                : .stale(checkedAt: clock.now, staleSince: capturedAt)
        )
    }

    private func liveMeters(from limits: ClaudeUsageLimits, planName: String) throws -> [UsageMeterSnapshot] {
        var meters: [MeterKind: UsageMeterSnapshot] = [:]
        func add(_ kind: MeterKind, _ window: ClaudeUsageLimitWindow?, isCoreLimit: Bool = false) throws {
            guard meters[kind] == nil,
                  let window,
                  let utilization = window.utilization,
                  let resetAt = window.resetsAt else {
                return
            }
            guard utilization.isFinite, utilization >= 0 else {
                // A bad per-model window is dropped so it cannot hide the session and weekly limits.
                guard isCoreLimit else {
                    return
                }
                throw ProviderClientFailure.malformedResponse(provider: provider)
            }
            guard resetAt > clock.now else {
                return
            }
            var display = MeterDisplayMetadata(kind: kind)
            display.planName = planName
            // The plan endpoint can report slightly over 100 once a limit is overrun; that is a full meter.
            meters[kind] = UsageMeterSnapshot(
                kind: kind,
                utilization: try UtilizationPercentage(min(utilization, 100)),
                resetAt: resetAt,
                display: display
            )
        }

        try add(.claudeSession, limits.fiveHour, isCoreLimit: true)
        try add(.claudeWeekAll, limits.sevenDay, isCoreLimit: true)
        try add(.claudeWeekSonnet, limits.sevenDaySonnet)
        for model in limits.modelScoped {
            if let kind = Self.weeklyMeterKind(forModelNamed: model.displayName) {
                try add(kind, model.window)
            }
        }
        return MeterKind.allCases.compactMap { meters[$0] }
    }

    static func weeklyMeterKind(forModelNamed name: String) -> MeterKind? {
        let normalized = name.lowercased()
        if normalized.contains("fable") {
            return .claudeWeekFable
        }
        if normalized.contains("sonnet") {
            return .claudeWeekSonnet
        }
        if normalized.contains("haiku") {
            return .claudeWeekHaiku
        }
        return nil
    }

    func startAuthentication() async throws -> ProviderAuthenticationResult {
        let status = try await readAuthenticationStatus()
        if !status.usesClaudeAIAuthentication {
            do {
                try await cli.startClaudeAIAuthentication()
            } catch {
                throw mapCLIFailure(error)
            }
            let refreshedStatus = try await readAuthenticationStatus()
            guard refreshedStatus.usesClaudeAIAuthentication else {
                throw ProviderClientFailure.authenticationRequired(provider: provider)
            }
            // The cache may hold usage from whichever account was signed in
            // before this login, so it cannot be trusted afterward.
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
            guard overrides.claudeUsageSource == .statusLine else {
                return ProviderConnectionStatus(
                    provider: provider,
                    state: .connected,
                    planName: planDisplayName(for: status.subscriptionType),
                    usageSyncEnabled: true,
                    detail: "Usage sync enabled"
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
                detail: mapCLIFailure(error) == .executableNotFound(provider: provider)
                    ? "Claude Code CLI was not found."
                    : "Claude Code CLI is unavailable."
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
        if let failure = error as? ProviderClientFailure {
            return failure
        }
        guard let failure = error as? ClaudeCLIFailure else {
            return .runtimeUnavailable(provider: provider)
        }
        switch failure {
        case .malformedStatus, .malformedUsage:
            return .malformedResponse(provider: provider)
        case .executableNotFound:
            return .executableNotFound(provider: provider)
        case .executableUnavailable, .processFailed:
            return .runtimeUnavailable(provider: provider)
        case .usageRequestRejected, .usageRequestFailed, .usageRequestTimedOut, .usageUnavailable:
            return .usageUnavailable(provider: provider)
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
