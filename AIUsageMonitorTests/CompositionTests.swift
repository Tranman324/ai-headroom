import XCTest
@testable import AIUsageMonitor

final class CompositionTests: XCTestCase {
    func testFixtureCompositionInstallsExplicitDependenciesForBothProviders() async throws {
        let dependencies = AppCompositionRoot.fixture(snapshot: UsageMonitorFixtures.criticalSnapshot)

        XCTAssertEqual(dependencies.configuredProviders, [.claude, .codex])
        XCTAssertNotNil(dependencies.providerClient(for: .claude))
        XCTAssertNotNil(dependencies.providerClient(for: .codex))

        let settings = try await dependencies.settingsStore.loadSettings()
        let snapshot = await dependencies.fetchAllProviderSnapshots()

        XCTAssertEqual(settings, .defaults)
        XCTAssertEqual(snapshot.provider(.claude)?.meters.count, 5)
        XCTAssertEqual(snapshot.provider(.codex)?.meters.count, 2)
        XCTAssertEqual(snapshot.hottestBand, .critical)
    }

    func testProductionCompositionUsesPlaceholderNoDataProviders() async {
        let dependencies = AppCompositionRoot.production()
        let snapshot = await dependencies.fetchAllProviderSnapshots()

        XCTAssertEqual(dependencies.configuredProviders, [.claude, .codex])
        XCTAssertEqual(snapshot.provider(.claude)?.health.kind, .noData)
        XCTAssertEqual(snapshot.provider(.codex)?.health.kind, .noData)
        XCTAssertTrue(snapshot.meters.isEmpty)
    }
}
