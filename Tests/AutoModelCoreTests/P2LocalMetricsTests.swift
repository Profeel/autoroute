import XCTest
@testable import AutoModelCore

final class P2LocalMetricsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmptySingleSampleAndSevenDayActivityAreWellDefined() throws {
        let empty = LocalProductMetricsCalculator.calculate(
            records: [],
            funnel: LocalOnboardingFunnelState(),
            now: now
        )
        XCTAssertEqual(empty.realRouteSampleCount, 0)
        XCTAssertEqual(empty.activeDaysLast7, 0)
        XCTAssertNil(empty.firstRealRouteSuccessRate)
        XCTAssertNil(empty.routingP50Ms)
        XCTAssertNil(empty.routingP95Ms)
        XCTAssertNil(empty.fallbackRecoveryRate)

        let current = record(id: "current", timestamp: now.addingTimeInterval(-3600), routingMs: 10)
        let old = record(id: "old", timestamp: now.addingTimeInterval(-8 * 24 * 3600), routingMs: 90)
        let metrics = LocalProductMetricsCalculator.calculate(
            records: [current, old],
            funnel: LocalOnboardingFunnelState(),
            now: now
        )
        XCTAssertEqual(metrics.realRouteSampleCount, 2)
        XCTAssertEqual(metrics.activeDaysLast7, 1)
        XCTAssertEqual(metrics.routingLatencySampleCount, 2)
        XCTAssertEqual(try XCTUnwrap(metrics.routingP50Ms), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(metrics.routingP95Ms), 90, accuracy: 0.001)
        XCTAssertEqual(metrics.lastRealRouteAt, current.timestamp)
    }

    func testDemoLegacyRecoveryUsageAndCostStaySeparate() throws {
        var recovered = record(id: "recovered", timestamp: now.addingTimeInterval(-7200), routingMs: 4)
        recovered.attempts = [
            attempt(model: "primary", succeeded: false),
            attempt(model: "backup", succeeded: true)
        ]
        recovered.comparison = ComparisonAnalysis(
            basis: .realABTest,
            baselineModelID: "baseline",
            baselineModelDisplayName: "Baseline",
            costDifferenceUSD: 0.4,
            costSavingsPercent: 40,
            latencyDifferenceMs: 20,
            sampleCount: 1,
            note: "controlled real A/B",
            isMeasuredPair: true
        )

        var estimatedAB = record(id: "estimated-ab", timestamp: now.addingTimeInterval(-7600), routingMs: 5)
        estimatedAB.source = .testBench
        estimatedAB.comparison = ComparisonAnalysis(
            basis: .realABTest,
            baselineModelID: "baseline",
            baselineModelDisplayName: "Baseline",
            costDifferenceUSD: 0.9,
            costSavingsPercent: 50,
            latencyDifferenceMs: 10,
            sampleCount: 1,
            note: "estimated retry must not count as measured",
            isMeasuredPair: false
        )

        var historical = record(id: "historical", timestamp: now.addingTimeInterval(-8000), routingMs: 6)
        historical.usageSource = .estimatedWhenMissing
        historical.comparison = ComparisonAnalysis(
            basis: .historicalEstimate,
            baselineModelID: "baseline",
            baselineModelDisplayName: "Baseline",
            costDifferenceUSD: 0.2,
            costSavingsPercent: nil,
            latencyDifferenceMs: nil,
            sampleCount: 2,
            note: "historical estimate"
        )

        var missing = record(id: "missing", timestamp: now.addingTimeInterval(-9000), routingMs: 8)
        missing.finalUsage = nil
        missing.usageSource = .unavailable
        missing.totalCostUSD = nil
        missing.costStatus = .missingPriceConfig

        var demo = record(id: "demo", timestamp: now, routingMs: 100)
        demo.executionOrigin = .demo
        var legacy = record(id: "legacy", timestamp: now, routingMs: 100)
        legacy.executionOrigin = nil
        var testBench = record(id: "test-bench", timestamp: now, routingMs: 100)
        testBench.source = .testBench

        let metrics = LocalProductMetricsCalculator.calculate(
            records: [recovered, estimatedAB, historical, missing, demo, legacy, testBench],
            funnel: LocalOnboardingFunnelState(),
            now: now
        )
        XCTAssertEqual(metrics.realRouteSampleCount, 3)
        XCTAssertEqual(metrics.demoRouteSampleCount, 1)
        XCTAssertEqual(metrics.unclassifiedRouteSampleCount, 1)
        XCTAssertEqual(metrics.fallbackEligibleSampleCount, 1)
        XCTAssertEqual(metrics.fallbackRecoveredSampleCount, 1)
        XCTAssertEqual(try XCTUnwrap(metrics.fallbackRecoveryRate), 1, accuracy: 0.001)
        XCTAssertEqual(metrics.realABPricedSampleCount, 1)
        XCTAssertEqual(try XCTUnwrap(metrics.realABMeasuredCostDifferenceUSD), 0.4, accuracy: 0.001)
        XCTAssertEqual(metrics.historicalPricedSampleCount, 1)
        XCTAssertEqual(try XCTUnwrap(metrics.historicalEstimatedCostDifferenceUSD), 0.2, accuracy: 0.001)
        XCTAssertEqual(metrics.missingUsageSampleCount, 1)
        XCTAssertEqual(metrics.missingPriceSampleCount, 1)
    }

    @MainActor
    func testEngineRealABFeedsCostMetricsWithoutCountingAsExternalRouteActivity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteRealABMetrics-\(UUID().uuidString)", isDirectory: true)
        let upstream = LocalTestUpstreamServer()
        let upstreamPort = try upstream.start(port: 0)
        defer { upstream.stop() }
        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: directory),
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        let provider = ProviderConfig(
            name: "Independent A/B Upstream",
            baseURL: "http://127.0.0.1:\(upstreamPort)",
            isEnabled: true,
            timeoutSeconds: 10,
            healthStatus: .healthy
        )
        try engine.upsertProvider(provider, apiKey: "ab-metrics-key")
        let cheap = ModelConfig(
            providerID: provider.id,
            modelID: "cheap-auto",
            displayName: "Cheap Auto",
            isEnabled: true,
            inputPricePerMillion: 1,
            outputPricePerMillion: 2,
            capabilities: [.chat],
            availabilityStatus: .available
        )
        let baseline = ModelConfig(
            providerID: provider.id,
            modelID: "expensive-baseline",
            displayName: "Expensive Baseline",
            isEnabled: true,
            inputPricePerMillion: 10,
            outputPricePerMillion: 20,
            capabilities: [.chat],
            availabilityStatus: .available
        )
        engine.upsertModel(cheap)
        engine.upsertModel(baseline)
        for tier in ModelTier.allCases {
            engine.setTierModel(tier: tier, modelUUID: cheap.id)
        }

        let report = await engine.runABExperiment(
            baselineModel: baseline,
            prompt: "public-text-v1 deterministic local A/B sample",
            repetitions: 1
        )
        XCTAssertEqual(report.summary.comparablePricedPairs, 1)
        XCTAssertEqual(report.samples.map(\.side), [.auto, .baseline])
        let expectedDifference = try XCTUnwrap(report.summary.measuredCostDifferenceUSD)
        XCTAssertGreaterThan(expectedDifference, 0)

        let metrics = engine.localProductMetrics(now: Date())
        XCTAssertEqual(metrics.realRouteSampleCount, 0, "testBench A/B must not inflate external route activity")
        XCTAssertEqual(metrics.activeDaysLast7, 0)
        XCTAssertEqual(metrics.routingLatencySampleCount, 0)
        XCTAssertEqual(metrics.realABPricedSampleCount, 1)
        XCTAssertEqual(try XCTUnwrap(metrics.realABMeasuredCostDifferenceUSD), expectedDifference, accuracy: 0.000001)
    }

    func testOnboardingFunnelDeduplicatesStartAndOnlyRealSuccessCompletes() {
        var funnel = LocalOnboardingFunnelState()
        funnel.recordStart(at: now)
        funnel.recordStart(at: now.addingTimeInterval(1))
        funnel.recordDemoValidation()
        XCTAssertEqual(funnel.startedCount, 1)
        XCTAssertEqual(funnel.demoValidationCount, 1)
        XCTAssertTrue(funnel.isAwaitingFirstRealRoute)
        XCTAssertEqual(try XCTUnwrap(funnel.firstRealRouteSuccessRate), 0, accuracy: 0.001)

        funnel.recordRealSuccess(at: now.addingTimeInterval(2))
        funnel.recordRealSuccess(at: now.addingTimeInterval(3))
        XCTAssertEqual(funnel.firstRealSuccessCount, 1)
        XCTAssertEqual(try XCTUnwrap(funnel.firstRealRouteSuccessRate), 1, accuracy: 0.001)
        XCTAssertFalse(funnel.isAwaitingFirstRealRoute)

        funnel.recordStart(at: now.addingTimeInterval(4))
        funnel.recordSkip()
        XCTAssertEqual(funnel.startedCount, 2)
        XCTAssertEqual(funnel.firstRealSuccessCount, 1)
        XCTAssertEqual(try XCTUnwrap(funnel.firstRealRouteSuccessRate), 0.5, accuracy: 0.001)
    }

    @MainActor
    func testEnginePersistsMinimalFunnelAndClearHistoryResetsMetrics() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteMetricsTests-\(UUID().uuidString)", isDirectory: true)
        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: directory),
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        defer {
            engine.stopProxy()
            engine.stopLocalTestUpstream()
        }
        engine.recordOnboardingStarted()
        engine.recordOnboardingStarted()
        try engine.installLocalTestPreset()
        let proxyPort = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 22_300))
        engine.updateProxyPort(proxyPort)
        let result = try await engine.validateOnboardingEndToEnd()
        XCTAssertTrue(result.isDemo)
        XCTAssertEqual(result.record.executionOrigin, .demo)
        XCTAssertEqual(engine.onboardingFunnel.startedCount, 1)
        XCTAssertEqual(engine.onboardingFunnel.firstRealSuccessCount, 0)
        XCTAssertEqual(engine.onboardingFunnel.demoValidationCount, 1)
        XCTAssertEqual(engine.localProductMetrics(now: now).demoRouteSampleCount, 1)

        try engine.clearCallHistory()
        XCTAssertEqual(engine.onboardingFunnel, LocalOnboardingFunnelState())
        XCTAssertEqual(engine.localProductMetrics(now: now).realRouteSampleCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.persistence.metricsFileURL.path))
        engine.stopProxy()
        engine.stopLocalTestUpstream()
    }

    func testAggregateExportRoundTripsWithoutBodyOrCredentialFields() throws {
        let record = record(id: "private", timestamp: now, routingMs: 3)
        let metrics = LocalProductMetricsCalculator.calculate(
            records: [record],
            funnel: LocalOnboardingFunnelState(),
            now: now
        )
        let export = LocalProductMetricsExport(metrics: metrics, records: [record], now: now)
        let data = try export.jsonData()
        let json = String(decoding: data, as: UTF8.self)
        for forbidden in ["private-prompt-sentinel", "requestPreview", "responsePreview", "reasoningPreview", "apiKey", "Authorization", "token"] {
            XCTAssertFalse(json.contains(forbidden), "unexpected sensitive field: \(forbidden)")
        }
        let decoded = try JSONDecoder().decode(LocalProductMetricsExport.self, from: data)
        XCTAssertEqual(decoded, export)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.definitionVersion, "local-product-metrics-v1")

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AutoModelCore/LocalProductMetrics.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("URLSession"))
        XCTAssertFalse(source.contains("URLRequest"))
    }

    private func record(id: String, timestamp: Date, routingMs: Double) -> CallRecord {
        let usage = TokenUsage(promptTokens: 10, completionTokens: 5)
        let successfulAttempt = attempt(model: id, succeeded: true)
        return CallRecord(
            timestamp: timestamp,
            source: .externalProxy,
            status: .success,
            requestedModel: "auto",
            executedModelID: id,
            executedModelDisplayName: id,
            executedProviderName: "controlled",
            httpStatusCode: 200,
            requestFeatures: RequestFeatureExtractor.extract(from: [
                "model": "auto",
                "messages": [["role": "user", "content": "private-prompt-sentinel"]]
            ]),
            decision: RoutingDecision(
                requestedModel: "auto",
                isAutoRouted: true,
                selectedModelID: id,
                strategyName: "均衡模式",
                policyVersion: 1,
                deciderPluginID: "builtin.deterministic.v1",
                decisionDurationMs: routingMs
            ),
            attempts: [successfulAttempt],
            routingDecisionMs: routingMs,
            upstreamFirstTokenMs: 2,
            totalCompletionMs: 10,
            finalUsage: usage,
            usageSource: .upstreamReported,
            usageEstimationMethod: nil,
            costStatus: .calculated,
            primaryAttemptCostUSD: 0.1,
            retryAttemptsCostUSD: 0,
            totalCostUSD: 0.1,
            requestPreview: "private-prompt-sentinel",
            responsePreview: "private-response-sentinel",
            executionOrigin: .real
        )
    }

    private func attempt(model: String, succeeded: Bool) -> UpstreamAttemptRecord {
        UpstreamAttemptRecord(
            attemptIndex: succeeded ? 2 : 1,
            modelUUID: UUID(),
            modelID: model,
            providerID: UUID(),
            providerName: "controlled",
            httpStatusCode: succeeded ? 200 : 503,
            succeeded: succeeded,
            firstTokenMs: succeeded ? 2 : nil,
            totalLatencyMs: 5,
            usage: succeeded ? TokenUsage(promptTokens: 10, completionTokens: 5) : nil,
            usageSource: succeeded ? .upstreamReported : .unavailable,
            usageEstimationMethod: nil,
            costUSD: succeeded ? 0.1 : nil,
            costStatus: succeeded ? .calculated : .noUsage,
            errorMessage: succeeded ? nil : "retryable"
        )
    }
}
