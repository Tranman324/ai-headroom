import Foundation

struct ProviderHTTPRequest: Equatable, Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?

    init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

struct ProviderHTTPResponse: Equatable, Sendable {
    var statusCode: Int
    var data: Data
}

protocol ProviderHTTPTransporting: Sendable {
    func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse
}

struct URLSessionProviderHTTPTransport: ProviderHTTPTransporting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ProviderHTTPResponse(statusCode: httpResponse.statusCode, data: data)
    }
}

enum ProviderClientFailure: Error, Equatable, LocalizedError, Sendable {
    case credentialUnavailable(provider: ProviderID)
    case credentialUnreadable(provider: ProviderID)
    case credentialInsecure(provider: ProviderID)
    case malformedCredential(provider: ProviderID)
    case missingCredentialValue(provider: ProviderID)
    case credentialPersistence(provider: ProviderID)
    case authenticationRequired(provider: ProviderID)
    case runtimeUnavailable(provider: ProviderID)
    case executableNotFound(provider: ProviderID)
    case usageUnavailable(provider: ProviderID)
    case transport(provider: ProviderID)
    case unauthorized(provider: ProviderID)
    case rateLimited(provider: ProviderID)
    case httpStatus(provider: ProviderID, statusCode: Int)
    case refreshFailed(provider: ProviderID)
    case malformedResponse(provider: ProviderID)

    var provider: ProviderID {
        switch self {
        case let .credentialUnavailable(provider),
             let .credentialUnreadable(provider),
             let .credentialInsecure(provider),
             let .malformedCredential(provider),
             let .missingCredentialValue(provider),
             let .credentialPersistence(provider),
             let .authenticationRequired(provider),
             let .runtimeUnavailable(provider),
             let .executableNotFound(provider),
             let .usageUnavailable(provider),
             let .transport(provider),
             let .unauthorized(provider),
             let .rateLimited(provider),
             let .httpStatus(provider, _),
             let .refreshFailed(provider),
             let .malformedResponse(provider):
            return provider
        }
    }

    var code: ProviderErrorCode {
        switch self {
        case .credentialUnavailable, .credentialUnreadable, .credentialInsecure, .credentialPersistence, .runtimeUnavailable, .executableNotFound, .usageUnavailable, .transport, .httpStatus, .refreshFailed:
            return .unavailable
        case .malformedCredential, .missingCredentialValue, .malformedResponse:
            return .malformedResponse
        case .authenticationRequired, .unauthorized:
            return .unauthorized
        case .rateLimited:
            return .rateLimited
        }
    }

    var errorDescription: String? {
        switch self {
        case let .credentialUnavailable(provider):
            return "\(provider.displayName) credentials are unavailable."
        case let .credentialUnreadable(provider):
            return "\(provider.displayName) credentials could not be read."
        case let .credentialInsecure(provider):
            return "\(provider.displayName) credentials are not stored with restrictive permissions."
        case let .malformedCredential(provider):
            return "\(provider.displayName) credentials are malformed."
        case let .missingCredentialValue(provider):
            return "\(provider.displayName) credentials are missing required values."
        case let .credentialPersistence(provider):
            return "\(provider.displayName) credentials could not be updated."
        case let .authenticationRequired(provider):
            return "\(provider.displayName) authorization is required."
        case let .runtimeUnavailable(provider):
            return "\(provider.displayName) sign-in service is unavailable."
        case let .executableNotFound(provider):
            return "\(provider.cliDisplayName) was not found. Install or update it, then refresh."
        case let .usageUnavailable(provider):
            return "\(provider.displayName) usage could not be read from \(provider.cliDisplayName)."
        case let .transport(provider):
            return "\(provider.displayName) usage service could not be reached."
        case let .unauthorized(provider):
            return "\(provider.displayName) credentials were rejected."
        case let .rateLimited(provider):
            return "\(provider.displayName) usage service is rate limited."
        case let .httpStatus(provider, statusCode):
            return "\(provider.displayName) usage service returned HTTP \(statusCode)."
        case let .refreshFailed(provider):
            return "\(provider.displayName) credentials could not be refreshed."
        case let .malformedResponse(provider):
            return "\(provider.displayName) usage data was malformed."
        }
    }

    var sanitizedError: SanitizedProviderError {
        SanitizedProviderError(code: code, displayMessage: errorDescription ?? "\(provider.displayName) usage failed.")
    }
}

private extension ProviderID {
    var cliDisplayName: String {
        switch self {
        case .claude:
            return "Claude Code CLI"
        case .codex:
            return "Codex CLI"
        }
    }
}

enum ProviderJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let date = parseISO8601(rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 timestamp."
                )
            }
            return date
        }
        return decoder
    }

    static func parseISO8601(_ rawValue: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: rawValue) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }
}
