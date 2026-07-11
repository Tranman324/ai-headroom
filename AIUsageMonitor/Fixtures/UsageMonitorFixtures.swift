import Foundation

enum UsageMonitorFixtures {
    static let baseDate = Date(timeIntervalSince1970: 1_735_689_600)
    static let oneHour: TimeInterval = 60 * 60
    static let oneDay: TimeInterval = 24 * oneHour

    static let allMeterSnapshots: [UsageMeterSnapshot] = [
        meter(.claudeSession, percent: 72, resetOffset: 5 * oneHour),
        meter(.claudeWeekAll, percent: 48, resetOffset: 3 * oneDay),
        meter(.claudeWeekFable, percent: 83, resetOffset: 3 * oneDay),
        meter(.claudeWeekSonnet, percent: 41, resetOffset: 3 * oneDay),
        meter(.claudeWeekHaiku, percent: 12, resetOffset: 3 * oneDay),
        meter(.codexSession, percent: 31, resetOffset: 5 * oneHour),
        meter(.codexWeek, percent: 91, resetOffset: 3 * oneDay)
    ]

    static let normalSnapshot = combinedSnapshot(
        capturedOffset: 0,
        claudeMeters: [
            meter(.claudeSession, percent: 24, resetOffset: 5 * oneHour),
            meter(.claudeWeekAll, percent: 48, resetOffset: 3 * oneDay),
            meter(.claudeWeekFable, percent: 63, resetOffset: 3 * oneDay),
            meter(.claudeWeekSonnet, percent: 41, resetOffset: 3 * oneDay),
            meter(.claudeWeekHaiku, percent: 12, resetOffset: 3 * oneDay)
        ],
        codexMeters: [
            meter(.codexSession, percent: 31, resetOffset: 5 * oneHour),
            meter(.codexWeek, percent: 62, resetOffset: 3 * oneDay)
        ]
    )

    static let warningSnapshot = combinedSnapshot(
        capturedOffset: oneHour,
        claudeMeters: allMeterSnapshots.filter { $0.provider == .claude },
        codexMeters: [
            meter(.codexSession, percent: 31, resetOffset: 5 * oneHour),
            meter(.codexWeek, percent: 61, resetOffset: 3 * oneDay)
        ]
    )

    static let criticalSnapshot = combinedSnapshot(
        capturedOffset: 2 * oneHour,
        claudeMeters: allMeterSnapshots.filter { $0.provider == .claude },
        codexMeters: allMeterSnapshots.filter { $0.provider == .codex }
    )

    static let staleLastKnownGoodSnapshot = CombinedUsageSnapshot(
        capturedAt: baseDate.addingTimeInterval(3 * oneHour),
        providers: [
            ProviderUsageSnapshot(
                provider: .claude,
                meters: allMeterSnapshots.filter { $0.provider == .claude },
                health: .stale(
                    checkedAt: baseDate.addingTimeInterval(3 * oneHour),
                    staleSince: baseDate.addingTimeInterval(2 * oneHour),
                    error: SanitizedProviderError(code: .unavailable, displayMessage: "Claude usage is temporarily unavailable.")
                )
            ),
            ProviderUsageSnapshot(
                provider: .codex,
                meters: allMeterSnapshots.filter { $0.provider == .codex },
                health: .fresh(checkedAt: baseDate.addingTimeInterval(3 * oneHour))
            )
        ]
    )

    static let providerErrorOtherHealthySnapshot = CombinedUsageSnapshot(
        capturedAt: baseDate.addingTimeInterval(4 * oneHour),
        providers: [
            ProviderUsageSnapshot(
                provider: .claude,
                meters: allMeterSnapshots.filter { $0.provider == .claude },
                health: .errored(
                    checkedAt: baseDate.addingTimeInterval(4 * oneHour),
                    error: SanitizedProviderError(code: .malformedResponse, displayMessage: "Claude returned malformed usage data.")
                )
            ),
            ProviderUsageSnapshot(
                provider: .codex,
                meters: allMeterSnapshots.filter { $0.provider == .codex },
                health: .fresh(checkedAt: baseDate.addingTimeInterval(4 * oneHour))
            )
        ]
    )

