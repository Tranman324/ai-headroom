import AppKit
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageMonitorStore

    var body: some View {
        ZStack {
            VisualEffectBackdrop()
            UsagePalette.warmCharcoal.swiftUIColor.opacity(0.88)

            VStack(spacing: 10) {
                header
                separator
                ProviderUsageSection(
                    providerID: .claude,
                    provider: store.snapshot.provider(.claude),
                    orderedKinds: UsageMeterOrder.claude,
                    capturedAt: store.snapshot.capturedAt,
                    run: run
                )
                ProviderUsageSection(
                    providerID: .codex,
                    provider: store.snapshot.provider(.codex),
                    orderedKinds: UsageMeterOrder.codex,
                    capturedAt: store.snapshot.capturedAt,
                    run: run
                )
                HistorySection(isExpanded: store.navigation.isHistoryExpanded) {
                    run(.setHistoryExpanded(!store.navigation.isHistoryExpanded))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UsagePopoverMetrics.horizontalPadding)
            .padding(.vertical, 12)

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("navigation-state")
                .accessibilityLabel(accessibilityState)
        }
        .frame(width: UsagePopoverMetrics.contentWidth, height: UsagePopoverMetrics.contentHeight)
        .clipShape(RoundedRectangle(cornerRadius: UsagePopoverMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: UsagePopoverMetrics.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-popover-root")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(UsagePalette.claudeAccent.swiftUIColor)
                .frame(width: 20, height: 24)
                .accessibilityHidden(true)

            Text("AI Usage")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(UsagePalette.primaryText.swiftUIColor)

            Spacer()

            IconButton(
                systemName: "arrow.clockwise",
                accessibilityLabel: "Refresh Now",
                identifier: "popover-refresh-button"
            ) {
                run(.refresh)
            }
            .help("Refresh Now")

            IconButton(
                systemName: "gearshape",
                accessibilityLabel: "Settings",
                identifier: "popover-settings-button"
            ) {
                run(.openSettings)
            }
            .help("Settings")
        }
        .frame(height: 28)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    private var accessibilityState: String {
        switch store.navigation.meterRoute {
        case .list:
            return store.navigation.isHistoryExpanded ? "list history-expanded" : "list history-collapsed"
        case let .detail(kind):
            return "detail \(kind.rawValue)"
        }
    }

    private func run(_ command: AppIntentCommand) {
        Task { @MainActor in
            try? await store.handle(command)
        }
    }
}

private struct ProviderUsageSection: View {
    var providerID: ProviderID
    var provider: ProviderUsageSnapshot?
    var orderedKinds: [MeterKind]
    var capturedAt: Date
    var run: (AppIntentCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(providerID.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(UsagePalette.primaryText.swiftUIColor)

                if providerID == .codex {
                    Text("Pro")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(UsagePalette.codexAccent.swiftUIColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(UsagePalette.codexAccent.swiftUIColor.opacity(0.42), lineWidth: 1)
                        )
                        .accessibilityIdentifier("codex-plan-badge")
                }

                Spacer()

                if let healthLabel {
                    Text(healthLabel)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(healthColor.swiftUIColor)
                        .lineLimit(1)
                        .accessibilityElement()
                        .accessibilityLabel(healthLabel)
                        .accessibilityIdentifier("\(providerID.rawValue)-health-label")
                }
            }
            .frame(height: 18)

            if let provider, !provider.meters.isEmpty {
                ForEach(orderedMeters(from: provider)) { meter in
                    UsageMeterRow(
                        meter: meter,
                        capturedAt: capturedAt,
                        isModelRow: isModelRow(meter.kind),
                        run: run
                    )
                }

                if let healthDetail {
                    Text(healthDetail)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("\(providerID.rawValue)-health-detail")
                }
            } else {
                NoDataProviderRow(providerID: providerID)
            }
        }
        .accessibilityIdentifier("\(providerID.rawValue)-provider-section")
    }

    private var healthLabel: String? {
        guard let provider else {
            return "No data"
        }

        switch provider.health.kind {
        case .fresh:
            return nil
        case .stale:
            return "Stale"
        case .errored:
            return "Error"
        case .noData:
            return "No data"
        }
    }

    private var healthDetail: String? {
        guard let provider else {
            return nil
        }

        switch provider.health.kind {
        case .fresh:
            return nil
        case .stale:
            return provider.health.error?.displayMessage ?? "Using last known values."
        case .errored:
            return provider.health.error?.displayMessage ?? "Unable to refresh usage."
        case .noData:
            return nil
        }
    }

    private var healthColor: NSColor {
        guard let provider else {
            return UsagePalette.mutedText
        }

        switch provider.health.kind {
        case .fresh:
            return UsagePalette.mutedText
        case .stale:
            return UsagePalette.warning
        case .errored:
            return UsagePalette.critical
        case .noData:
            return UsagePalette.mutedText
        }
    }

    private func orderedMeters(from provider: ProviderUsageSnapshot) -> [UsageMeterSnapshot] {
        orderedKinds.compactMap { kind in
            provider.meters.first { $0.kind == kind }
        }
    }

    private func isModelRow(_ kind: MeterKind) -> Bool {
        switch kind {
        case .claudeWeekFable, .claudeWeekSonnet, .claudeWeekHaiku:
            return true
        case .claudeSession, .claudeWeekAll, .codexSession, .codexWeek:
            return false
        }
    }
}

private struct UsageMeterRow: View {
    var meter: UsageMeterSnapshot
    var capturedAt: Date
    var isModelRow: Bool
    var run: (AppIntentCommand) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            run(.showMeterDetail(meter.kind))
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(UsagePresentation.compactLabel(for: meter.kind))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(labelColor)
                            .lineLimit(1)

                        Text(UsagePresentation.resetLabel(for: meter, capturedAt: capturedAt))
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text("\(Int(round(meter.utilization.value)))%")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                        .frame(width: 42, alignment: .trailing)
                        .accessibilityIdentifier("meter-percent-\(meter.kind.rawValue)")
                }

                UsageProgressBar(meter: meter, height: isModelRow ? UsagePopoverMetrics.modelBarHeight : UsagePopoverMetrics.primaryBarHeight)
            }
            .padding(.leading, isModelRow ? 26 : 0)
            .frame(height: isModelRow ? UsagePopoverMetrics.modelRowHeight : UsagePopoverMetrics.primaryRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.045 : 0))
        )
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("meter-row-\(meter.kind.rawValue)")
    }

    private var labelColor: Color {
        isModelRow ? UsagePalette.mutedText.swiftUIColor : UsagePalette.primaryText.swiftUIColor
    }

    private var accessibilityLabel: String {
        "\(UsagePresentation.compactLabel(for: meter.kind)), \(Int(round(meter.utilization.value)))%, \(UsagePresentation.resetLabel(for: meter, capturedAt: capturedAt))"
    }
}

