import Foundation

enum CodexAppServerFailure: Error, Equatable, Sendable {
    case executableNotFound
    case executableUnavailable
    case processUnavailable
    case authenticationRequired
    case malformedResponse
    case requestFailed
}

struct CodexAppServerRuntime: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
    /// Tried when the app-server exits during startup, in case a newer CLI drops a flag.
    var alternateArguments: [String]?
}

protocol CodexAppServerRuntimeLocating: Sendable {
    func runtime() -> CodexAppServerRuntime?
}

struct CodexAppServerRuntimeLocator: CodexAppServerRuntimeLocating {
    static let arguments = ["app-server", "--stdio"]
    /// Spelled out rather than relying on the default transport, so a changed default can never
    /// start a network listener.
    static let alternateArguments = ["app-server", "--listen", "stdio://"]

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
            ProviderExecutableDiscovery.codexCandidatePaths(overrides: overrides)
        }
        self.isExecutable = isExecutable
        self.isTrustedExecutable = isTrustedExecutable
    }

    func runtime() -> CodexAppServerRuntime? {
        let candidates = ProviderExecutableSelection.inspect(
            paths: candidateExecutablePaths(),
            isExecutable: isExecutable,
            isTrustedExecutable: isTrustedExecutable,
            inspectAll: false
        )
        return ProviderExecutableSelection.firstTrustedURL(in: candidates).map {
            CodexAppServerRuntime(
                executableURL: $0,
                arguments: Self.arguments,
                alternateArguments: Self.alternateArguments
            )
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
            ProviderExecutableTrust.openAIRequirement,
            executableURL: url
        )
    }
}

