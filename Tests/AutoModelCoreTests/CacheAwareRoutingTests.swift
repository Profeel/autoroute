import Foundation
import XCTest
@testable import AutoModelCore

final class CacheAwareRoutingTests: XCTestCase {
    private func makeProvider() -> ProviderConfig {
        ProviderConfig(
            name: "Anthropic",
            baseURL: "https://api.anthropic.com",
            apiProtocol: .anthropicMessages
        )
    }

    private func makeModels(providerID: UUID) -> (low: ModelConfig, medium: ModelConfig, high: ModelConfig) {
        let low = ModelConfig(
            providerID: providerID,
            modelID: "claude-3-5-haiku",
            displayName: "Claude Haiku",
            inputPricePerMillion: 0.8,
            outputPricePerMillion: 4.0,
            cachedInputPricePerMillion: 0.08,
            cacheCreationPricePerMillion: 1.0,
            contextWindow: 200_000,
            capabilities: [.chat, .coding, .tools],
            defaultRole: .fastEconomy,
            qualityScore: 78,
            speedScore: 95
        )
        let medium = ModelConfig(
            providerID: providerID,
            modelID: "claude-sonnet-4",
            displayName: "Claude Sonnet",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            cachedInputPricePerMillion: 0.3,
            cacheCreationPricePerMillion: 3.75,
            contextWindow: 200_000,
            capabilities: [.chat, .coding, .tools],
            defaultRole: .coding,
            qualityScore: 90,
            speedScore: 82
        )
        let high = ModelConfig(
            providerID: providerID,
            modelID: "claude-opus-4",
            displayName: "Claude Opus",
            inputPricePerMillion: 15.0,
            outputPricePerMillion: 75.0,
            cachedInputPricePerMillion: 1.5,
            cacheCreationPricePerMillion: 18.75,
            contextWindow: 200_000,
            capabilities: [.chat, .coding, .tools, .reasoning],
            defaultRole: .complexReasoning,
            qualityScore: 97,
            speedScore: 68
        )
        return (low, medium, high)
    }

    private func makePolicy(low: UUID, medium: UUID, high: UUID) -> RoutingPolicyConfig {
        RoutingPolicyConfig(
            policyVersion: 1,
            activeStrategy: .balanced,
            enableSessionStickiness: true,
            lowTierModelID: low,
            mediumTierModelID: medium,
            highTierModelID: high,
            preferTierMappingInAuto: true,
            enablePhaseDowngradeHysteresis: true,
            strictThreeTierPoolOnly: true
        )
    }

