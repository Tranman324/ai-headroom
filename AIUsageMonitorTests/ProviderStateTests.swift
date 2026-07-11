import XCTest
@testable import AIUsageMonitor

final class ProviderStateTests: XCTestCase {
    func testProviderErrorRetainsLocalLastKnownGoodDataWithoutCorruptingOtherProvider() {
        let snapshot = UsageMonitorFixtures.providerErrorOtherHealthySnapshot
        let claude = snapshot.provider(.claude)
        let codex = snapshot.provider(.codex)

        XCTAssertEqual(claude?.health.kind, .errored)
        XCTAssertEqual(claude?.hasLastKnownGoodData, true)
        XCTAssertEqual(claude?.meters.count, 5)
        XCTAssertEqual(codex?.health.kind, .fresh)
        XCTAssertEqual(codex?.hasCurrentData, true)
        XCTAssertEqual(codex?.meters.count, 2)
    }

    func testSanitizedProviderErrorRedactsCredentialLikeFragments() {
        let error = SanitizedProviderError(
            code: .unauthorized,
            displayMessage: "Bearer secret-token-123 access_token=abc123 sk-1234567890"
        )

        XCTAssertFalse(error.displayMessage.contains("secret-token-123"))
        XCTAssertFalse(error.displayMessage.contains("access_token=abc123"))
        XCTAssertFalse(error.displayMessage.contains("sk-1234567890"))
        XCTAssertTrue(error.displayMessage.contains("[redacted]"))
    }

    func testSanitizedProviderErrorRedactsJSONAndCamelCaseCredentialFragments() {
        let error = SanitizedProviderError(
            code: .unauthorized,
            displayMessage: """
            Claude usage failed with {"accessToken":"fake-access-token-value","refresh_token":"fake-refresh-token-value","api-key":"fake-api-key-value","Authorization":"Bearer fake-bearer-value"} while keeping provider context.
            """
        )

        XCTAssertFalse(error.displayMessage.contains("fake-access-token-value"))
        XCTAssertFalse(error.displayMessage.contains("fake-refresh-token-value"))
        XCTAssertFalse(error.displayMessage.contains("fake-api-key-value"))
        XCTAssertFalse(error.displayMessage.contains("fake-bearer-value"))
        XCTAssertTrue(error.displayMessage.contains("Claude usage failed"))
        XCTAssertTrue(error.displayMessage.contains("provider context"))
    }

    func testProviderSnapshotDropsMismatchedMeters() {
        let snapshot = ProviderUsageSnapshot(
            provider: .codex,
            meters: UsageMonitorFixtures.allMeterSnapshots,
            health: .fresh(checkedAt: UsageMonitorFixtures.baseDate)
        )

        XCTAssertEqual(snapshot.meters.map(\.provider), [.codex, .codex])
    }
}
