import XCTest
@testable import AutoModelCore

final class AdaptiveRoutingTests: XCTestCase {
    private let provider = ProviderConfig(name: "Routing fixture", baseURL: "https://routing.example/v1")

    private func model(_ name: String) -> ModelConfig {
        ModelConfig(
            providerID: provider.id, modelID: name, displayName: name,
            capabilities: [.chat, .tools, .coding, .reasoning, .vision]
        )
    }

    func testCostFirstLearnsMeasuredUnitCostAfterColdStart() {
        let expensive = ModelConfig(
            providerID: provider.id, modelID: "expensive", displayName: "Expensive",
            inputPricePerMillion: 10, outputPricePerMillion: 10,
            capabilities: [.chat], qualityScore: 75, speedScore: 75
        )
        let cheap = ModelConfig(
            providerID: provider.id, modelID: "cheap", displayName: "Cheap",
            inputPricePerMillion: 0.5, outputPricePerMillion: 0.5,
            capabilities: [.chat], qualityScore: 75, speedScore: 75
        )
        let policy = RoutingPolicyConfig(
            activeStrategy: .costFirst,
            autoConfigureTiers: false,
            preferTierMappingInAuto: false,
            strictThreeTierPoolOnly: false
        )
        let features = RequestFeatureExtractor.extract(from: [
            "messages": [["role": "user", "content": "Classify this"]]
        ])
        let router = ModelRouter()

        let coldStart = router.route(
            requestedModel: "auto", features: features,
            providers: [provider], models: [expensive, cheap], policy: policy
        )
        XCTAssertEqual(coldStart.selectedModelUUID, cheap.id)

        let measured = [
            expensive.id: ModelRuntimeMetrics(
                averageLatencyMs: 100, successRate: 1, averageCostPerMillionTokens: 0.10, sampleCount: 2
            ),
            cheap.id: ModelRuntimeMetrics(
                averageLatencyMs: 100, successRate: 1, averageCostPerMillionTokens: 4.00, sampleCount: 2
            )
        ]
        let learned = router.route(
            requestedModel: "auto", features: features,
            providers: [provider], models: [expensive, cheap], policy: policy,
            runtimeMetricsByModelID: measured
        )
        XCTAssertEqual(learned.selectedModelUUID, expensive.id)
        XCTAssertTrue(learned.candidateEvaluations.first(where: { $0.modelUUID == expensive.id })?.scoreBreakdown.contains { $0.contains("近况实测") } == true)
    }

    func testBalancedRouteUsesTaskComplexityAndEffortIndependently() {
        let low = model("light")
        let medium = model("scoped")
        let high = model("advanced")
        let policy = RoutingPolicyConfig(lowTierModelID: low.id, mediumTierModelID: medium.id, highTierModelID: high.id)
        let router = ModelRouter()

        let cases: [(String, UUID, ReasoningEffort)] = [
            ("Classify each ticket by status", low.id, .low),
            ("从以下记录提取订单号", low.id, .low),
            ("Fix the typo in README.md", medium.id, .medium),
            ("Write a product announcement email", medium.id, .medium),
            ("Check this", medium.id, .medium),
            ("Debug why checkout sometimes hangs", medium.id, .medium),
            ("Plan a cross-service database migration", high.id, .high),
            ("Find the root cause of a deadlock", high.id, .high),
        ]
        for (prompt, expectedModel, expectedEffort) in cases {
            let features = RequestFeatureExtractor.extract(from: ["messages": [["role": "user", "content": prompt]]])
            let decision = router.route(requestedModel: "auto", features: features, providers: [provider], models: [low, medium, high], policy: policy)
            XCTAssertEqual(decision.selectedModelUUID, expectedModel, prompt)
            XCTAssertEqual(decision.selectedEffort, expectedEffort, prompt)
        }
    }

    func testHistoryLengthDoesNotImplyHighComplexityButStillLimitsCapacity() {
        var medium = model("scoped")
        medium.contextWindow = 32_000
        var high = model("advanced")
        high.contextWindow = 300_000
        let policy = RoutingPolicyConfig(mediumTierModelID: medium.id, highTierModelID: high.id)
        let messages = [["role": "user", "content": String(repeating: "x", count: 450_000)],
                        ["role": "assistant", "content": "Done"], ["role": "user", "content": "Check this"]]
        let features = RequestFeatureExtractor.extract(from: ["messages": messages])
        XCTAssertEqual(features.subtaskCategory, .generalEngineering)
        let result = ModelRouter().route(requestedModel: "auto", features: features, providers: [provider], models: [medium, high], policy: policy)
        XCTAssertEqual(result.selectedModelUUID, high.id)
        XCTAssertEqual(result.candidateEvaluations.first { $0.modelUUID == medium.id }?.passedHardConstraints, false)
    }

