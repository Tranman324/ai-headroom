import Foundation

struct MeterHistorySample: Equatable, Sendable {
    var kind: MeterKind
    var capturedAt: Date
    var utilization: UtilizationPercentage
    var resetAt: Date

    init(kind: MeterKind, capturedAt: Date, utilization: UtilizationPercentage, resetAt: Date) {
        self.kind = kind
        self.capturedAt = capturedAt
        self.utilization = utilization
        self.resetAt = resetAt
    }

    init(snapshot: UsageMeterSnapshot, capturedAt: Date) {
        self.init(
            kind: snapshot.kind,
            capturedAt: capturedAt,
            utilization: snapshot.utilization,
            resetAt: snapshot.resetAt
        )
    }
}

enum BurnRateStatus: Equatable, Sendable {
    case available
    case insufficientSamples
    case nonIncreasingTimestamps
    case resetDiscontinuity
    case fallingUtilization
}

struct BurnRateResult: Equatable, Sendable {
    var pointsPerHour: Double
    var status: BurnRateStatus

    var hasPositiveRate: Bool {
        status == .available && pointsPerHour > 0 && pointsPerHour.isFinite
    }

    static let insufficientSamples = BurnRateResult(pointsPerHour: 0, status: .insufficientSamples)
}

struct UsageProjection: Equatable, Sendable {
    var expectedExhaustionAt: Date
    var occursBeforeReset: Bool
    var hoursUntilExhaustion: Double
}

struct ModelShareResult: Equatable, Sendable {
    var kind: MeterKind
    var utilization: UtilizationPercentage
    var share: Double
    var hasData: Bool
}

struct UsageChartPoint: Equatable, Sendable {
    var kind: MeterKind
    var capturedAt: Date
    var utilization: UtilizationPercentage
    var resetAt: Date
    var preservesResetDiscontinuity: Bool
}

enum UsageAnalytics {
    static let burnRateWindow: TimeInterval = 30 * 60
    static let sessionChartWindow: TimeInterval = 24 * 60 * 60
    static let weeklyChartWindow: TimeInterval = 7 * 24 * 60 * 60
    static let defaultChartTargetPointCount = 44

    static func samples(for kind: MeterKind, in snapshots: [CombinedUsageSnapshot]) -> [MeterHistorySample] {
        snapshots.flatMap { snapshot in
            snapshot.meters
                .filter { $0.kind == kind }
                .map { MeterHistorySample(snapshot: $0, capturedAt: snapshot.capturedAt) }
        }
        .sorted { lhs, rhs in
            lhs.capturedAt < rhs.capturedAt
        }
    }

    static func burnRate(
        for kind: MeterKind,
        in snapshots: [CombinedUsageSnapshot],
        window: TimeInterval = burnRateWindow
    ) -> BurnRateResult {
        burnRate(for: samples(for: kind, in: snapshots), window: window)
    }

    static func burnRate(
        for samples: [MeterHistorySample],
        window: TimeInterval = burnRateWindow
    ) -> BurnRateResult {
        let orderedSamples = samples.sorted { lhs, rhs in
            lhs.capturedAt < rhs.capturedAt
        }
        guard let latest = orderedSamples.last else {
            return .insufficientSamples
        }

        let windowStart = latest.capturedAt.addingTimeInterval(-window)
        let recentSamples = orderedSamples.filter { $0.capturedAt >= windowStart && $0.capturedAt <= latest.capturedAt }
        guard recentSamples.count >= 2 else {
            return .insufficientSamples
        }

        guard recentSamples[recentSamples.count - 2].capturedAt < latest.capturedAt else {
            return BurnRateResult(pointsPerHour: 0, status: .nonIncreasingTimestamps)
        }

        var currentResetSegment: [MeterHistorySample] = []
        for sample in recentSamples.reversed() {
            guard sample.resetAt == latest.resetAt && sample.capturedAt <= latest.capturedAt else {
                break
            }
            currentResetSegment.insert(sample, at: 0)
        }
        guard currentResetSegment.count >= 2, let first = currentResetSegment.first else {
            return BurnRateResult(pointsPerHour: 0, status: .resetDiscontinuity)
        }

        let elapsedSeconds = latest.capturedAt.timeIntervalSince(first.capturedAt)
        guard elapsedSeconds > 0 else {
            return BurnRateResult(pointsPerHour: 0, status: .nonIncreasingTimestamps)
        }

        let delta = latest.utilization.value - first.utilization.value
        guard delta >= 0 else {
            return BurnRateResult(pointsPerHour: 0, status: .fallingUtilization)
        }

        return BurnRateResult(pointsPerHour: delta / (elapsedSeconds / 3600), status: .available)
    }