    static let noDataSnapshot = CombinedUsageSnapshot(
        capturedAt: baseDate.addingTimeInterval(5 * oneHour),
        providers: [
            ProviderUsageSnapshot(provider: .claude, meters: [], health: .noData(checkedAt: baseDate.addingTimeInterval(5 * oneHour))),
            ProviderUsageSnapshot(provider: .codex, meters: [], health: .noData(checkedAt: baseDate.addingTimeInterval(5 * oneHour)))
        ]
    )

    static let safeProjectionSnapshot: CombinedUsageSnapshot = {
        let capturedAt = baseDate.addingTimeInterval(6 * oneHour)
        return combinedSnapshot(
            capturedAt: capturedAt,
            claudeMeters: [
                meter(.claudeSession, percent: 24, resetAt: capturedAt.addingTimeInterval(5 * oneHour)),
                meter(.claudeWeekAll, percent: 48, resetAt: capturedAt.addingTimeInterval(3 * oneDay)),
                meter(.claudeWeekFable, percent: 63, resetAt: capturedAt.addingTimeInterval(3 * oneDay)),
                meter(.claudeWeekSonnet, percent: 41, resetAt: capturedAt.addingTimeInterval(3 * oneDay)),
                meter(.claudeWeekHaiku, percent: 12, resetAt: capturedAt.addingTimeInterval(3 * oneDay))
            ],
            codexMeters: [
                meter(.codexSession, percent: 31, resetAt: capturedAt.addingTimeInterval(5 * oneHour)),
                meter(.codexWeek, percent: 61, resetAt: capturedAt.addingTimeInterval(12 * oneHour))
            ]
        )
    }()

    static let settingsSnapshot = normalSnapshot

    static let expandedHistorySnapshots = historySnapshots(
        endingWith: criticalSnapshot,
        count: 72,
        stride: 3 * oneHour,
        resetDrop: true,
        recentDeltas: [
            .claudeSession: 3.0,
            .claudeWeekAll: 0.5,
            .claudeWeekFable: 0.7,
            .claudeWeekSonnet: 0.3,
            .claudeWeekHaiku: 0.1,
            .codexSession: 0.5,
            .codexWeek: 1.1
        ]
    )

    static let preResetExhaustionHistory = historySnapshots(
        endingWith: criticalSnapshot,
        count: 72,
        stride: 3 * oneHour,
        resetDrop: true,
        recentDeltas: [.claudeWeekFable: 0.7]
    )

    static let safeProjectionHistory = historySnapshots(
        endingWith: safeProjectionSnapshot,
        count: 72,
        stride: 3 * oneHour,
        resetDrop: true,
        recentDeltas: [.codexWeek: 0.5]
    )

    static let insufficientBurnHistory = historySnapshots(
        endingWith: normalSnapshot,
        count: 1,
        stride: 3 * oneHour,
        resetDrop: false
    )

    static let noHistorySnapshots: [CombinedUsageSnapshot] = []

    static let settingsFixtureSettings = MonitorSettings(
        pollingInterval: try! PollingInterval(minutes: 5),
        alertThreshold: try! AlertThreshold(percentage: 85),
        historyRetention: try! HistoryRetention(days: 45),
        launchAtLogin: true
    )

    private static func combinedSnapshot(
        capturedOffset: TimeInterval,
        claudeMeters: [UsageMeterSnapshot],
        codexMeters: [UsageMeterSnapshot]
    ) -> CombinedUsageSnapshot {
        let capturedAt = baseDate.addingTimeInterval(capturedOffset)
        return combinedSnapshot(capturedAt: capturedAt, claudeMeters: claudeMeters, codexMeters: codexMeters)
    }

