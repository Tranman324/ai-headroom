import SwiftUI

@main
struct AIUsageMonitorApp: App {
    @StateObject private var store = UsageMonitorStore(dependencies: AppCompositionRoot.production())

    var body: some Scene {
        MenuBarExtra("AI Usage Monitor", systemImage: "chart.line.uptrend.xyaxis") {
            Button {
                run(.refresh)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")

            Button {
                run(.openSettings)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            Divider()

            Button {
                run(.quit)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

        Settings {
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

    private func run(_ command: AppIntentCommand) {
        Task { @MainActor in
            try await store.handle(command)
        }
    }
}
