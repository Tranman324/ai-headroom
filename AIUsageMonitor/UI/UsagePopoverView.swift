import AppKit
import SwiftUI

struct UsagePopoverConfiguration: Equatable, Sendable {
    static let production = UsagePopoverConfiguration()
    static let populatedFixture = UsagePopoverConfiguration()
}

@MainActor
enum UsagePopoverHostFactory {
    static func makeHostingController(
        store: UsageMonitorStore,
        configuration: UsagePopoverConfiguration
    ) -> NSHostingController<UsagePopoverView> {
        let host = NSHostingController(rootView: UsagePopoverView(store: store, configuration: configuration))
        host.sizingOptions = .preferredContentSize
        return host
    }
}

struct UsagePopoverView: View {
    @ObservedObject var store: UsageMonitorStore
    var configuration: UsagePopoverConfiguration

    @State private var historyLoadingTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            VisualEffectBackdrop()
            UsagePalette.warmCharcoal.swiftUIColor.opacity(0.88)

            content
                .padding(.horizontal, UsagePopoverMetrics.horizontalPadding)
                .padding(.vertical, 10)

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("navigation-state")
                .accessibilityLabel(accessibilityState)
        }
        .frame(width: UsagePopoverMetrics.contentWidth)
        .clipShape(RoundedRectangle(cornerRadius: UsagePopoverMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: UsagePopoverMetrics.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-popover-root")
        .onAppear(perform: scheduleHistoryLoad)
        .onChange(of: store.snapshot.capturedAt) { _, _ in
            scheduleHistoryLoad()
        }
        .onDisappear {
            historyLoadingTask?.cancel()
            historyLoadingTask = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.navigation.isSettingsPresented {
            if store.navigation.isProviderConnectionsPresented {
                ProviderConnectionsScreen(
                    challenge: store.providerAuthenticationChallenge,
                    connectionError: store.providerConnectionError,
                    statuses: store.providerConnectionStatuses,
                    authenticatingProviders: store.authenticatingProviders,
                    run: run
                )
            } else {
                SettingsPopoverScreen(settings: store.settings, run: run)
            }
        } else {
            switch store.navigation.meterRoute {
            case .list:
                UsageListScreen(store: store, run: run)
            case let .detail(kind):
                MeterDetailScreen(store: store, kind: kind, run: run)
            }
        }
    }

    private var accessibilityState: String {
        if store.navigation.isSettingsPresented {
            return store.navigation.isProviderConnectionsPresented ? "connections" : "settings"
        }

        switch store.navigation.meterRoute {
        case .list:
            return store.navigation.isHistoryExpanded ? "list history-expanded" : "list history-collapsed"
        case let .detail(kind):
            return "detail \(kind.rawValue) range \(effectiveRange(for: kind).rawValue)"
        }
    }

    private func effectiveRange(for kind: MeterKind) -> MeterDetailRange {
        kind.window == .rollingFiveHours ? .twentyFourHours : store.navigation.detailRange
    }

    private func scheduleHistoryLoad() {
        historyLoadingTask?.cancel()
        let startDate = store.snapshot.capturedAt.addingTimeInterval(-UsagePresentation.historyLookback)
        historyLoadingTask = Task { @MainActor in
            await store.loadHistory(since: startDate)
        }
    }

    private func run(_ command: AppIntentCommand) {
        Task { @MainActor in
            try? await store.handle(command)
        }
    }
}

private struct UsageListScreen: View {
    @ObservedObject var store: UsageMonitorStore
    var run: (AppIntentCommand) -> Void

    var body: some View {
        VStack(spacing: 8) {
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
            HistorySection(
                isExpanded: store.navigation.isHistoryExpanded,
                series: UsagePresentation.historySeries(
                    from: store.historicalSnapshots,
                    now: store.snapshot.capturedAt
                ),
                loadState: store.historyLoadState
            ) {
                run(.setHistoryExpanded(!store.navigation.isHistoryExpanded))
            }
            Spacer(minLength: 0)
        }
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
                Circle()
                    .fill(UsagePalette.accent(for: providerID).swiftUIColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text(providerID == .claude ? "CLAUDE MAX" : "OPENAI CODEX")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(UsagePalette.allModels.swiftUIColor)
                    .tracking(1.1)

                if providerID == .codex {
                    Text("Pro")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(UsagePalette.codexAccent.swiftUIColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(providerID == .claude ? "Claude Max usage meters" : "OpenAI Codex usage meters")
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "minus.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("No data")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UsagePalette.mutedText.swiftUIColor)

                if let hint {
                    Text(hint)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(UsagePalette.mutedText.swiftUIColor.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
        .frame(minHeight: UsagePopoverMetrics.primaryRowHeight, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(providerID.displayName) no data")
        .accessibilityIdentifier("\(providerID.rawValue)-no-data-row")
    }

    private var hint: String? {
        guard providerID == .claude else {
            return nil
        }
        return "Usage syncs while Claude Code runs in a terminal — send one message there to populate."
    }
}

private struct HistorySection: View {
    var isExpanded: Bool
    var series: [HistorySparklineSeries]
    var loadState: HistoryLoadState
    var toggle: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                        .accessibilityHidden(true)

                    Text("7-day history")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(UsagePalette.allModels.swiftUIColor)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 22)
            .accessibilityIdentifier("history-toggle")

            if isExpanded {
                if series.isEmpty {
                    NoHistoryView(message: emptyMessage)
                        .frame(width: UsagePopoverMetrics.chartWidth, height: 44)
                } else {
                    VStack(spacing: 5) {
                        HistorySparklineView(series: series)
                            .frame(width: UsagePopoverMetrics.chartWidth, height: UsagePopoverMetrics.chartHeight)
                        HistoryLegendView(series: series)
                    }
                    .accessibilityIdentifier("history-expanded-content")
                }
            }
        }
    }

    private var emptyMessage: String {
        if case .failed = loadState {
            return "History unavailable"
        }
        return "No history"
    }
}

private struct NoHistoryView: View {
    var message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 11, weight: .medium))

            Spacer()
        }
        .padding(.horizontal, 10)
        .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
        .background(UsagePalette.inset.swiftUIColor.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityIdentifier("history-empty-state")
    }
}

private struct HistorySparklineView: View {
    var series: [HistorySparklineSeries]

    var body: some View {
        Canvas { context, size in
            let allPoints = series.flatMap(\.points)
            guard let firstDate = allPoints.map(\.capturedAt).min(),
                  let lastDate = allPoints.map(\.capturedAt).max(),
                  firstDate < lastDate else {
                return
            }

            drawGrid(in: &context, size: size)
            drawResetMarkers(in: &context, size: size, points: allPoints, firstDate: firstDate, lastDate: lastDate)

            for item in series {
                var path = Path()
                var didStart = false
                for (index, point) in item.points.enumerated() {
                    let cgPoint = pointPosition(point, size: size, firstDate: firstDate, lastDate: lastDate)
                    if !didStart {
                        path.move(to: cgPoint)
                        didStart = true
                    } else if point.preservesResetDiscontinuity,
                              index > 0,
                              point.utilization < item.points[index - 1].utilization {
                        path.move(to: cgPoint)
                    } else {
                        path.addLine(to: cgPoint)
                    }
                }

                let style = item.isDashed
                    ? StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [1, 2.5])
                    : StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
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

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        for fraction in [0.25, 0.5, 0.75] {
            var path = Path()
            let y = size.height * fraction
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(Color.white.opacity(0.05)), lineWidth: 1)
        }
    }

    private func drawResetMarkers(
        in context: inout GraphicsContext,
        size: CGSize,
        points: [HistorySparklinePoint],
        firstDate: Date,
        lastDate: Date
    ) {
        let resetDates = Array(Set(points.filter(\.preservesResetDiscontinuity).map(\.capturedAt))).sorted()
        for date in resetDates.prefix(3) {
            let x = xPosition(for: date, width: size.width, firstDate: firstDate, lastDate: lastDate)
            var marker = Path()
            marker.move(to: CGPoint(x: x, y: 8))
            marker.addLine(to: CGPoint(x: x, y: size.height - 5))
            context.stroke(marker, with: .color(UsagePalette.mutedText.swiftUIColor.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func pointPosition(
        _ point: HistorySparklinePoint,
        size: CGSize,
        firstDate: Date,
        lastDate: Date
    ) -> CGPoint {
        CGPoint(
            x: xPosition(for: point.capturedAt, width: size.width, firstDate: firstDate, lastDate: lastDate),
            y: yPosition(for: point.utilization, height: size.height)
        )
    }

    private func xPosition(for date: Date, width: CGFloat, firstDate: Date, lastDate: Date) -> CGFloat {
        let denominator = max(1, lastDate.timeIntervalSince(firstDate))
        return CGFloat(date.timeIntervalSince(firstDate) / denominator) * width
    }

    private func yPosition(for value: Double, height: CGFloat) -> CGFloat {
        height - CGFloat(min(100, max(0, value)) / 100) * (height - 10) - 5
    }
}

private struct HistoryLegendView: View {
    var series: [HistorySparklineSeries]

    var body: some View {
        HStack(spacing: 9) {
            ForEach(series) { item in
                HStack(spacing: 4) {
                    Capsule()
                        .fill(item.color.swiftUIColor)
                        .frame(width: 8, height: 3)
                    Text(item.title)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: UsagePopoverMetrics.chartWidth, height: 12)
        .accessibilityIdentifier("history-legend")
    }
}

private struct MeterDetailScreen: View {
    @ObservedObject var store: UsageMonitorStore
    var kind: MeterKind
    var run: (AppIntentCommand) -> Void

    var body: some View {
        if let presentation = UsagePresentation.detailPresentation(
            kind: kind,
            snapshot: store.snapshot,
            historicalSnapshots: store.historicalSnapshots,
            range: effectiveRange
        ) {
            VStack(spacing: 10) {
                detailHeader(presentation)
                detailHero(presentation)
                ProjectionBanner(presentation: presentation)
                if presentation.showsRangeSelector {
                    RangeSelector(selectedRange: presentation.range, run: run)
                }
                DetailTrendChart(presentation: presentation)
                    .frame(width: UsagePopoverMetrics.chartWidth, height: 118)
                DetailStatsView(stats: presentation.stats)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(presentation.title) detail")
            .accessibilityIdentifier("meter-detail-\(kind.rawValue)")
        } else {
            MissingMeterDetail(kind: kind, run: run)
        }
    }

    private var effectiveRange: MeterDetailRange {
        kind.window == .rollingFiveHours ? .twentyFourHours : store.navigation.detailRange
    }

    private func detailHeader(_ presentation: MeterDetailPresentation) -> some View {
        HStack(spacing: 8) {
            Button {
                run(.backFromMeterDetail)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to meters")
            .accessibilityIdentifier("meter-detail-back-button")

            Spacer()

            Text(presentation.providerLabel)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(UsagePresentation.chartColor(for: kind).swiftUIColor)
                .tracking(1.0)
                .lineLimit(1)
                .accessibilityIdentifier("meter-detail-provider")
        }
        .frame(height: 24)
    }

    private func detailHero(_ presentation: MeterDetailPresentation) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            Text(presentation.percentText)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .foregroundStyle(presentation.percentColor.swiftUIColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .accessibilityIdentifier("meter-detail-percent")

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier("meter-detail-title")

                Text("\(presentation.resetContext) · burning \(presentation.burnText)")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityIdentifier("meter-detail-subtitle")
            }
            .padding(.bottom, 5)

            Spacer(minLength: 0)
        }
        .frame(height: 42)
    }
}

private struct ProjectionBanner: View {
    var presentation: MeterDetailPresentation

    var body: some View {
        Text(presentation.bannerText)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityIdentifier("projection-banner-\(toneIdentifier)")
    }

    private var toneIdentifier: String {
        switch presentation.bannerTone {
        case .critical:
            return "critical"
        case .safe:
            return "safe"
        case .muted:
            return "muted"
        }
    }

    private var foreground: Color {
        switch presentation.bannerTone {
        case .critical:
            return Color(nsColor: NSColor(hex: 0xF2A6A9))
        case .safe:
            return UsagePalette.codexAccent.swiftUIColor
        case .muted:
            return UsagePalette.mutedText.swiftUIColor
        }
    }

    private var background: Color {
        switch presentation.bannerTone {
        case .critical:
            return UsagePalette.critical.swiftUIColor.opacity(0.13)
        case .safe:
            return UsagePalette.codexAccent.swiftUIColor.opacity(0.10)
        case .muted:
            return Color.white.opacity(0.045)
        }
    }
}

private struct RangeSelector: View {
    var selectedRange: MeterDetailRange
    var run: (AppIntentCommand) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MeterDetailRange.allCases, id: \.self) { range in
                Button {
                    run(.setMeterDetailRange(range))
                } label: {
                    Text(range.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(range == selectedRange ? UsagePalette.primaryText.swiftUIColor : UsagePalette.mutedText.swiftUIColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 21)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(range == selectedRange ? Color.white.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(range.rawValue) range")
                .accessibilityIdentifier("range-\(range.rawValue)-button")
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityIdentifier("meter-detail-range-selector")
    }
}

private struct DetailTrendChart: View {
    var presentation: MeterDetailPresentation

    var body: some View {
        VStack(spacing: 2) {
            Canvas { context, size in
                drawChart(in: &context, size: size)
            }
            .background(UsagePalette.inset.swiftUIColor.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )

            HStack {
                Text(xStartLabel)
                Spacer()
                Text("now")
            }
            .font(.system(size: 8.5, weight: .regular))
            .foregroundStyle(UsagePalette.mutedText.swiftUIColor.opacity(0.72))
        }
        .accessibilityIdentifier("meter-detail-chart")
    }

    private var xStartLabel: String {
        switch presentation.range {
        case .twentyFourHours:
            return "24h ago"
        case .threeDays:
            return "3d ago"
        case .sevenDays:
            return "7d ago"
        }
    }

    private func drawChart(in context: inout GraphicsContext, size: CGSize) {
        for value in [25.0, 50.0, 75.0] {
            var grid = Path()
            let y = yPosition(for: value, height: size.height)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(grid, with: .color(Color.white.opacity(0.05)), lineWidth: 1)
        }

        var limit = Path()
        let limitY = yPosition(for: 100, height: size.height)
        limit.move(to: CGPoint(x: 0, y: limitY))
        limit.addLine(to: CGPoint(x: size.width, y: limitY))
        context.stroke(limit, with: .color(UsagePalette.critical.swiftUIColor.opacity(0.30)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

        let dates = chartDates
        guard let firstDate = dates.min(), let lastDate = dates.max(), firstDate < lastDate else {
            drawEmptyChart(in: &context, size: size)
            return
        }

        drawResetMarkers(in: &context, size: size, firstDate: firstDate, lastDate: lastDate)
        drawUsageLine(in: &context, size: size, firstDate: firstDate, lastDate: lastDate)
        drawProjection(in: &context, size: size, firstDate: firstDate, lastDate: lastDate)
    }

    private var chartDates: [Date] {
        let pointDates = presentation.points.map(\.capturedAt)
        if let projection = presentation.projection {
            return pointDates + [projection.endDate]
        }
        return pointDates
    }

    private func drawResetMarkers(in context: inout GraphicsContext, size: CGSize, firstDate: Date, lastDate: Date) {
        let resetDates = Array(Set(presentation.points.filter(\.preservesResetDiscontinuity).map(\.capturedAt))).sorted()
        for date in resetDates.prefix(3) {
            let x = xPosition(for: date, width: size.width, firstDate: firstDate, lastDate: lastDate)
            var marker = Path()
            marker.move(to: CGPoint(x: x, y: 10))
            marker.addLine(to: CGPoint(x: x, y: size.height - 10))
            context.stroke(marker, with: .color(UsagePalette.mutedText.swiftUIColor.opacity(0.50)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func drawUsageLine(in context: inout GraphicsContext, size: CGSize, firstDate: Date, lastDate: Date) {
        guard !presentation.points.isEmpty else {
            drawEmptyChart(in: &context, size: size)
            return
        }

        var line = Path()
        var area = Path()
        var areaStarted = false
        let bottom = size.height - 8

        for (index, point) in presentation.points.enumerated() {
            let cgPoint = pointPosition(point, size: size, firstDate: firstDate, lastDate: lastDate)
            if index == 0 {
                line.move(to: cgPoint)
                area.move(to: CGPoint(x: cgPoint.x, y: bottom))
                area.addLine(to: cgPoint)
                areaStarted = true
            } else if point.preservesResetDiscontinuity,
                      point.utilization.value < presentation.points[index - 1].utilization.value {
                line.move(to: cgPoint)
                if areaStarted {
                    area.addLine(to: CGPoint(x: pointPosition(presentation.points[index - 1], size: size, firstDate: firstDate, lastDate: lastDate).x, y: bottom))
                    area.closeSubpath()
                }
                area.move(to: CGPoint(x: cgPoint.x, y: bottom))
                area.addLine(to: cgPoint)
            } else {
                line.addLine(to: cgPoint)
                area.addLine(to: cgPoint)
            }
        }

        if let lastPoint = presentation.points.last {
            area.addLine(to: CGPoint(x: pointPosition(lastPoint, size: size, firstDate: firstDate, lastDate: lastDate).x, y: bottom))
            area.closeSubpath()
        }

        context.fill(area, with: .color(presentation.chartColor.swiftUIColor.opacity(0.09)))
        context.stroke(line, with: .color(presentation.chartColor.swiftUIColor), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }

    private func drawProjection(in context: inout GraphicsContext, size: CGSize, firstDate: Date, lastDate: Date) {
        guard let projection = presentation.projection,
              let lastPoint = presentation.points.last else {
            return
        }

        let start = pointPosition(lastPoint, size: size, firstDate: firstDate, lastDate: lastDate)
        let end = CGPoint(
            x: xPosition(for: projection.endDate, width: size.width, firstDate: firstDate, lastDate: lastDate),
            y: yPosition(for: projection.endUtilization, height: size.height)
        )
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        let color = projection.isCritical ? UsagePalette.critical : UsagePalette.mutedText
        context.stroke(path, with: .color(color.swiftUIColor), style: StrokeStyle(lineWidth: 1.2, dash: [2, 4]))

        if projection.isCritical {
            context.fill(
                Path(ellipseIn: CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10)),
                with: .color(UsagePalette.critical.swiftUIColor.opacity(0.18))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: end.x - 2.4, y: end.y - 2.4, width: 4.8, height: 4.8)),
                with: .color(UsagePalette.critical.swiftUIColor)
            )
        }
    }

    private func drawEmptyChart(in context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: CGPoint(x: 10, y: size.height / 2))
        path.addLine(to: CGPoint(x: size.width - 10, y: size.height / 2))
        context.stroke(path, with: .color(UsagePalette.mutedText.swiftUIColor.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    private func pointPosition(_ point: UsageChartPoint, size: CGSize, firstDate: Date, lastDate: Date) -> CGPoint {
        CGPoint(
            x: xPosition(for: point.capturedAt, width: size.width, firstDate: firstDate, lastDate: lastDate),
            y: yPosition(for: point.utilization.value, height: size.height)
        )
    }

    private func xPosition(for date: Date, width: CGFloat, firstDate: Date, lastDate: Date) -> CGFloat {
        let denominator = max(1, lastDate.timeIntervalSince(firstDate))
        return CGFloat(date.timeIntervalSince(firstDate) / denominator) * width
    }

    private func yPosition(for value: Double, height: CGFloat) -> CGFloat {
        height - CGFloat(min(100, max(0, value)) / 100) * (height - 18) - 8
    }
}

private struct DetailStatsView: View {
    var stats: [MeterDetailStat]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(stats, id: \.label) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.label)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color(nsColor: NSColor(hex: 0x6E6A64)))
                        .tracking(0.8)
                    Text(stat.value)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(stat.color.swiftUIColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.04))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("meter-detail-stats")
    }
}

private struct MissingMeterDetail: View {
    var kind: MeterKind
    var run: (AppIntentCommand) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    run(.backFromMeterDetail)
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("meter-detail-back-button")
                Spacer()
            }

            Spacer()
            NoHistoryView(message: "\(kind.displayName) unavailable")
                .frame(width: UsagePopoverMetrics.chartWidth, height: 44)
            Spacer()
        }
    }
}

private struct SettingsPopoverScreen: View {
    var settings: MonitorSettings
    var run: (AppIntentCommand) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    run(.closeSettings)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to meters")
                .accessibilityIdentifier("settings-back-button")

                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(UsagePalette.primaryText.swiftUIColor)

                Spacer()
            }
            .frame(height: 28)

            SettingsStepperRow(
                title: "Polling interval",
                valueText: "\(settings.pollingInterval.minutes) min",
                identifier: "settings-polling-stepper",
                decrementDisabled: settings.pollingInterval.minutes <= PollingInterval.allowedRange.lowerBound,
                incrementDisabled: settings.pollingInterval.minutes >= PollingInterval.allowedRange.upperBound,
                decrement: {
                    setPolling(settings.pollingInterval.minutes - 1)
                },
                increment: {
                    setPolling(settings.pollingInterval.minutes + 1)
                }
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Alert threshold")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                    Spacer()
                    Text("\(Int(settings.alertThreshold.percentage))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                }

                Slider(
                    value: Binding(
                        get: { settings.alertThreshold.percentage },
                        set: { setAlertThreshold($0) }
                    ),
                    in: Double(AlertThreshold.allowedRange.lowerBound)...Double(AlertThreshold.allowedRange.upperBound),
                    step: Double(AlertThreshold.step)
                )
                .controlSize(.small)
                .accessibilityIdentifier("settings-alert-threshold-slider")

                Text("Status colors stay fixed at 70% and 90%.")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                    .lineLimit(1)
            }
            .settingsPanelStyle()

            SettingsStepperRow(
                title: "History retention",
                valueText: "\(settings.historyRetention.days) days",
                identifier: "settings-retention-stepper",
                decrementDisabled: settings.historyRetention.days <= HistoryRetention.allowedRange.lowerBound,
                incrementDisabled: settings.historyRetention.days >= HistoryRetention.allowedRange.upperBound,
                decrement: {
                    setRetention(settings.historyRetention.days - 1)
                },
                increment: {
                    setRetention(settings.historyRetention.days + 1)
                }
            )

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at Login")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                    Text(settings.launchAtLogin ? "Enabled" : "Disabled")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                        .accessibilityIdentifier("settings-launch-at-login-state")
                }
                Spacer()
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { run(.setLaunchAtLogin($0)) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("settings-launch-at-login-toggle")
            }
            .settingsPanelStyle()

            Button {
                run(.openProviderConnections)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(UsagePalette.codexAccent.swiftUIColor)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text("Provider connections")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .settingsPanelStyle()
            .accessibilityIdentifier("settings-provider-connections-button")

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-screen")
    }

    private func setPolling(_ minutes: Int) {
        guard let interval = try? PollingInterval(minutes: minutes) else {
            return
        }
        run(.setPollingInterval(interval))
    }

    private func setAlertThreshold(_ value: Double) {
        let rounded = (value / Double(AlertThreshold.step)).rounded() * Double(AlertThreshold.step)
        guard let threshold = try? AlertThreshold(percentage: rounded) else {
            return
        }
        run(.setAlertThreshold(threshold))
    }

    private func setRetention(_ days: Int) {
        guard let retention = try? HistoryRetention(days: days) else {
            return
        }
        run(.setHistoryRetention(retention))
    }
}

private struct ProviderConnectionsScreen: View {
    var challenge: ProviderAuthenticationChallenge?
    var connectionError: SanitizedProviderError?
    var statuses: [ProviderID: ProviderConnectionStatus]
    var authenticatingProviders: Set<ProviderID>
    var run: (AppIntentCommand) -> Void

    private var codexUserCode: String? {
        guard challenge?.provider == .codex else {
            return nil
        }
        return challenge?.userCode
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    run(.closeProviderConnections)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to settings")
                .accessibilityIdentifier("connections-back-button")

                Text("Connections")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(UsagePalette.primaryText.swiftUIColor)

                Spacer()
            }
            .frame(height: 28)

            connectionPanel(
                title: "OpenAI Codex",
                status: codexUserCode == nil ? statusText(for: .codex) : "Complete sign-in in browser",
                accent: UsagePalette.codexAccent.swiftUIColor,
                actionTitle: actionTitle(for: .codex),
                action: {
                    run(.startProviderAuthentication(.codex))
                }
            ) {
                if let codexUserCode {
                    Text(codexUserCode)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("codex-device-code")
                } else if let detail = statuses[.codex]?.detail {
                    connectionDetail(detail, provider: .codex)
                }
            }

            connectionPanel(
                title: "Claude Max",
                status: statusText(for: .claude),
                accent: UsagePalette.claudeAccent.swiftUIColor,
                actionTitle: actionTitle(for: .claude),
                action: {
                    run(.startProviderAuthentication(.claude))
                }
            ) {
                if let detail = statuses[.claude]?.detail {
                    connectionDetail(detail, provider: .claude)
                }
            }

            if let connectionError {
                Text(connectionError.displayMessage)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(UsagePalette.critical.swiftUIColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("provider-connection-error")
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-connections-screen")
    }

    private func statusText(for provider: ProviderID) -> String {
        if authenticatingProviders.contains(provider) {
            return "Connecting..."
        }
        let status = statuses[provider] ?? .unknown(provider)
        switch status.state {
        case .unknown, .checking:
            return "Checking..."
        case .disconnected:
            return "Not connected"
        case .connected:
            if let planName = status.planName, !planName.isEmpty {
                return "Connected - \(planName)"
            }
            return "Connected"
        case .unavailable:
            return "Unavailable"
        }
    }

    private func actionTitle(for provider: ProviderID) -> String? {
        guard !authenticatingProviders.contains(provider) else {
            return nil
        }
        if provider == .codex, codexUserCode != nil {
            return "Start again"
        }
        let status = statuses[provider] ?? .unknown(provider)
        switch status.state {
        case .unknown, .checking:
            return nil
        case .disconnected:
            return "Connect"
        case .connected:
            if provider == .claude, status.usageSyncEnabled == false {
                return "Enable"
            }
            return "Reconnect"
        case .unavailable:
            return nil
        }
    }

    private func connectionDetail(_ detail: String, provider: ProviderID) -> some View {
        Text(detail)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("\(provider.rawValue)-connection-detail")
    }

    @ViewBuilder
    private func connectionPanel<Content: View>(
        title: String,
        status: String,
        accent: Color,
        actionTitle: String?,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                    Text(status)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier(title == "OpenAI Codex" ? "connect-codex-button" : "connect-claude-button")
                }
            }
            content()
        }
        .settingsPanelStyle()
    }
}

private struct SettingsStepperRow: View {
    var title: String
    var valueText: String
    var identifier: String
    var decrementDisabled: Bool
    var incrementDisabled: Bool
    var decrement: () -> Void
    var increment: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                Text(valueText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                    .accessibilityIdentifier("\(identifier)-value")
            }

            Spacer()

            Stepper(
                "",
                onIncrement: {
                    guard !incrementDisabled else {
                        return
                    }
                    increment()
                },
                onDecrement: {
                    guard !decrementDisabled else {
                        return
                    }
                    decrement()
                }
            )
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier(identifier)
        }
        .settingsPanelStyle()
    }
}

private extension View {
    func settingsPanelStyle() -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(UsagePalette.inset.swiftUIColor.opacity(0.70))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
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

    init(snapshot: CombinedUsageSnapshot, history: [CombinedUsageSnapshot] = UsageMonitorFixtures.expandedHistorySnapshots) {
        _store = StateObject(
            wrappedValue: UsageMonitorStore(
                dependencies: AppCompositionRoot.fixture(snapshot: snapshot, historySnapshots: history),
                initialSnapshot: snapshot,
                historicalSnapshots: history,
                navigation: AppNavigationState(isHistoryExpanded: true)
            )
        )
    }

    var body: some View {
        UsagePopoverView(store: store, configuration: .production)
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
    UsagePopoverFixturePreview(snapshot: UsageMonitorFixtures.noDataSnapshot, history: [])
}