    private static func combinedSnapshot(
        capturedAt: Date,
        claudeMeters: [UsageMeterSnapshot],
        codexMeters: [UsageMeterSnapshot]
    ) -> CombinedUsageSnapshot {
        return CombinedUsageSnapshot(
            capturedAt: capturedAt,
            providers: [
                ProviderUsageSnapshot(provider: .claude, meters: claudeMeters, health: .fresh(checkedAt: capturedAt)),
                ProviderUsageSnapshot(provider: .codex, meters: codexMeters, health: .fresh(checkedAt: capturedAt))
            ]
        )
    }

    private static func meter(_ kind: MeterKind, percent: Double, resetOffset: TimeInterval) -> UsageMeterSnapshot {
        meter(kind, percent: percent, resetAt: baseDate.addingTimeInterval(resetOffset))
    }

    private static func meter(_ kind: MeterKind, percent: Double, resetAt: Date) -> UsageMeterSnapshot {
        UsageMeterSnapshot(
            kind: kind,
            utilization: try! UtilizationPercentage(percent),
            resetAt: resetAt
        )
    }

    private static func historySnapshots(
        endingWith snapshot: CombinedUsageSnapshot,
        count: Int,
        stride: TimeInterval,
        resetDrop: Bool,
        recentDeltas: [MeterKind: Double] = [:]
    ) -> [CombinedUsageSnapshot] {
        guard count > 0 else {
            return []
        }

        let latest = snapshot.capturedAt
        var captureDates = (0 ..< count).map { index in
            latest.addingTimeInterval(-stride * Double(count - index - 1))
        }
        if count >= 2 {
            captureDates[count - 2] = latest.addingTimeInterval(-30 * 60)
            captureDates[count - 1] = latest
        }

        let resetIndex = max(1, count / 2)
        let resetBoundary = captureDates[min(resetIndex, captureDates.count - 1)]
        let currentMeters = Dictionary(uniqueKeysWithValues: snapshot.meters.map { ($0.kind, $0) })

        return captureDates.enumerated().map { index, capturedAt in
            let meters = MeterKind.allCases.compactMap { kind -> UsageMeterSnapshot? in
                guard let current = currentMeters[kind] else {
                    return nil
                }

                let value = historicalValue(
                    for: current,
                    at: index,
                    count: count,
                    resetIndex: resetIndex,
                    resetDrop: resetDrop,
                    recentDelta: recentDeltas[kind]
                )
                let resetAt = resetDrop && index < resetIndex ? resetBoundary : current.resetAt
                return meter(kind, percent: value, resetAt: resetAt)
            }

            return CombinedUsageSnapshot(
                capturedAt: capturedAt,
                providers: ProviderID.allCases.map { provider in
                    ProviderUsageSnapshot(
                        provider: provider,
                        meters: meters.filter { $0.provider == provider },
                        health: .fresh(checkedAt: capturedAt)
                    )
                }
            )
        }
    }

    private static func historicalValue(
        for current: UsageMeterSnapshot,
        at index: Int,
        count: Int,
        resetIndex: Int,
        resetDrop: Bool,
        recentDelta: Double?
    ) -> Double {
        if count == 1 {
            return current.utilization.value
        }

        if index == count - 2, let recentDelta {
            return max(0, current.utilization.value - recentDelta)
        }
        if index == count - 1 {
            return current.utilization.value
        }

        if resetDrop && index < resetIndex {
            let phase = Double(index) / Double(max(1, resetIndex - 1))
            return min(98, max(8, 38 + phase * 56 + modelOffset(for: current.kind)))
        }

        let phase = Double(index - resetIndex) / Double(max(1, count - resetIndex - 1))
        let start = max(2, current.utilization.value - 32 + modelOffset(for: current.kind))
        return min(99, max(0, start + phase * (current.utilization.value - start)))
    }

    private static func modelOffset(for kind: MeterKind) -> Double {
        switch kind {
        case .claudeSession:
            return 4
        case .claudeWeekAll:
            return 0
        case .claudeWeekFable:
            return 8
        case .claudeWeekSonnet:
            return -5
        case .claudeWeekHaiku:
            return -12
        case .codexSession:
            return -4
        case .codexWeek:
            return 6
        }
    }
}