actor CodexAppServerClient: CodexAppServerCommunicating {
    private let runtimeLocator: (any CodexAppServerRuntimeLocating)?
    private let explicitRuntime: CodexAppServerRuntime?
    private let requestTimeout: Duration

    private var process: Process?
    private var processToken: UUID?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var outputReadTask: Task<Void, Never>?
    private var outputChunks: AsyncStream<Data>.Continuation?
    private var outputBuffer = Data()
    private var startupTask: Task<Void, Error>?
    private var consecutiveTimeouts = 0
    private var nextRequestID = 1
    /// One slow answer is tolerated; repeated silence means the app-server is hung.
    static let timeoutsBeforeRestart = 2
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var requestTimeoutTasks: [Int: Task<Void, Never>] = [:]

    init(
        runtimeLocator: any CodexAppServerRuntimeLocating = CodexAppServerRuntimeLocator(),
        requestTimeout: Duration = .seconds(15)
    ) {
        self.runtimeLocator = runtimeLocator
        self.explicitRuntime = nil
        self.requestTimeout = requestTimeout
    }

    init(
        executableURL: URL,
        executableArguments: [String],
        alternateExecutableArguments: [String]? = nil,
        requestTimeout: Duration = .seconds(15)
    ) {
        self.runtimeLocator = nil
        self.explicitRuntime = CodexAppServerRuntime(
            executableURL: executableURL,
            arguments: executableArguments,
            alternateArguments: alternateExecutableArguments
        )
        self.requestTimeout = requestTimeout
    }

    func readAccount() async throws -> CodexAppServerAccount? {
        try await ensureStarted()
        let response = try await sendRequest(
            method: "account/read",
            parameters: ["refreshToken": false]
        )
        let account = try decode(CodexAccountResponse.self, from: response).account
        return account.map {
            CodexAppServerAccount(type: $0.type, planType: $0.planType)
        }
    }

    func readUsage() async throws -> CodexAppServerUsage {
        guard let account = try await readAccount(), account.type == "chatgpt" else {
            throw CodexAppServerFailure.authenticationRequired
        }

        let rateLimitResponse = try await sendRequest(method: "account/rateLimits/read")
        let rateLimits = try decode(CodexRateLimitResponse.self, from: rateLimitResponse).rateLimits
        guard rateLimits.primary != nil || rateLimits.secondary != nil else {
            throw CodexAppServerFailure.malformedResponse
        }
        // Reset credits are an optional extra; a missing or unrecognised block must not hide the limits.
        let resetCredits = (try? decode(CodexResetCreditsResponse.self, from: rateLimitResponse))?
            .rateLimitResetCredits?
            .summary
        return CodexAppServerUsage(
            planType: account.planType,
            primaryWindow: rateLimits.primary.map(\.usageWindow),
            secondaryWindow: rateLimits.secondary.map(\.usageWindow),
            resetCredits: resetCredits
        )
    }

    func startChatGPTAuthentication() async throws -> ProviderAuthenticationChallenge {
        try await ensureStarted()
        let response = try await sendRequest(
            method: "account/login/start",
            parameters: ["type": "chatgptDeviceCode"]
        )
        let login = try decode(CodexDeviceCodeLoginResponse.self, from: response)
        guard login.type == "chatgptDeviceCode",
              let authorizationURL = URL(string: login.verificationURL),
              !login.userCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexAppServerFailure.malformedResponse
        }
        return ProviderAuthenticationChallenge(
            provider: .codex,
            authorizationURL: authorizationURL,
            userCode: login.userCode
        )
    }

    func shutdown() {
        stopProcess()
        failPendingResponses(with: .processUnavailable)
    }

    private func ensureStarted() async throws {
        // Concurrent callers share one startup so none of them talks to a half-initialized
        // app-server or has its process replaced by another caller's retry.
        if let startupTask {
            try await startupTask.value
            return
        }
        guard process == nil else {
            return
        }
        let task = Task { try await self.startAndInitialize() }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    private func startAndInitialize() async throws {
        // Resolved on every launch so a CLI moved by an app update is found without a restart.
        guard let runtime = runtimeLocator?.runtime() ?? explicitRuntime else {
            throw CodexAppServerFailure.executableNotFound
        }

        let argumentSets = [runtime.arguments] + (runtime.alternateArguments.map { [$0] } ?? [])
        for (index, arguments) in argumentSets.enumerated() {
            do {
                try startProcess(executableURL: runtime.executableURL, arguments: arguments)
            } catch {
                throw CodexAppServerFailure.executableUnavailable
            }

            do {
                _ = try await sendRequest(
                    method: "initialize",
                    parameters: [
                        "clientInfo": [
                            "name": "ai_usage_monitor",
                            "title": "AI Usage Monitor",
                            "version": "1.0"
                        ]
                    ]
                )
                try sendNotification(method: "initialized")
                return
            } catch {
                stopProcess()
                // Only an app-server that exited during startup suggests rejected arguments.
                let exitedDuringStartup = (error as? CodexAppServerFailure) == .processUnavailable
                guard exitedDuringStartup, index < argumentSets.count - 1 else {
                    throw error
                }
            }
        }
    }

    private func startProcess(executableURL: URL, arguments: [String]) throws {
        ProcessSignalPolicy.ignoreBrokenPipes()
        let input = Pipe()
        let output = Pipe()
        let standardError = Pipe()
        let newProcess = Process()
        let token = UUID()

        newProcess.executableURL = executableURL
        newProcess.arguments = arguments
        newProcess.standardInput = input
        newProcess.standardOutput = output
        newProcess.standardError = standardError
        newProcess.terminationHandler = { [weak self] _ in
            Task {
                await self?.processDidTerminate(token: token)
            }
        }
        process = newProcess
        processToken = token
        inputPipe = input
        outputPipe = output
        errorPipe = standardError
        standardInput = input.fileHandleForWriting

        do {
            try newProcess.run()
        } catch {
            stopProcess()
            throw error
        }

        // Pipes are read on Foundation's handler queue so a hung app-server never pins a thread
        // of the shared concurrency pool; a single consumer keeps the chunks in order.
        var continuation: AsyncStream<Data>.Continuation?
        let chunks = AsyncStream<Data> { continuation = $0 }
        let chunkContinuation = continuation
        outputChunks = chunkContinuation
        let outputHandle = output.fileHandleForReading
        standardOutput = outputHandle
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                chunkContinuation?.finish()
                return
            }
            chunkContinuation?.yield(data)
        }
        outputReadTask = Task { [weak self] in
            for await chunk in chunks {
                await self?.receive(data: chunk)
            }
        }

        let errorHandle = standardError.fileHandleForReading
        self.standardError = errorHandle
        errorHandle.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    private func sendRequest(
        method: String,
        parameters: [String: Any]? = nil
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        let identifier = nextRequestID
        nextRequestID += 1
        let timeout = requestTimeout

        var request: [String: Any] = [
            "id": identifier,
            "method": method
        ]
        if let parameters {
            request["params"] = parameters
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingResponses[identifier] = continuation
                requestTimeoutTasks[identifier] = Task { [weak self, timeout] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.requestDidTimeOut(identifier)
                }
                do {
                    try write(request)
                } catch {
                    requestTimeoutTasks.removeValue(forKey: identifier)?.cancel()
                    pendingResponses.removeValue(forKey: identifier)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task {
                await self.failPendingRequest(identifier, with: CancellationError())
            }
        }
    }

    private func sendNotification(
        method: String,
        parameters: [String: Any]? = nil
    ) throws {
        var notification: [String: Any] = ["method": method]
        if let parameters {
            notification["params"] = parameters
        }
        try write(notification)
    }

    private func write(_ message: [String: Any]) throws {
        guard let standardInput else {
            throw CodexAppServerFailure.processUnavailable
        }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        do {
            try standardInput.write(contentsOf: data)
        } catch {
            throw CodexAppServerFailure.processUnavailable
        }
    }

    private func receive(data: Data) {
        outputBuffer.append(data)

        // Pipe callbacks may split a JSON-RPC line or deliver several at once.
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(outputBuffer.startIndex ... newline)
            receive(line: Data(line))
        }
    }

    private func receive(line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let identifier = requestIdentifier(in: message) else {
            return
        }
        // Any answer, even a late one, shows the app-server is alive.
        consecutiveTimeouts = 0
        guard let continuation = pendingResponses.removeValue(forKey: identifier) else {
            return
        }
        requestTimeoutTasks.removeValue(forKey: identifier)?.cancel()

        guard message["error"] == nil else {
            continuation.resume(throwing: CodexAppServerFailure.requestFailed)
            return
        }
        guard let result = message["result"] as? [String: Any] else {
            continuation.resume(throwing: CodexAppServerFailure.malformedResponse)
            return
        }
        continuation.resume(returning: result)
    }

    private func requestIdentifier(in message: [String: Any]) -> Int? {
        if let identifier = message["id"] as? Int {
            return identifier
        }
        return (message["id"] as? NSNumber)?.intValue
    }

    private func decode<Response: Decodable>(
        _ type: Response.Type,
        from result: [String: Any]
    ) throws -> Response {
        do {
            let data = try JSONSerialization.data(withJSONObject: result)
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CodexAppServerFailure.malformedResponse
        }
    }

    private func processDidTerminate(token: UUID) {
        guard processToken == token else {
            return
        }
        stopProcess()
        failPendingResponses(with: .processUnavailable)
    }

    private func stopProcess() {
        let runningProcess = process
        process = nil
        processToken = nil
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
            let processIdentifier = runningProcess.processIdentifier
            // An app-server that ignores SIGTERM must not pile up across restarts.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if runningProcess.isRunning {
                    kill(processIdentifier, SIGKILL)
                }
            }
        }
        consecutiveTimeouts = 0
        try? standardInput?.close()
        standardInput = nil
        standardOutput?.readabilityHandler = nil
        standardOutput = nil
        outputChunks?.finish()
        outputChunks = nil
        outputReadTask?.cancel()
        outputReadTask = nil
        standardError?.readabilityHandler = nil
        standardError = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
    }

    private func failPendingResponses(with failure: CodexAppServerFailure) {
        let pending = pendingResponses
        pendingResponses.removeAll()
        let timeoutTasks = requestTimeoutTasks.values
        requestTimeoutTasks.removeAll()
        for task in timeoutTasks {
            task.cancel()
        }
        for continuation in pending.values {
            continuation.resume(throwing: failure)
        }
    }

    private func requestDidTimeOut(_ identifier: Int) {
        guard pendingResponses[identifier] != nil else {
            return
        }
        consecutiveTimeouts += 1
        guard consecutiveTimeouts >= Self.timeoutsBeforeRestart else {
            // Fail only this request: the shared app-server may be holding a sign-in or answering others.
            failPendingRequest(identifier, with: CodexAppServerFailure.requestFailed)
            return
        }
        // A hung app-server would fail every later poll; dropping it makes the next request relaunch.
        stopProcess()
        failPendingResponses(with: .requestFailed)
    }

    private func failPendingRequest(_ identifier: Int, with error: any Error) {
        guard let continuation = pendingResponses.removeValue(forKey: identifier) else {
            return
        }
        requestTimeoutTasks.removeValue(forKey: identifier)?.cancel()
        continuation.resume(throwing: error)
    }
}

