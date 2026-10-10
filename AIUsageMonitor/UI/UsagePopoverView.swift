import AppKit
import Combine
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
        let controller = NSHostingController(
            rootView: UsagePopoverView(store: store, configuration: configuration)
        )
        controller.sizingOptions = [.preferredContentSize]
        controller.preferredContentSize = contentSize(for: controller)
        return controller
    }

    static func contentSize(for controller: NSHostingController<UsagePopoverView>) -> NSSize {
        let fittingSize = controller.sizeThatFits(in: NSSize(
            width: UsagePopoverMetrics.contentWidth,
            height: .greatestFiniteMagnitude
        ))
        return NSSize(
            width: UsagePopoverMetrics.contentWidth,
            height: ceil(fittingSize.height)
        )
    }
}

@MainActor
final class UsagePopoverIntrinsicSizeObserver {
    private let hostingController: NSHostingController<UsagePopoverView>
    private let applyContentSize: (NSSize) -> Void
    private var cancellable: AnyCancellable?
    private var isResizeScheduled = false
    private var lastAppliedSize: NSSize?

    init(
        store: UsageMonitorStore,
        hostingController: NSHostingController<UsagePopoverView>,
        applyContentSize: @escaping (NSSize) -> Void
    ) {
        self.hostingController = hostingController
        self.applyContentSize = applyContentSize
        cancellable = store.objectWillChange.sink { [weak self] _ in
            self?.scheduleResize()
        }
        resizeNow()
    }

    func resizeNow() {
        isResizeScheduled = false
        let contentSize = UsagePopoverHostFactory.contentSize(for: hostingController)
        guard contentSize != lastAppliedSize else {
            return
        }
        lastAppliedSize = contentSize
        hostingController.preferredContentSize = contentSize
        applyContentSize(contentSize)
    }

    private func scheduleResize() {
        guard !isResizeScheduled else {
            return
        }
        isResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.resizeNow()
        }
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
        .fixedSize(horizontal: false, vertical: true)
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
        VStack(spacing: 0) {
            header
                .padding(.bottom, 2)
            ForEach(Array(cards.enumerated()), id: \.element.provider) { index, card in
                ProviderCardView(card: card, showsDivider: index > 0, run: run)
                    // Later sections draw above earlier ones so the credits list can rise over them.
                    .zIndex(Double(index))
            }
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
                .padding(.top, 6)
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
            .padding(.top, 2)
            footer
        }
    }

    private var cards: [ProviderCardPresentation] {
        ProviderID.allCases.map { provider in
            ProviderCardPresenter.card(
                provider: provider,
                snapshot: store.snapshot,
                history: store.historicalSnapshots,
                connection: store.providerConnectionStatuses[provider],
                alertThreshold: store.settings.alertThreshold.percentage
            )
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(nsImage: StatusItemGaugeRenderer.glyphImage(utilization: store.snapshot.hottestMeter?.utilization.value))
                .renderingMode(.template)
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                .accessibilityHidden(true)

            Text("AI Usage")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(UsagePalette.primaryText.swiftUIColor)

            Spacer()

            IconButton(
                systemName: "arrow.clockwise",
                accessibilityLabel: "Refresh Now",
                identifier: "popover-refresh-button"
            ) {
                run(.refresh)
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh Now (⌘R)")

            IconButton(
                systemName: "slider.horizontal.3",
                accessibilityLabel: "Settings",
                identifier: "popover-settings-button"
            ) {
                run(.openSettings)
            }
            .help("Settings")
        }
        .frame(height: 26)
    }

    private var footer: some View {
        HStack {
            Text("Updated \(updatedText)")
                .monospacedDigit()
            Spacer()
            Text("⌘R refresh")
        }
        .font(.system(size: 10))
        .foregroundStyle(UsagePalette.faintText.swiftUIColor)
        .padding(.top, 7)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("popover-footer")
    }

    private var updatedText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.autoupdatingCurrent.isDateInToday(store.snapshot.capturedAt)
            ? "h:mm:ss a"
            : "MMM d h:mm:ss a"
        return formatter.string(from: store.snapshot.capturedAt)
    }
}

