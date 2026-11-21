import Foundation

// MARK: - Usage Analytics, Budgets, Metrics & Impact Summaries

public struct HourlyTokenBucket: Identifiable, Equatable, Sendable {
    public var id: Int { hour }
    public let hour: Int
    public let label: String
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int

    public init(hour: Int, label: String, totalTokens: Int, inputTokens: Int, outputTokens: Int) {
        self.hour = hour
        self.label = label
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct ModelTokenBreakdownItem: Identifiable, Equatable, Sendable {
    public var id: String { modelID }
    public let modelID: String
    public let modelLabel: String
    public let totalTokens: Int
    public let sharePercent: Double
    public let callCount: Int

    public init(modelID: String? = nil, modelLabel: String, totalTokens: Int, sharePercent: Double, callCount: Int) {
        self.modelID = modelID ?? ModelPresentationIdentity.id(for: modelLabel)
        self.modelLabel = modelLabel
        self.totalTokens = totalTokens
        self.sharePercent = sharePercent
        self.callCount = callCount
    }

    public static func summarize(_ records: [CallRecord], models: [ModelConfig] = []) -> [ModelTokenBreakdownItem] {
        var tokensByModel: [String: (label: String, tokens: Int, calls: Int)] = [:]
        var grandTotal = 0
        for record in records {
            guard let usage = record.finalUsage else { continue }
            let tokens = max(0, usage.totalTokens)
            guard tokens > 0 else { continue }
            let label = record.executedModelShortLabel
            let id = ModelPresentationIdentity.id(for: record, models: models)
            var entry = tokensByModel[id] ?? (label, 0, 0)
            entry.tokens += tokens
            entry.calls += 1
            tokensByModel[id] = entry
            grandTotal += tokens
        }
        guard grandTotal > 0 else { return [] }
        return tokensByModel.map { id, stats in
            ModelTokenBreakdownItem(
                modelID: id,
                modelLabel: stats.label,
                totalTokens: stats.tokens,
                sharePercent: (Double(stats.tokens) / Double(grandTotal)) * 100.0,
                callCount: stats.calls
            )
        }.sorted { $0.totalTokens > $1.totalTokens }
    }
}

public struct CumulativeSavingsSummary: Equatable, Sendable {
    public let baselineModelDisplayName: String?
    public let totalCostSavedUSD: Double
    public let totalTimeSavedSeconds: Double
    public let actualCostUSD: Double
    public let baselineCostUSD: Double
    public let totalCallCount: Int

    public init(
        baselineModelDisplayName: String?,
        totalCostSavedUSD: Double,
        totalTimeSavedSeconds: Double,
        actualCostUSD: Double,
        baselineCostUSD: Double,
        totalCallCount: Int
    ) {
        self.baselineModelDisplayName = baselineModelDisplayName
        self.totalCostSavedUSD = totalCostSavedUSD
        self.totalTimeSavedSeconds = totalTimeSavedSeconds
        self.actualCostUSD = actualCostUSD
        self.baselineCostUSD = baselineCostUSD
        self.totalCallCount = totalCallCount
    }
}

extension AutoModelEngine {
    public func dailyUsageTrends(days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> [DailyUsageTrendPoint] {
        let sqliteTrends = persistence.queryDailyTrends(days: days, now: now, calendar: calendar)
        if sqliteTrends.contains(where: { $0.callCount > 0 }) {
            return sqliteTrends
        }
        // Fall back to DailyUsageLedger buckets if SQLite has not recorded older historical buckets.
        let clampedDays = max(1, min(365, days))
        let todayStart = calendar.startOfDay(for: now)
        let startDate = calendar.date(byAdding: .day, value: -(clampedDays - 1), to: todayStart) ?? todayStart
        return (0..<clampedDays).compactMap { offset in
            guard let dayDate = calendar.date(byAdding: .day, value: offset, to: startDate) else { return nil }
            let key = DailyUsageLedger.dayKey(for: dayDate, calendar: calendar)
            let summary = dailyUsageLedger.summary(dayKey: key)
            return DailyUsageTrendPoint(
                dayKey: key,
                callCount: summary.callCount,
                successCount: summary.successCount,
                totalTokens: summary.totalTokens,
                promptTokens: summary.promptTokens,
                cachedInputTokens: summary.cachedInputTokens,
                cacheCreationTokens: summary.cacheCreationTokens,
                totalCostUSD: summary.totalCostUSD
            )
        }
    }

    public func usageBreakdownByAgent(days: Int? = 7, now: Date = Date()) -> [UsageBreakdownItem] {
        let since = days.map { now.addingTimeInterval(-Double(max(1, $0)) * 86_400) }
        return persistence.queryBreakdownByAgent(since: since)
    }

    public func usageBreakdownByModel(days: Int? = 7, now: Date = Date()) -> [UsageBreakdownItem] {
        let since = days.map { now.addingTimeInterval(-Double(max(1, $0)) * 86_400) }
        return persistence.queryBreakdownByModel(since: since)
    }

    public func totalStoredRecordCount() -> Int {
        max(callHistory.count, persistence.totalStoredRecordCount())
    }

    public func todayUsageSummary(now: Date = Date(), calendar: Calendar = .current) -> DailyUsageSummary {
        dailyUsageLedger.summary(for: now, calendar: calendar)
    }

    public func cumulativeUsageSummary() -> DailyUsageSummary {
        dailyUsageLedger.cumulativeSummary()
    }

    public func monthlyBudgetUsage(agentID: String? = nil, now: Date = Date()) -> MonthlyBudgetUsage {
        budgetLedger.usage(agentID: agentID, now: now)
    }

    func budgetRejection(agentID: String?, now: Date = Date()) -> BudgetExceededError? {
        if let global = config.budgetSettings.global {
            let usage = budgetLedger.usage(agentID: nil, now: now)
            if let rejection = MonthlyBudgetEvaluator.rejection(usage: usage, limit: global) {
                return rejection
            }
        }
        if let agentID, let limit = config.budgetSettings.agentLimits[agentID] {
            let usage = budgetLedger.usage(agentID: agentID, now: now)
            if let rejection = MonthlyBudgetEvaluator.rejection(usage: usage, limit: limit) {
                return rejection
            }
        }
        return nil
    }

    public func monthlyBudgetWarning(agentID: String? = nil, now: Date = Date()) -> MonthlyBudgetWarningState {
        let usage = monthlyBudgetUsage(agentID: agentID, now: now)
        let limit: MonthlyBudgetLimit?
        if let agentID {
            limit = config.budgetSettings.agentLimits[agentID]
        } else {
            limit = config.budgetSettings.global
        }
        return MonthlyBudgetEvaluator.warning(
            usage: usage,
            limit: limit,
            warningThreshold: config.budgetSettings.warningThreshold
        )
    }

    public func updateGlobalBudget(_ limit: MonthlyBudgetLimit?) {
        config.budgetSettings.global = limit
        saveConfig()
    }

    public func updateBudgetWarningThreshold(_ threshold: Double) {
        config.budgetSettings.warningThreshold = min(1, max(0, threshold))
        saveConfig()
    }

    public func updateAgentBudget(_ limit: MonthlyBudgetLimit?, for kind: AgentKind) {
        config.budgetSettings.agentLimits[kind.rawValue] = limit
        saveConfig()
    }

    public func localProductMetrics(now: Date = Date()) -> LocalProductMetrics {
        let stored = persistence.queryHistoryRecords()
        let sourceRecords = stored.count >= callHistory.count ? stored : callHistory
        return LocalProductMetricsCalculator.calculate(records: sourceRecords, funnel: onboardingFunnel, now: now)
    }

    public func localProductMetricsExport(now: Date = Date()) -> LocalProductMetricsExport {
        let stored = persistence.queryHistoryRecords()
        let sourceRecords = stored.count >= callHistory.count ? stored : callHistory
        return LocalProductMetricsExport(
            metrics: LocalProductMetricsCalculator.calculate(records: sourceRecords, funnel: onboardingFunnel, now: now),
            records: sourceRecords,
            now: now
        )
    }

    public func currentAlertLevel(now: Date = Date()) -> EngineAlertLevel {
        if !isLocalAPITokenPersistent {
            return .error("本地 API 凭据未持久化")
        }
        switch proxyState {
        case .portConflict(let port, _):
            return .error("端口 \(port) 冲突")
        case .error(let msg):
            return .error(msg)
        case .stopped:
            return .warning("本地代理已停止")
        case .running:
            break
        }
        let globalWarning = monthlyBudgetWarning(agentID: nil, now: now)
        if globalWarning.level == .hardLimit {
            return .error("全局月度预算已达硬上限")
        }
        for kind in AgentKind.allCases {
            let agentWarning = monthlyBudgetWarning(agentID: kind.rawValue, now: now)
            if agentWarning.level == .hardLimit {
                return .error("\(kind.displayName) 月度预算已达硬上限")
            }
        }
        if globalWarning.level == .warning {
            return .warning("全局月度预算已达预警阈值")
        }
        if config.providers.contains(where: { $0.isEnabled && $0.healthStatus == .authError }) {
            return .warning("存在供应商密钥鉴权失败")
        }
        for tier in ModelTier.allCases {
            let pool = config.policy.modelIDs(for: tier)
            if !pool.isEmpty && pool.allSatisfy({ (cooldownUntilByModelID[$0] ?? .distantPast) > now }) {
                return .warning("\(tier.shortName) 档位全部冷却中")
            }
        }
        return .normal
    }

    func computeAttemptCost(model: ModelConfig, usage: TokenUsage?) -> (costUSD: Double?, status: CostCalculationStatus) {
        guard let usage else {
            return (nil, .noUsage)
        }
        guard let calculated = model.calculateCostUSD(usage: usage) else {
            return (nil, .missingPriceConfig)
        }
        return (calculated, .calculated)
    }

    private struct BaselineLatencyProfile {
        var sampleCount: Int
        var rawAvgLatencyMs: Double
        var avgTTFTMs: Double?
        var decodeMsPerOutputToken: Double?

        func estimatedLatencyMs(forCompletionTokens completionTokens: Int?) -> Double {
            if let outTokens = completionTokens,
               outTokens > 0,
               let ttft = avgTTFTMs,
               let decodeRate = decodeMsPerOutputToken {
                return ttft + Double(outTokens) * decodeRate
            }
            return rawAvgLatencyMs
        }
    }

    private func baselineLatencyProfile(for baselineModelID: String) -> BaselineLatencyProfile? {
        let samples = callHistory.filter {
            $0.executionOrigin == .real && $0.status == .success && $0.executedModelID == baselineModelID
        }
        guard !samples.isEmpty else { return nil }

        let rawAvg = samples.map(\.totalCompletionMs).reduce(0.0, +) / Double(samples.count)
        let tokenSamples = samples.filter { ($0.finalUsage?.completionTokens ?? 0) > 0 }
        var avgTTFTMs: Double?
        var decodeMsPerOutputToken: Double?

        if !tokenSamples.isEmpty {
            let ttftSamples = tokenSamples.compactMap(\.upstreamFirstTokenMs)
            if !ttftSamples.isEmpty {
                let ttftSum = ttftSamples.reduce(0.0, +)
                let avgTTFT = ttftSum / Double(ttftSamples.count)
                var decodeTimeSum = 0.0
                var outTokenSum = 0
                for sample in tokenSamples {
                    guard let outTok = sample.finalUsage?.completionTokens, outTok > 0 else { continue }
                    let ttft = sample.upstreamFirstTokenMs ?? avgTTFT
                    decodeTimeSum += max(0.0, sample.totalCompletionMs - ttft)
                    outTokenSum += outTok
                }
                if outTokenSum > 0 {
                    avgTTFTMs = avgTTFT
                    decodeMsPerOutputToken = decodeTimeSum / Double(outTokenSum)
                }
            } else {
                let outTokenSum = tokenSamples.compactMap { $0.finalUsage?.completionTokens }.reduce(0, +)
                if outTokenSum > 0 {
                    avgTTFTMs = 0.0
                    decodeMsPerOutputToken = tokenSamples.map(\.totalCompletionMs).reduce(0.0, +) / Double(outTokenSum)
                }
            }
        }

        return BaselineLatencyProfile(
            sampleCount: samples.count,
            rawAvgLatencyMs: rawAvg,
            avgTTFTMs: avgTTFTMs,
            decodeMsPerOutputToken: decodeMsPerOutputToken
        )
    }

    func buildHistoricalComparison(
        executedModel: ModelConfig,
        executedUsage: TokenUsage?,
        autoTotalCostUSD: Double?,
        autoTotalLatencyMs: Double
    ) -> ComparisonAnalysis? {
        let alternativeModels = config.models.filter { $0.id != executedModel.id && $0.isEnabled }
            .sorted { $0.qualityScore > $1.qualityScore }

        for baseline in alternativeModels {
            guard let profile = baselineLatencyProfile(for: baseline.modelID) else { continue }

            let estBaselineLatency = profile.estimatedLatencyMs(forCompletionTokens: executedUsage?.completionTokens)
            let latencyDiff = estBaselineLatency - autoTotalLatencyMs

            var costDiff: Double?
            var savingsPct: Double?
            if let autoCost = autoTotalCostUSD,
               let usage = executedUsage,
               let estBaselineCost = baseline.calculateCostUSD(usage: usage) {
                costDiff = estBaselineCost - autoCost
                if estBaselineCost > 0 {
                    savingsPct = ((estBaselineCost - autoCost) / estBaselineCost) * 100.0
                }
            }

            let basisDetail: String
            if let outTok = executedUsage?.completionTokens,
               outTok > 0,
               profile.decodeMsPerOutputToken != nil {
                basisDetail = "同输出量 \(outTok) tokens 归一化估算 \(AutoModelFormatter.formatMs(estBaselineLatency))"
            } else {
                basisDetail = "历史均值 \(AutoModelFormatter.formatMs(profile.rawAvgLatencyMs))"
            }

            return ComparisonAnalysis(
                basis: .historicalEstimate,
                baselineModelID: baseline.modelID,
                baselineModelDisplayName: baseline.displayName,
                costDifferenceUSD: costDiff,
                costSavingsPercent: savingsPct,
                latencyDifferenceMs: latencyDiff,
                sampleCount: profile.sampleCount,
                note: "历史估算：基于「\(baseline.displayName)」在本机的 \(profile.sampleCount) 条真实历史样本（\(basisDetail)）与当前请求用量按单价估算。"
            )
        }
        return nil
    }

    /// Computes aggregate cost savings, speed improvement, retry rate, and top-10% hard-task cost share
    /// against a traditional single-flagship-model baseline, strictly grounded in recorded call history.
    public func routingImpactSummary(todayOnly: Bool = false) -> RoutingImpactSummary? {
        let cal = Calendar.current
        let nonDemoRecords = callHistory.filter { $0.executionOrigin == .real }
        let scopedRecords = todayOnly
            ? nonDemoRecords.filter { cal.isDateInToday($0.timestamp) }
            : nonDemoRecords
        return computeImpactSummary(scopedRecords: scopedRecords)
    }

    /// Computes cost savings and speed improvement for a specific session's records
    /// compared against always using the highest-tier flagship model.
    public func sessionImpactSummary(for records: [CallRecord]) -> RoutingImpactSummary? {
        computeImpactSummary(scopedRecords: records.filter { $0.executionOrigin == .real })
    }

    public func todayHourlyTokenBuckets(now: Date = Date(), calendar: Calendar = .current) -> [HourlyTokenBucket] {
        let todayRecords = callHistory.filter {
            $0.executionOrigin == .real && calendar.isDate($0.timestamp, inSameDayAs: now)
        }
        var inByHour = Array(repeating: 0, count: 24)
        var outByHour = Array(repeating: 0, count: 24)
        for record in todayRecords {
            guard let usage = record.finalUsage else { continue }
            let hour = min(23, max(0, calendar.component(.hour, from: record.timestamp)))
            inByHour[hour] += max(0, usage.promptTokens)
            outByHour[hour] += max(0, usage.completionTokens)
        }
        return (0..<24).map { hour in
            let inputTok = inByHour[hour]
            let outputTok = outByHour[hour]
            return HourlyTokenBucket(
                hour: hour,
                label: String(format: "%02d", hour),
                totalTokens: inputTok + outputTok,
                inputTokens: inputTok,
                outputTokens: outputTok
            )
        }
    }

    public func todayModelTokenBreakdown(now: Date = Date(), calendar: Calendar = .current) -> [ModelTokenBreakdownItem] {
        let todayRecords = callHistory.filter {
            $0.executionOrigin == .real && calendar.isDate($0.timestamp, inSameDayAs: now)
        }
        return ModelTokenBreakdownItem.summarize(todayRecords, models: config.models)
    }

    public func cumulativeSavingsSummary() -> CumulativeSavingsSummary {
        let ledger = dailyUsageLedger.cumulativeSummary()
        let baselineName = flagshipBaselineModel()?.displayName
        // Prefer durable ledger values; fall back to current callHistory impact if ledger has no baseline data yet.
        if ledger.baselineCostUSD > 0 || ledger.baselineTotalLatencyMs > 0 {
            return CumulativeSavingsSummary(
                baselineModelDisplayName: baselineName,
                totalCostSavedUSD: ledger.costSavedUSD,
                totalTimeSavedSeconds: ledger.timeSavedSeconds,
                actualCostUSD: ledger.totalCostUSD,
                baselineCostUSD: ledger.baselineCostUSD,
                totalCallCount: ledger.callCount
            )
        }
        if let fallbackImpact = routingImpactSummary(todayOnly: false) {
            return CumulativeSavingsSummary(
                baselineModelDisplayName: fallbackImpact.baselineModelDisplayName,
                totalCostSavedUSD: max(0, fallbackImpact.costSavedUSD),
                totalTimeSavedSeconds: max(0, fallbackImpact.totalTimeSavedSeconds ?? 0),
                actualCostUSD: fallbackImpact.actualCostUSD,
                baselineCostUSD: fallbackImpact.baselineCostUSD,
                totalCallCount: ledger.callCount > 0 ? ledger.callCount : fallbackImpact.evaluatedTurnCount
            )
        }
        return CumulativeSavingsSummary(
            baselineModelDisplayName: baselineName,
            totalCostSavedUSD: 0,
            totalTimeSavedSeconds: 0,
            actualCostUSD: ledger.totalCostUSD,
            baselineCostUSD: 0,
            totalCallCount: ledger.callCount
        )
    }

    func flagshipBaselineModel() -> ModelConfig? {
        if let high = model(for: .high), high.blendedPricePerMillion != nil {
            return high
        }
        if let pricedFlagship = config.models
            .filter({ $0.isEnabled && $0.blendedPricePerMillion != nil })
            .max(by: { $0.qualityScore < $1.qualityScore }) {
            return pricedFlagship
        }
        return model(for: .high) ?? config.models.max(by: { $0.qualityScore < $1.qualityScore })
    }

    func baselineEstimatesForLedger(record: CallRecord) -> (costUSD: Double?, latencyMs: Double?) {
        guard record.executionOrigin != .demo,
              let baseline = flagshipBaselineModel() else {
            return (nil, nil)
        }
        var estCost: Double?
        if let comparison = record.comparison,
           comparison.baselineModelID == baseline.modelID,
           let diff = comparison.costDifferenceUSD,
           let actual = record.totalCostUSD {
            estCost = max(0, actual + diff)
        } else if let usage = record.finalUsage {
            estCost = baseline.calculateCostUSD(usage: usage)
        }

        var estLatency: Double?
        if record.status == .success {
            if record.executedModelID == baseline.modelID {
                estLatency = record.totalCompletionMs
            } else if let profile = baselineLatencyProfile(for: baseline.modelID) {
                estLatency = profile.estimatedLatencyMs(forCompletionTokens: record.finalUsage?.completionTokens)
            } else if let comparison = record.comparison,
                      comparison.baselineModelID == baseline.modelID,
                      let diff = comparison.latencyDifferenceMs {
                estLatency = max(0, record.totalCompletionMs + diff)
            }
        }
        return (estCost, estLatency)
    }

    private func computeImpactSummary(scopedRecords: [CallRecord]) -> RoutingImpactSummary? {
        guard !scopedRecords.isEmpty else { return nil }

        let baselineModel: ModelConfig? = {
            if let high = model(for: .high), high.blendedPricePerMillion != nil {
                return high
            }
            if let pricedFlagship = config.models
                .filter({ $0.isEnabled && $0.blendedPricePerMillion != nil })
                .max(by: { $0.qualityScore < $1.qualityScore }) {
                return pricedFlagship
            }
            return model(for: .high) ?? config.models.max(by: { $0.qualityScore < $1.qualityScore })
        }()

        guard let baseline = baselineModel else { return nil }

        let successRecords = scopedRecords.filter { $0.status == .success }
        let successRatePct = Int((Double(successRecords.count) / Double(scopedRecords.count) * 100.0).rounded())
        let retryCount = scopedRecords.filter { $0.attempts.count > 1 }.count

        var actualCostSum = 0.0
        var baselineCostSum = 0.0
        var evaluatedTurnCount = 0

        for record in successRecords {
            if record.costStatus == .calculated, let actualCost = record.totalCostUSD,
               let usage = record.finalUsage,
               let estBaselineCost = baseline.calculateCostUSD(usage: usage) {
                actualCostSum += actualCost
                baselineCostSum += estBaselineCost
                evaluatedTurnCount += 1
            }
        }

        let costSavedUSD = baselineCostSum - actualCostSum
        let costSavingsPercent: Double? = baselineCostSum > 0
            ? (costSavedUSD / baselineCostSum) * 100.0
            : nil

        let baselineProfile = baselineLatencyProfile(for: baseline.modelID)
        let comparisonLatencyPairs: [(actual: Double, baseline: Double)] = successRecords.compactMap { rec in
            guard let comparison = rec.comparison,
                  comparison.baselineModelID == baseline.modelID,
                  let diff = comparison.latencyDifferenceMs else { return nil }
            return (rec.totalCompletionMs, max(0, rec.totalCompletionMs + diff))
        }

        var baselineAvgLatencyMs: Double?
        var latencyRecords = successRecords.map(\.totalCompletionMs)
        var speedSampleCount = 0
        var speedBasisLabel = "待采集基准耗时样本"

        if let profile = baselineProfile, !successRecords.isEmpty {
            var estTurnLatencies: [Double] = []
            var usedTokenNormalized = false
            for rec in successRecords {
                if rec.executedModelID == baseline.modelID {
                    estTurnLatencies.append(rec.totalCompletionMs)
                } else {
                    if (rec.finalUsage?.completionTokens ?? 0) > 0 && profile.decodeMsPerOutputToken != nil {
                        usedTokenNormalized = true
                    }
                    estTurnLatencies.append(profile.estimatedLatencyMs(forCompletionTokens: rec.finalUsage?.completionTokens))
                }
            }
            baselineAvgLatencyMs = estTurnLatencies.reduce(0, +) / Double(estTurnLatencies.count)
            speedSampleCount = profile.sampleCount
            speedBasisLabel = usedTokenNormalized
                ? "同机 \(profile.sampleCount) 条按用量归一化"
                : "同机 \(profile.sampleCount) 条基准实测"
        } else if !comparisonLatencyPairs.isEmpty {
            baselineAvgLatencyMs = comparisonLatencyPairs.map(\.baseline).reduce(0, +) / Double(comparisonLatencyPairs.count)
            latencyRecords = comparisonLatencyPairs.map(\.actual)
            speedSampleCount = comparisonLatencyPairs.count
            speedBasisLabel = "对照样本 \(comparisonLatencyPairs.count) 条"
        }

        let actualTotalLatencyMs = latencyRecords.reduce(0, +)
        let actualAvgLatencyMs = latencyRecords.isEmpty ? 0 : actualTotalLatencyMs / Double(latencyRecords.count)
        let baselineTotalLatencyMs = baselineAvgLatencyMs.map { $0 * Double(latencyRecords.count) }
        var speedSavedMsPerTurn: Double?
        var speedGainPercent: Double?
        var totalTimeSavedSeconds: Double?
        if let baseAvg = baselineAvgLatencyMs, !latencyRecords.isEmpty, baseAvg > 0 {
            let saved = baseAvg - actualAvgLatencyMs
            speedSavedMsPerTurn = saved
            speedGainPercent = (saved / baseAvg) * 100.0
            if let baseTotal = baselineTotalLatencyMs {
                totalTimeSavedSeconds = max(0, (baseTotal - actualTotalLatencyMs) / 1000.0)
            }
        }

        let costedValues = successRecords.compactMap(\.totalCostUSD).filter { $0 > 0 }.sorted(by: >)
        var top10Share: Double?
        if costedValues.count >= 3 {
            let totalPositiveCost = costedValues.reduce(0, +)
            let topCount = max(1, Int(ceil(Double(costedValues.count) * 0.10)))
            let topSum = costedValues.prefix(topCount).reduce(0, +)
            if totalPositiveCost > 0 {
                top10Share = (topSum / totalPositiveCost) * 100.0
            }
        }

        return RoutingImpactSummary(
            baselineModelDisplayName: baseline.displayName,
            evaluatedTurnCount: evaluatedTurnCount,
            actualCostUSD: actualCostSum,
            baselineCostUSD: baselineCostSum,
            costSavedUSD: costSavedUSD,
            costSavingsPercent: costSavingsPercent,
            actualAvgLatencyMs: actualAvgLatencyMs,
            baselineAvgLatencyMs: baselineAvgLatencyMs,
            speedGainPercent: speedGainPercent,
            speedSavedMsPerTurn: speedSavedMsPerTurn,
            totalTimeSavedSeconds: totalTimeSavedSeconds,
            actualTotalLatencyMs: actualTotalLatencyMs,
            baselineTotalLatencyMs: baselineTotalLatencyMs,
            speedSampleCount: speedSampleCount,
            successRatePercent: successRatePct,
            retryCount: retryCount,
            top10PercentCostSharePercent: top10Share,
            speedBasisLabel: speedBasisLabel,
            speedComparedTurnCount: baselineAvgLatencyMs == nil ? 0 : latencyRecords.count
        )
    }
}
