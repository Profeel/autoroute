import Foundation

public struct LocalOnboardingFunnelState: Codable, Equatable, Sendable {
    public var startedCount: Int
    public var firstRealSuccessCount: Int
    public var demoValidationCount: Int
    public var isAwaitingFirstRealRoute: Bool
    public var lastStartedAt: Date?
    public var lastRealSuccessAt: Date?

    public init(
        startedCount: Int = 0,
        firstRealSuccessCount: Int = 0,
        demoValidationCount: Int = 0,
        isAwaitingFirstRealRoute: Bool = false,
        lastStartedAt: Date? = nil,
        lastRealSuccessAt: Date? = nil
    ) {
        self.startedCount = startedCount
        self.firstRealSuccessCount = firstRealSuccessCount
        self.demoValidationCount = demoValidationCount
        self.isAwaitingFirstRealRoute = isAwaitingFirstRealRoute
        self.lastStartedAt = lastStartedAt
        self.lastRealSuccessAt = lastRealSuccessAt
    }

    public var firstRealRouteSuccessRate: Double? {
        guard startedCount > 0 else { return nil }
        return Double(firstRealSuccessCount) / Double(startedCount)
    }

    public mutating func recordStart(at date: Date = Date()) {
        // Reopening or redrawing an in-progress onboarding flow is not a new funnel sample.
        guard !isAwaitingFirstRealRoute else { return }
        startedCount += 1
        isAwaitingFirstRealRoute = true
        lastStartedAt = date
    }

    public mutating func recordDemoValidation() {
        demoValidationCount += 1
    }

    public mutating func recordRealSuccess(at date: Date = Date()) {
        guard isAwaitingFirstRealRoute else { return }
        firstRealSuccessCount += 1
        isAwaitingFirstRealRoute = false
        lastRealSuccessAt = date
    }

    public mutating func recordSkip() {
        isAwaitingFirstRealRoute = false
    }
}

public struct LocalProductMetrics: Codable, Equatable, Sendable {
    public var funnel: LocalOnboardingFunnelState
    public var realRouteSampleCount: Int
    public var demoRouteSampleCount: Int
    public var unclassifiedRouteSampleCount: Int
    public var activeDaysLast7: Int
    public var lastRealRouteAt: Date?
    public var routingLatencySampleCount: Int
    public var routingP50Ms: Double?
    public var routingP95Ms: Double?
    public var fallbackEligibleSampleCount: Int
    public var fallbackRecoveredSampleCount: Int
    public var realABPricedSampleCount: Int
    public var realABMeasuredCostDifferenceUSD: Double?
    public var historicalPricedSampleCount: Int
    public var historicalEstimatedCostDifferenceUSD: Double?
    public var missingUsageSampleCount: Int
    public var missingPriceSampleCount: Int

    public init(
        funnel: LocalOnboardingFunnelState,
        realRouteSampleCount: Int,
        demoRouteSampleCount: Int,
        unclassifiedRouteSampleCount: Int,
        activeDaysLast7: Int,
        lastRealRouteAt: Date?,
        routingLatencySampleCount: Int,
        routingP50Ms: Double?,
        routingP95Ms: Double?,
        fallbackEligibleSampleCount: Int,
        fallbackRecoveredSampleCount: Int,
        realABPricedSampleCount: Int,
        realABMeasuredCostDifferenceUSD: Double?,
        historicalPricedSampleCount: Int,
        historicalEstimatedCostDifferenceUSD: Double?,
        missingUsageSampleCount: Int,
        missingPriceSampleCount: Int
    ) {
        self.funnel = funnel
        self.realRouteSampleCount = realRouteSampleCount
        self.demoRouteSampleCount = demoRouteSampleCount
        self.unclassifiedRouteSampleCount = unclassifiedRouteSampleCount
        self.activeDaysLast7 = activeDaysLast7
        self.lastRealRouteAt = lastRealRouteAt
        self.routingLatencySampleCount = routingLatencySampleCount
        self.routingP50Ms = routingP50Ms
        self.routingP95Ms = routingP95Ms
        self.fallbackEligibleSampleCount = fallbackEligibleSampleCount
        self.fallbackRecoveredSampleCount = fallbackRecoveredSampleCount
        self.realABPricedSampleCount = realABPricedSampleCount
        self.realABMeasuredCostDifferenceUSD = realABMeasuredCostDifferenceUSD
        self.historicalPricedSampleCount = historicalPricedSampleCount
        self.historicalEstimatedCostDifferenceUSD = historicalEstimatedCostDifferenceUSD
        self.missingUsageSampleCount = missingUsageSampleCount
        self.missingPriceSampleCount = missingPriceSampleCount
    }

    public var firstRealRouteSuccessRate: Double? { funnel.firstRealRouteSuccessRate }