private struct ProviderCardView: View {
    var card: ProviderCardPresentation
    var showsDivider: Bool
    var run: (AppIntentCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.vertical, 6)
            }

            header
                .padding(.top, 4)
                .padding(.bottom, 2)

            if let reason = card.reason {
                reasonBox(reason)
            }

            if card.showsMeters {
                VStack(spacing: 0) {
                    ForEach(card.leadingMeters) { row in
                        CardMeterRow(row: row, estimate: nil, provider: card.provider, run: run)
                    }
                    if let primary = card.primaryMeter {
                        CardMeterRow(row: primary, estimate: card.estimate, provider: card.provider, run: run)
                    }
                    ForEach(card.modelMeters) { row in
                        CardMeterRow(row: row, estimate: nil, provider: card.provider, run: run)
                    }
                }
                .opacity(card.meterOpacity)
            }

            if let credits = card.credits, card.showsMeters {
                ResetCreditsRow(credits: credits)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.provider == .claude ? "Claude usage" : "OpenAI Codex usage")
        .accessibilityIdentifier("\(card.provider.rawValue)-provider-section")
    }

    /// Badges never wrap and nothing may push past the popover edge: narrower layouts drop the
    /// countdown, then the plan badge, and the last resort lets the reset text truncate.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(showsCountdown: true, showsPlan: true, fixedReset: true)
            headerRow(showsCountdown: false, showsPlan: true, fixedReset: true)
            headerRow(showsCountdown: false, showsPlan: false, fixedReset: true)
            headerRow(showsCountdown: false, showsPlan: false, fixedReset: false)
        }
        .frame(minHeight: 18)
    }

    private func headerRow(showsCountdown: Bool, showsPlan: Bool, fixedReset: Bool) -> some View {
        HStack(spacing: 5) {
            Text(card.title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(UsagePalette.allModels.swiftUIColor)
                .fixedSize()

            if showsPlan, let plan = card.planBadge {
                Text(plan)
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(accent.opacity(0.4), lineWidth: 1))
                    .fixedSize()
                    .accessibilityIdentifier("\(card.provider.rawValue)-plan-badge")
            }

            if let pill = statusPill {
                Text(pill.text)
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(pill.color.swiftUIColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(pill.color.swiftUIColor.opacity(pill.backgroundOpacity)))
                    .fixedSize()
                    .accessibilityIdentifier("\(card.provider.rawValue)-health-label")
            }

            Spacer(minLength: 0)

            if card.state == .normal || card.state == .stale, let lead = card.resetLead {
                resetLabel(lead: lead, showsCountdown: showsCountdown)
                    .fixedSize(horizontal: fixedReset, vertical: false)
            }
        }
    }

    private func resetLabel(lead: String, showsCountdown: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
            Text(lead)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                .truncationMode(.tail)
            if showsCountdown, let countdown = card.resetCountdown {
                Text(countdown)
                    .font(.system(size: 10.5))
                    .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.resetCountdown.map { "Resets \(lead), in \($0)" } ?? "Resets \(lead)")
        .accessibilityIdentifier("\(card.provider.rawValue)-reset-lead")
    }

    private func reasonBox(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Text(reason)
                .font(.system(size: 10.5))
                .foregroundStyle(reasonColor.swiftUIColor)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let action = card.reasonAction {
                Button(action.title) {
                    run(action.command(for: card.provider))
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                .accessibilityIdentifier("\(card.provider.rawValue)-reason-action")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(reasonBackground))
        .padding(.top, 4)
        .padding(.bottom, card.showsMeters ? 6 : 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(card.provider.rawValue)-health-detail")
    }

    private var accent: Color {
        UsagePalette.accent(for: card.provider).swiftUIColor
    }

    private var statusPill: (text: String, color: NSColor, backgroundOpacity: Double)? {
        switch card.state {
        case .stale:
            return ("STALE", UsagePalette.warning, 0.14)
        case .error:
            return ("ERROR", UsagePalette.criticalText, 0.16)
        case .normal, .notConnected:
            return nil
        }
    }

    private var reasonColor: NSColor {
        switch card.state {
        case .stale:
            return UsagePalette.warning
        case .error:
            return UsagePalette.errorReasonText
        case .normal, .notConnected:
            return UsagePalette.mutedText
        }
    }

    private var reasonBackground: Color {
        switch card.state {
        case .stale:
            return UsagePalette.warning.swiftUIColor.opacity(0.08)
        case .error:
            return UsagePalette.critical.swiftUIColor.opacity(0.1)
        case .normal, .notConnected:
            return Color.white.opacity(0.04)
        }
    }
}

private struct CardMeterRow: View {
    var row: MeterRowPresentation
    var estimate: UsageEstimatePresentation?
    var provider: ProviderID
    var run: (AppIntentCommand) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            run(.showMeterDetail(row.kind))
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle((row.isModelRow ? UsagePalette.allModels : UsagePalette.primaryText).swiftUIColor)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let trailing = row.trailingText {
                        Text(trailing)
                            .font(.system(size: 9.5))
                            .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                            .monospacedDigit()
                    }

                    Text(row.percentText)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(row.percentColor.swiftUIColor)
                        .frame(minWidth: 32, alignment: .trailing)
                        .accessibilityIdentifier("meter-percent-\(row.kind.rawValue)")
                }
                .padding(.bottom, 4)

                CardMeterBar(row: row)

                if let estimate {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(estimate.dotColor.swiftUIColor)
                            .frame(width: 6, height: 6)
                        Text(estimate.text)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(estimate.textColor.swiftUIColor)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(estimate.basis)
                            .font(.system(size: 9.5))
                            .foregroundStyle(UsagePalette.faintText.swiftUIColor)
                    }
                    .padding(.top, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("\(provider.rawValue)-estimate")
                }
            }
            .padding(.leading, row.isModelRow ? 12 : 0)
            .padding(.top, row.isModelRow ? 4 : 6)
            .padding(.bottom, row.isModelRow ? 6 : 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.045 : 0))
                .padding(.horizontal, -6)
        )
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel + (estimate.map { ", \($0.text)" } ?? ""))
        .accessibilityIdentifier("meter-row-\(row.kind.rawValue)")
    }
}