private struct UsageProgressBar: View {
    var meter: UsageMeterSnapshot
    var height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(UsagePalette.inset.swiftUIColor)

                Capsule()
                    .fill(UsagePresentation.barColor(for: meter).swiftUIColor)
                    .frame(width: geometry.size.width * CGFloat(meter.utilization.value / 100))
            }
        }
        .frame(height: height)
        .accessibilityIdentifier("meter-bar-\(meter.kind.rawValue)")
    }
}

private struct NoDataProviderRow: View {
    var providerID: ProviderID

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "minus.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                .accessibilityHidden(true)

            Text("No data")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UsagePalette.mutedText.swiftUIColor)

            Spacer()
        }
        .frame(height: UsagePopoverMetrics.primaryRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(providerID.displayName) no data")
        .accessibilityIdentifier("\(providerID.rawValue)-no-data-row")
    }
}

private struct HistorySection: View {
    var isExpanded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12)
                        .accessibilityHidden(true)

                    Text("7-day history")
                        .font(.system(size: 12, weight: .medium))

                    Spacer()
                }
                .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 22)
            .accessibilityIdentifier("history-toggle")

            if isExpanded {
                HistorySparklineView(series: MockHistoryData.series)
                    .frame(width: UsagePopoverMetrics.chartWidth, height: UsagePopoverMetrics.chartHeight)
            }
        }
    }
}

struct HistorySparklinePoint: Equatable, Sendable {
    var dayIndex: Int
    var utilization: Double
}