    public var fallbackRecoveryRate: Double? {
        guard fallbackEligibleSampleCount > 0 else { return nil }
        return Double(fallbackRecoveredSampleCount) / Double(fallbackEligibleSampleCount)
    }
}

public enum LocalProductMetricsCalculator {
    public static func calculate(
        records: [CallRecord],
        funnel: LocalOnboardingFunnelState,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> LocalProductMetrics {
        let externalRecords = records.filter { $0.source == .externalProxy && $0.status != .rejected }
        let realRecords = externalRecords.filter { $0.executionOrigin == .real }
        let demoRecords = externalRecords.filter { $0.executionOrigin == .demo }
        let unclassifiedRecords = externalRecords.filter { $0.executionOrigin == nil }

        let activityWindowStart = calendar.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7 * 24 * 3600)
        let activeDays = Set(realRecords.compactMap { record -> Date? in
            guard record.timestamp >= activityWindowStart && record.timestamp <= now else { return nil }
            return calendar.startOfDay(for: record.timestamp)
        })

        let sortedLatencies = realRecords.map(\.routingDecisionMs).filter { $0.isFinite && $0 >= 0 }.sorted()
        let fallbackEligible = realRecords.filter { record in
            record.attempts.count > 1 && record.attempts.contains(where: { !$0.succeeded })
        }
        let recovered = fallbackEligible.filter { record in
            guard record.status == .success else { return false }
            for (index, attempt) in record.attempts.enumerated() where !attempt.succeeded {
                let failedModel = attempt.modelID
                if record.attempts.dropFirst(index + 1).contains(where: { $0.succeeded && $0.modelID != failedModel }) {
                    return true
                }
            }
            return false
        }

        let realABRecords = records.filter {
            $0.executionOrigin == .real &&
            ($0.source == .externalProxy || $0.source == .testBench) &&
            $0.status == .success
        }
        let realAB = realABRecords.filter {
            $0.comparison?.basis == .realABTest &&
            $0.comparison?.isMeasuredPair == true &&
            $0.comparison?.costDifferenceUSD != nil &&
            $0.finalUsage != nil &&
            $0.usageSource == .upstreamReported &&
            $0.totalCostUSD != nil
        }
        let historical = realRecords.filter {
            $0.comparison?.basis == .historicalEstimate &&
            $0.comparison?.costDifferenceUSD != nil &&
            $0.totalCostUSD != nil
        }

        return LocalProductMetrics(
            funnel: funnel,
            realRouteSampleCount: realRecords.count,
            demoRouteSampleCount: demoRecords.count,
            unclassifiedRouteSampleCount: unclassifiedRecords.count,
            activeDaysLast7: activeDays.count,
            lastRealRouteAt: realRecords.map(\.timestamp).max(),
            routingLatencySampleCount: sortedLatencies.count,
            routingP50Ms: percentile(0.50, sorted: sortedLatencies),
            routingP95Ms: percentile(0.95, sorted: sortedLatencies),
            fallbackEligibleSampleCount: fallbackEligible.count,
            fallbackRecoveredSampleCount: recovered.count,
            realABPricedSampleCount: realAB.count,
            realABMeasuredCostDifferenceUSD: sumDifferences(realAB),
            historicalPricedSampleCount: historical.count,
            historicalEstimatedCostDifferenceUSD: sumDifferences(historical),
            missingUsageSampleCount: realRecords.filter { $0.finalUsage == nil || $0.usageSource == .unavailable }.count,
            missingPriceSampleCount: realRecords.filter { $0.totalCostUSD == nil || $0.costStatus != .calculated }.count
        )
    }

    private static func percentile(_ percentile: Double, sorted values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let rank = max(1, Int((percentile * Double(values.count)).rounded(.up)))
        return values[min(values.count - 1, rank - 1)]
    }

    private static func sumDifferences(_ records: [CallRecord]) -> Double? {
        let values = records.compactMap(\.comparison?.costDifferenceUSD)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

public struct LocalProductMetricsExport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var definitionVersion: String
    public var generatedAt: Date
    public var activityWindowStart: Date
    public var activityWindowEnd: Date
    public var retainedHistoryStart: Date?
    public var retainedHistoryEnd: Date?
    public var metrics: LocalProductMetrics

    public init(
        schemaVersion: Int = 1,
        definitionVersion: String = "local-product-metrics-v1",
        metrics: LocalProductMetrics,
        records: [CallRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.schemaVersion = schemaVersion
        self.definitionVersion = definitionVersion
        generatedAt = now
        activityWindowStart = calendar.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7 * 24 * 3600)
        activityWindowEnd = now
        retainedHistoryStart = records.map(\.timestamp).min()
        retainedHistoryEnd = records.map(\.timestamp).max()
        self.metrics = metrics
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
