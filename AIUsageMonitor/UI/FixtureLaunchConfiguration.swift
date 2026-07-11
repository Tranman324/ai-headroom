import AppKit
import SwiftUI

enum UsageFixtureScenario: String, CaseIterable, Sendable {
    case normal
    case warning
    case critical
    case stale
    case error
    case noData = "no-data"
    case expandedHistory = "expanded-history"
    case preResetExhaustion = "pre-reset-exhaustion"
    case safeProjection = "safe-projection"
    case insufficientBurn = "insufficient-burn"
    case rangeTwentyFourHours = "range-24h"
    case rangeThreeDays = "range-3d"
    case rangeSevenDays = "range-7d"
    case settings
    case noHistory = "no-history"

    var snapshot: CombinedUsageSnapshot {
        switch self {
        case .normal:
            return UsageMonitorFixtures.normalSnapshot
        case .warning:
            return UsageMonitorFixtures.warningSnapshot
        case .critical:
            return UsageMonitorFixtures.criticalSnapshot
        case .stale:
            return UsageMonitorFixtures.staleLastKnownGoodSnapshot
        case .error:
            return UsageMonitorFixtures.providerErrorOtherHealthySnapshot
        case .noData:
            return UsageMonitorFixtures.noDataSnapshot
        case .expandedHistory, .preResetExhaustion, .rangeTwentyFourHours, .rangeThreeDays, .rangeSevenDays:
            return UsageMonitorFixtures.criticalSnapshot
        case .safeProjection:
            return UsageMonitorFixtures.safeProjectionSnapshot
        case .insufficientBurn, .noHistory:
            return UsageMonitorFixtures.normalSnapshot
        case .settings:
            return UsageMonitorFixtures.settingsSnapshot
        }
    }

    var historySnapshots: [CombinedUsageSnapshot] {
        switch self {
        case .noData, .noHistory:
            return UsageMonitorFixtures.noHistorySnapshots
        case .preResetExhaustion, .rangeTwentyFourHours, .rangeThreeDays, .rangeSevenDays:
            return UsageMonitorFixtures.preResetExhaustionHistory
        case .safeProjection:
            return UsageMonitorFixtures.safeProjectionHistory
        case .insufficientBurn:
            return UsageMonitorFixtures.insufficientBurnHistory
        case .normal, .warning, .critical, .stale, .error, .expandedHistory, .settings:
            return UsageMonitorFixtures.expandedHistorySnapshots
        }
    }

    var monitorSettings: MonitorSettings {
        switch self {
        case .settings:
            return UsageMonitorFixtures.settingsFixtureSettings
        case .normal, .warning, .critical, .stale, .error, .noData, .expandedHistory, .preResetExhaustion, .safeProjection, .insufficientBurn, .rangeTwentyFourHours, .rangeThreeDays, .rangeSevenDays, .noHistory:
            return .defaults
        }
    }

    var popoverConfiguration: UsagePopoverConfiguration {
        .production
    }

    func navigation(startsWithHistoryExpanded: Bool) -> AppNavigationState {
        switch self {
        case .preResetExhaustion:
            return AppNavigationState(meterRoute: .detail(.claudeWeekFable), detailRange: .sevenDays)
        case .safeProjection:
            return AppNavigationState(meterRoute: .detail(.codexWeek), detailRange: .sevenDays)
        case .insufficientBurn:
            return AppNavigationState(meterRoute: .detail(.claudeSession), detailRange: .twentyFourHours)
        case .rangeTwentyFourHours:
            return AppNavigationState(meterRoute: .detail(.claudeWeekFable), detailRange: .twentyFourHours)
        case .rangeThreeDays:
            return AppNavigationState(meterRoute: .detail(.claudeWeekFable), detailRange: .threeDays)
        case .rangeSevenDays:
            return AppNavigationState(meterRoute: .detail(.claudeWeekFable), detailRange: .sevenDays)
        case .settings:
            return AppNavigationState(isSettingsPresented: true)
        case .expandedHistory, .noHistory:
            return AppNavigationState(isHistoryExpanded: true)
        case .normal, .warning, .critical, .stale, .error, .noData:
            return AppNavigationState(isHistoryExpanded: startsWithHistoryExpanded)
        }
    }

    static func parse(_ value: String) -> UsageFixtureScenario? {
        if value == "noData" {
            return .noData
        }
        return UsageFixtureScenario(rawValue: value)
    }
}

