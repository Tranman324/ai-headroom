import XCTest
@testable import AIUsageMonitor

final class ClaudeUsageProviderTests: XCTestCase {
    private let token = "fake-claude-access-token"
    private let checkedAt = Date(timeIntervalSince1970: 1_783_756_800)

    func testSuccessfulFetchMapsAllFiveClaudeMetersAndRequestShape() async throws {
        let credentialReader = FakeClaudeCredentialReader(data: credentialJSON(token: token))
        let transport = FakeProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 200, data: fullUsageJSON()))
        ])
        let provider = ClaudeUsageProvider(
            credentialReader: credentialReader,
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()
        let requests = await transport.requests
        let authorization = requests.first?.headers["Authorization"]

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.health.kind, .fresh)
        XCTAssertEqual(snapshot.health.checkedAt, checkedAt)
        XCTAssertEqual(snapshot.meters.map(\.provider), Array(repeating: .claude, count: 5))
        XCTAssertEqual(snapshot.meters.map(\.kind), [
            .claudeSession,
            .claudeWeekAll,
            .claudeWeekFable,
            .claudeWeekSonnet,
            .claudeWeekHaiku
        ])
        XCTAssertEqual(snapshot.meters.map(\.utilization.value), [11, 22, 33, 44, 55])
        XCTAssertEqual(snapshot.meters.map(\.resetAt), [
            date("2026-07-11T15:00:00Z"),
            date("2026-07-18T15:00:00Z"),
            date("2026-07-18T16:00:00Z"),
            date("2026-07-18T17:00:00Z"),
            date("2026-07-18T18:00:00Z")
        ])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertEqual(requests.first?.url.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(requests.first?.headers["anthropic-beta"], "oauth-2025-04-20")
        XCTAssertEqual(authorization?.hasPrefix("Bearer "), true)
        XCTAssertEqual(authorization?.count, "Bearer ".count + token.count)

        let encodedSnapshot = try String(data: JSONEncoder().encode(snapshot), encoding: .utf8).unwrap()
        XCTAssertFalse(encodedSnapshot.contains(token))
    }

    func testCredentialReaderRunsForEveryFetchInvocation() async throws {
        let credentialReader = FakeClaudeCredentialReader(data: credentialJSON(token: token))
        let transport = FakeProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 200, data: fullUsageJSON())),
            .success(ProviderHTTPResponse(statusCode: 200, data: fullUsageJSON()))
        ])
        let provider = ClaudeUsageProvider(
            credentialReader: credentialReader,
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        _ = try await provider.fetchUsageSnapshot()
        _ = try await provider.fetchUsageSnapshot()

        let readCount = await credentialReader.readCount
        let requests = await transport.requests
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(requests.count, 2)
    }

    func testUnknownFieldsAndUnrelatedLimitsAreTolerated() async throws {
        let credentialReader = FakeClaudeCredentialReader(data: credentialJSON(token: token, includeUnknownFields: true))
        let transport = FakeProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 200, data: fullUsageJSON(includeUnknownFields: true)))
        ])
        let provider = ClaudeUsageProvider(
            credentialReader: credentialReader,
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.meters.count, 5)
        XCTAssertEqual(snapshot.meters.map(\.kind), [
            .claudeSession,
            .claudeWeekAll,
            .claudeWeekFable,
            .claudeWeekSonnet,
            .claudeWeekHaiku
        ])
    }

    func testMissingRequiredModelLimitFailsWithoutLeakingSecrets() async {
        let credentialJSON = credentialJSON(token: token)
        let credentialReader = FakeClaudeCredentialReader(data: credentialJSON)
        let transport = FakeProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 200, data: fullUsageJSON(omitHaiku: true)))
        ])
        let provider = ClaudeUsageProvider(
            credentialReader: credentialReader,
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        await assertProviderFailure(from: provider, code: .malformedResponse, disallowing: [
            token,
            String(data: credentialJSON, encoding: .utf8)!
        ])
    }

    func testMalformedTimestampFailsWithoutResponseBodyLeakage() async {
        let responseBody = fullUsageJSON(sessionReset: "not-a-date")
        let credentialReader = FakeClaudeCredentialReader(data: credentialJSON(token: token))
        let transport = FakeProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 200, data: responseBody))
        ])
        let provider = ClaudeUsageProvider(
            credentialReader: credentialReader,
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        await assertProviderFailure(from: provider, code: .malformedResponse, disallowing: [
            token,
            String(data: responseBody, encoding: .utf8)!
        ])
    }

    func testMissingRequiredWindowFailsWithoutResponseBodyLeakage() async {
        let responseBody = Data("""
        {
          "seven_day": { "utilization": 22, "resets_at": "2026-07-18T15:00:00Z" },
          "limits": [
            { "utilization": 33, "resets_at": "2026-07-18T16:00:00Z", "scope": { "model": { "display_name": "Fable" } } },
            { "utilization": 44, "resets_at": "2026-07-18T17:00:00Z", "scope": { "model": { "display_name": "Sonnet" } } },
            { "utilization": 55, "resets_at": "2026-07-18T18:00:00Z", "scope": { "model": { "display_name": "Haiku" } } }
          ],
          "access_token": "fake-claude-access-token"
        }
        """.utf8)
        let provider = ClaudeUsageProvider(
            credentialReader: FakeClaudeCredentialReader(data: credentialJSON(token: token)),
            transport: FakeProviderHTTPTransport(responses: [
                .success(ProviderHTTPResponse(statusCode: 200, data: responseBody))
            ]),
            clock: FixedClock(now: checkedAt)
        )

        await assertProviderFailure(from: provider, code: .malformedResponse, disallowing: [
            token,
            String(data: responseBody, encoding: .utf8)!
        ])
    }

    func testCredentialFailuresAreSanitized() async {
        let malformedCredential = Data(#"{"claudeAiOauth":{"accessToken":"fake-claude-access-token"}}"#.utf8.dropLast())
        let provider = ClaudeUsageProvider(
            credentialReader: FakeClaudeCredentialReader(data: malformedCredential),
            transport: FakeProviderHTTPTransport(responses: []),
            clock: FixedClock(now: checkedAt)
        )

        await assertProviderFailure(from: provider, code: .malformedResponse, disallowing: [
            token,
            String(data: malformedCredential, encoding: .utf8) ?? ""
        ])
    }

    func testMissingTokenFailsSanitized() async {
        let missingTokenCredential = Data(#"{"claudeAiOauth":{"accessToken":" "}}"#.utf8)
        let provider = ClaudeUsageProvider(
            credentialReader: FakeClaudeCredentialReader(data: missingTokenCredential),
            transport: FakeProviderHTTPTransport(responses: []),
            clock: FixedClock(now: checkedAt)
        )

        await assertProviderFailure(from: provider, code: .malformedResponse, disallowing: [
            String(data: missingTokenCredential, encoding: .utf8)!
        ])
    }

    func testUnreadableCredentialFailureIsSanitized() async {
        let provider = ClaudeUsageProvider(
            credentialReader: FakeClaudeCredentialReader(error: SecretCredentialError()),
            transport: FakeProviderHTTPTransport(responses: []),
            clock: FixedClock(now: checkedAt)
        )

        await assertProviderFailure(from: provider, code: .unavailable, disallowing: [
            token,
            SecretCredentialError().localizedDescription
        ])
    }

    func testStatusAndTransportFailuresAreSanitized() async {
        let secretBody = Data(#"{"access_token":"fake-claude-access-token","error":"nope"}"#.utf8)
        let statusProvider = ClaudeUsageProvider(
            credentialReader: FakeClaudeCredentialReader(data: credentialJSON(token: token)),
            transport: FakeProviderHTTPTransport(responses: [
                .success(ProviderHTTPResponse(statusCode: 401, data: secretBody))
            ]),
            clock: FixedClock(now: checkedAt)
        )

        await assertProviderFailure(from: statusProvider, code: .unauthorized, disallowing: [
            token,
            String(data: secretBody, encoding: .utf8)!
        ])

        let transportProvider = ClaudeUsageProvider(
            credentialReader: FakeClaudeCredentialReader(data: credentialJSON(token: token)),
            transport: FakeProviderHTTPTransport(responses: [
                .failure(SecretTransportError())
            ]),
            clock: FixedClock(now: checkedAt)
        )

        await assertProviderFailure(from: transportProvider, code: .unavailable, disallowing: [
            token,
            SecretTransportError().localizedDescription
        ])
    }

    private func assertProviderFailure(
        from provider: ClaudeUsageProvider,
        code: ProviderErrorCode,
        disallowing forbiddenFragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.fetchUsageSnapshot()
            XCTFail("Expected provider failure.", file: file, line: line)
        } catch let failure as ProviderClientFailure {
            let description = failure.localizedDescription
            XCTAssertEqual(failure.code, code, file: file, line: line)
            for fragment in forbiddenFragments where !fragment.isEmpty {
                XCTAssertFalse(description.contains(fragment), file: file, line: line)
            }
        } catch {
            XCTFail("Expected sanitized provider failure.", file: file, line: line)
        }
    }

    private func credentialJSON(token: String, includeUnknownFields: Bool = false) -> Data {
        let suffix = includeUnknownFields ? #","extra":{"nested":true}"# : ""
        return Data(#"{"claudeAiOauth":{"accessToken":"\#(token)"\#(suffix)},"other":"preserved"}"#.utf8)
    }

    private func fullUsageJSON(
        includeUnknownFields: Bool = false,
        omitHaiku: Bool = false,
        sessionReset: String = "2026-07-11T15:00:00Z"
    ) -> Data {
        let topLevelExtra = includeUnknownFields ? #","unknown_top":{"nested":true}"# : ""
        let nestedExtra = includeUnknownFields ? #","unknown_nested":42"# : ""
        let haikuLimit = omitHaiku ? "" : """
        ,{
          "utilization": 55,
          "resets_at": "2026-07-18T18:00:00Z",
          "scope": { "model": { "display_name": "Haiku"\(nestedExtra) } }
        }
        """

        return Data("""
        {
          "five_hour": {
            "utilization": 11,
            "resets_at": "\(sessionReset)"\(nestedExtra)
          },
          "seven_day": {
            "utilization": 22,
            "resets_at": "2026-07-18T15:00:00Z"\(nestedExtra)
          },
          "limits": [
            {
              "utilization": 33,
              "resets_at": "2026-07-18T16:00:00Z",
              "scope": { "model": { "display_name": "Fable"\(nestedExtra) } }
            },
            {
              "utilization": 44,
              "resets_at": "2026-07-18T17:00:00Z",
              "scope": { "model": { "display_name": "Sonnet"\(nestedExtra) } }
            }\(haikuLimit),
            {
              "utilization": 99,
              "resets_at": "2026-07-18T19:00:00Z",
              "scope": { "model": { "display_name": "Opus"\(nestedExtra) } }
            }
          ]\(topLevelExtra)
        }
        """.utf8)
    }

    private func date(_ rawValue: String) -> Date {
        ProviderJSON.parseISO8601(rawValue)!
    }
}

private actor FakeClaudeCredentialReader: ClaudeCredentialReading {
    private let result: Result<Data, Error>
    private(set) var readCount = 0

    init(data: Data) {
        self.result = .success(data)
    }

    init(error: Error) {
        self.result = .failure(error)
    }

    func credentialData() async throws -> Data {
        readCount += 1
        return try result.get()
    }
}

private actor FakeProviderHTTPTransport: ProviderHTTPTransporting {
    private(set) var requests: [ProviderHTTPRequest] = []
    private var responses: [Result<ProviderHTTPResponse, Error>]

    init(responses: [Result<ProviderHTTPResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return try responses.removeFirst().get()
    }
}

private struct SecretTransportError: LocalizedError {
    var errorDescription: String? {
        "transport leaked fake-claude-access-token"
    }
}

private struct SecretCredentialError: LocalizedError {
    var errorDescription: String? {
        "credential reader leaked fake-claude-access-token"
    }
}

private extension Optional {
    func unwrap(file: StaticString = #filePath, line: UInt = #line) throws -> Wrapped {
        guard let value = self else {
            XCTFail("Expected optional value.", file: file, line: line)
            throw XCTSkip("Expected optional value.")
        }
        return value
    }
}
