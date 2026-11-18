import XCTest
@testable import AutoModelCore

final class ContextEstimationTests: XCTestCase {
    func testEstimatorCountsCJKAndToolSchemaSize() {
        let chinese = String(repeating: "汉", count: 1_000)
        let english = String(repeating: "a", count: 1_000)

        let chineseEstimate = RequestFeatureExtractor.estimateTokens(text: chinese, messageCount: 1)
        let englishEstimate = RequestFeatureExtractor.estimateTokens(text: english, messageCount: 1)
        XCTAssertGreaterThan(chineseEstimate, englishEstimate * 3)

        let smallTools: [[String: Any]] = [[
            "type": "function",
            "function": ["name": "lookup", "description": "Find one item"]
        ]]
        let largeTools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "lookup",
                "description": String(repeating: "Return the matching record with its audit fields. ", count: 80),
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search expression"],
                        "limit": ["type": "integer", "description": "Maximum number of records"]
                    ],
                    "required": ["query"]
                ]
            ]
        ]]
        let smallFeatures = RequestFeatureExtractor.extract(from: [
            "messages": [["role": "user", "content": "lookup"]],
            "tools": smallTools
        ])
        let largeFeatures = RequestFeatureExtractor.extract(from: [
            "messages": [["role": "user", "content": "lookup"]],
            "tools": largeTools
        ])

        XCTAssertEqual(smallFeatures.tokenEstimateConfidence, .low)
        XCTAssertEqual(largeFeatures.tokenEstimateConfidence, .low)
        XCTAssertGreaterThan(largeFeatures.estimatedInputTokens, smallFeatures.estimatedInputTokens)
    }

    func testVisionEstimateIncludesEachImageAndIsLowConfidence() {
        let payload: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "Compare these images"],
                    ["type": "input_image", "image_url": "https://example.com/a.png"],
                    ["type": "input_image", "image_url": "https://example.com/b.png"]
                ]
            ]]
        ]
        let features = RequestFeatureExtractor.extract(from: payload)

        XCTAssertTrue(features.requiresVision)
        XCTAssertEqual(features.tokenEstimateConfidence, .low)
        XCTAssertGreaterThanOrEqual(features.estimatedInputTokens, 1_536)
    }

    func testContextBoundaryUsesBufferForUncertainEstimate() {
        let provider = ProviderConfig(name: "context-test", baseURL: "https://context.test", healthStatus: .healthy)
        let model = ModelConfig(
            providerID: provider.id,
            modelID: "boundary-model",
            contextWindow: 2_000,
            capabilities: [.chat],
            availabilityStatus: .available
        )
        let policy = RoutingPolicyConfig(activeStrategy: .qualityFirst)
        let boundaryFeatures = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [["role": "user", "content": String(repeating: "汉", count: 1_400)]]
        ])
        let decision = ModelRouter().route(
            requestedModel: "auto",
            features: boundaryFeatures,
            providers: [provider],
            models: [model],
            policy: policy
        )

        XCTAssertGreaterThan(boundaryFeatures.estimatedInputTokens, model.contextWindow)
        XCTAssertLessThanOrEqual(boundaryFeatures.estimatedInputTokens, 2_000 + 256)
        XCTAssertEqual(decision.selectedModelUUID, model.id)
    }

    func testClearContextOverageStillHardRejectsModel() {
        let provider = ProviderConfig(name: "context-test", baseURL: "https://context.test", healthStatus: .healthy)
        let model = ModelConfig(
            providerID: provider.id,
            modelID: "small-context-model",
            contextWindow: 2_000,
            capabilities: [.chat],
            availabilityStatus: .available
        )
        let features = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [["role": "user", "content": String(repeating: "汉", count: 2_000)]]
        ])
        let decision = ModelRouter().route(
            requestedModel: "auto",
            features: features,
            providers: [provider],
            models: [model],
            policy: RoutingPolicyConfig(activeStrategy: .qualityFirst)
        )

        XCTAssertNil(decision.selectedModelUUID)
        XCTAssertTrue(decision.candidateEvaluations.first?.exclusionReasons.contains(where: { $0.contains("明确超过上下文上限") }) == true)
    }
}
