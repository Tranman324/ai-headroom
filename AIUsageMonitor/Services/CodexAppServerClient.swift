import Foundation

enum CodexAppServerFailure: Error, Equatable, Sendable {
    case executableUnavailable
    case processUnavailable
    case authenticationRequired
    case malformedResponse
    case requestFailed
}

struct CodexAppServerRuntime: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
}

protocol CodexAppServerRuntimeLocating: Sendable {
    func runtime() -> CodexAppServerRuntime?
}

struct CodexAppServerRuntimeLocator: CodexAppServerRuntimeLocating {
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
                ProviderExecutableTrust.openAIRequirement,
                executableURL: url
            )
        }
    ) {
        self.candidateExecutablePaths = candidateExecutablePaths
        self.isExecutable = isExecutable
        self.isTrustedExecutable = isTrustedExecutable
    }

    func runtime() -> CodexAppServerRuntime? {
        if let path = candidateExecutablePaths.first(where: { path in
            isExecutable(path) && isTrustedExecutable(URL(fileURLWithPath: path))
        }) {
            return CodexAppServerRuntime(
                executableURL: URL(fileURLWithPath: path).resolvingSymlinksInPath(),
                arguments: ["app-server", "--stdio"]
            )
        }
        return nil
    }

    private static var defaultCandidateExecutablePaths: [String] {
        let homeDirectory = NSHomeDirectory()
        return [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(homeDirectory)/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(homeDirectory)/.local/bin/codex",
            "\(homeDirectory)/.codex/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
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
    private var errorReadTask: Task<Void, Never>?
    private var outputBuffer = Data()
    private var nextRequestID = 1
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
        requestTimeout: Duration = .seconds(15)
    ) {
        self.runtimeLocator = nil
        self.explicitRuntime = CodexAppServerRuntime(
            executableURL: executableURL,
            arguments: executableArguments
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
        let rateLimits = try decode(CodexRateLimitResponse.self, from: rateLimitResponse)
        return CodexAppServerUsage(
            planType: account.planType,
            primaryWindow: CodexAppServerUsageWindow(
                usedPercent: rateLimits.rateLimits.primary.usedPercent,
                windowDurationMinutes: rateLimits.rateLimits.primary.windowDurationMinutes,
                resetsAtUnixSeconds: rateLimits.rateLimits.primary.resetsAt
            ),
            secondaryWindow: rateLimits.rateLimits.secondary.map {
                CodexAppServerUsageWindow(
                    usedPercent: $0.usedPercent,
                    windowDurationMinutes: $0.windowDurationMinutes,
                    resetsAtUnixSeconds: $0.resetsAt
                )
            }
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
        guard process == nil else {
            return
        }

        do {
            try startProcess()
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
        } catch {
            stopProcess()
            throw error
        }
    }

    private func startProcess() throws {
        guard let runtime = runtimeLocator?.runtime() ?? explicitRuntime else {
            throw CodexAppServerFailure.executableUnavailable
        }
        let input = Pipe()
        let output = Pipe()
        let standardError = Pipe()
        let newProcess = Process()
        let token = UUID()

        newProcess.executableURL = runtime.executableURL
        newProcess.arguments = runtime.arguments
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

        let outputHandle = output.fileHandleForReading
        standardOutput = outputHandle
        // Blocking reads stay off the actor; closing the handle unblocks cancellation.
        outputReadTask = Task.detached(priority: .utility) { [weak self, outputHandle] in
            while !Task.isCancelled {
                let data = outputHandle.availableData
                guard !data.isEmpty else {
                    return
                }
                await self?.receive(data: data)
            }
        }

        let errorHandle = standardError.fileHandleForReading
        self.standardError = errorHandle
        errorReadTask = Task.detached(priority: .utility) { [errorHandle] in
            while !Task.isCancelled {
                guard !errorHandle.availableData.isEmpty else {
                    return
                }
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
                    await self?.failPendingRequest(identifier, with: CodexAppServerFailure.requestFailed)
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
        let data = try JSONSerialization.data(withJSONObject: message)
        standardInput.write(data)
        standardInput.write(Data([0x0A]))
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
              let identifier = requestIdentifier(in: message),
              let continuation = pendingResponses.removeValue(forKey: identifier) else {
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
        }
        standardInput?.closeFile()
        standardInput = nil
        outputReadTask?.cancel()
        outputReadTask = nil
        standardOutput = nil
        errorReadTask?.cancel()
        errorReadTask = nil
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

private struct CodexRateLimits: Decodable {
    var primary: CodexRateLimitWindow
    var secondary: CodexRateLimitWindow?
}

private struct CodexRateLimitWindow: Decodable {
    var usedPercent: Double
    var windowDurationMinutes: Double
    var resetsAt: Double

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