    func testExplicitHighEffortDoesNotPreventNewLightTaskDowngradeOrChangeToolContinuation() {
        let low = model("light"), medium = model("scoped"), high = model("advanced")
        let policy = RoutingPolicyConfig(lowTierModelID: low.id, mediumTierModelID: medium.id, highTierModelID: high.id)
        let router = ModelRouter()
        let session = "switch-session"
        router.recordSuccessfulSessionModel(fingerprint: session, modelUUID: high.id, policyVersion: policy.policyVersion)
        let history: [[String: Any]] = [["role": "user", "content": "Plan cross-service architecture"], ["role": "assistant", "content": "Done"]]
        let continuation = history + [["role": "tool", "content": "Found source"]]
        let toolFeatures = RequestFeatureExtractor.extract(from: ["messages": continuation, "reasoning_effort": "high"], sessionHeader: session)
        let toolDecision = router.route(requestedModel: "auto", features: toolFeatures, providers: [provider], models: [low, medium, high], policy: policy)
        XCTAssertEqual(toolDecision.selectedModelUUID, high.id)
        XCTAssertEqual(toolDecision.selectedEffort, .high)
        let next = history + [["role": "user", "content": "Search for the config file"]]
        let features = RequestFeatureExtractor.extract(from: ["messages": next, "reasoning_effort": "high"], sessionHeader: session)
        let decision = router.route(requestedModel: "auto", features: features, providers: [provider], models: [low, medium, high], policy: policy)
        XCTAssertEqual(decision.selectedModelUUID, low.id)
        XCTAssertEqual(decision.selectedEffort, .high)
        XCTAssertTrue(decision.matchedRules.contains { $0.contains("轻量任务") })
    }

    func testVerifiedFailureRecoversSameModelThenAdjacentTierAndStopsAtTop() {
        let low = model("light"), medium = model("scoped"), high = model("advanced")
        let models = [low, medium, high]
        let policy = RoutingPolicyConfig(lowTierModelID: low.id, mediumTierModelID: medium.id, highTierModelID: high.id)
        let router = ModelRouter()
        let session = "quality-session", key = "same-required-tool-context"
        let features = RequestFeatureExtractor.extract(from: ["messages": [["role": "user", "content": "Implement the requested function"]]], sessionHeader: session)
        func record(_ model: ModelConfig, effort: ReasoningEffort, failed: Bool = true) {
            router.recordSuccessfulSessionModel(fingerprint: session, modelUUID: model.id, policyVersion: policy.policyVersion,
                wasToolStarved: failed, selectedEffort: effort, qualityRecoveryKey: key, isMultiTurn: false)
        }
        func route(_ recoveryKey: String?) -> RoutingDecision {
            router.route(requestedModel: "auto", features: features, providers: [provider], models: models, policy: policy, qualityRecoveryKey: recoveryKey)
        }
        record(medium, effort: .medium)
        let first = route(key)
        XCTAssertEqual(first.selectedModelUUID, medium.id)
        XCTAssertEqual(first.selectedEffort, .high)
        XCTAssertTrue(first.matchedRules.contains { $0.contains("必需工具调用缺失") })
        XCTAssertEqual(route("unrelated-task").selectedEffort, .medium)
        XCTAssertEqual(route(key).selectedEffort, .medium, "An unrelated user task must clear stale recovery state")
        record(medium, effort: .high)
        let second = route(key)
        XCTAssertEqual(second.selectedModelUUID, high.id)
        record(high, effort: .high)
        let top = route(key)
        XCTAssertEqual(top.selectedModelUUID, high.id)
        XCTAssertTrue(top.routingReasonNote?.contains("最高档") == true)
        record(high, effort: .high, failed: false)
        XCTAssertEqual(route(key).selectedEffort, .medium)
    }

    func testRecoveryHonorsExplicitEffortAndUnavailableAdjacentTier() {
        let medium = model("scoped"), high = model("advanced")
        let policy = RoutingPolicyConfig(mediumTierModelID: medium.id, highTierModelID: high.id)
        let router = ModelRouter(), session = "quality-explicit", key = "same"
        let features = RequestFeatureExtractor.extract(from: ["reasoning_effort": "high", "messages": [["role": "user", "content": "Implement the requested function"]]], sessionHeader: session)
        router.recordSuccessfulSessionModel(fingerprint: session, modelUUID: medium.id, policyVersion: policy.policyVersion,
            wasToolStarved: true, selectedEffort: .high, qualityRecoveryKey: key, isMultiTurn: false)
        let selected = router.route(requestedModel: "auto", features: features, providers: [provider], models: [medium, high], policy: policy, qualityRecoveryKey: key)
        XCTAssertEqual(selected.selectedModelUUID, high.id)
        XCTAssertEqual(selected.selectedEffort, .high)
        var unavailable = high
        unavailable.isEnabled = false
        let held = router.route(requestedModel: "auto", features: features, providers: [provider], models: [medium, unavailable], policy: policy, qualityRecoveryKey: key)
        XCTAssertEqual(held.selectedModelUUID, medium.id)
        XCTAssertEqual(held.selectedEffort, .high)
        XCTAssertTrue(held.routingReasonNote?.contains("不可用") == true)
    }

