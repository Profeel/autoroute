import Foundation

public struct DailyUsageSummary: Equatable, Sendable {
    public var callCount: Int
    public var successCount: Int
    public var totalTokens: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var cachedInputTokens: Int
    public var cacheCreationTokens: Int
    public var totalCostUSD: Double
    public var actualTotalLatencyMs: Double
    public var baselineCostUSD: Double
    public var baselineTotalLatencyMs: Double

    public init(
        callCount: Int = 0,
        successCount: Int = 0,
        totalTokens: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        totalCostUSD: Double = 0,
        actualTotalLatencyMs: Double = 0,
        baselineCostUSD: Double = 0,
        baselineTotalLatencyMs: Double = 0
    ) {
        self.callCount = callCount
        self.successCount = successCount
        self.totalTokens = totalTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalCostUSD = totalCostUSD
        self.actualTotalLatencyMs = actualTotalLatencyMs
        self.baselineCostUSD = baselineCostUSD
        self.baselineTotalLatencyMs = baselineTotalLatencyMs
    }

    public var cacheHitRate: Double? {
        guard cachedInputTokens > 0, promptTokens > 0 else { return nil }
        return min(1.0, Double(cachedInputTokens) / Double(promptTokens))
    }

    public var costSavedUSD: Double {
        max(0, baselineCostUSD - totalCostUSD)
    }

    public var timeSavedSeconds: Double {
        max(0, (baselineTotalLatencyMs - actualTotalLatencyMs) / 1000.0)
    }
}

public struct DailyUsageBucket: Codable, Equatable, Sendable {
    public var dayKey: String
    public var callCount: Int
    public var successCount: Int
    public var totalTokens: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var cachedInputTokens: Int
    public var cacheCreationTokens: Int
    public var totalCostUSD: Double
    public var actualTotalLatencyMs: Double
    public var baselineCostUSD: Double
    public var baselineTotalLatencyMs: Double

    public init(
        dayKey: String,
        callCount: Int = 0,
        successCount: Int = 0,
        totalTokens: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        totalCostUSD: Double = 0,
        actualTotalLatencyMs: Double = 0,
        baselineCostUSD: Double = 0,
        baselineTotalLatencyMs: Double = 0
    ) {
        self.dayKey = dayKey
        self.callCount = callCount
        self.successCount = successCount
        self.totalTokens = totalTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalCostUSD = totalCostUSD
        self.actualTotalLatencyMs = actualTotalLatencyMs
        self.baselineCostUSD = baselineCostUSD
        self.baselineTotalLatencyMs = baselineTotalLatencyMs
    }

    enum CodingKeys: String, CodingKey {
        case dayKey, callCount, successCount, totalTokens, promptTokens, completionTokens
        case cachedInputTokens, cacheCreationTokens, totalCostUSD
        case actualTotalLatencyMs, baselineCostUSD, baselineTotalLatencyMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try c.decode(String.self, forKey: .dayKey)
        callCount = try c.decodeIfPresent(Int.self, forKey: .callCount) ?? 0
        successCount = try c.decodeIfPresent(Int.self, forKey: .successCount) ?? 0
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        cachedInputTokens = try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        totalCostUSD = try c.decodeIfPresent(Double.self, forKey: .totalCostUSD) ?? 0
        actualTotalLatencyMs = try c.decodeIfPresent(Double.self, forKey: .actualTotalLatencyMs) ?? 0
        baselineCostUSD = try c.decodeIfPresent(Double.self, forKey: .baselineCostUSD) ?? 0
        baselineTotalLatencyMs = try c.decodeIfPresent(Double.self, forKey: .baselineTotalLatencyMs) ?? 0
    }

    public var summary: DailyUsageSummary {
        DailyUsageSummary(
            callCount: callCount,
            successCount: successCount,
            totalTokens: totalTokens,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedInputTokens: cachedInputTokens,
            cacheCreationTokens: cacheCreationTokens,
            totalCostUSD: totalCostUSD,
            actualTotalLatencyMs: actualTotalLatencyMs,
            baselineCostUSD: baselineCostUSD,
            baselineTotalLatencyMs: baselineTotalLatencyMs
        )
    }
}