private struct CardMeterBar: View {
    var row: MeterRowPresentation

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.07))

                Capsule()
                    .fill(row.fillColor.swiftUIColor)
                    .frame(width: geometry.size.width * CGFloat(row.fraction))
                    .shadow(color: row.glows ? row.fillColor.swiftUIColor.opacity(0.4) : .clear, radius: 5)
            }
        }
        .frame(height: row.isModelRow ? UsagePopoverMetrics.modelBarHeight : UsagePopoverMetrics.primaryBarHeight)
        .accessibilityIdentifier("meter-bar-\(row.kind.rawValue)")
    }
}

private struct ResetCreditsRow: View {
    /// Keeps the open list inside the popover even when the other account is collapsed.
    static let maximumListedCredits = 4
    static let rowHeight: CGFloat = 24

    var credits: ResetCreditsPresentation

    @Environment(\.showsResetCreditListForEvidence) private var showsListForEvidence
    @State private var isHoveringRow = false
    @State private var isHoveringList = false
    @State private var isListOpen = false
    @State private var hoveredCredit: Int?
    @State private var closeTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle((credits.hasCredits ? UsagePalette.codexAccent : UsagePalette.faintText).swiftUIColor)

            Text(credits.countText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle((credits.hasCredits ? UsagePalette.primaryText : UsagePalette.mutedText).swiftUIColor)

            Spacer(minLength: 6)

            // A blank expiry still reserves its line so the row height never jumps.
            Text(credits.expiryText.isEmpty ? " " : credits.expiryText)
                .font(.system(size: 9.5))
                .foregroundStyle((credits.isExpiringSoon ? UsagePalette.warning : UsagePalette.mutedText).swiftUIColor)
        }
        .frame(height: Self.rowHeight)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(isHoveringRow ? 0.045 : 0))
                .padding(.horizontal, -6)
        )
        .onHover { hovering in
            isHoveringRow = hovering
            updateListVisibility()
        }
        // Anchored to the row's bottom and lifted by one row, so the list rises above the row
        // (overlapping it by two points) instead of covering the history and footer below.
        .overlay(alignment: .bottomTrailing) {
            if (isListOpen || showsListForEvidence), !credits.credits.isEmpty {
                creditList
                    .onHover { hovering in
                        isHoveringList = hovering
                        updateListVisibility()
                    }
                    .offset(y: -(Self.rowHeight + 3 - 2))
            }
        }
        .onDisappear {
            closeTask?.cancel()
            isHoveringRow = false
            isHoveringList = false
            isListOpen = false
            hoveredCredit = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("codex-reset-credits")
    }

    /// The list overlaps the row by two points, but the pointer still leaves one view before it
    /// enters the other, so closing waits a moment for the other view to report the hover.
    private func updateListVisibility() {
        closeTask?.cancel()
        if isHoveringRow || isHoveringList {
            isListOpen = true
            return
        }
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, !isHoveringRow, !isHoveringList else {
                return
            }
            isListOpen = false
            hoveredCredit = nil
        }
    }

    private var creditList: some View {
        let listed = Array(credits.credits.prefix(Self.maximumListedCredits))
        let hidden = credits.credits.count - listed.count
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(listed.enumerated()), id: \.offset) { index, credit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(credit.title)
                            .font(.system(size: 11))
                            .foregroundStyle(UsagePalette.primaryText.swiftUIColor)
                        Spacer(minLength: 8)
                        Text(credit.dateText)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .underline(pattern: .dot, color: dateColor(credit).swiftUIColor.opacity(0.5))
                            .foregroundStyle(dateColor(credit).swiftUIColor)
                    }
                    if hoveredCredit == index || (showsListForEvidence && index == 0) {
                        Text(credit.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(dateColor(credit).swiftUIColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .accessibilityIdentifier("codex-reset-credit-detail")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        hoveredCredit = index
                    } else if hoveredCredit == index {
                        hoveredCredit = nil
                    }
                }
            }
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.system(size: 10))
                    .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 210, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UsagePalette.inset.swiftUIColor))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 15, y: 10)
        .accessibilityIdentifier("codex-reset-credit-list")
    }

    private func dateColor(_ credit: ResetCreditsPresentation.Credit) -> NSColor {
        credit.isExpiringSoon ? UsagePalette.warning : UsagePalette.primaryText
    }

    private var accessibilityText: String {
        guard credits.hasCredits else {
            return "No rate limit resets left"
        }
        let details = credits.credits.map { "\($0.title), \($0.detail)" }.joined(separator: "; ")
        return "\(credits.countText) available, \(credits.expiryText). \(details)"
    }
}

private struct ShowsResetCreditListForEvidenceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Offscreen evidence renders open the reset-credit list the way a hover would.
    var showsResetCreditListForEvidence: Bool {
        get { self[ShowsResetCreditListForEvidenceKey.self] }
        set { self[ShowsResetCreditListForEvidenceKey.self] = newValue }
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

            NoHistoryView(message: "\(kind.displayName) unavailable")
                .frame(width: UsagePopoverMetrics.chartWidth, height: 44)
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

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UsagePalette.mutedText.swiftUIColor)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.06 : 0))
        )
        .onHover { isHovering = $0 }
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
