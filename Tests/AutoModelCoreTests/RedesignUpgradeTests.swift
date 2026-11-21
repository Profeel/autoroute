import AutoModelCore
import XCTest

final class RedesignUpgradeTests: XCTestCase {
    func testLegacyConfigBackwardCompatibilityDefaults() throws {
        let legacyProviderJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy Claude",
          "baseURL": "https://api.anthropic.com"
        }
        """.data(using: .utf8)!
        let provider = try JSONDecoder().decode(ProviderConfig.self, from: legacyProviderJSON)
        XCTAssertTrue(provider.isEnabled)
        XCTAssertFalse(provider.isAutoDiscovered)
        XCTAssertNil(provider.discoverySourceLabel)

        let legacyModelJSON = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "providerID": "11111111-1111-1111-1111-111111111111",
          "modelID": "claude-3-7-sonnet-20250219",
          "displayName": "Claude 3.7 Sonnet"
        }
        """.data(using: .utf8)!
        let model = try JSONDecoder().decode(ModelConfig.self, from: legacyModelJSON)
        XCTAssertNil(model.canonicalModelID)

        let legacyPolicyJSON = """
        {
          "policyVersion": 3,
          "activeStrategy": "balanced"
        }
        """.data(using: .utf8)!
        let policy = try JSONDecoder().decode(RoutingPolicyConfig.self, from: legacyPolicyJSON)
        XCTAssertTrue(policy.enableAutoSameModelGrouping)
        XCTAssertTrue(policy.perStrategyTiers.isEmpty)

