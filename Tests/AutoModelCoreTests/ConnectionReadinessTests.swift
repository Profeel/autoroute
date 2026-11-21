import Foundation
import XCTest
@testable import AutoModelCore

final class ConnectionReadinessTests: XCTestCase {
    func testAgentProofRequiresCurrentConfigurationAndRealAliasedSuccess() {
        let now = Date()
        let configuredAt = now.addingTimeInterval(-1)
        let configured = AgentIntegrationStatus(kind: .codex, configFilePath: "test", isInstalled: true, isConnectedToAutoModel: true, hasBackup: true)
        var record = makeRecord(at: now)
        XCTAssertEqual(AgentReadiness.evaluate(status: configured, updatedAt: configuredAt, records: [record]), .verified(record.id))
        var inFlight = record
        inFlight.totalCompletionMs = 2_000
        XCTAssertEqual(AgentReadiness.evaluate(status: configured, updatedAt: configuredAt, records: [inFlight]), .waiting)
        XCTAssertEqual(AgentReadiness.evaluate(status: configured, updatedAt: now.addingTimeInterval(1), records: [record]), .waiting)
        XCTAssertEqual(AgentReadiness.evaluate(status: configured, updatedAt: nil, records: [record]), .waiting)
        var disconnected = configured
        disconnected.isConnectedToAutoModel = false
        XCTAssertEqual(AgentReadiness.evaluate(status: disconnected, updatedAt: now, records: [record]), .notConfigured)
        record.decision.agentID = AgentKind.opencode.rawValue
        XCTAssertEqual(AgentReadiness.evaluate(status: configured, updatedAt: configuredAt, records: [record]), .waiting)
        record.decision.agentID = AgentKind.codex.rawValue
        record.decision.agentIdentitySource = .explicitHeader
        XCTAssertEqual(AgentReadiness.evaluate(status: configured, updatedAt: configuredAt, records: [record]), .waiting)
        record.decision.agentIdentitySource = .modelAlias
        record.executionOrigin = .demo
        XCTAssertEqual(AgentReadiness.evaluate(status: configured, updatedAt: configuredAt, records: [record]), .waiting)
        record.executionOrigin = .real
        record.source = .testBench
        XCTAssertEqual(AgentReadiness.evaluate(status: configured, updatedAt: configuredAt, records: [record]), .waiting)
        record.source = .externalProxy
        record.status = .failed
        XCTAssertEqual(AgentReadiness.evaluate(status: configured, updatedAt: configuredAt, records: [record]), .waiting)
    }