    func testExplicitModelAndTierPreserveEffortAndRecoveryIntent() {
        let medium = model("scoped"), high = model("advanced")
        let policy = RoutingPolicyConfig(mediumTierModelID: medium.id, highTierModelID: high.id)
        let router = ModelRouter(), session = "explicit-session", key = "required"
        let selectedHigh = RequestFeatureExtractor.extract(from: ["reasoning_effort": "high", "messages": [["role": "user", "content": "Implement the requested function"]]], sessionHeader: session)
        let direct = router.route(requestedModel: "scoped", features: selectedHigh, providers: [provider], models: [medium, high], policy: policy)
        XCTAssertEqual(direct.selectedEffort, .high)
        let automatic = RequestFeatureExtractor.extract(from: ["messages": [["role": "user", "content": "Implement the requested function"]]], sessionHeader: session)
        router.recordSuccessfulSessionModel(fingerprint: session, modelUUID: medium.id, policyVersion: policy.policyVersion,
            wasToolStarved: true, selectedEffort: .medium, qualityRecoveryKey: key, requestedModel: "auto/medium", isMultiTurn: false)
        let retry = router.route(requestedModel: "auto/medium", features: automatic, providers: [provider], models: [medium, high], policy: policy, qualityRecoveryKey: key)
        XCTAssertEqual(retry.selectedModelUUID, medium.id)
        XCTAssertEqual(retry.selectedEffort, .high)
        XCTAssertTrue(retry.matchedRules.contains { $0.contains("思考强度提高") })
        router.recordSuccessfulSessionModel(fingerprint: session, modelUUID: medium.id, policyVersion: policy.policyVersion,
            wasToolStarved: true, selectedEffort: .high, qualityRecoveryKey: key, requestedModel: "auto/medium", isMultiTurn: false)
        let exhausted = router.route(requestedModel: "auto/medium", features: automatic, providers: [provider], models: [medium, high], policy: policy, qualityRecoveryKey: key)
        XCTAssertEqual(exhausted.selectedModelUUID, medium.id)
    }

    func testNativeAnthropicEffortRespectsClientSettingsAndCurrentModelSupport() {
        let payload: [String: Any] = ["messages": [["role": "user", "content": "Implement the spec"]]]
        func appliedEffort(_ payload: [String: Any], modelID: String) -> String? {
            let result = NativeAnthropicRouting.applyingInitialEffort(to: payload, modelID: modelID, effort: .medium)
            return (result["output_config"] as? [String: Any])?["effort"] as? String
        }
        XCTAssertEqual(appliedEffort(payload, modelID: "claude-sonnet-5-5"), "medium")
        XCTAssertNil(appliedEffort(payload, modelID: "claude-3-haiku-20240307"))
        var withClientEffort = payload
        withClientEffort["output_config"] = ["effort": "xhigh"]
        XCTAssertEqual(appliedEffort(withClientEffort, modelID: "claude-opus-5-5"), "xhigh")
        var continuation = payload
        continuation["messages"] = [["role": "user"], ["role": "assistant"], ["role": "user"]]
        XCTAssertNil(appliedEffort(continuation, modelID: "claude-opus-5-5"))
    }

    func testBalancedSessionRaisesTierAtUserBoundaryEvenWhenPreviousModelCanReason() {
        let low = model("light")
        let high = model("advanced")
        let policy = RoutingPolicyConfig(lowTierModelID: low.id, highTierModelID: high.id)
        let router = ModelRouter()
        let history = [["role": "user", "content": "Classify the incoming tickets"], ["role": "assistant", "content": "Done"]]
        let continuation = history + [["role": "tool", "content": "Error: tool timed out"]]
        let nextPhase = history + [["role": "user", "content": "Plan a cross-service migration of the database"]]
        let session = "adaptive-session"
        router.recordSuccessfulSessionModel(fingerprint: session, modelUUID: low.id, policyVersion: policy.policyVersion)

        for (messages, expectedModel, effort): ([[String: String]], UUID, ReasoningEffort) in [
            (continuation, low.id, .high), (nextPhase, high.id, .high),
        ] {
            let features = RequestFeatureExtractor.extract(from: ["messages": messages], sessionHeader: session)
            let decision = router.route(requestedModel: "auto", features: features, providers: [provider], models: [low, high], policy: policy)
            XCTAssertEqual(decision.selectedModelUUID, expectedModel)
            XCTAssertEqual(decision.selectedEffort, effort)
        }
    }
}