private struct CodexAccountResponse: Decodable {
    var account: CodexAccount?
}

private struct CodexAccount: Decodable {
    var type: String
    var planType: String?
}

private struct CodexRateLimitResponse: Decodable {
    var rateLimits: CodexRateLimits
}

private struct CodexResetCreditsResponse: Decodable {
    var rateLimitResetCredits: CodexResetCreditsSummary?
}

private struct CodexResetCreditsSummary: Decodable {
    var availableCount: Int
    var credits: [CodexResetCredit]?

    enum CodingKeys: String, CodingKey {
        case availableCount
        case credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try container.decode(Int.self, forKey: .availableCount)
        // One unreadable credit entry drops only that entry, never the count.
        credits = (try? container.decodeIfPresent([CodexLossyResetCredit].self, forKey: .credits))?
            .compactMap(\.credit)
    }

    var summary: RateLimitResetCredits {
        RateLimitResetCredits(
            availableCount: max(0, availableCount),
            credits: (credits ?? [])
                .filter { $0.status == nil || $0.status == "available" }
                .map { RateLimitResetCredit(title: $0.title, expiresAt: $0.expiresAt.map(Date.init(timeIntervalSince1970:))) }
                .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        )
    }
}

private struct CodexLossyResetCredit: Decodable {
    var credit: CodexResetCredit?

    init(from decoder: Decoder) throws {
        credit = try? CodexResetCredit(from: decoder)
    }
}

/// The opaque credit `id` is deliberately not decoded.
private struct CodexResetCredit: Decodable {
    var status: String?
    var title: String?
    var expiresAt: Double?
}

private struct CodexRateLimits: Decodable {
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
}

private struct CodexRateLimitWindow: Decodable {
    var usedPercent: Double
    var windowDurationMinutes: Double?
    var resetsAt: Double?

    var usageWindow: CodexAppServerUsageWindow {
        CodexAppServerUsageWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMinutes,
            resetsAtUnixSeconds: resetsAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMinutes = "windowDurationMins"
        case resetsAt
    }
}

private struct CodexDeviceCodeLoginResponse: Decodable {
    var type: String
    var verificationURL: String
    var userCode: String

    enum CodingKeys: String, CodingKey {
        case type
        case verificationURL = "verificationUrl"
        case userCode
    }
}