    static func projection(from sample: MeterHistorySample, burnRate: BurnRateResult) -> UsageProjection? {
        guard burnRate.hasPositiveRate else {
            return nil
        }

        let remainingPoints = max(0, 100 - sample.utilization.value)
        let hoursUntilExhaustion = remainingPoints / burnRate.pointsPerHour
        guard hoursUntilExhaustion.isFinite else {
            return nil
        }

        let expectedDate = sample.capturedAt.addingTimeInterval(hoursUntilExhaustion * 3600)
        return UsageProjection(
            expectedExhaustionAt: expectedDate,
            occursBeforeReset: expectedDate <= sample.resetAt,
            hoursUntilExhaustion: hoursUntilExhaustion
        )
    }

    static func modelShares(for meters: [UsageMeterSnapshot]) -> [ModelShareResult] {
        let denominator = meters.reduce(0) { total, meter in
            total + meter.utilization.value
        }
        return meters.map { meter in
            let share = denominator > 0 ? meter.utilization.value / denominator : 0
            return ModelShareResult(
                kind: meter.kind,
                utilization: meter.utilization,
                share: share.isFinite ? share : 0,
                hasData: denominator > 0
            )
        }
    }

    static func downsample(
        samples: [MeterHistorySample],
        kind: MeterKind,
        now: Date? = nil,
        targetPointCount: Int = defaultChartTargetPointCount
    ) -> [UsageChartPoint] {
        let orderedSamples = samples
            .filter { $0.kind == kind }
            .sorted { lhs, rhs in
                lhs.capturedAt < rhs.capturedAt
            }
        guard let latestSample = orderedSamples.last else {
            return []
        }

        let anchorDate = now ?? latestSample.capturedAt
        let window = kind.window == .rollingFiveHours ? sessionChartWindow : weeklyChartWindow
        let windowStart = anchorDate.addingTimeInterval(-window)
        let windowedSamples = orderedSamples.filter { $0.capturedAt >= windowStart && $0.capturedAt <= anchorDate }
        guard !windowedSamples.isEmpty else {
            return []
        }
        guard windowedSamples.count > targetPointCount, targetPointCount > 1 else {
            return chartPoints(from: windowedSamples, discontinuityIndexes: resetDiscontinuityIndexes(in: windowedSamples))
        }

        let discontinuityIndexes = resetDiscontinuityIndexes(in: windowedSamples)
        var selectedIndexes = Set(discontinuityIndexes)
        selectedIndexes.insert(0)
        selectedIndexes.insert(windowedSamples.count - 1)
        let mandatoryIndexes = selectedIndexes

        let denominator = max(1, targetPointCount - 1)
        for pointIndex in 0 ..< targetPointCount {
            let scaledIndex = Double(pointIndex) * Double(windowedSamples.count - 1) / Double(denominator)
            selectedIndexes.insert(Int(scaledIndex.rounded()))
        }

        if selectedIndexes.count < targetPointCount {
            for index in 0 ..< windowedSamples.count where selectedIndexes.count < targetPointCount {
                selectedIndexes.insert(index)
            }
        }

        let desiredCount = max(targetPointCount, mandatoryIndexes.count)
        if selectedIndexes.count > desiredCount {
            for index in selectedIndexes.sorted().dropFirst().dropLast().reversed() where !mandatoryIndexes.contains(index) {
                selectedIndexes.remove(index)
                if selectedIndexes.count <= desiredCount {
                    break
                }
            }
        }

        return chartPoints(
            from: selectedIndexes.sorted().map { windowedSamples[$0] },
            discontinuityIndexes: Set(selectedIndexes
                .sorted()
                .enumerated()
                .compactMap { outputIndex, sourceIndex in
                    discontinuityIndexes.contains(sourceIndex) ? outputIndex : nil
                })
        )
    }

    private static func resetDiscontinuityIndexes(in samples: [MeterHistorySample]) -> Set<Int> {
        guard samples.count > 1 else {
            return Set<Int>()
        }

        var indexes = Set<Int>()
        for index in 1 ..< samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            if previous.resetAt != current.resetAt || current.utilization.value < previous.utilization.value {
                indexes.insert(index - 1)
                indexes.insert(index)
            }
        }
        return indexes
    }

    private static func chartPoints(from samples: [MeterHistorySample], discontinuityIndexes: Set<Int>) -> [UsageChartPoint] {
        samples.enumerated().map { index, sample in
            UsageChartPoint(
                kind: sample.kind,
                capturedAt: sample.capturedAt,
                utilization: sample.utilization,
                resetAt: sample.resetAt,
                preservesResetDiscontinuity: discontinuityIndexes.contains(index)
            )
        }
    }
}