    func testCodexStatusRequiresActiveManagedProviderAndCurrentPortAndKeepsRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentConfigService(homeDirectory: root, backupDirectory: root.appendingPathComponent("backups"))
        let url = service.primaryConfigURL(for: .codex)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "model_provider = \"external\"\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        _ = try service.applyAgentConfig(kind: .codex, binding: .stableIdentity(for: .codex), proxyPort: 8765, localAPIToken: "test-token")
        XCTAssertTrue(service.inspectAgent(.codex, proxyPort: 8765).isConnectedToAutoModel)
        XCTAssertFalse(service.inspectAgent(.codex, proxyPort: 8766).isConnectedToAutoModel)
        let written = try String(contentsOf: url, encoding: .utf8)
        for invalid in ["http://127.0.0.1:87650/v1", "http://example.invalid/?next=localhost:8765", "http://127.0.0.1:8765/wrong"] {
            try written.replacingOccurrences(of: "http://127.0.0.1:8765/v1", with: invalid).write(to: url, atomically: true, encoding: .utf8)
            XCTAssertFalse(service.inspectAgent(.codex, proxyPort: 8765).isConnectedToAutoModel)
        }
        try written.replacingOccurrences(of: "model_provider = \"autoroute\"", with: "model_provider = \"external\"").write(to: url, atomically: true, encoding: .utf8)
        let mismatch = service.inspectAgent(.codex, proxyPort: 8765)
        XCTAssertFalse(mismatch.isConnectedToAutoModel)
        XCTAssertTrue(mismatch.hasBackup)
        _ = try service.restoreAgentConfig(kind: .codex, proxyPort: 8765)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains(original.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @MainActor
    func testOneAvailableModelCanFillEveryTierAndReadinessDistinguishesTesting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AutoModelEngine(persistence: LocalPersistenceStore(baseDirectoryURL: root), keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        let provider = ProviderConfig(name: "Test", baseURL: "https://example.invalid/v1", healthStatus: .unknown)
        try engine.upsertProvider(provider, apiKey: nil)
        var model = ModelConfig(providerID: provider.id, modelID: "one-model")
        engine.upsertModel(model)
        XCTAssertEqual(engine.providerReadiness, .needsTesting)
        for tier in ModelTier.allCases { XCTAssertEqual(engine.model(for: tier)?.id, model.id) }
        model.lastProbedAt = Date()
        engine.upsertModel(model)
        engine.updateProviderHealth(providerID: provider.id, status: .healthy, error: nil)
        XCTAssertEqual(engine.providerReadiness, .ready)
        engine.updateProviderHealth(providerID: provider.id, status: .authError, error: nil)
        XCTAssertEqual(engine.providerReadiness, .missing)
    }

    @MainActor
    func testSavingsUseCurrentBaselineAndExcludeUnclassifiedOrMissingUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalPersistenceStore(baseDirectoryURL: root)
        let keychain = InMemoryKeychainService()
        let engine = AutoModelEngine(persistence: store, keychain: keychain, autoStartProxyIfConfigured: false)
        let provider = ProviderConfig(name: "Test", baseURL: "https://example.invalid/v1", healthStatus: .healthy)
        try engine.upsertProvider(provider, apiKey: nil)
        let first = ModelConfig(providerID: provider.id, modelID: "first", inputPricePerMillion: 10, outputPricePerMillion: 20)
        let second = ModelConfig(providerID: provider.id, modelID: "second", inputPricePerMillion: 3, outputPricePerMillion: 6)
        engine.upsertModel(first)
        engine.upsertModel(second)
        engine.setTierModel(tier: .high, modelUUID: first.id, isManual: true)
        try store.saveConfig(engine.config)
        var real = makeRecord(at: Date())
        real.executedModelID = "other"
        real.finalUsage = TokenUsage(promptTokens: 1_000, completionTokens: 1_000)
        real.usageSource = .upstreamReported
        real.costStatus = .calculated
        real.totalCostUSD = 0.01
        real.comparison = ComparisonAnalysis(basis: .historicalEstimate, baselineModelID: first.modelID, baselineModelDisplayName: first.displayName, costDifferenceUSD: 99, costSavingsPercent: nil, latencyDifferenceMs: nil, sampleCount: 1, note: "old price")
        var unclassified = real
        unclassified.id = UUID()
        unclassified.executionOrigin = nil
        var missingUsage = real
        missingUsage.id = UUID()
        missingUsage.finalUsage = nil
        try store.saveHistory([real, unclassified, missingUsage])
        let reloaded = AutoModelEngine(persistence: store, keychain: keychain, autoStartProxyIfConfigured: false)
        let firstImpact = try XCTUnwrap(reloaded.routingImpactSummary())
        XCTAssertEqual(firstImpact.evaluatedTurnCount, 1)
        XCTAssertEqual(firstImpact.costSavedUSD, 0.02, accuracy: 0.000001)
        reloaded.setTierModel(tier: .high, modelUUID: second.id, isManual: true)
        let secondImpact = try XCTUnwrap(reloaded.routingImpactSummary())
        XCTAssertEqual(secondImpact.baselineModelDisplayName, second.displayName)
        XCTAssertEqual(secondImpact.costSavedUSD, -0.001, accuracy: 0.000001)
    }

    private func makeRecord(at date: Date) -> CallRecord {
        let features = RequestFeatureExtractor.extract(from: ["model": "auto/agent/codex", "messages": [["role": "user", "content": "hello"]]])
        let decision = RoutingDecision(requestedModel: "auto/agent/codex", isAutoRouted: true, selectedModelID: "test", strategyName: "test", policyVersion: 1, deciderPluginID: "test", decisionDurationMs: 1, agentID: AgentKind.codex.rawValue, agentIdentitySource: .modelAlias)
        return CallRecord(timestamp: date, source: .externalProxy, status: .success, requestedModel: "auto/agent/codex", executedModelID: "test", executedModelDisplayName: nil, executedProviderName: nil, httpStatusCode: 200, requestFeatures: features, decision: decision, attempts: [], routingDecisionMs: 1, upstreamFirstTokenMs: nil, totalCompletionMs: 1, finalUsage: nil, usageSource: .unavailable, usageEstimationMethod: nil, costStatus: .noUsage, primaryAttemptCostUSD: nil, retryAttemptsCostUSD: 0, totalCostUSD: nil, executionOrigin: .real)
    }
}