    func testWarmLongContextSuppressesCostlyDowngradeAutomatically() {
        let router = ModelRouter()
        let provider = makeProvider()
        let (low, medium, high) = makeModels(providerID: provider.id)
        let policy = makePolicy(low: low.id, medium: medium.id, high: high.id)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Turn 1: medium coding task on Claude Sonnet, with 60k prompt tokens reported
        let turn1 = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "user", "content": "请帮我实现 Swift 中的用户配置保存逻辑"]
            ]
        ], sessionHeader: "sess-cache-hold")
        let d1 = router.route(requestedModel: "auto", features: turn1, providers: [provider], models: [low, medium, high], policy: policy, now: t0)
        XCTAssertEqual(d1.selectedModelUUID, medium.id)
        router.recordSuccessfulSessionModel(
            fingerprint: turn1.conversationFingerprint,
            modelUUID: medium.id,
            policyVersion: 1,
            isRoutineSubtask: true,
            promptTokens: 60_000,
            cachedInputTokens: 45_000,
            now: t0
        )

        // Turn 2 (30s later, still within 5-min warm cache window): explicit light summary task
        // Normally clearLightTask would immediately downgrade to Haiku,
        // but 60k cold prefill on Haiku ($1.0/M = $0.06) > staying on warm Sonnet ($0.3/M cache read).
        let turn2 = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "user", "content": "请帮我实现 Swift 中的用户配置保存逻辑"],
                ["role": "assistant", "content": "已完成实现。"],
                ["role": "user", "content": "请帮我总结一下刚才的改动要点"]
            ]
        ], sessionHeader: "sess-cache-hold")
        let d2 = router.route(
            requestedModel: "auto",
            features: turn2,
            providers: [provider],
            models: [low, medium, high],
            policy: policy,
            now: t0.addingTimeInterval(30)
        )
        XCTAssertEqual(d2.selectedModelUUID, medium.id)
        XCTAssertTrue(d2.matchedRules.contains(where: { $0.contains("KV 缓存成本保护") }))
    }

    func testExpiredWarmCacheAllowsDowngrade() {
        let router = ModelRouter()
        let provider = makeProvider()
        let (low, medium, high) = makeModels(providerID: provider.id)
        let policy = makePolicy(low: low.id, medium: medium.id, high: high.id)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let turn1 = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "user", "content": "请帮我实现 Swift 中的用户配置保存逻辑"]
            ]
        ], sessionHeader: "sess-cache-expired")
        router.recordSuccessfulSessionModel(
            fingerprint: turn1.conversationFingerprint,
            modelUUID: medium.id,
            policyVersion: 1,
            isRoutineSubtask: true,
            promptTokens: 60_000,
            cachedInputTokens: 45_000,
            now: t0
        )

        // 6 minutes later (> 300s warm TTL): sticky cache has likely expired, so downgrade proceeds normally
        let turn2 = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "user", "content": "请帮我实现 Swift 中的用户配置保存逻辑"],
                ["role": "assistant", "content": "已完成实现。"],
                ["role": "user", "content": "请帮我总结一下刚才的改动要点"]
            ]
        ], sessionHeader: "sess-cache-expired")
        let d2 = router.route(
            requestedModel: "auto",
            features: turn2,
            providers: [provider],
            models: [low, medium, high],
            policy: policy,
            now: t0.addingTimeInterval(360)
        )
        XCTAssertEqual(d2.selectedModelUUID, low.id)
    }

    func testHugePriceGapStillAllowsDowngradeEvenWithLongContext() {
        let router = ModelRouter()
        let provider = makeProvider()
        let (_, medium, high) = makeModels(providerID: provider.id)
        let ultraCheapLow = ModelConfig(
            providerID: provider.id,
            modelID: "gemini-2.5-flash-lite",
            displayName: "Ultra Cheap",
            inputPricePerMillion: 0.10,
            outputPricePerMillion: 0.40,
            cachedInputPricePerMillion: 0.01,
            cacheCreationPricePerMillion: 0.10,
            contextWindow: 200_000,
            capabilities: [.chat, .coding, .tools],
            defaultRole: .fastEconomy,
            qualityScore: 76,
            speedScore: 98
        )
        let policy = makePolicy(low: ultraCheapLow.id, medium: medium.id, high: high.id)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let turn1 = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "user", "content": "Compare microservices architecture tradeoffs and make a migration plan."]
            ]
        ], sessionHeader: "sess-huge-gap")
        router.recordSuccessfulSessionModel(
            fingerprint: turn1.conversationFingerprint,
            modelUUID: high.id,
            policyVersion: 1,
            isRoutineSubtask: false,
            promptTokens: 80_000,
            cachedInputTokens: 70_000,
            now: t0
        )

        // Opus warm cache read ($1.5/M) is still 15x more expensive than Ultra Cheap cold prefill ($0.10/M)
        let turn2 = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "user", "content": "Compare microservices architecture tradeoffs and make a migration plan."],
                ["role": "assistant", "content": "Plan ready."],
                ["role": "user", "content": "请总结一下上述方案的核心要点"]
            ]
        ], sessionHeader: "sess-huge-gap")
        let d2 = router.route(
            requestedModel: "auto",
            features: turn2,
            providers: [provider],
            models: [ultraCheapLow, medium, high],
            policy: policy,
            now: t0.addingTimeInterval(20)
        )
        XCTAssertEqual(d2.selectedModelUUID, ultraCheapLow.id)
    }

    func testWarmCacheDoesNotBlockUpgradeOnHardTask() {
        let router = ModelRouter()
        let provider = makeProvider()
        let (low, medium, high) = makeModels(providerID: provider.id)
        let policy = makePolicy(low: low.id, medium: medium.id, high: high.id)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let turn1 = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "user", "content": "请帮我实现 Swift 中的用户配置保存逻辑"]
            ]
        ], sessionHeader: "sess-upgrade-ok")
        router.recordSuccessfulSessionModel(
            fingerprint: turn1.conversationFingerprint,
            modelUUID: medium.id,
            policyVersion: 1,
            isRoutineSubtask: true,
            promptTokens: 80_000,
            cachedInputTokens: 70_000,
            now: t0
        )

        // Hard architecture/migration task must still upgrade to High tier despite warm Medium cache
        let turn2 = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "user", "content": "请帮我实现 Swift 中的用户配置保存逻辑"],
                ["role": "assistant", "content": "已完成。"],
                ["role": "user", "content": "Compare microservices architecture tradeoffs and design a zero-downtime migration plan."]
            ]
        ], sessionHeader: "sess-upgrade-ok")
        let d2 = router.route(
            requestedModel: "auto",
            features: turn2,
            providers: [provider],
            models: [low, medium, high],
            policy: policy,
            now: t0.addingTimeInterval(20)
        )
        XCTAssertEqual(d2.selectedModelUUID, high.id)
    }

    func testUnpricedModelWithObservedLargeCacheStillSuppressesDowngrade() {
        let router = ModelRouter()
        let provider = makeProvider()
        let low = ModelConfig(
            providerID: provider.id,
            modelID: "custom-fast",
            displayName: "Custom Fast",
            contextWindow: 200_000,
            capabilities: [.chat, .coding, .tools],
            defaultRole: .fastEconomy,
            qualityScore: 75,
            speedScore: 95
        )
        let medium = ModelConfig(
            providerID: provider.id,
            modelID: "custom-pro",
            displayName: "Custom Pro",
            contextWindow: 200_000,
            capabilities: [.chat, .coding, .tools],
            defaultRole: .coding,
            qualityScore: 90,
            speedScore: 80
        )
        let policy = makePolicy(low: low.id, medium: medium.id, high: medium.id)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let turn1 = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "user", "content": "请帮我实现 Swift 中的用户配置保存逻辑"]
            ]
        ], sessionHeader: "sess-unpriced-cache")
        router.recordSuccessfulSessionModel(
            fingerprint: turn1.conversationFingerprint,
            modelUUID: medium.id,
            policyVersion: 1,
            isRoutineSubtask: true,
            promptTokens: 30_000,
            cachedInputTokens: 20_000,
            now: t0
        )

        let turn2 = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "user", "content": "请帮我实现 Swift 中的用户配置保存逻辑"],
                ["role": "assistant", "content": "已完成。"],
                ["role": "user", "content": "请帮我总结一下刚才的改动要点"]
            ]
        ], sessionHeader: "sess-unpriced-cache")
        let d2 = router.route(
            requestedModel: "auto",
            features: turn2,
            providers: [provider],
            models: [low, medium],
            policy: policy,
            now: t0.addingTimeInterval(25)
        )
        XCTAssertEqual(d2.selectedModelUUID, medium.id)
        XCTAssertTrue(d2.matchedRules.contains(where: { $0.contains("KV 缓存成本保护") }))
    }
}