struct HistorySparklineSeries: Identifiable, Equatable, Sendable {
    var id: String
    var color: NSColor
    var isDashed: Bool
    var points: [HistorySparklinePoint]
}

enum MockHistoryData {
    static let series: [HistorySparklineSeries] = [
        HistorySparklineSeries(
            id: "All Models",
            color: UsagePalette.allModels,
            isDashed: true,
            points: [42, 51, 58, 66, 71, 64, 76].enumerated().map { HistorySparklinePoint(dayIndex: $0.offset, utilization: Double($0.element)) }
        ),
        HistorySparklineSeries(
            id: "Fable",
            color: UsagePalette.claudeAccent,
            isDashed: false,
            points: [34, 45, 57, 63, 83, 72, 79].enumerated().map { HistorySparklinePoint(dayIndex: $0.offset, utilization: Double($0.element)) }
        ),
        HistorySparklineSeries(
            id: "Sonnet",
            color: UsagePalette.sonnet,
            isDashed: false,
            points: [18, 24, 36, 38, 42, 41, 46].enumerated().map { HistorySparklinePoint(dayIndex: $0.offset, utilization: Double($0.element)) }
        ),
        HistorySparklineSeries(
            id: "Haiku",
            color: UsagePalette.haiku,
            isDashed: false,
            points: [8, 12, 17, 11, 14, 12, 16].enumerated().map { HistorySparklinePoint(dayIndex: $0.offset, utilization: Double($0.element)) }
        )
    ]
}

private struct HistorySparklineView: View {
    var series: [HistorySparklineSeries]

    var body: some View {
        Canvas { context, size in
            let baseline = Path(CGRect(origin: .zero, size: size))
            context.stroke(baseline, with: .color(Color.white.opacity(0.05)), lineWidth: 1)

            var resetMarker = Path()
            let resetX = size.width * 0.78
            resetMarker.move(to: CGPoint(x: resetX, y: 0))
            resetMarker.addLine(to: CGPoint(x: resetX, y: size.height))
            context.stroke(resetMarker, with: .color(Color.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

            for item in series {
                var path = Path()
                for point in item.points {
                    let x = CGFloat(point.dayIndex) / 6 * size.width
                    let y = size.height - CGFloat(min(100, max(0, point.utilization)) / 100) * size.height
                    let cgPoint = CGPoint(x: x, y: y)
                    if point.dayIndex == 0 {
                        path.move(to: cgPoint)
                    } else {
                        path.addLine(to: cgPoint)
                    }
                }

                let style = item.isDashed
                    ? StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [5, 4])
                    : StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                context.stroke(path, with: .color(item.color.swiftUIColor), style: style)
            }
        }
        .background(UsagePalette.inset.swiftUIColor.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("history-chart")
    }
}

private struct IconButton: View {
    var systemName: String
    var accessibilityLabel: String
    var identifier: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct UsagePopoverFixturePreview: View {
    @StateObject private var store: UsageMonitorStore

    init(snapshot: CombinedUsageSnapshot) {
        _store = StateObject(
            wrappedValue: UsageMonitorStore(
                dependencies: AppCompositionRoot.fixture(snapshot: snapshot),
                initialSnapshot: snapshot,
                navigation: AppNavigationState(isHistoryExpanded: true)
            )
        )
    }

    var body: some View {
        UsagePopoverView(store: store)
    }
}

#Preview("Normal") {
    UsagePopoverFixturePreview(snapshot: UsageMonitorFixtures.normalSnapshot)
}

#Preview("Warning") {
    UsagePopoverFixturePreview(snapshot: UsageMonitorFixtures.warningSnapshot)
}

#Preview("Critical") {
    UsagePopoverFixturePreview(snapshot: UsageMonitorFixtures.criticalSnapshot)
}

#Preview("Stale") {
    UsagePopoverFixturePreview(snapshot: UsageMonitorFixtures.staleLastKnownGoodSnapshot)
}

#Preview("Provider Error") {
    UsagePopoverFixturePreview(snapshot: UsageMonitorFixtures.providerErrorOtherHealthySnapshot)
}

#Preview("No Data") {
    UsagePopoverFixturePreview(snapshot: UsageMonitorFixtures.noDataSnapshot)
}
