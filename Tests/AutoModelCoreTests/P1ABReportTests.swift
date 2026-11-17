import XCTest
@testable import AutoModelCore

final class P1ABReportTests: XCTestCase {
    private func record(for request: ABRunRequest, cost: Double, latency: Double, usageSource: UsageDataSource = .upstreamReported) -> CallRecord {
        let features = RequestFeatureExtractor.extract(from: [
            "model": request.requestedModel,
            "messages": [["role": "user", "content": "private-prompt-sentinel"]]
        ])
        let usage = TokenUsage(promptTokens: 100, completionTokens: 20)
        let attempt = UpstreamAttemptRecord(
            attemptIndex: 1,
            modelUUID: UUID(),
            modelID: request.side == .auto ? "cheap-model" : "baseline-model",
            providerID: UUID(),
            providerName: "controlled-upstream",
            httpStatusCode: 200,
            succeeded: true,
            firstTokenMs: latency / 2,
            totalLatencyMs: latency,
            usage: usage,
            usageSource: usageSource,
            usageEstimationMethod: usageSource == .estimatedWhenMissing ? "character estimate" : nil,
            costUSD: cost,
            costStatus: .calculated,
            errorMessage: nil
        )
        return CallRecord(
            source: .testBench,
            status: .success,
            requestedModel: request.requestedModel,
            executedModelID: attempt.modelID,
            executedModelDisplayName: attempt.modelID,
            executedProviderName: attempt.providerName,
            httpStatusCode: 200,
            requestFeatures: features,
            decision: RoutingDecision(
                requestedModel: request.requestedModel,
                isAutoRouted: request.side == .auto,
                selectedModelID: attempt.modelID,
                strategyName: "均衡模式",
                policyVersion: 7,
                deciderPluginID: "builtin.deterministic.v1",
                decisionDurationMs: 2
            ),
            attempts: [attempt],
            routingDecisionMs: 2,
            upstreamFirstTokenMs: latency / 2,
            totalCompletionMs: latency,
            finalUsage: usage,
            usageSource: usageSource,
            usageEstimationMethod: attempt.usageEstimationMethod,
            costStatus: .calculated,
            primaryAttemptCostUSD: cost,
            retryAttemptsCostUSD: 0,
            totalCostUSD: cost,
            requestPreview: "private-prompt-sentinel"
        )
    }

    private func record(
        for request: ABRunRequest,
        attempts: [(source: UsageDataSource, cost: Double)],
        latency: Double
    ) -> CallRecord {
        var record = record(for: request, cost: 0, latency: latency)
        let usage = TokenUsage(promptTokens: 100, completionTokens: 20)
        record.attempts = attempts.enumerated().map { index, item in
            UpstreamAttemptRecord(
                attemptIndex: index + 1,
                modelUUID: UUID(),
                modelID: request.side == .auto ? "cheap-model" : "baseline-model",
                providerID: UUID(),
                providerName: "controlled-upstream",
                httpStatusCode: 200,
                succeeded: true,
                firstTokenMs: latency / 2,
                totalLatencyMs: latency,
                usage: usage,
                usageSource: item.source,
                usageEstimationMethod: item.source == .estimatedWhenMissing ? "character estimate" : nil,
                costUSD: item.cost,
                costStatus: .calculated,
                errorMessage: nil
            )
        }
        let costs = attempts.map(\.cost)
        record.primaryAttemptCostUSD = costs.first
        record.retryAttemptsCostUSD = costs.dropFirst().reduce(0, +)
        record.totalCostUSD = costs.reduce(0, +)
        record.usageSource = attempts.last?.source ?? .unavailable
        return record
    }

