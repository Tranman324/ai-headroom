import AppKit
import CoreGraphics
import SwiftUI

enum UsageFixtureScenario: String, CaseIterable, Sendable {
    case normal
    case warning
    case critical
    case stale
    case error
    case noData = "no-data"

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
            return AppCompositionRoot.fixture(snapshot: scenario.snapshot)
        }
        return AppCompositionRoot.production()
    }

    var settings: MonitorSettings {
        MonitorSettings()
    }

    var navigation: AppNavigationState {
        AppNavigationState(isHistoryExpanded: startsWithHistoryExpanded)
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

        let controller = NSHostingController(rootView: UsagePopoverView(store: store))
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [configuration, store, window] in
            FixtureEvidenceWriter.writeWindowScreenshot(
                window,
                scenario: configuration.scenario,
                snapshot: store.snapshot,
                navigation: store.navigation,
                directory: screenshotDirectory
            )

            if configuration.shouldTerminateAfterScreenshot {
                NSApp.terminate(nil)
            }
        }
    }
}

private enum FixtureEvidenceWriter {
    static func writeWindowScreenshot(
        _ window: NSWindow,
        scenario: UsageFixtureScenario?,
        snapshot: CombinedUsageSnapshot,
        navigation: AppNavigationState,
        directory: URL
    ) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let bitmap = windowBitmap(window) else {
                return
            }

            let scenarioName = scenario?.rawValue ?? "production"
            let imageURL = directory.appendingPathComponent("popover-\(scenarioName).png")
            let metadataURL = directory.appendingPathComponent("popover-\(scenarioName).txt")
            let data = bitmap.representation(using: .png, properties: [:])
            try data?.write(to: imageURL, options: .atomic)

            let metadata = """
            scenario: \(scenarioName)
            content_points: \(Int(UsagePopoverMetrics.contentWidth))x\(Int(UsagePopoverMetrics.contentHeight))
            pixels: \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)
            status_band: \(snapshot.hottestBand.rawValue)
            hottest_percent: \(hottestPercentText(snapshot))
            meter_order: \(meterOrder(snapshot).joined(separator: ","))
            provider_health: \(providerHealth(snapshot).joined(separator: ","))
            no_data_providers: \(noDataProviders(snapshot).joined(separator: ","))
            navigation: \(navigationState(navigation))
            secret_free_fixture: true
            """
            try metadata.write(to: metadataURL, atomically: true, encoding: .utf8)
        } catch {
            return
        }
    }

    private static func windowBitmap(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let contentView = window.contentView,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            if let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(window.windowNumber),
                [.bestResolution, .boundsIgnoreFraming]
            ) {
                return NSBitmapImageRep(cgImage: image)
            }
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
        switch navigation.meterRoute {
        case .list:
            return navigation.isHistoryExpanded ? "list history-expanded" : "list history-collapsed"
        case let .detail(kind):
            return "detail \(kind.rawValue)"
        }
    }
}
