import Foundation
import XCTest
@testable import AutoModelCore

final class DailyUsageLedgerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }()

    private func date(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func makeRecord(
        at timestamp: Date,
        status: CallStatus = .success,
        promptTokens: Int = 100,
        completionTokens: Int = 50,
        costUSD: Double? = 0.01
    ) -> CallRecord {
        let usage = TokenUsage(promptTokens: promptTokens, completionTokens: completionTokens)
        let attempt = UpstreamAttemptRecord(
            attemptIndex: 1,
            modelUUID: UUID(),
            modelID: "test-model",
            providerID: UUID(),
            providerName: "test-provider",
            httpStatusCode: status == .success ? 200 : 500,
            succeeded: status == .success,
            firstTokenMs: 10,
            totalLatencyMs: 20,
            usage: usage,
            usageSource: .upstreamReported,
            usageEstimationMethod: nil,
            costUSD: costUSD,
            costStatus: costUSD == nil ? .missingPriceConfig : .calculated,
            errorMessage: nil
        )
        return CallRecord(
            timestamp: timestamp,
            source: .externalProxy,
            status: status,
            requestedModel: "auto",
            executedModelID: "test-model",
            executedModelDisplayName: "Test Model",
            executedProviderName: "test-provider",
            httpStatusCode: status == .success ? 200 : 500,
            requestFeatures: RequestFeatureExtractor.extract(from: [
                "model": "auto",
                "messages": [["role": "user", "content": "daily usage test"]]
            ]),
            decision: RoutingDecision(
                requestedModel: "auto",
                isAutoRouted: true,
                strategyName: "均衡模式",
                policyVersion: 1,
                deciderPluginID: "builtin.deterministic.v1",
                decisionDurationMs: 1
            ),
            attempts: [attempt],
            routingDecisionMs: 1,
            upstreamFirstTokenMs: 10,
            totalCompletionMs: 20,
            finalUsage: usage,
            usageSource: .upstreamReported,
            usageEstimationMethod: nil,
            costStatus: costUSD == nil ? .missingPriceConfig : .calculated,
            primaryAttemptCostUSD: costUSD,
            retryAttemptsCostUSD: 0,
            totalCostUSD: costUSD,
            executionOrigin: .real
        )
    }

    func testLedgerSeparatesDaysAndAccumulatesCumulativeSummary() {
        var ledger = DailyUsageLedger()
        let day1 = date(year: 2026, month: 11, day: 18)
        let day2 = date(year: 2026, month: 11, day: 19)

        ledger.record(makeRecord(at: day1, status: .success, promptTokens: 200, completionTokens: 100, costUSD: 0.05), calendar: calendar)
        ledger.record(makeRecord(at: day1, status: .failed, promptTokens: 50, completionTokens: 0, costUSD: 0.01), calendar: calendar)
        ledger.record(makeRecord(at: day2, status: .success, promptTokens: 300, completionTokens: 150, costUSD: 0.08), calendar: calendar)

        let summary1 = ledger.summary(for: day1, calendar: calendar)
        XCTAssertEqual(summary1.callCount, 2)
        XCTAssertEqual(summary1.successCount, 1)
        XCTAssertEqual(summary1.totalTokens, 350)
        XCTAssertEqual(summary1.promptTokens, 250)
        XCTAssertEqual(summary1.completionTokens, 100)
        XCTAssertEqual(summary1.totalCostUSD, 0.06, accuracy: 0.0001)

        let summary2 = ledger.summary(for: day2, calendar: calendar)
        XCTAssertEqual(summary2.callCount, 1)
        XCTAssertEqual(summary2.successCount, 1)
        XCTAssertEqual(summary2.totalTokens, 450)
        XCTAssertEqual(summary2.totalCostUSD, 0.08, accuracy: 0.0001)

        let cumulative = ledger.cumulativeSummary()
        XCTAssertEqual(cumulative.callCount, 3)
        XCTAssertEqual(cumulative.successCount, 2)
        XCTAssertEqual(cumulative.totalTokens, 800)
        XCTAssertEqual(cumulative.totalCostUSD, 0.14, accuracy: 0.0001)
    }

    @MainActor
    func testMissingDailyLedgerBackfillsFrom500HistoryAndIncrementsPast500() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteDailyUsage500-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        let now = Date()
        let initial500 = (0..<500).map { offset in
            makeRecord(
                at: now.addingTimeInterval(-Double(offset) * 0.01),
                status: .success,
                promptTokens: 100,
                completionTokens: 50,
                costUSD: 0.01
            )
        }
        try store.saveHistory(initial500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.dailyUsageLedgerFileURL.path))

        let upstream = LoopbackHTTPServer { _, writer in
            writer.sendJSON(
                statusCode: 200,
                body: Data("{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":200,\"completion_tokens\":100}}".utf8)
            )
        }
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }

        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        XCTAssertEqual(engine.callHistory.count, 500)
        XCTAssertEqual(engine.todayUsageSummary().callCount, 500)
        XCTAssertEqual(engine.todayUsageSummary().totalTokens, 500 * 150)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.dailyUsageLedgerFileURL.path))

        let provider = ProviderConfig(name: "fixture", baseURL: "http://127.0.0.1:\(port)", healthStatus: .healthy)
        try engine.upsertProvider(provider, apiKey: nil)
        let model = ModelConfig(
            providerID: provider.id,
            modelID: "daily-model",
            inputPricePerMillion: 1_000,
            outputPricePerMillion: 1_000,
            capabilities: [.chat],
            availabilityStatus: .available
        )
        engine.upsertModel(model)

        for _ in 0..<5 {
            let outcome = await engine.executeChatCompletion(
                payload: ["model": model.modelID, "messages": [["role": "user", "content": "ping"]]],
                source: .externalProxy
            )
            XCTAssertEqual(outcome.httpStatusCode, 200)
        }
        try await store.flush()

        XCTAssertEqual(engine.callHistory.count, 500, "UI callHistory remains capped at 500")
        let today = engine.todayUsageSummary()
        XCTAssertEqual(today.callCount, 505, "Today turn count must continue incrementing past 500")
        XCTAssertEqual(today.successCount, 505)
        XCTAssertEqual(today.totalTokens, 500 * 150 + 5 * 300)
        XCTAssertEqual(today.totalCostUSD, 500 * 0.01 + 5 * 0.3, accuracy: 0.0001)

        // Reload engine from disk and verify count > 500 persists across restart.
        let reloaded = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: directory),
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        XCTAssertEqual(reloaded.callHistory.count, 500)
        XCTAssertEqual(reloaded.todayUsageSummary().callCount, 505)
        XCTAssertEqual(reloaded.todayUsageSummary().totalTokens, 500 * 150 + 5 * 300)
        XCTAssertEqual(reloaded.cumulativeUsageSummary().callCount, 505)
    }

    @MainActor
    func testClearHistoryClearsDailyUsageAndRollsBackOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteClearDailyUsage-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = LocalPersistenceStore(baseDirectoryURL: directory)
        let savedRecord = makeRecord(at: Date(), promptTokens: 40, completionTokens: 20, costUSD: 0.25)
        try store.saveHistory([savedRecord])
        var ledger = DailyUsageLedger()
        ledger.record(savedRecord)
        try store.saveDailyUsageLedger(ledger)

        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        XCTAssertEqual(engine.todayUsageSummary().callCount, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try engine.clearCallHistory())
        XCTAssertEqual(engine.todayUsageSummary().callCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.dailyUsageLedgerFileURL.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try engine.clearCallHistory()
        XCTAssertEqual(engine.todayUsageSummary().callCount, 0)
        XCTAssertEqual(engine.cumulativeUsageSummary().callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.dailyUsageLedgerFileURL.path))
    }
}
