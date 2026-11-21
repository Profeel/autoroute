import Foundation
import XCTest
@testable import AutoModelCore

final class P1BudgetLedgerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }()

    private func date(year: Int, month: Int, day: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func attempt(
        cost: Double?,
        source: UsageDataSource,
        status: CostCalculationStatus = .calculated
    ) -> UpstreamAttemptRecord {
        UpstreamAttemptRecord(
            attemptIndex: 1,
            modelUUID: UUID(),
            modelID: "ledger-model",
            providerID: UUID(),
            providerName: "ledger-provider",
            httpStatusCode: 200,
            succeeded: true,
            firstTokenMs: nil,
            totalLatencyMs: 1,
            usage: source == .unavailable ? nil : TokenUsage(promptTokens: 10, completionTokens: 5),
            usageSource: source,
            usageEstimationMethod: source == .estimatedWhenMissing ? "test estimate" : nil,
            costUSD: cost,
            costStatus: status,
            errorMessage: nil
        )
    }

    private func record(
        at date: Date,
        agent: AgentKind?,
        attempts: [UpstreamAttemptRecord],
        origin: CallExecutionOrigin? = .real
    ) -> CallRecord {
        CallRecord(
            timestamp: date,
            source: .externalProxy,
            status: .success,
            requestedModel: "auto",
            executedModelID: "ledger-model",
            executedModelDisplayName: "Ledger Model",
            executedProviderName: "ledger-provider",
            httpStatusCode: 200,
            requestFeatures: RequestFeatureExtractor.extract(from: [
                "model": "auto",
                "messages": [["role": "user", "content": "ledger test"]]
            ]),
            decision: RoutingDecision(
                requestedModel: "auto",
                isAutoRouted: true,
                strategyName: "均衡模式",
                policyVersion: 1,
                deciderPluginID: "builtin.deterministic.v1",
                decisionDurationMs: 1,
                agentID: agent?.rawValue
            ),
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

    func testLedgerSeparatesPeriodsAgentsCategoriesAndExcludesDemo() {
        var ledger = BudgetLedger()
        ledger.record(record(at: date(year: 2026, month: 11), agent: .codex, attempts: [
            attempt(cost: 2, source: .upstreamReported),
            attempt(cost: 1, source: .estimatedWhenMissing),
            attempt(cost: nil, source: .upstreamReported, status: .missingPriceConfig)
        ]), calendar: calendar)
        ledger.record(record(at: date(year: 2026, month: 11), agent: .opencode, attempts: [
            attempt(cost: 3, source: .upstreamReported)
        ]), calendar: calendar)
        ledger.record(record(at: date(year: 2026, month: 11), agent: .codex, attempts: [
            attempt(cost: 100, source: .upstreamReported)
        ], origin: .demo), calendar: calendar)
        ledger.record(record(at: date(year: 2026, month: 12), agent: .codex, attempts: [
            attempt(cost: 4, source: .upstreamReported)
        ]), calendar: calendar)

        let novemberGlobal = ledger.usage(agentID: nil, period: "2026-11")
        XCTAssertEqual(novemberGlobal.measuredCostUSD, 5, accuracy: 0.0001)
        XCTAssertEqual(novemberGlobal.estimatedCostUSD, 1, accuracy: 0.0001)
        XCTAssertEqual(novemberGlobal.unpricedCallCount, 1)

        let novemberCodex = ledger.usage(agentID: AgentKind.codex.rawValue, period: "2026-11")
        XCTAssertEqual(novemberCodex.measuredCostUSD, 2, accuracy: 0.0001)
        XCTAssertEqual(novemberCodex.estimatedCostUSD, 1, accuracy: 0.0001)
        XCTAssertEqual(novemberCodex.unpricedCallCount, 1)

        let decemberCodex = ledger.usage(agentID: AgentKind.codex.rawValue, period: "2026-12")
        XCTAssertEqual(decemberCodex.measuredCostUSD, 4, accuracy: 0.0001)
        XCTAssertEqual(decemberCodex.estimatedCostUSD, 0, accuracy: 0.0001)
    }

    @MainActor
    func testLedgerOver500RecordsSurvivesEmptyUIHistoryAndStillRejectsAtHardLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteBudgetLedger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        var ledger = BudgetLedger()
        for index in 0..<501 {
            ledger.record(record(
                at: date(year: 2026, month: 11, day: 1).addingTimeInterval(Double(index)),
                agent: .codex,
                attempts: [attempt(cost: 0.1, source: .upstreamReported)]
            ), calendar: calendar)
        }
        try store.saveBudgetLedger(ledger)

        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        let now = date(year: 2026, month: 11)
        XCTAssertTrue(engine.callHistory.isEmpty)
        let usage = engine.monthlyBudgetUsage(now: now)
        XCTAssertEqual(usage.measuredCostUSD, 50.1, accuracy: 0.0001)
        XCTAssertEqual(usage.totalCostUSD, 50.1, accuracy: 0.0001)

        engine.updateGlobalBudget(MonthlyBudgetLimit(limitUSD: 50, warningThreshold: 0.8))
        let outcome = await engine.executeChatCompletion(
            payload: ["model": "ledger-model", "messages": [["role": "user", "content": "blocked"]]],
            source: .externalProxy
        )
        XCTAssertEqual(outcome.httpStatusCode, 429)
        XCTAssertEqual(outcome.callRecord.status, .rejected)

        let reloaded = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        XCTAssertEqual(reloaded.monthlyBudgetUsage(now: now).measuredCostUSD, 50.1, accuracy: 0.0001)
    }

    @MainActor
    func testClearHistoryThrowsOnPersistentFailureAndKeepsMemoryLedgerInSync() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteClearHistory-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        let savedRecord = record(
            at: date(year: 2026, month: 11),
            agent: .codex,
            attempts: [attempt(cost: 2, source: .upstreamReported)]
        )
        try store.saveHistory([savedRecord])
        var ledger = BudgetLedger()
        ledger.record(savedRecord, calendar: calendar)
        try store.saveBudgetLedger(ledger)
        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        XCTAssertEqual(engine.callHistory.count, 1)
        XCTAssertEqual(engine.monthlyBudgetUsage(now: date(year: 2026, month: 11)).measuredCostUSD, 2, accuracy: 0.0001)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try engine.clearCallHistory())
        XCTAssertEqual(engine.callHistory.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.historyFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.budgetLedgerFileURL.path))
        XCTAssertEqual(engine.monthlyBudgetUsage(now: date(year: 2026, month: 11)).measuredCostUSD, 2, accuracy: 0.0001)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try engine.clearCallHistory()
        XCTAssertTrue(engine.callHistory.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.historyFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.budgetLedgerFileURL.path))
        XCTAssertEqual(engine.monthlyBudgetUsage(now: date(year: 2026, month: 11)).totalCostUSD, 0, accuracy: 0.0001)
    }

    @MainActor
    func testEngineWarningUsesSettingsThresholdNotLimitMirror() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteBudgetWarning-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        var ledger = BudgetLedger()
        ledger.record(record(
            at: date(year: 2026, month: 11),
            agent: .codex,
            attempts: [attempt(cost: 8, source: .upstreamReported)]
        ), calendar: calendar)
        try store.saveBudgetLedger(ledger)
        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        engine.updateBudgetWarningThreshold(0.8)
        engine.updateGlobalBudget(MonthlyBudgetLimit(limitUSD: 10, warningThreshold: 0.99))

        let warning = engine.monthlyBudgetWarning(now: date(year: 2026, month: 11))
        XCTAssertEqual(warning.level, .warning)
        XCTAssertEqual(try XCTUnwrap(warning.warningThreshold), 0.8, accuracy: 0.0001)
        XCTAssertNil(MonthlyBudgetEvaluator.rejection(
            usage: engine.monthlyBudgetUsage(now: date(year: 2026, month: 11)),
            limit: MonthlyBudgetLimit(limitUSD: 10)
        ))
    }

    @MainActor
    func testMissingLedgerBackfillsFromExistingHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteBudgetBackfill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        let records = [
            record(at: date(year: 2026, month: 11), agent: .codex, attempts: [
                attempt(cost: 2, source: .upstreamReported)
            ]),
            record(at: date(year: 2026, month: 11), agent: .codex, attempts: [
                attempt(cost: 3, source: .estimatedWhenMissing)
            ])
        ]
        try store.saveHistory(records)

        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        let usage = engine.monthlyBudgetUsage(now: date(year: 2026, month: 11))
        XCTAssertEqual(usage.measuredCostUSD, 2, accuracy: 0.0001)
        XCTAssertEqual(usage.estimatedCostUSD, 3, accuracy: 0.0001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.budgetLedgerFileURL.path))
    }
}