struct FixtureLaunchConfiguration {
    var scenario: UsageFixtureScenario?
    var shouldOpenFixtureWindow: Bool
    var shouldWriteScreenshot: Bool
    var shouldTerminateAfterScreenshot: Bool
    var startsWithHistoryExpanded: Bool
    var screenshotDirectory: URL?

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FixtureLaunchConfiguration {
        let scenarioValue = value(after: "--fixture-scenario", in: arguments)
            ?? environment["AI_USAGE_MONITOR_FIXTURE_SCENARIO"]
        let screenshotPath = value(after: "--screenshot-directory", in: arguments)
            ?? environment["AI_USAGE_MONITOR_SCREENSHOT_DIR"]

        return FixtureLaunchConfiguration(
            scenario: scenarioValue.flatMap(UsageFixtureScenario.parse),
            shouldOpenFixtureWindow: arguments.contains("--ui-smoke-window"),
            shouldWriteScreenshot: arguments.contains("--write-fixture-screenshot") || screenshotPath != nil,
            shouldTerminateAfterScreenshot: arguments.contains("--terminate-after-screenshot"),
            startsWithHistoryExpanded: arguments.contains("--history-expanded"),
            screenshotDirectory: screenshotPath.map { URL(fileURLWithPath: $0) }
        )
    }

    var initialSnapshot: CombinedUsageSnapshot {
        scenario?.snapshot ?? UsageMonitorFixtures.noDataSnapshot
    }

    var dependencies: AppDependencies {
        if let scenario {
            return AppCompositionRoot.fixture(
                snapshot: scenario.snapshot,
                historySnapshots: scenario.historySnapshots,
                settings: scenario.monitorSettings
            )
        }
        return AppCompositionRoot.production()
    }

    var settings: MonitorSettings {
        scenario?.monitorSettings ?? MonitorSettings()
    }

    var initialHistorySnapshots: [CombinedUsageSnapshot] {
        scenario?.historySnapshots ?? []
    }

    var navigation: AppNavigationState {
        scenario?.navigation(startsWithHistoryExpanded: startsWithHistoryExpanded)
            ?? AppNavigationState(isHistoryExpanded: startsWithHistoryExpanded)
    }

    var popoverConfiguration: UsagePopoverConfiguration {
        scenario?.popoverConfiguration ?? .production
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }
        return arguments[valueIndex]
    }
}

@MainActor
final class FixtureWindowController {
    private let store: UsageMonitorStore
    private let configuration: FixtureLaunchConfiguration
    private let window: NSWindow

