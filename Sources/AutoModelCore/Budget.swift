import Foundation

public struct MonthlyBudgetLimit: Codable, Equatable, Sendable {
    public var limitUSD: Double
    /// Legacy mirrored value kept for Codable compatibility. The authoritative
    /// threshold is `MonthlyBudgetSettings.warningThreshold`.
    public var warningThreshold: Double

    public init(limitUSD: Double, warningThreshold: Double = 0.8) {
        self.limitUSD = max(0, limitUSD)
        self.warningThreshold = min(1, max(0, warningThreshold))
    }
}

public struct MonthlyBudgetSettings: Codable, Equatable, Sendable {
    public var global: MonthlyBudgetLimit?
    public var agentLimits: [String: MonthlyBudgetLimit]
    public var warningThreshold: Double

    public init(
        global: MonthlyBudgetLimit? = nil,
        agentLimits: [String: MonthlyBudgetLimit] = [:],
        warningThreshold: Double = 0.8
    ) {
        self.global = global
        self.agentLimits = agentLimits
        self.warningThreshold = min(1, max(0, warningThreshold))
    }

    enum CodingKeys: String, CodingKey {
        case global, agentLimits, warningThreshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        global = try container.decodeIfPresent(MonthlyBudgetLimit.self, forKey: .global)
        agentLimits = try container.decodeIfPresent([String: MonthlyBudgetLimit].self, forKey: .agentLimits) ?? [:]
        warningThreshold = try container.decodeIfPresent(Double.self, forKey: .warningThreshold) ?? 0.8
    }
}

public struct MonthlyBudgetUsage: Codable, Equatable, Sendable {
    public var period: String
    public var measuredCostUSD: Double
    public var estimatedCostUSD: Double
    public var unpricedCallCount: Int

    public init(period: String, measuredCostUSD: Double, estimatedCostUSD: Double, unpricedCallCount: Int) {
        self.period = period
        self.measuredCostUSD = measuredCostUSD
        self.estimatedCostUSD = estimatedCostUSD
        self.unpricedCallCount = unpricedCallCount
    }

    public var totalCostUSD: Double { measuredCostUSD + estimatedCostUSD }
}

public struct BudgetLedgerBucket: Codable, Equatable, Sendable {
    public var period: String
    public var agentID: String?
    public var measuredCostUSD: Double
    public var estimatedCostUSD: Double
    public var unpricedCallCount: Int

    public init(
        period: String,
        agentID: String?,
        measuredCostUSD: Double = 0,
        estimatedCostUSD: Double = 0,
        unpricedCallCount: Int = 0
    ) {
        self.period = period
        self.agentID = agentID
        self.measuredCostUSD = measuredCostUSD
        self.estimatedCostUSD = estimatedCostUSD
        self.unpricedCallCount = unpricedCallCount
    }
}

/// Durable aggregation used for budget enforcement, independent of the capped UI history.
public struct BudgetLedger: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var buckets: [String: BudgetLedgerBucket]

    public init(schemaVersion: Int = 1, buckets: [String: BudgetLedgerBucket] = [:]) {
        self.schemaVersion = schemaVersion
        self.buckets = buckets
    }

    public init(records: [CallRecord], calendar: Calendar = .current) {
        self.init()
        for record in records {
            self.record(record, calendar: calendar)
        }
    }

    public mutating func record(_ record: CallRecord, calendar: Calendar = .current) {
        guard record.executionOrigin != .demo else { return }
        let period = MonthlyBudgetEvaluator.period(for: record.timestamp, calendar: calendar)
        var measured = 0.0
        var estimated = 0.0
        for attempt in record.attempts {
            guard let cost = attempt.costUSD else { continue }
            switch attempt.usageSource {
            case .upstreamReported:
                measured += cost
            case .estimatedWhenMissing:
                estimated += cost
            case .unavailable:
                break
            }
        }
        let unpriced = record.attempts.contains {
            $0.usage != nil && $0.costStatus == .missingPriceConfig
        } ? 1 : 0

        let scopes: [String?] = record.decision.agentID.map { [nil, $0] } ?? [nil]
        for scope in scopes {
            let key = Self.key(period: period, agentID: scope)
            var bucket = buckets[key] ?? BudgetLedgerBucket(period: period, agentID: scope)
            bucket.measuredCostUSD += measured
            bucket.estimatedCostUSD += estimated
            bucket.unpricedCallCount += unpriced
            buckets[key] = bucket
        }
    }

    public func usage(agentID: String?, period: String) -> MonthlyBudgetUsage {
        let bucket = buckets[Self.key(period: period, agentID: agentID)]
        return MonthlyBudgetUsage(
            period: period,
            measuredCostUSD: bucket?.measuredCostUSD ?? 0,
            estimatedCostUSD: bucket?.estimatedCostUSD ?? 0,
            unpricedCallCount: bucket?.unpricedCallCount ?? 0
        )
    }

    public func usage(agentID: String?, now: Date = Date(), calendar: Calendar = .current) -> MonthlyBudgetUsage {
        usage(agentID: agentID, period: MonthlyBudgetEvaluator.period(for: now, calendar: calendar))
    }

    public mutating func removeAll() {
        buckets.removeAll()
    }

    private static func key(period: String, agentID: String?) -> String {
        "\(period)|\(agentID ?? "__global__")"
    }
}

public struct BudgetExceededError: Error, Equatable, Sendable {
    public let statusCode: Int = 429
    public let code: String = "budget_exceeded"
    public let message: String
}

