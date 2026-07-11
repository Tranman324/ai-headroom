import XCTest
@testable import AIUsageMonitor

final class CompositionTests: XCTestCase {
    func testProductionLaunchModeUsesProductionDependenciesAndMonitoring() {
        let configuration = FixtureLaunchConfiguration.current(arguments: [], environment: [:])
        let dependencies = configuration.dependencies

        XCTAssertEqual(configuration.launchMode, .production)
        XCTAssertTrue(configuration.shouldStartMonitoring)
        XCTAssertTrue(dependencies.providerClient(for: .claude) is ClaudeUsageProvider)
        XCTAssertTrue(dependencies.providerClient(for: .codex) is CodexUsageProvider)
        XCTAssertTrue(dependencies.historyStore is LocalHistoryStore)
        XCTAssertTrue(dependencies.settingsStore is LocalSettingsStore)
        XCTAssertTrue(dependencies.connectivityMonitor is NetworkPathConnectivityMonitor)
        XCTAssertTrue(dependencies.lifecycleEvents is WorkspaceLifecycleEvents)
        XCTAssertTrue(dependencies.loginRegistration is ServiceManagementLoginRegistration)
    }

    func testFixtureLaunchModeWinsOverTestEnvironmentAndDisablesMonitoring() async throws {
        let configuration = FixtureLaunchConfiguration.current(
            arguments: ["AI Usage Monitor", "--fixture-scenario", "critical", "--ui-smoke-window"],
            environment: ["AI_USAGE_MONITOR_TEST_HOST": "1"]
        )
        let dependencies = configuration.dependencies
        let snapshot = await dependencies.fetchAllProviderSnapshots()

        XCTAssertEqual(configuration.launchMode, .fixture(.critical))
        XCTAssertEqual(configuration.scenario, .critical)
        XCTAssertTrue(configuration.shouldOpenFixtureWindow)
        XCTAssertFalse(configuration.shouldStartMonitoring)
        assertFixtureDependencies(dependencies)
        XCTAssertEqual(snapshot.hottestBand, .critical)
    }

    func testTestHostLaunchModeUsesFixtureDependenciesAndDisablesMonitoring() async throws {
        let configuration = FixtureLaunchConfiguration.current(
            arguments: ["AI Usage Monitor"],
            environment: ["AI_USAGE_MONITOR_TEST_HOST": "true"]
        )
        let dependencies = configuration.dependencies
        let snapshot = await dependencies.fetchAllProviderSnapshots()

        XCTAssertEqual(configuration.launchMode, .testHost)
        XCTAssertNil(configuration.scenario)
        XCTAssertFalse(configuration.shouldStartMonitoring)
        assertFixtureDependencies(dependencies)
        XCTAssertEqual(snapshot.provider(.claude)?.meters, [])
        XCTAssertEqual(snapshot.provider(.codex)?.meters, [])
    }

    func testXcodeHostedEnvironmentSignalsSelectTestHostLaunchMode() {
        for environment in [
            ["XCInjectBundleInto": "unused"],
            ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"],
            ["XCTestBundlePath": "/tmp/AI Usage MonitorTests.xctest"],
            ["XCODE_TEST_PLAN_NAME": "AI Usage Monitor"]
        ] {
            let configuration = FixtureLaunchConfiguration.current(arguments: [], environment: environment)

            XCTAssertEqual(configuration.launchMode, .testHost)
            XCTAssertFalse(configuration.shouldStartMonitoring)
        }
    }

    func testUnknownOrDisabledTestEnvironmentFieldsRemainProductionSafe() {
        let configuration = FixtureLaunchConfiguration.current(
            arguments: [],
            environment: [
                "AI_USAGE_MONITOR_TEST_HOST": "0",
                "AI_USAGE_MONITOR_UNKNOWN": "1",
                "XCODE_SCHEME_NAME": "AI Usage Monitor"
            ]
        )

        XCTAssertEqual(configuration.launchMode, .production)
        XCTAssertTrue(configuration.shouldStartMonitoring)
    }

    func testCurrentHostedXCTestLaunchDoesNotSelectProductionDependencies() {
        let configuration = FixtureLaunchConfiguration.current()
        let dependencies = configuration.dependencies

        XCTAssertEqual(configuration.launchMode, .testHost)
        XCTAssertFalse(configuration.shouldStartMonitoring)
        assertFixtureDependencies(dependencies)
    }

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

    func testProductionCompositionInstallsProviderClientsWithoutFetchingCredentials() {
        let dependencies = AppCompositionRoot.production()

        XCTAssertEqual(dependencies.configuredProviders, [.claude, .codex])
        XCTAssertNotNil(dependencies.providerClient(for: .claude))
        XCTAssertNotNil(dependencies.providerClient(for: .codex))
    }

    private func assertFixtureDependencies(
        _ dependencies: AppDependencies,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(dependencies.providerClient(for: .claude) is FixtureProviderClient, file: file, line: line)
        XCTAssertTrue(dependencies.providerClient(for: .codex) is FixtureProviderClient, file: file, line: line)
        XCTAssertTrue(dependencies.historyStore is InMemoryHistoryStore, file: file, line: line)
        XCTAssertTrue(dependencies.settingsStore is InMemorySettingsStore, file: file, line: line)
        XCTAssertTrue(dependencies.connectivityMonitor is StaticConnectivityMonitor, file: file, line: line)
        XCTAssertTrue(dependencies.lifecycleEvents is NoopLifecycleEvents, file: file, line: line)
        XCTAssertTrue(dependencies.loginRegistration is UnsupportedLoginRegistration, file: file, line: line)
    }
}
