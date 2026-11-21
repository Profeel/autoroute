import XCTest
@testable import AutoModelCore

final class P1BudgetTests: XCTestCase {
    private func record(
        at date: Date,
        agent: AgentKind?,
        attempts: [UpstreamAttemptRecord],
        origin: CallExecutionOrigin? = nil
    ) -> CallRecord {
        let features = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [["role": "user", "content": "budget test"]]
        ])
        let decision = RoutingDecision(
            requestedModel: "auto",
            isAutoRouted: true,
            strategyName: "均衡模式",
            policyVersion: 1,
            deciderPluginID: "builtin.deterministic.v1",
            decisionDurationMs: 1,
            agentID: agent?.rawValue
        )
        return CallRecord(
            timestamp: date,
            source: .externalProxy,
            status: attempts.allSatisfy(\.succeeded) ? .success : .failed,
            requestedModel: "auto",
            executedModelID: attempts.last?.modelID,
            executedModelDisplayName: nil,
            executedProviderName: nil,
            httpStatusCode: 200,
            requestFeatures: features,
            decision: decision,
            attempts: attempts,
            routingDecisionMs: 1,
            upstreamFirstTokenMs: nil,
            totalCompletionMs: 2,
            finalUsage: attempts.last?.usage,
            usageSource: attempts.last?.usageSource ?? .unavailable,
            usageEstimationMethod: nil,
            costStatus: attempts.last?.costStatus ?? .noUsage,
            primaryAttemptCostUSD: attempts.first?.costUSD,
            retryAttemptsCostUSD: attempts.dropFirst().compactMap(\.costUSD).reduce(0, +),
            totalCostUSD: attempts.compactMap(\.costUSD).reduce(0, +),
            executionOrigin: origin
        )
    }

    private func attempt(
        cost: Double?,
        source: UsageDataSource,
        succeeded: Bool = true,
        status: CostCalculationStatus = .calculated
    ) -> UpstreamAttemptRecord {
        UpstreamAttemptRecord(
            attemptIndex: 1,
            modelUUID: UUID(),
            modelID: "model",
            providerID: UUID(),
            providerName: "provider",
            httpStatusCode: succeeded ? 200 : 500,
            succeeded: succeeded,
            firstTokenMs: nil,
            totalLatencyMs: 1,
            usage: source == .unavailable ? nil : TokenUsage(promptTokens: 10, completionTokens: 5),
            usageSource: source,
            usageEstimationMethod: source == .estimatedWhenMissing ? "test estimate" : nil,
            costUSD: cost,
            costStatus: status,
            errorMessage: succeeded ? nil : "upstream failed"
        )
    }

    func testNaturalMonthUsageSeparatesMeasuredEstimatedUnpricedAndRetries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let november = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!
        let october = november.addingTimeInterval(-31 * 24 * 3600)
        let records = [
            record(at: november, agent: .codex, attempts: [
                attempt(cost: 2, source: .upstreamReported),
                attempt(cost: 1, source: .estimatedWhenMissing, succeeded: false),
                attempt(cost: nil, source: .upstreamReported, status: .missingPriceConfig)
            ]),
            record(at: november, agent: .opencode, attempts: [attempt(cost: 4, source: .upstreamReported)]),
            record(at: october, agent: .codex, attempts: [attempt(cost: 100, source: .upstreamReported)])
        ]

        let global = MonthlyBudgetEvaluator.usage(callHistory: records, agentID: nil, now: november, calendar: calendar)
        XCTAssertEqual(global.period, "2026-11")
        XCTAssertEqual(global.measuredCostUSD, 6, accuracy: 0.0001)
        XCTAssertEqual(global.estimatedCostUSD, 1, accuracy: 0.0001)
        XCTAssertEqual(global.totalCostUSD, 7, accuracy: 0.0001)
        XCTAssertEqual(global.unpricedCallCount, 1)

        let codex = MonthlyBudgetEvaluator.usage(callHistory: records, agentID: AgentKind.codex.rawValue, now: november, calendar: calendar)
        XCTAssertEqual(codex.measuredCostUSD, 2, accuracy: 0.0001)
        XCTAssertEqual(codex.estimatedCostUSD, 1, accuracy: 0.0001)
        XCTAssertEqual(codex.unpricedCallCount, 1)

        let rejection = MonthlyBudgetEvaluator.rejection(
            usage: codex,
            limit: MonthlyBudgetLimit(limitUSD: 3, warningThreshold: 0.8)
        )
        XCTAssertEqual(rejection?.code, "budget_exceeded")
        XCTAssertEqual(rejection?.statusCode, 429)
        XCTAssertTrue(rejection?.message.contains("2026-11") == true)
    }

    func testDemoUsageNeverCountsOrBlocksGlobalAndAgentBudgets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let november = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!
        let records = [
            record(at: november, agent: .codex, attempts: [
                attempt(cost: 10, source: .upstreamReported),
                attempt(cost: 5, source: .estimatedWhenMissing),
                attempt(cost: nil, source: .upstreamReported, status: .missingPriceConfig)
            ], origin: .demo),
            record(at: november, agent: .codex, attempts: [
                attempt(cost: 1, source: .upstreamReported)
            ], origin: .real),
            record(at: november, agent: .opencode, attempts: [
                attempt(cost: 100, source: .upstreamReported)
            ], origin: .demo)
        ]

        let global = MonthlyBudgetEvaluator.usage(callHistory: records, agentID: nil, now: november, calendar: calendar)
        XCTAssertEqual(global.measuredCostUSD, 1, accuracy: 0.0001)
        XCTAssertEqual(global.estimatedCostUSD, 0, accuracy: 0.0001)
        XCTAssertEqual(global.unpricedCallCount, 0)
        XCTAssertNil(MonthlyBudgetEvaluator.rejection(usage: global, limit: MonthlyBudgetLimit(limitUSD: 2)))

        let codex = MonthlyBudgetEvaluator.usage(callHistory: records, agentID: AgentKind.codex.rawValue, now: november, calendar: calendar)
        XCTAssertEqual(codex.measuredCostUSD, 1, accuracy: 0.0001)
        XCTAssertEqual(codex.estimatedCostUSD, 0, accuracy: 0.0001)
        XCTAssertEqual(codex.unpricedCallCount, 0)

        let openCode = MonthlyBudgetEvaluator.usage(callHistory: records, agentID: AgentKind.opencode.rawValue, now: november, calendar: calendar)
        XCTAssertEqual(openCode.totalCostUSD, 0, accuracy: 0.0001)
        XCTAssertEqual(openCode.unpricedCallCount, 0)
        XCTAssertNil(MonthlyBudgetEvaluator.rejection(usage: openCode, limit: MonthlyBudgetLimit(limitUSD: 1)))
    }

    @MainActor
    func testEngineRejectsAtGlobalAndAgentBudgetBeforeRouting() async throws {
        let store = LocalPersistenceStore(
            baseDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        engine.updateGlobalBudget(MonthlyBudgetLimit(limitUSD: 0, warningThreshold: 0.8))

        let outcome = await engine.executeChatCompletion(
            payload: ["model": "auto", "messages": [["role": "user", "content": "must not route"]]],
            source: .externalProxy
        )
        XCTAssertEqual(outcome.httpStatusCode, 429)
        XCTAssertEqual(outcome.callRecord.status, .rejected)
        XCTAssertEqual(outcome.callRecord.attempts.count, 0)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.responseBody) as? [String: Any])
        XCTAssertEqual((body["error"] as? [String: Any])?["code"] as? String, "budget_exceeded")

        engine.updateGlobalBudget(nil)
        engine.updateAgentBudget(MonthlyBudgetLimit(limitUSD: 0, warningThreshold: 0.8), for: .codex)
        let codex = await engine.executeChatCompletion(
            payload: ["model": "auto/agent/codex", "messages": [["role": "user", "content": "must not route"]]],
            source: .externalProxy
        )
        XCTAssertEqual(codex.httpStatusCode, 429)
        let other = await engine.executeChatCompletion(
            payload: ["model": "auto/agent/opencode", "messages": [["role": "user", "content": "routes independently"]]],
            source: .externalProxy
        )
        XCTAssertEqual(other.httpStatusCode, 503)
    }

    func testBudgetWarningThresholdIsNonBlockingAndCoversAllBoundaries() {
        let usage = MonthlyBudgetUsage(
            period: "2026-11",
            measuredCostUSD: 7,
            estimatedCostUSD: 1,
            unpricedCallCount: 2
        )
        let limit = MonthlyBudgetLimit(limitUSD: 10, warningThreshold: 0.8)

        let below = MonthlyBudgetEvaluator.warning(
            usage: MonthlyBudgetUsage(period: "2026-11", measuredCostUSD: 5, estimatedCostUSD: 2, unpricedCallCount: 0),
            limit: limit,
            warningThreshold: 0.8
        )
        XCTAssertEqual(below.level, .normal)
        XCTAssertFalse(below.hasReachedThreshold)
        XCTAssertFalse(below.hasReachedHardLimit)

        let atThreshold = MonthlyBudgetEvaluator.warning(usage: usage, limit: limit, warningThreshold: 0.8)
        XCTAssertEqual(atThreshold.level, .warning)
        XCTAssertTrue(atThreshold.hasReachedThreshold)
        XCTAssertFalse(atThreshold.hasReachedHardLimit)
        XCTAssertEqual(atThreshold.accountedCostUSD, 8, accuracy: 0.0001)
        XCTAssertEqual(atThreshold.period, "2026-11")
        XCTAssertEqual(atThreshold.limitUSD, 10)
        XCTAssertNil(MonthlyBudgetEvaluator.rejection(usage: usage, limit: limit), "warning must not block")

        let settingsAuthoritative = MonthlyBudgetEvaluator.warning(
            usage: usage,
            limit: MonthlyBudgetLimit(limitUSD: 10, warningThreshold: 0.99),
            warningThreshold: 0.8
        )
        XCTAssertEqual(settingsAuthoritative.level, .warning)
        XCTAssertEqual(settingsAuthoritative.warningThreshold, 0.8)
        XCTAssertNil(MonthlyBudgetEvaluator.rejection(usage: usage, limit: limit), "settings warning must not block")

        let hardUsage = MonthlyBudgetUsage(period: "2026-11", measuredCostUSD: 9, estimatedCostUSD: 1, unpricedCallCount: 0)
        let atHardLimit = MonthlyBudgetEvaluator.warning(usage: hardUsage, limit: limit, warningThreshold: 0.8)
        XCTAssertEqual(atHardLimit.level, .hardLimit)
        XCTAssertTrue(atHardLimit.hasReachedHardLimit)
        XCTAssertNotNil(MonthlyBudgetEvaluator.rejection(usage: hardUsage, limit: limit))

        let unlimited = MonthlyBudgetEvaluator.warning(usage: usage, limit: nil, warningThreshold: 0.8)
        XCTAssertEqual(unlimited.level, .unlimited)
        XCTAssertNil(unlimited.limitUSD)
        XCTAssertFalse(unlimited.hasReachedThreshold)
        XCTAssertFalse(unlimited.hasReachedHardLimit)
    }

    func testMissingBudgetConfigFieldsMigrateToUnlimited() throws {
        let config = try JSONDecoder().decode(AppConfigBundle.self, from: Data("{}".utf8))
        XCTAssertNil(config.budgetSettings.global)
        XCTAssertTrue(config.budgetSettings.agentLimits.isEmpty)
        XCTAssertEqual(config.budgetSettings.warningThreshold, 0.8, accuracy: 0.0001)
    }
}