/// Durable daily usage aggregation independent of the 500-record UI callHistory cap.
public struct DailyUsageLedger: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var buckets: [String: DailyUsageBucket]

    public init(schemaVersion: Int = 1, buckets: [String: DailyUsageBucket] = [:]) {
        self.schemaVersion = schemaVersion
        self.buckets = buckets
    }

    public init(records: [CallRecord], calendar: Calendar = .current) {
        self.init()
        for record in records {
            self.record(record, calendar: calendar)
        }
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    public mutating func record(
        _ record: CallRecord,
        baselineCostUSD: Double? = nil,
        baselineLatencyMs: Double? = nil,
        calendar: Calendar = .current
    ) {
        if record.executionOrigin == .demo {
            return
        }
        let key = Self.dayKey(for: record.timestamp, calendar: calendar)
        var bucket = buckets[key] ?? DailyUsageBucket(dayKey: key)
        bucket.callCount += 1
        if record.status == .success {
            bucket.successCount += 1
            if record.totalCompletionMs.isFinite, record.totalCompletionMs > 0 {
                bucket.actualTotalLatencyMs += record.totalCompletionMs
            }
            if let baseLat = baselineLatencyMs, baseLat.isFinite, baseLat > 0 {
                bucket.baselineTotalLatencyMs += baseLat
            } else if let compLat = record.comparison?.latencyDifferenceMs,
                      record.totalCompletionMs.isFinite {
                bucket.baselineTotalLatencyMs += max(0, record.totalCompletionMs + compLat)
            }
        }
        if let usage = record.finalUsage {
            bucket.totalTokens += max(0, usage.totalTokens)
            bucket.promptTokens += max(0, usage.promptTokens)
            bucket.completionTokens += max(0, usage.completionTokens)
            bucket.cachedInputTokens += max(0, usage.cachedInputTokens ?? 0)
            bucket.cacheCreationTokens += max(0, usage.cacheCreationTokens ?? 0)
        }
        if let cost = record.totalCostUSD, cost.isFinite {
            let safeCost = max(0, cost)
            bucket.totalCostUSD += safeCost
            if let baseCost = baselineCostUSD, baseCost.isFinite {
                bucket.baselineCostUSD += max(0, baseCost)
            } else if let compDiff = record.comparison?.costDifferenceUSD {
                bucket.baselineCostUSD += max(0, safeCost + compDiff)
            }
        }
        buckets[key] = bucket
    }

    public func summary(for date: Date = Date(), calendar: Calendar = .current) -> DailyUsageSummary {
        let key = Self.dayKey(for: date, calendar: calendar)
        return buckets[key]?.summary ?? DailyUsageSummary()
    }

    public func summary(dayKey: String) -> DailyUsageSummary {
        buckets[dayKey]?.summary ?? DailyUsageSummary()
    }

    public func cumulativeSummary() -> DailyUsageSummary {
        var total = DailyUsageSummary()
        for bucket in buckets.values {
            total.callCount += bucket.callCount
            total.successCount += bucket.successCount
            total.totalTokens += bucket.totalTokens
            total.promptTokens += bucket.promptTokens
            total.completionTokens += bucket.completionTokens
            total.cachedInputTokens += bucket.cachedInputTokens
            total.cacheCreationTokens += bucket.cacheCreationTokens
            total.totalCostUSD += bucket.totalCostUSD
            total.actualTotalLatencyMs += bucket.actualTotalLatencyMs
            total.baselineCostUSD += bucket.baselineCostUSD
            total.baselineTotalLatencyMs += bucket.baselineTotalLatencyMs
        }
        return total
    }

    public mutating func removeAll() {
        buckets.removeAll()
    }
}
