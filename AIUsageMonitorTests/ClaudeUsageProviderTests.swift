import Security
import XCTest
@testable import AIUsageMonitor

final class ClaudeUsageProviderTests: XCTestCase {
    private let token = "fake-claude-access-token"
    private let checkedAt = Date(timeIntervalSince1970: 1_783_756_800)

    func testProductionKeychainQueryTargetsCurrentAccountExactly() {
        let reader = KeychainClaudeCredentialReader()
        let query = reader.query

        XCTAssertEqual(reader.account, NSUserName())
        XCTAssertEqual(query.count, 5)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "Claude Code-credentials")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, NSUserName())
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }

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

    // Previously this asserted `.malformedResponse` when a model-scoped weekly
    // limit was missing. The live API only returns model limits that are
    // currently active (e.g. Fable alone), so the provider now degrades
    // gracefully: it omits the absent model's meter instead of failing the poll.
    func testMissingModelLimitOmitsThatMeterWithoutFailing() async throws {
        let credentialReader = FakeClaudeCredentialReader(data: credentialJSON(token: token))
        let transport = FakeProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 200, data: fullUsageJSON(omitHaiku: true)))
        ])
        let provider = ClaudeUsageProvider(
            credentialReader: credentialReader,
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        XCTAssertEqual(snapshot.meters.map(\.kind), [
            .claudeSession,
            .claudeWeekAll,
            .claudeWeekFable,
            .claudeWeekSonnet
        ])
        XCTAssertFalse(snapshot.meters.contains { $0.kind == .claudeWeekHaiku })
    }

    func testLiveShapePercentAndNullableScopeMapsAvailableMeters() async throws {
        let credentialReader = FakeClaudeCredentialReader(data: credentialJSON(token: token))
        let transport = FakeProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 200, data: liveShapeUsageJSON()))
        ])
        let provider = ClaudeUsageProvider(
            credentialReader: credentialReader,
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        // Live payload carries only one active model-scoped weekly limit (Fable),
        // reports usage as integer `percent`, and sets `scope: null` on the
        // non-model limits. Session + week-all + Fable should all map.
        XCTAssertEqual(snapshot.meters.map(\.kind), [
            .claudeSession,
            .claudeWeekAll,
            .claudeWeekFable
        ])
        XCTAssertEqual(snapshot.meters.map(\.utilization.value), [16, 71, 93])
        XCTAssertEqual(snapshot.health.kind, .fresh)
    }

    func testUnknownExtraModelLimitIsSkipped() async throws {
        let credentialReader = FakeClaudeCredentialReader(data: credentialJSON(token: token))
        let transport = FakeProviderHTTPTransport(responses: [
            .success(ProviderHTTPResponse(statusCode: 200, data: liveShapeUsageJSON(includeUnknownModel: true)))
        ])
        let provider = ClaudeUsageProvider(
            credentialReader: credentialReader,
            transport: transport,
            clock: FixedClock(now: checkedAt)
        )

        let snapshot = try await provider.fetchUsageSnapshot()

        // An extra `weekly_scoped` entry for an unrecognized model must be
        // ignored rather than mapped to a meter or failing the poll.
        XCTAssertEqual(snapshot.meters.map(\.kind), [
            .claudeSession,
            .claudeWeekAll,
            .claudeWeekFable
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

    // Sanitized fixture derived from a real live `oauth/usage` response: limits
    // report integer `percent` (not `utilization`), carry `kind`/`group`/
    // `severity`/`is_active` fields, set `scope: null` on non-model limits, and
    // include only the single active model-scoped weekly limit (Fable). No
    // verbatim identifiers — rounded percentages and generic timestamps only.
    private func liveShapeUsageJSON(includeUnknownModel: Bool = false) -> Data {
        let unknownModelLimit = includeUnknownModel ? """
        ,{
          "kind": "weekly_scoped",
          "group": "weekly",
          "percent": 40,
          "severity": "normal",
          "resets_at": "2026-07-12T00:00:00Z",
          "scope": { "model": { "id": null, "display_name": "Mystery" }, "surface": null },
          "is_active": false
        }
        """ : ""

        return Data("""
        {
          "five_hour": {
            "utilization": 16.0,
            "resets_at": "2026-07-12T02:00:00.608522+00:00",
            "limit_dollars": null,
            "used_dollars": null,
            "remaining_dollars": null
          },
          "seven_day": {
            "utilization": 71.0,
            "resets_at": "2026-07-11T23:59:59.608543+00:00",
            "limit_dollars": null,
            "used_dollars": null,
            "remaining_dollars": null
          },
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "extra_usage": { "is_enabled": false, "utilization": null },
          "limits": [
            {
              "kind": "session",
              "group": "session",
              "percent": 16,
              "severity": "normal",
              "resets_at": "2026-07-12T02:00:00.608522+00:00",
              "scope": null,
              "is_active": false
            },
            {
              "kind": "weekly_all",
              "group": "weekly",
              "percent": 71,
              "severity": "normal",
              "resets_at": "2026-07-11T23:59:59.608543+00:00",
              "scope": null,
              "is_active": false
            },
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 93,
              "severity": "critical",
              "resets_at": "2026-07-12T00:00:00.608792+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": true
            }\(unknownModelLimit)
          ],
          "spend": { "percent": 0, "enabled": false },
          "member_dashboard_available": false
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
