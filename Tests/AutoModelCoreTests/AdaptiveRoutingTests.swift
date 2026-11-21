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
            ("Check this", high.id, .medium),
            ("Debug why checkout sometimes hangs", high.id, .medium),
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