    func testRepeatedInterleavedRunsHaveIndependentSessionsAndStableHonestReport() async throws {
        let requestParameters = ABRequestParameters(
            endpointPath: "engine://ab-experiment",
            stream: false,
            messageCount: 1,
            promptCharacterCount: 42,
            includesTools: false,
            includesVision: false
        )
        let configuration = ABExperimentConfiguration(
            baselineModelID: "baseline-model",
            autoRequestedModel: "auto",
            repetitions: 3,
            policyVersion: 7,
            sampleVersion: "public-text-v1",
            agentID: AgentKind.codex.rawValue,
            policyStrategyName: "均衡模式",
            requestParameters: requestParameters,
            qualityAssessmentMethod: .notAssessed
        )
        let runner = ABExperimentRunner()
        var observedRequests: [ABRunRequest] = []
        let report = await runner.run(configuration: configuration) { request in
            observedRequests.append(request)
            return self.record(
                for: request,
                cost: request.side == .auto ? 0.2 : 0.5,
                latency: request.side == .auto ? 20 : 40
            )
        }

        XCTAssertEqual(observedRequests.count, 6)
        XCTAssertTrue(observedRequests.allSatisfy { $0.parameters == requestParameters })
        XCTAssertEqual(Set(observedRequests.map(\.sessionID)).count, 6)
        XCTAssertEqual(observedRequests.filter { $0.side == .auto }.map(\.requestedModel), Array(repeating: "auto", count: 3))
        XCTAssertEqual(report.requestParameters, requestParameters)
        XCTAssertEqual(report.policyStrategyName, "均衡模式")
        XCTAssertEqual(report.agentID, AgentKind.codex.rawValue)
        XCTAssertEqual(report.samples.count, 6)
        XCTAssertEqual(report.samples.map(\.side), [.auto, .baseline, .baseline, .auto, .auto, .baseline])
        XCTAssertEqual(Set(report.samples.map(\.sessionID)).count, 6)
        XCTAssertEqual(report.summary.comparablePricedPairs, 3)
        XCTAssertEqual(try XCTUnwrap(report.summary.measuredCostDifferenceUSD), 0.9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(report.summary.meanLatencyDifferenceMs), 20, accuracy: 0.0001)
        XCTAssertEqual(report.qualityAssessmentMethod, .notAssessed)
        XCTAssertEqual(report.sampleVersion, "public-text-v1")
        XCTAssertTrue(report.summary.qualityNote.contains("不能声称质量不下降"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("private-prompt-sentinel"))
        XCTAssertFalse(json.contains("requestPreview"))
        XCTAssertFalse(json.contains("responsePreview"))
        let decoded = try JSONDecoder().decode(ABExperimentReport.self, from: data)
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.definitionVersion, "ab-report-v2")
    }

    func testTestBenchExposesOnlyAuditableInterleavedABPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoModelCore/AutoModelEngine.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(engine.contains("abBaselineModelUUID"))
        XCTAssertFalse(engine.contains("runRealABComparison"))
        let testBench = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoModel/TestBenchView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(testBench.contains("enableABBaseline"))
        XCTAssertFalse(testBench.contains("实测对照 (A/B)"))
        XCTAssertTrue(testBench.contains("运行交错 A/B"))
    }

    func testMixedRetryAttemptsKeepMeasuredAndEstimatedCostsSeparate() async throws {
        let configuration = ABExperimentConfiguration(
            baselineModelID: "baseline-model",
            autoRequestedModel: "auto",
            repetitions: 1,
            policyVersion: 3,
            qualityAssessmentMethod: .notAssessed
        )
        let report = await ABExperimentRunner().run(configuration: configuration) { request in
            let attempts: [(UsageDataSource, Double)] = request.side == .auto
                ? [(.estimatedWhenMissing, 0.3), (.upstreamReported, 0.1)]
                : [(.estimatedWhenMissing, 0.2), (.upstreamReported, 0.5)]
            return self.record(for: request, attempts: attempts, latency: 10)
        }

        let auto = try XCTUnwrap(report.samples.first { $0.side == .auto })
        let baseline = try XCTUnwrap(report.samples.first { $0.side == .baseline })
        XCTAssertEqual(try XCTUnwrap(auto.measuredCostUSD), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(auto.estimatedCostUSD), 0.3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(baseline.measuredCostUSD), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(baseline.estimatedCostUSD), 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(report.summary.measuredCostDifferenceUSD), 0.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(report.summary.estimatedCostDifferenceUSD), -0.1, accuracy: 0.0001)
    }

    func testUnpricedAndMissingQualityDoNotBecomeZeroCostOrQualityClaims() async throws {
        let configuration = ABExperimentConfiguration(
            baselineModelID: "baseline-model",
            autoRequestedModel: "auto",
            repetitions: 1,
            policyVersion: 1,
            qualityAssessmentMethod: .notAssessed
        )
        let report = await ABExperimentRunner().run(configuration: configuration) { request in
            var record = self.record(for: request, cost: 0, latency: 10, usageSource: .estimatedWhenMissing)
            record.totalCostUSD = nil
            record.primaryAttemptCostUSD = nil
            record.costStatus = .missingPriceConfig
            record.attempts[0].costUSD = nil
            record.attempts[0].costStatus = .missingPriceConfig
            return record
        }
        XCTAssertEqual(report.summary.comparablePricedPairs, 0)
        XCTAssertNil(report.summary.measuredCostDifferenceUSD)
        XCTAssertEqual(try XCTUnwrap(report.summary.meanLatencyDifferenceMs), 0, accuracy: 0.0001)
        XCTAssertTrue(report.summary.costNote.contains("未定价"))
    }
}