        let legacyBucketJSON = """
        {
          "dayKey": "2026-11-20",
          "callCount": 5,
          "totalCostUSD": 0.42
        }
        """.data(using: .utf8)!
        let bucket = try JSONDecoder().decode(DailyUsageBucket.self, from: legacyBucketJSON)
        XCTAssertEqual(bucket.actualTotalLatencyMs, 0)
        XCTAssertEqual(bucket.baselineCostUSD, 0)
        XCTAssertEqual(bucket.baselineTotalLatencyMs, 0)
    }

    func testCanonicalModelNormalizerMergesEquivalentIDs() {
        XCTAssertEqual(
            CanonicalModelNormalizer.normalize("anthropic/claude-3-7-sonnet-20250219"),
            "claude-3.7-sonnet"
        )
        XCTAssertEqual(
            CanonicalModelNormalizer.normalize("claude-3.7-sonnet"),
            "claude-3.7-sonnet"
        )
        XCTAssertEqual(
            CanonicalModelNormalizer.normalize("openrouter/anthropic/claude-3-7-sonnet:beta"),
            "claude-3.7-sonnet"
        )
        XCTAssertEqual(
            CanonicalModelNormalizer.normalize("deepseek-ai/DeepSeek-V3-0324"),
            "deepseek-v3"
        )
    }

    func testSameModelGroupFailoverWhenPrimaryChannelInCooldown() {
        let p1 = ProviderConfig(name: "Claude", baseURL: "https://api.anthropic.com", isEnabled: true)
        let p2 = ProviderConfig(name: "Antigravity CLI", baseURL: "http://127.0.0.1:9001", isEnabled: true)

        let m1 = ModelConfig(
            providerID: p1.id,
            modelID: "anthropic/claude-3-7-sonnet-20250219",
            displayName: "Claude 3.7 Sonnet (Claude)",
            qualityScore: 92,
            speedScore: 80
        )
        let m2 = ModelConfig(
            providerID: p2.id,
            modelID: "claude-3.7-sonnet",
            displayName: "Claude 3.7 Sonnet (Antigravity)",
            qualityScore: 92,
            speedScore: 80,
            lastProbeLatencyMs: 650
        )
        let mBackupDifferent = ModelConfig(
            providerID: p1.id,
            modelID: "claude-3-5-haiku-20241022",
            displayName: "Claude 3.5 Haiku",
            qualityScore: 70,
            speedScore: 95
        )

        var policy = RoutingPolicyConfig(activeStrategy: .balanced)
        policy.mediumTierModelID = m1.id
        policy.mediumTierBackupModelIDs = [mBackupDifferent.id]
        policy.enableAutoSameModelGrouping = true

        let features = RequestFeatureExtractor.extract(from: [
            "model": "auto/medium",
            "messages": [["role": "user", "content": "refactor swift module"]]
        ])
        let context = RoutingContext(
            requestedModel: "auto/medium",
            features: features,
            providers: [p1, p2],
            models: [m1, m2, mBackupDifferent],
            policy: policy,
            runtimeMetricsByModelID: [
                m1.id: ModelRuntimeMetrics(
                    averageLatencyMs: 800,
                    successRate: 1.0,
                    sampleCount: 3,
                    cooldownUntil: Date().addingTimeInterval(60)
                )
            ]
        )

        let decision = DeterministicLocalDeciderPlugin().decide(context: context)
        XCTAssertEqual(decision.selectedModelUUID, m2.id)
        XCTAssertEqual(decision.selectedProviderID, p2.id)
        XCTAssertEqual(decision.canonicalGroupID, "claude-3.7-sonnet")
    }

    func testDisablingProviderExcludesFromGroupsAndBenchmarkLights() {
        var provider = ProviderConfig(name: "Antigravity CLI", baseURL: "http://127.0.0.1:9001", isEnabled: true)
        var model = ModelConfig(
            providerID: provider.id,
            modelID: "claude-sonnet-5-5",
            displayName: "Claude Sonnet 5.5"
        )

        let litPoints = PublicBenchmarkCatalog.matchPoints(providers: [provider], models: [model])
        XCTAssertTrue(litPoints.first(where: { $0.entry.canonicalModelID == "claude-sonnet-5.5" })?.isLit == true)

        model.isEnabled = false
        XCTAssertFalse(PublicBenchmarkCatalog.matchPoints(providers: [provider], models: [model])
            .first(where: { $0.entry.canonicalModelID == "claude-sonnet-5.5" })!.isLit)

        provider.isEnabled = false
        model.isEnabled = true
        let dimmedPoints = PublicBenchmarkCatalog.matchPoints(providers: [provider], models: [model])
        XCTAssertTrue(dimmedPoints.first(where: { $0.entry.canonicalModelID == "claude-sonnet-5.5" })?.isLit == false)

        let connectedGroups = CanonicalModelGroupingBuilder.buildGroups(
            providers: [provider],
            models: [model],
            connectedOnly: true
        )
        XCTAssertTrue(connectedGroups.isEmpty)
    }

    func testBenchmarkSnapshotHasValidSameRowValuesAndSources() {
        let entries = PublicBenchmarkCatalog.entries
        XCTAssertEqual(Set(entries.map(\.canonicalModelID)).count, entries.count)
        XCTAssertTrue(entries.allSatisfy {
            $0.benchmarkScore.isFinite && (0...100).contains($0.benchmarkScore)
                && $0.avgCostPerTaskUSD.isFinite && $0.avgCostPerTaskUSD > 0
                && !$0.harness.isEmpty && !$0.configuration.isEmpty
                && $0.sourceURL.scheme == "https" && $0.sourceURL.host == "artificialanalysis.ai"
        })
        let expected: [(String, Double, Double, String, String)] = [
            ("gpt-6.2-astra", 53, 5.12, "Codex", "Max"),
            ("gpt-6.2-sol", 50, 0.90, "Codex", "Xhigh"),
            ("gpt-6-astra", 53, 7.63, "Codex", "Max"),
            ("gpt-6.1-sol", 52, 1.51, "Codex", "Max"),
            ("gpt-6.1-terra", 49, 1.53, "Codex", "Max"),
            ("gpt-6-luna", 26, 0.19, "Codex", "Max"),
            ("glm-5.3", 40, 5.41, "OpenCode", "Max"),
            ("claude-opus-5.5", 58, 12.61, "Claude Code", "Max · Default Fallback"),
            ("claude-sonnet-5.5", 56, 11.40, "Claude Code", "Max · Default Fallback"),
            ("claude-haiku-5.5", 30, 2.25, "Claude Code", "Max"),
            ("deepseek-v4.1-flash", 37, 0.32, "DeepSeek Harness", "Max"),
            ("claude-fable-5.2", 58, 15.47, "Claude Code", "Xhigh · Default Fallback"),
            ("claude-fable-5.1", 52, 11.70, "Claude Code", "Max · Default Fallback"),
            ("step-5-preview", 36, 3.55, "Claude Code", "Reasoning"),
            ("qwen3.8-max", 33, 4.03, "Claude Code", "Reasoning"),
            ("gemini-4-neon", 59, 6.86, "Antigravity CLI", "Xhigh"),
            ("kimi-k3.1-pro", 49, 2.94, "Kimi Code CLI", "Max")
        ]
        XCTAssertEqual(entries.count, expected.count)
        for (id, score, cost, harness, configuration) in expected {
            let entry = entries.first { $0.id == id }
            XCTAssertEqual(entry?.benchmarkScore, score, id)
            XCTAssertEqual(entry?.avgCostPerTaskUSD, cost, id)
            XCTAssertEqual(entry?.harness, harness, id)
            XCTAssertEqual(entry?.configuration, configuration, id)
        }
        XCTAssertNotNil(entries.first { $0.id == "deepseek-v4.1-flash" }?.versionNote)
    }

    func testBenchmarkIdentityMatchesOnlyKnownAliasesAndKeepsVariantsDistinct() {
        let providerA = ProviderConfig(name: "A", baseURL: "https://example.com")
        let providerB = ProviderConfig(name: "B", baseURL: "https://example.org")
        let aliases = ["antigravity/claude-sonnet-5-5", "opendesign/claude-sonnet-5.5"]
        let variants = [
            "auto/claude-sonnet-4-6", "auto/claude-sonnet-5-5-thinking",
            "paiyun/glm-5.3-flash", "opendesign/glm-5.3-flashx",
            "auto/deepseek-v4-flash", "opendesign/deepseek-v4.1-flash-eco",
            "auto/deepseek-v4-flash-vision-exp", "group/gpt-6.2-sol",
            "other/gpt-6.2-sol", "gpt-6.2-sol:alternate"
        ]
        let models = aliases.enumerated().map { index, id in
            ModelConfig(providerID: index == 0 ? providerA.id : providerB.id, modelID: id)
        } + variants.map { ModelConfig(providerID: providerA.id, modelID: $0) }
        let cooldown = [models[0].id: Date().addingTimeInterval(60)]
        let coverage = PublicBenchmarkCatalog.coverage(
            providers: [providerA, providerB], models: models, cooldownUntilByModelID: cooldown
        )
        let sonnet = coverage.points.first { $0.id == "claude-sonnet-5.5" }!
        XCTAssertEqual(sonnet.connectedChannels.count, 2)
        XCTAssertTrue(sonnet.connectedChannels.contains { $0.isCoolingDown })
        XCTAssertEqual(coverage.points.filter(\.isLit).count, 1)
        XCTAssertEqual(Set(coverage.unmatchedModels.map(\.id)), Set(variants.map { ModelPresentationIdentity.id(for: $0) }))
        XCTAssertEqual(ModelPresentationIdentity.id(for: "paiyun/deepseek-v4.1-flash-1017"), "deepseek-v4.1-flash")
        XCTAssertNotEqual(ModelPresentationIdentity.id(for: "auto/gpt-6.2-sol"), ModelPresentationIdentity.id(for: "auto/gpt-6.2-astra"))
        XCTAssertEqual(CanonicalModelNormalizer.normalize("opendesign/claude-sonnet-5-5"), "claude-sonnet-5.5")
    }

    func testModelTokenBreakdownCombinesChannelsButSeparatesRevisions() {
        func record(_ modelID: String, _ name: String, _ tokens: Int) -> CallRecord {
            CallRecord(
                source: .externalProxy,
                status: .success,
                requestedModel: "auto",
                executedModelID: modelID,
                executedModelDisplayName: name,
                executedProviderName: "test",
                httpStatusCode: 200,
                requestFeatures: RequestFeatureExtractor.extract(from: ["model": "auto"]),
                decision: RoutingDecision(requestedModel: "auto", isAutoRouted: true, strategyName: "test",
                                          policyVersion: 1, deciderPluginID: "test", decisionDurationMs: 1),
                attempts: [],
                routingDecisionMs: 1,
                upstreamFirstTokenMs: 1,
                totalCompletionMs: 2,
                finalUsage: TokenUsage(promptTokens: tokens, completionTokens: 0),
                usageSource: .upstreamReported,
                usageEstimationMethod: nil,
                costStatus: .calculated,
                primaryAttemptCostUSD: 0,
                retryAttemptsCostUSD: 0,
                totalCostUSD: 0,
                executionOrigin: .real
            )
        }
        let breakdown = ModelTokenBreakdownItem.summarize([
            record("codex/gpt-6.2-sol", "Sol · first", 100),
            record("auto/gpt-6.2-sol", "Sol · second", 300),
            record("gpt-6.1-sol", "Earlier Sol", 200)
        ])
        XCTAssertEqual(breakdown.map(\.id), ["gpt-6.2-sol", "gpt-6.1-sol"])
        XCTAssertEqual(breakdown[0].totalTokens, 400)
        XCTAssertEqual(breakdown[0].callCount, 2)
        XCTAssertEqual(breakdown[0].sharePercent, 200.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(breakdown[1].totalTokens, 200)

        let provider = ProviderConfig(name: "custom", baseURL: "https://example.com")
        let explicit = ModelConfig(providerID: provider.id, modelID: "custom-sol", canonicalModelID: "gpt-6.2-sol")
        let oldSelection = ModelConfig(providerID: provider.id, modelID: "old-sol", canonicalModelID: "gpt-6.1-sol")
        var actual = record("custom-sol", "Custom", 50)
        actual.decision.selectedModelUUID = oldSelection.id
        actual.attempts = [UpstreamAttemptRecord(
            attemptIndex: 1, modelUUID: explicit.id, modelID: "custom-sol", providerID: provider.id,
            providerName: provider.name, httpStatusCode: 200, succeeded: true, firstTokenMs: 1,
            totalLatencyMs: 2, usage: nil, usageSource: .upstreamReported,
            usageEstimationMethod: nil, costUSD: 0, costStatus: .calculated, errorMessage: nil
        )]
        XCTAssertEqual(ModelPresentationIdentity.id(for: actual, models: [explicit, oldSelection]), "gpt-6.2-sol")
        var decisionOnly = actual
        decisionOnly.attempts = []
        decisionOnly.decision.selectedModelUUID = explicit.id
        XCTAssertEqual(ModelPresentationIdentity.id(for: decisionOnly, models: [explicit]), "gpt-6.2-sol")
        decisionOnly.executedModelID = "different-model"
        XCTAssertEqual(ModelPresentationIdentity.id(for: decisionOnly, models: [explicit]), "different-model")
        XCTAssertEqual(ModelPresentationIdentity.id(for: actual, models: []), "custom-sol")
        XCTAssertEqual(ModelTokenBreakdownItem.summarize([actual, record("gpt-6.2-sol", "Sol", 25)], models: [explicit]).first?.totalTokens, 75)
    }

    func testDailyUsageLedgerPersistsSavingsAndIgnoresDemoRecords() {
        var ledger = DailyUsageLedger()
        let features = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [["role": "user", "content": "write code"]]
        ])
        let decision = RoutingDecision(
            requestedModel: "auto",
            isAutoRouted: true,
            selectedModelID: "deepseek-chat",
            strategyName: "省钱优先",
            policyVersion: 1,
            deciderPluginID: "builtin.deterministic.v1",
            decisionDurationMs: 2.0
        )

        let realRecord = CallRecord(
            source: .externalProxy,
            status: .success,
            requestedModel: "auto",
            executedModelID: "deepseek-chat",
            executedModelDisplayName: "DeepSeek Chat",
            executedProviderName: "DeepSeek",
            httpStatusCode: 200,
            requestFeatures: features,
            decision: decision,
            attempts: [],
            routingDecisionMs: 2.0,
            upstreamFirstTokenMs: 200.0,
            totalCompletionMs: 900.0,
            finalUsage: TokenUsage(promptTokens: 300, completionTokens: 200),
            usageSource: .upstreamReported,
            usageEstimationMethod: nil,
            costStatus: .calculated,
            primaryAttemptCostUSD: 0.01,
            retryAttemptsCostUSD: 0,
            totalCostUSD: 0.01,
            executionOrigin: .real
        )
        ledger.record(realRecord, baselineCostUSD: 0.25, baselineLatencyMs: 3900.0)

        let demoRecord = CallRecord(
            source: .testBench,
            status: .success,
            requestedModel: "auto",
            executedModelID: "deepseek-chat",
            executedModelDisplayName: "DeepSeek Chat",
            executedProviderName: "DeepSeek",
            httpStatusCode: 200,
            requestFeatures: features,
            decision: decision,
            attempts: [],
            routingDecisionMs: 2.0,
            upstreamFirstTokenMs: 200.0,
            totalCompletionMs: 900.0,
            finalUsage: TokenUsage(promptTokens: 300, completionTokens: 200),
            usageSource: .upstreamReported,
            usageEstimationMethod: nil,
            costStatus: .calculated,
            primaryAttemptCostUSD: 0.01,
            retryAttemptsCostUSD: 0,
            totalCostUSD: 0.01,
            executionOrigin: .demo
        )
        ledger.record(demoRecord, baselineCostUSD: 99.0, baselineLatencyMs: 99_000.0)

        let summary = ledger.cumulativeSummary()
        XCTAssertEqual(summary.callCount, 1)
        XCTAssertEqual(summary.costSavedUSD, 0.24, accuracy: 0.0001)
        XCTAssertEqual(summary.timeSavedSeconds, 3.0, accuracy: 0.001)
    }

    func testPerStrategyTierAssignmentsAreIndependent() {
        var policy = RoutingPolicyConfig(activeStrategy: .balanced)
        let lowA = UUID()
        let lowB = UUID()
        let backupA = UUID()

        policy.setTierAssignment(TierModelAssignment(primaryModelID: lowA, backupModelIDs: [backupA]), for: .low, strategy: .costFirst)
        policy.setTierAssignment(TierModelAssignment(primaryModelID: lowB, backupModelIDs: []), for: .low, strategy: .qualityFirst)

        policy.applyStrategyTierSnapshot(.costFirst)
        XCTAssertEqual(policy.lowTierModelID, lowA)
        XCTAssertEqual(policy.lowTierBackupModelIDs, [backupA])

        policy.applyStrategyTierSnapshot(.qualityFirst)
        XCTAssertEqual(policy.lowTierModelID, lowB)
        XCTAssertEqual(policy.lowTierBackupModelIDs, [])
    }
}
