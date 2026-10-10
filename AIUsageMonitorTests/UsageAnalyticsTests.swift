import XCTest
@testable import AIUsageMonitor

final class UsageAnalyticsTests: XCTestCase {
    func testBurnRateRequiresEnoughIncreasingSamples() throws {
        let first = sample(.claudeSession, minutes: 0, percent: 10, resetOffset: 300)
        let duplicateTimestamp = sample(.claudeSession, minutes: 0, percent: 20, resetOffset: 300)

        XCTAssertEqual(UsageAnalytics.burnRate(for: [first]).status, .insufficientSamples)
        XCTAssertEqual(UsageAnalytics.burnRate(for: [first, duplicateTimestamp]).status, .nonIncreasingTimestamps)
    }

    func testBurnRateNormalResetAndFallingCases() throws {
        let normal = UsageAnalytics.burnRate(for: [
            sample(.claudeSession, minutes: 0, percent: 20, resetOffset: 300),
            sample(.claudeSession, minutes: 30, percent: 35, resetOffset: 300)
        ])
        XCTAssertEqual(normal.status, .available)
        XCTAssertEqual(normal.pointsPerHour, 30, accuracy: 0.0001)

        let falling = UsageAnalytics.burnRate(for: [
            sample(.claudeSession, minutes: 0, percent: 50, resetOffset: 300),
            sample(.claudeSession, minutes: 30, percent: 40, resetOffset: 300)
        ])
        XCTAssertEqual(falling.status, .fallingUtilization)
        XCTAssertEqual(falling.pointsPerHour, 0)

        let reset = UsageAnalytics.burnRate(for: [
            sample(.claudeSession, minutes: 0, percent: 80, resetOffset: 120),
            sample(.claudeSession, minutes: 30, percent: 5, resetOffset: 300)
        ])
        XCTAssertEqual(reset.status, .resetDiscontinuity)
        XCTAssertEqual(reset.pointsPerHour, 0)
    }

    func testProjectionIndicatesWhetherExhaustionPrecedesReset() throws {
        let sampleBeforeReset = sample(.codexSession, minutes: 0, percent: 50, resetOffset: 120)
        let fastBurn = BurnRateResult(pointsPerHour: 50, status: .available)
        let beforeReset = try XCTUnwrap(UsageAnalytics.projection(from: sampleBeforeReset, burnRate: fastBurn))

        XCTAssertEqual(beforeReset.expectedExhaustionAt, sampleBeforeReset.capturedAt.addingTimeInterval(60 * 60))
        XCTAssertTrue(beforeReset.occursBeforeReset)

        let slowBurn = BurnRateResult(pointsPerHour: 10, status: .available)
        let afterReset = try XCTUnwrap(UsageAnalytics.projection(from: sampleBeforeReset, burnRate: slowBurn))

        XCTAssertFalse(afterReset.occursBeforeReset)
        XCTAssertNil(UsageAnalytics.projection(from: sampleBeforeReset, burnRate: .insufficientSamples))
    }

    func testModelShareHandlesZeroDenominatorAndNormalShares() throws {
        let zeroShares = UsageAnalytics.modelShares(for: [
            meter(.claudeWeekFable, percent: 0),
            meter(.claudeWeekSonnet, percent: 0)
        ])

        XCTAssertEqual(zeroShares.map(\.share), [0, 0])
        XCTAssertTrue(zeroShares.allSatisfy { !$0.hasData })
        XCTAssertTrue(zeroShares.allSatisfy { $0.share.isFinite })

        let shares = UsageAnalytics.modelShares(for: [
            meter(.claudeWeekFable, percent: 25),
            meter(.claudeWeekSonnet, percent: 75)
        ])

        XCTAssertEqual(shares.map(\.share), [0.25, 0.75])
        XCTAssertTrue(shares.allSatisfy(\.hasData))
    }

    func testSessionDownsamplingTargetsFortyFourPointsAndPreservesResetDiscontinuity() throws {
        let samples = denseSamples(
            kind: .claudeSession,
            count: 121,
            strideMinutes: 12,
            resetIndex: 60,
            resetOffsetMinutes: 300
        )
        let points = UsageAnalytics.downsample(
            samples: samples,
            kind: .claudeSession,
            now: samples.last?.capturedAt
        )
        let repeated = UsageAnalytics.downsample(
            samples: samples,
            kind: .claudeSession,
            now: samples.last?.capturedAt
        )

        XCTAssertEqual(points, repeated)
        XCTAssertTrue((44 ... 46).contains(points.count), "Expected approximately 44 points, got \(points.count)")
        XCTAssertEqual(points.first?.capturedAt, samples.first?.capturedAt)
        XCTAssertEqual(points.last?.capturedAt, samples.last?.capturedAt)
        XCTAssertTrue(isStrictlyOrdered(points.map(\.capturedAt)))
        XCTAssertTrue(points.contains { $0.capturedAt == samples[59].capturedAt && $0.preservesResetDiscontinuity })
        XCTAssertTrue(points.contains { $0.capturedAt == samples[60].capturedAt && $0.preservesResetDiscontinuity })
    }

