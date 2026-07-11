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

    private static func combinedSnapshot(
        capturedOffset: TimeInterval,
        claudeMeters: [UsageMeterSnapshot],
        codexMeters: [UsageMeterSnapshot]
    ) -> CombinedUsageSnapshot {
        let capturedAt = baseDate.addingTimeInterval(capturedOffset)
        return CombinedUsageSnapshot(
            capturedAt: capturedAt,
            providers: [
                ProviderUsageSnapshot(provider: .claude, meters: claudeMeters, health: .fresh(checkedAt: capturedAt)),
                ProviderUsageSnapshot(provider: .codex, meters: codexMeters, health: .fresh(checkedAt: capturedAt))
            ]
        )
    }

    private static func meter(_ kind: MeterKind, percent: Double, resetOffset: TimeInterval) -> UsageMeterSnapshot {
        UsageMeterSnapshot(
            kind: kind,
            utilization: try! UtilizationPercentage(percent),
            resetAt: baseDate.addingTimeInterval(resetOffset)
        )
    }
}