public enum MonthlyBudgetWarningLevel: String, Codable, Equatable, Sendable {
    case unlimited
    case normal
    case warning
    case hardLimit = "hard_limit"
}

public struct MonthlyBudgetWarningState: Equatable, Sendable {
    public var period: String
    public var limitUSD: Double?
    public var accountedCostUSD: Double
    public var measuredCostUSD: Double
    public var estimatedCostUSD: Double
    public var unpricedCallCount: Int
    public var warningThreshold: Double?
    public var level: MonthlyBudgetWarningLevel
    public var message: String

    public var hasReachedThreshold: Bool {
        level == .warning || level == .hardLimit
    }

    public var hasReachedHardLimit: Bool {
        level == .hardLimit
    }
}

public enum MonthlyBudgetEvaluator {
    public static func period(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    public static func usage(
        callHistory: [CallRecord],
        agentID: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MonthlyBudgetUsage {
        let targetPeriod = period(for: now, calendar: calendar)
        let records = callHistory.filter { record in
            record.executionOrigin != .demo
                && period(for: record.timestamp, calendar: calendar) == targetPeriod
                && (agentID == nil || record.decision.agentID == agentID)
        }
        var measured = 0.0
        var estimated = 0.0
        var unpriced = 0
        for record in records {
            if record.attempts.contains(where: {
                $0.usage != nil && $0.costStatus == .missingPriceConfig
            }) {
                unpriced += 1
            }
            for attempt in record.attempts {
                guard let cost = attempt.costUSD else { continue }
                switch attempt.usageSource {
                case .upstreamReported:
                    measured += cost
                case .estimatedWhenMissing:
                    estimated += cost
                case .unavailable:
                    break
                }
            }
        }
        return MonthlyBudgetUsage(
            period: targetPeriod,
            measuredCostUSD: measured,
            estimatedCostUSD: estimated,
            unpricedCallCount: unpriced
        )
    }

    public static func warning(
        usage: MonthlyBudgetUsage,
        limit: MonthlyBudgetLimit?,
        warningThreshold: Double
    ) -> MonthlyBudgetWarningState {
        guard let limit else {
            return MonthlyBudgetWarningState(
                period: usage.period,
                limitUSD: nil,
                accountedCostUSD: usage.totalCostUSD,
                measuredCostUSD: usage.measuredCostUSD,
                estimatedCostUSD: usage.estimatedCostUSD,
                unpricedCallCount: usage.unpricedCallCount,
                warningThreshold: nil,
                level: .unlimited,
                message: "周期 \(usage.period) 未设置预算上限；实测与估算仍分别计量。"
            )
        }

        let accounted = usage.totalCostUSD
        let threshold = min(1, max(0, warningThreshold))
        let level: MonthlyBudgetWarningLevel
        if accounted >= limit.limitUSD {
            level = .hardLimit
        } else if accounted >= limit.limitUSD * threshold {
            level = .warning
        } else {
            level = .normal
        }
        let message: String
        switch level {
        case .hardLimit:
            message = "周期 \(usage.period) 已计量 $\(String(format: "%.4f", accounted))，达到硬上限 $\(String(format: "%.4f", limit.limitUSD))；新请求将在上游前被拒绝。"
        case .warning:
            message = "周期 \(usage.period) 已计量 $\(String(format: "%.4f", accounted))，达到预警阈值 \(Int((threshold * 100).rounded()))%（上限 $\(String(format: "%.4f", limit.limitUSD))）；预警不会阻止请求。"
        case .normal:
            message = "周期 \(usage.period) 已计量 $\(String(format: "%.4f", accounted))，尚未达到预警阈值。"
        case .unlimited:
            message = ""
        }
        return MonthlyBudgetWarningState(
            period: usage.period,
            limitUSD: limit.limitUSD,
            accountedCostUSD: accounted,
            measuredCostUSD: usage.measuredCostUSD,
            estimatedCostUSD: usage.estimatedCostUSD,
            unpricedCallCount: usage.unpricedCallCount,
            warningThreshold: threshold,
            level: level,
            message: message
        )
    }

    public static func rejection(usage: MonthlyBudgetUsage, limit: MonthlyBudgetLimit) -> BudgetExceededError? {
        guard usage.totalCostUSD >= limit.limitUSD else { return nil }
        return BudgetExceededError(
            message: "月度预算已达上限：周期 \(usage.period)，上限 $\(String(format: "%.4f", limit.limitUSD))，已计量 $\(String(format: "%.4f", usage.totalCostUSD))（实测 $\(String(format: "%.4f", usage.measuredCostUSD)) + 本地估算 $\(String(format: "%.4f", usage.estimatedCostUSD))）。未定价调用不按 0 元计入，请另行核对供应商账单。"
        )
    }

    public static func rejection(
        callHistory: [CallRecord],
        settings: MonthlyBudgetSettings,
        agentID: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> BudgetExceededError? {
        if let global = settings.global {
            let usage = usage(callHistory: callHistory, agentID: nil, now: now, calendar: calendar)
            if let rejection = rejection(usage: usage, limit: global) { return rejection }
        }
        if let agentID, let limit = settings.agentLimits[agentID] {
            let usage = usage(callHistory: callHistory, agentID: agentID, now: now, calendar: calendar)
            if let rejection = rejection(usage: usage, limit: limit) { return rejection }
        }
        return nil
    }
}