    func testWeeklyDownsamplingUsesSevenDayWindowAndRemainsDeterministic() throws {
        let samples = denseSamples(
            kind: .codexWeek,
            count: 200,
            strideMinutes: 60,
            resetIndex: 120,
            resetOffsetMinutes: 7 * 24 * 60
        )
        let now = samples.last!.capturedAt

        let points = UsageAnalytics.downsample(samples: samples, kind: .codexWeek, now: now)

        XCTAssertTrue((44 ... 46).contains(points.count), "Expected approximately 44 points, got \(points.count)")
        XCTAssertEqual(points.first?.capturedAt, now.addingTimeInterval(-UsageAnalytics.weeklyChartWindow))
        XCTAssertEqual(points.last?.capturedAt, now)
        XCTAssertTrue(isStrictlyOrdered(points.map(\.capturedAt)))
        XCTAssertTrue(points.contains { $0.capturedAt == samples[120].capturedAt && $0.preservesResetDiscontinuity })
    }

    private func sample(_ kind: MeterKind, minutes: Int, percent: Double, resetOffset: Int) -> MeterHistorySample {
        let capturedAt = UsageMonitorFixtures.baseDate.addingTimeInterval(TimeInterval(minutes * 60))
        return MeterHistorySample(
            kind: kind,
            capturedAt: capturedAt,
            utilization: try! UtilizationPercentage(percent),
            resetAt: UsageMonitorFixtures.baseDate.addingTimeInterval(TimeInterval(resetOffset * 60))
        )
    }

    private func meter(_ kind: MeterKind, percent: Double) -> UsageMeterSnapshot {
        UsageMeterSnapshot(
            kind: kind,
            utilization: try! UtilizationPercentage(percent),
            resetAt: UsageMonitorFixtures.baseDate.addingTimeInterval(UsageMonitorFixtures.oneDay)
        )
    }

    private func denseSamples(
        kind: MeterKind,
        count: Int,
        strideMinutes: Int,
        resetIndex: Int,
        resetOffsetMinutes: Int
    ) -> [MeterHistorySample] {
        (0 ..< count).map { index in
            let capturedAt = UsageMonitorFixtures.baseDate.addingTimeInterval(TimeInterval(index * strideMinutes * 60))
            let resetOffset = index < resetIndex ? resetOffsetMinutes : resetOffsetMinutes + 1_000
            let utilization = index < resetIndex ? Double(index % 90) : Double((index - resetIndex) % 90)
            return MeterHistorySample(
                kind: kind,
                capturedAt: capturedAt,
                utilization: try! UtilizationPercentage(utilization),
                resetAt: UsageMonitorFixtures.baseDate.addingTimeInterval(TimeInterval(resetOffset * 60))
            )
        }
    }

    private func isStrictlyOrdered(_ dates: [Date]) -> Bool {
        zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 }
    }

    func testSubSecondResetJitterIsOneWindowForBurnRateAndCharts() throws {
        // Claude's plan endpoint reports the same reset a fraction of a second apart on each read.
        let base = UsageMonitorFixtures.baseDate
        let reset = base.addingTimeInterval(3 * 86_400)
        let jitter: [TimeInterval] = [-0.053, 0.061, 0.338, -0.012, 0.150]
        let samples = try jitter.enumerated().map { index, offset in
            MeterHistorySample(
                kind: .claudeWeekAll,
                capturedAt: base.addingTimeInterval(Double(index) * 5 * 60),
                utilization: try UtilizationPercentage(60 + Double(index)),
                resetAt: reset.addingTimeInterval(offset)
            )
        }

        let burnRate = UsageAnalytics.burnRate(for: samples)
        let points = UsageAnalytics.downsample(samples: samples, kind: .claudeWeekAll)

        XCTAssertEqual(burnRate.status, .available)
        XCTAssertEqual(burnRate.pointsPerHour, 12, accuracy: 0.001)
        XCTAssertFalse(points.contains { $0.preservesResetDiscontinuity })
    }

    func testARealResetIsStillADiscontinuity() throws {
        let base = UsageMonitorFixtures.baseDate
        let samples = [
            MeterHistorySample(kind: .claudeSession, capturedAt: base, utilization: try UtilizationPercentage(80), resetAt: base.addingTimeInterval(600)),
            MeterHistorySample(kind: .claudeSession, capturedAt: base.addingTimeInterval(900), utilization: try UtilizationPercentage(5), resetAt: base.addingTimeInterval(5 * 3600 + 900))
        ]

        XCTAssertFalse(UsageAnalytics.isSameResetWindow(samples[0].resetAt, samples[1].resetAt))
        XCTAssertEqual(UsageAnalytics.burnRate(for: samples).status, .resetDiscontinuity)
        XCTAssertTrue(UsageAnalytics.downsample(samples: samples, kind: .claudeSession).allSatisfy(\.preservesResetDiscontinuity))
    }
}
