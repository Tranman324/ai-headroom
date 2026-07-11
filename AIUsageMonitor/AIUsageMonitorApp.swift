import SwiftUI

@main
struct AIUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AIUsageMonitorAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsPaneView(store: appDelegate.store)
        }
    }
}

@MainActor
final class AIUsageMonitorAppDelegate: NSObject, NSApplicationDelegate {
    private let launchConfiguration = FixtureLaunchConfiguration.current()
    lazy var store = UsageMonitorStore(
        dependencies: launchConfiguration.dependencies,
        initialSnapshot: launchConfiguration.initialSnapshot,
        settings: launchConfiguration.settings,
        navigation: launchConfiguration.navigation
    )

    private var statusItemController: StatusItemController?
    private var fixtureWindowController: FixtureWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            store: store,
            popoverConfiguration: launchConfiguration.popoverConfiguration
        )

        if launchConfiguration.shouldOpenFixtureWindow {
            NSApp.setActivationPolicy(.regular)
            fixtureWindowController = FixtureWindowController(
                store: store,
                configuration: launchConfiguration
            )
            fixtureWindowController?.show()
        }

        if launchConfiguration.shouldStartMonitoring {
            Task { @MainActor in
                await store.startMonitoring()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            await store.stopMonitoring()
        }
    }
}

private struct SettingsPaneView: View {
    @ObservedObject var store: UsageMonitorStore

    var body: some View {
        Form {
            Text("AI Usage Monitor")
                .font(.headline)

            LabeledContent("Polling", value: "\(store.settings.pollingInterval.minutes) min")
            LabeledContent("Alert", value: "\(Int(store.settings.alertThreshold.percentage))%")
            LabeledContent("History", value: "\(store.settings.historyRetention.days) days")
        }
        .padding()
        .frame(width: 360)
    }
}
