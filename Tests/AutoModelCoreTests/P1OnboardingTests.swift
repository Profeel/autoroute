import XCTest
@testable import AutoModelCore

final class P1OnboardingTests: XCTestCase {
    @MainActor
    func testOnboardingValidationUsesRealLoopbackHTTPAndDemoDoesNotComplete() async throws {
        let store = LocalPersistenceStore(
            baseDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        defer {
            engine.stopProxy()
            engine.stopLocalTestUpstream()
        }
        try engine.installLocalTestPreset()
        XCTAssertFalse(engine.config.privacySettings.hasCompletedOnboarding)
        let proxyPort = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 22_100))
        engine.updateProxyPort(proxyPort)

        let result = try await engine.validateOnboardingEndToEnd()
        XCTAssertTrue(result.isDemo)
        XCTAssertEqual(result.record.status, .success)
        XCTAssertEqual(result.record.source, .externalProxy)
        XCTAssertEqual(result.record.endpointPath, "/v1/chat/completions")
        XCTAssertNotNil(result.record.executedModelID)
        XCTAssertNotNil(result.record.decision.routingReasonNote)
        XCTAssertFalse(engine.config.privacySettings.hasCompletedOnboarding)
        XCTAssertTrue(engine.callHistory.contains { $0.id == result.record.id })

        engine.skipOnboarding()
        XCTAssertTrue(engine.config.privacySettings.hasCompletedOnboarding)
    }

    @MainActor
    func testMixedProvidersCompleteOnboardingOnlyWhenReceiptExecutedRealModel() async throws {
        let fixture = try mixedProviderEngine(routeToRealModel: true)
        defer {
            fixture.engine.stopProxy()
            fixture.engine.stopLocalTestUpstream()
            fixture.realUpstream.stop()
        }

        let result = try await fixture.engine.validateOnboardingEndToEnd()
        XCTAssertFalse(result.isDemo)
        XCTAssertEqual(result.record.executionOrigin, .real)
        XCTAssertEqual(result.record.executedProviderName, "Independent Real Test Upstream")
        XCTAssertTrue(fixture.engine.config.privacySettings.hasCompletedOnboarding)
        XCTAssertEqual(fixture.engine.onboardingFunnel.firstRealSuccessCount, 1)
        XCTAssertEqual(fixture.engine.onboardingFunnel.demoValidationCount, 0)
    }

    @MainActor
    func testMixedProvidersNeverCompleteOnboardingWhenReceiptExecutedMockModel() async throws {
        let fixture = try mixedProviderEngine(routeToRealModel: false)
        defer {
            fixture.engine.stopProxy()
            fixture.engine.stopLocalTestUpstream()
            fixture.realUpstream.stop()
        }

        let result = try await fixture.engine.validateOnboardingEndToEnd()
        XCTAssertTrue(result.isDemo)
        XCTAssertEqual(result.record.executionOrigin, .demo)
        XCTAssertFalse(fixture.engine.config.privacySettings.hasCompletedOnboarding)
        XCTAssertEqual(fixture.engine.onboardingFunnel.firstRealSuccessCount, 0)
        XCTAssertEqual(fixture.engine.onboardingFunnel.demoValidationCount, 1)
    }

    @MainActor
    private func mixedProviderEngine(routeToRealModel: Bool) throws -> (engine: AutoModelEngine, realUpstream: LocalTestUpstreamServer) {
        let store = LocalPersistenceStore(
            baseDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        let demoPort = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 22_500))
        _ = try engine.startLocalTestUpstream(port: demoPort)
        try engine.installLocalTestPreset()
        engine.recordOnboardingStarted()

        let realUpstream = LocalTestUpstreamServer()
        let realPort = try realUpstream.start(port: 0)
        let realProvider = ProviderConfig(
            name: "Independent Real Test Upstream",
            baseURL: "http://127.0.0.1:\(realPort)",
            isEnabled: true,
            timeoutSeconds: 10,
            healthStatus: .healthy
        )
        try engine.upsertProvider(realProvider, apiKey: "independent-real-test-key")
        let realModel = ModelConfig(
            providerID: realProvider.id,
            modelID: "independent-real-model",
            displayName: "Independent Real Model",
            isEnabled: true,
            inputPricePerMillion: 1,
            outputPricePerMillion: 2,
            capabilities: [.chat],
            availabilityStatus: .available
        )
        engine.upsertModel(realModel)

        let demoModel = try XCTUnwrap(engine.config.models.first { $0.modelID == "mock-fast-mini" })
        for tier in ModelTier.allCases {
            engine.setTierModel(tier: tier, modelUUID: routeToRealModel ? realModel.id : demoModel.id)
        }
        let proxyPort = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 22_700))
        engine.updateProxyPort(proxyPort)
        return (engine, realUpstream)
    }

    @MainActor
    func testOnboardingValidationWithoutHealthyModelReturnsActionableError() async {
        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(
                baseDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            ),
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        do {
            _ = try await engine.validateOnboardingEndToEnd()
            XCTFail("Expected actionable validation error")
        } catch let error as OnboardingValidationError {
            XCTAssertEqual(error, .noHealthyModel)
            XCTAssertTrue(error.localizedDescription.contains("供应商"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