    init(store: UsageMonitorStore, configuration: FixtureLaunchConfiguration) {
        self.store = store
        self.configuration = configuration

        let controller = UsagePopoverHostFactory.makeHostingController(
            store: store,
            configuration: configuration.popoverConfiguration
        )
        self.window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: UsagePopoverMetrics.contentWidth,
                height: UsagePopoverMetrics.contentHeight
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Usage Monitor Fixture"
        window.identifier = NSUserInterfaceItemIdentifier("usage-fixture-window")
        window.contentViewController = controller
        window.setContentSize(NSSize(
            width: UsagePopoverMetrics.contentWidth,
            height: UsagePopoverMetrics.contentHeight
        ))
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard configuration.shouldWriteScreenshot, let screenshotDirectory = configuration.screenshotDirectory else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [configuration, store, window] in
            Task { @MainActor in
                await store.loadHistory(since: store.snapshot.capturedAt.addingTimeInterval(-UsagePresentation.historyLookback))
                try? FixtureEvidenceWriter.writeWindowScreenshot(
                    window,
                    scenario: configuration.scenario,
                    snapshot: store.snapshot,
                    settings: store.settings,
                    navigation: store.navigation,
                    historicalSnapshots: store.historicalSnapshots,
                    directory: screenshotDirectory
                )

                guard configuration.shouldTerminateAfterScreenshot else {
                    return
                }
                window.orderOut(nil)
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

@MainActor
private enum FixtureEvidenceWriter {
    static func writeWindowScreenshot(
        _ window: NSWindow,
        scenario: UsageFixtureScenario?,
        snapshot: CombinedUsageSnapshot,
        settings: MonitorSettings,
        navigation: AppNavigationState,
        historicalSnapshots: [CombinedUsageSnapshot],
        directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let bitmap = windowBitmap(window),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureEvidenceError.bitmapUnavailable
        }

        let scenarioName = scenario?.rawValue ?? "production"
        let imageURL = directory.appendingPathComponent("popover-\(scenarioName).png")
        let metadataURL = directory.appendingPathComponent("popover-\(scenarioName).txt")
        let historySeries = UsagePresentation.historySeries(from: historicalSnapshots, now: snapshot.capturedAt)
        let detail = detailPresentation(for: navigation, snapshot: snapshot, historicalSnapshots: historicalSnapshots)
        try data.write(to: imageURL, options: .atomic)

        let metadata = """
        scenario: \(scenarioName)
        content_points: \(Int(UsagePopoverMetrics.contentWidth))x\(Int(UsagePopoverMetrics.contentHeight))
        pixels: \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)
        status_band: \(snapshot.hottestBand.rawValue)
        hottest_percent: \(hottestPercentText(snapshot))
        meter_order: \(meterOrder(snapshot).joined(separator: ","))
        provider_health: \(providerHealth(snapshot).joined(separator: ","))
        no_data_providers: \(noDataProviders(snapshot).joined(separator: ","))
        history_state: \(historySeries.isEmpty ? "empty" : "populated")
        history_snapshot_count: \(historicalSnapshots.count)
        history_series_count: \(historySeries.count)
        navigation: \(navigationState(navigation))
        detail_kind: \(detail?.kind.rawValue ?? "none")
        detail_range: \(detail?.range.rawValue ?? "none")
        detail_chart_points: \(detail?.points.count ?? 0)
        projection_state: \(projectionState(detail))
        settings_polling_minutes: \(settings.pollingInterval.minutes)
        settings_alert_threshold: \(Int(settings.alertThreshold.percentage))
        settings_history_retention_days: \(settings.historyRetention.days)
        settings_launch_at_login: \(settings.launchAtLogin)
        secret_free_fixture: true
        """
        try (metadata + "\n").write(to: metadataURL, atomically: true, encoding: .utf8)
    }

    private static func windowBitmap(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let contentView = window.contentView else {
            return nil
        }

        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()

        let scale: CGFloat = 2
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(contentView.bounds.width * scale),
            pixelsHigh: Int(contentView.bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap else {
            return nil
        }
        bitmap.size = contentView.bounds.size
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        return bitmap
    }

    private static func hottestPercentText(_ snapshot: CombinedUsageSnapshot) -> String {
        guard let hottest = snapshot.hottestMeter else {
            return "--"
        }
        return "\(Int(round(hottest.utilization.value)))"
    }

    private static func meterOrder(_ snapshot: CombinedUsageSnapshot) -> [String] {
        (UsageMeterOrder.claude + UsageMeterOrder.codex).compactMap { kind in
            snapshot.meters.contains { $0.kind == kind } ? kind.rawValue : nil
        }
    }

    private static func providerHealth(_ snapshot: CombinedUsageSnapshot) -> [String] {
        ProviderID.allCases.map { providerID in
            let health = snapshot.provider(providerID)?.health.kind.rawValue ?? ProviderHealthKind.noData.rawValue
            return "\(providerID.rawValue)=\(health)"
        }
    }

    private static func noDataProviders(_ snapshot: CombinedUsageSnapshot) -> [String] {
        ProviderID.allCases.compactMap { providerID in
            guard snapshot.provider(providerID)?.meters.isEmpty ?? true else {
                return nil
            }
            return providerID.rawValue
        }
    }

    private static func navigationState(_ navigation: AppNavigationState) -> String {
        if navigation.isSettingsPresented {
            return "settings"
        }

        switch navigation.meterRoute {
        case .list:
            return navigation.isHistoryExpanded ? "list history-expanded" : "list history-collapsed"
        case let .detail(kind):
            return "detail \(kind.rawValue) range \(navigation.detailRange.rawValue)"
        }
    }

    private static func detailPresentation(
        for navigation: AppNavigationState,
        snapshot: CombinedUsageSnapshot,
        historicalSnapshots: [CombinedUsageSnapshot]
    ) -> MeterDetailPresentation? {
        guard case let .detail(kind) = navigation.meterRoute else {
            return nil
        }
        return UsagePresentation.detailPresentation(
            kind: kind,
            snapshot: snapshot,
            historicalSnapshots: historicalSnapshots,
            range: navigation.detailRange
        )
    }

    private static func projectionState(_ detail: MeterDetailPresentation?) -> String {
        guard let detail else {
            return "none"
        }
        switch detail.bannerTone {
        case .critical:
            return "critical"
        case .safe:
            return "safe"
        case .muted:
            return "none"
        }
    }
}

private enum FixtureEvidenceError: Error {
    case bitmapUnavailable
}
