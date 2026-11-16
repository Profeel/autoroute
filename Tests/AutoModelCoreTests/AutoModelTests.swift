import XCTest
@testable import AutoModelCore

final class AutoModelTests: XCTestCase {
    private func makeTempStore() -> LocalPersistenceStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoModelTests-\(UUID().uuidString)", isDirectory: true)
        return LocalPersistenceStore(baseDirectoryURL: dir)
    }

    // MARK: - 1. Hard Constraints & Deterministic Routing Tests

    func testHardConstraintsFilterToolsVisionContextAndPriceCap() {
        let router = ModelRouter()
        let pID = UUID()
        let provider = ProviderConfig(id: pID, name: "Relay", baseURL: "https://relay.example.com/v1")

        let cheapTextOnly = ModelConfig(
            providerID: pID,
            modelID: "cheap-mini",
            inputPricePerMillion: 0.10,
            outputPricePerMillion: 0.40,
            contextWindow: 16_000,
            capabilities: [.chat],
            defaultRole: .fastEconomy,
            qualityScore: 60,
            speedScore: 95
        )
        let coderWithTools = ModelConfig(
            providerID: pID,
            modelID: "coder-tools",
            inputPricePerMillion: 1.50,
            outputPricePerMillion: 6.00,
            contextWindow: 128_000,
            capabilities: [.chat, .coding, .tools],
            defaultRole: .coding,
            qualityScore: 88,
            speedScore: 75
        )
        let visionPro = ModelConfig(
            providerID: pID,
            modelID: "vision-pro",
            inputPricePerMillion: 5.00,
            outputPricePerMillion: 15.00,
            contextWindow: 200_000,
            capabilities: [.chat, .vision, .tools],
            defaultRole: .vision,
            qualityScore: 95,
            speedScore: 60
        )
        let unpricedModel = ModelConfig(
            providerID: pID,
            modelID: "unpriced-general",
            inputPricePerMillion: nil,
            outputPricePerMillion: nil,
            contextWindow: 128_000,
            capabilities: [.chat, .tools, .vision],
            defaultRole: .general,
            qualityScore: 80,
            speedScore: 80
        )

        let models = [cheapTextOnly, coderWithTools, visionPro, unpricedModel]
        let policy = RoutingPolicyConfig(activeStrategy: .costFirst)

        // Vision request should exclude cheapTextOnly & coderWithTools
        let visionPayload: [String: Any] = [
            "model": "auto",
            "messages": [
                ["role": "user", "content": [
                    ["type": "text", "text": "What is in this image?"],
                    ["type": "image_url", "image_url": ["url": "https://example.com/a.png"]]
                ]]
            ]
        ]
        let visionFeatures = RequestFeatureExtractor.extract(from: visionPayload)
        let visionDecision = router.route(
            requestedModel: "auto",
            features: visionFeatures,
            providers: [provider],
            models: models,
            policy: policy
        )
        XCTAssertEqual(visionDecision.selectedModelID, "vision-pro")
        let cheapEval = visionDecision.candidateEvaluations.first { $0.modelID == "cheap-mini" }
        XCTAssertFalse(cheapEval?.passedHardConstraints ?? true)
        XCTAssertTrue(cheapEval?.exclusionReasons.contains(where: { $0.contains("视觉") }) ?? false)

        // Price cap should exclude expensive models and unpriced models
        var cappedPolicy = policy
        cappedPolicy.maxInputPricePerMillion = 2.0
        let toolsPayload: [String: Any] = [
            "model": "auto",
            "messages": [["role": "user", "content": "Call tool"]],
            "tools": [["type": "function", "function": ["name": "ping"]]]
        ]
        let toolsFeatures = RequestFeatureExtractor.extract(from: toolsPayload)
        let cappedDecision = router.route(
            requestedModel: "auto",
            features: toolsFeatures,
            providers: [provider],
            models: models,
            policy: cappedPolicy
        )
        XCTAssertEqual(cappedDecision.selectedModelID, "coder-tools")
        let visionEval = cappedDecision.candidateEvaluations.first { $0.modelID == "vision-pro" }
        XCTAssertFalse(visionEval?.passedHardConstraints ?? true)
        let unpricedEval = cappedDecision.candidateEvaluations.first { $0.modelID == "unpriced-general" }
        XCTAssertFalse(unpricedEval?.passedHardConstraints ?? true)

        // Context overflow should exclude cheapTextOnly (16k limit)
        let hugeText = String(repeating: "hello world ", count: 10_000) // ~120k chars -> ~37k tokens > 16k
        let longFeatures = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [["role": "user", "content": hugeText]]
        ])
        let longDecision = router.route(
            requestedModel: "auto",
            features: longFeatures,
            providers: [provider],
            models: [cheapTextOnly, coderWithTools],
            policy: policy
        )
        XCTAssertEqual(longDecision.selectedModelID, "coder-tools")
        XCTAssertFalse(longDecision.candidateEvaluations.first { $0.modelID == "cheap-mini" }?.passedHardConstraints ?? true)
    }

    func testStrategySwitchingAndSessionStickiness() {
        let router = ModelRouter()
        let pID = UUID()
        let provider = ProviderConfig(id: pID, name: "Relay", baseURL: "https://relay.example.com/v1")

        let economy = ModelConfig(
            providerID: pID,
            modelID: "fast-cheap",
            inputPricePerMillion: 0.1,
            outputPricePerMillion: 0.3,
            capabilities: [.chat],
            defaultRole: .fastEconomy,
            qualityScore: 62,
            speedScore: 95
        )
        let flagship = ModelConfig(
            providerID: pID,
            modelID: "flagship-pro",
            inputPricePerMillion: 10.0,
            outputPricePerMillion: 30.0,
            capabilities: [.chat, .coding, .reasoning],
            defaultRole: .complexReasoning,
            qualityScore: 98,
            speedScore: 65
        )

        let payload: [String: Any] = [
            "model": "auto",
            "messages": [
                ["role": "system", "content": "You are helpful."],
                ["role": "user", "content": "Hi"],
                ["role": "assistant", "content": "Hello!"],
                ["role": "user", "content": "Design a distributed consensus migration plan and compare tradeoffs."]
            ]
        ]
        let features = RequestFeatureExtractor.extract(from: payload)
        XCTAssertTrue(features.isMultiTurn)

        // Under costFirst (v1), economy is chosen
        let v1Policy = RoutingPolicyConfig(policyVersion: 1, activeStrategy: .costFirst, enableSessionStickiness: true)
        let d1 = router.route(requestedModel: "auto", features: features, providers: [provider], models: [economy, flagship], policy: v1Policy)
        XCTAssertEqual(d1.selectedModelID, "fast-cheap")
        router.recordSuccessfulSessionModel(fingerprint: features.conversationFingerprint, modelUUID: economy.id, policyVersion: 1)

        // Same session & same policyVersion v1 under stickiness keeps fast-cheap
        let d1Sticky = router.route(requestedModel: "auto", features: features, providers: [provider], models: [economy, flagship], policy: v1Policy)
        XCTAssertEqual(d1Sticky.selectedModelID, "fast-cheap")
        XCTAssertTrue(d1Sticky.matchedRules.contains(where: { $0.contains("多轮会话粘性") }))

        // Change policy to qualityFirst (v2) -> stickiness cache is versioned, so decision changes to flagship!
        let v2Policy = RoutingPolicyConfig(policyVersion: 2, activeStrategy: .qualityFirst, enableSessionStickiness: true)
        let d2 = router.route(requestedModel: "auto", features: features, providers: [provider], models: [economy, flagship], policy: v2Policy)
        XCTAssertEqual(d2.selectedModelID, "flagship-pro")
    }

    // MARK: - 2. Pricing & Honest Formatting Tests

    func testPricingCalculationAndMissingPriceLabel() {
        let priced = ModelConfig(
            providerID: UUID(),
            modelID: "priced",
            inputPricePerMillion: 2.0,
            outputPricePerMillion: 6.0
        )
        let cost = priced.calculateCostUSD(promptTokens: 500_000, completionTokens: 250_000)
        XCTAssertNotNil(cost)
        XCTAssertEqual(cost!, 1.0 + 1.5, accuracy: 0.0001)

        let unpriced = ModelConfig(
            providerID: UUID(),
            modelID: "unpriced",
            inputPricePerMillion: nil,
            outputPricePerMillion: nil
        )
        XCTAssertNil(unpriced.calculateCostUSD(promptTokens: 1000, completionTokens: 500))
        XCTAssertEqual(AutoModelFormatter.formatUSD(nil), "无法计算费用")
    }

    // MARK: - 3. End-to-End Proxy, Streaming, Errors, Retry & Keychain Non-Leakage

    @MainActor
    func testEndToEndProxyStreamingStrategyChangeErrorsAndKeychainIsolation() async throws {
        let store = makeTempStore()
        let keychain = InMemoryKeychainService()
        let upstream = LocalTestUpstreamServer(behavior: .init(
            requiredAPIKey: "sk-super-secret-test-9999",
            omitUsageForModels: ["mock-fast-mini"],
            artificialChunkDelayMs: 2
        ))
        let upstreamPort = try upstream.start(port: 0)
        defer { upstream.stop() }

        let engine = AutoModelEngine(
            persistence: store,
            keychain: keychain,
            autoStartProxyIfConfigured: false
        )

        let provider = ProviderConfig(
            name: "LocalMockRelay",
            baseURL: "http://127.0.0.1:\(upstreamPort)",
            isEnabled: true
        )
        try engine.upsertProvider(provider, apiKey: "sk-super-secret-test-9999")

        let fastMini = ModelConfig(
            providerID: provider.id,
            modelID: "mock-fast-mini",
            displayName: "Fast Mini",
            inputPricePerMillion: 0.15,
            outputPricePerMillion: 0.60,
            capabilities: [.chat, .tools],
            defaultRole: .fastEconomy,
            qualityScore: 65,
            speedScore: 95
        )
        let coderPro = ModelConfig(
            providerID: provider.id,
            modelID: "mock-coder-pro",
            displayName: "Coder Pro",
            inputPricePerMillion: 3.00,
            outputPricePerMillion: 12.00,
            capabilities: [.chat, .coding, .reasoning, .tools],
            defaultRole: .complexReasoning,
            qualityScore: 96,
            speedScore: 70
        )
        engine.upsertModel(fastMini)
        engine.upsertModel(coderPro)
        engine.setStrategy(.costFirst)

        let proxyPort = LoopbackHTTPServer.findAvailablePort(startingFrom: 19_100)!
        engine.updateProxyPort(proxyPort)
        engine.startProxy()
        defer { engine.stopProxy() }

        XCTAssertEqual(engine.proxyState, .running(port: proxyPort))

        // A. Port conflict detection when another server binds the same port
        let conflictTestEngine = AutoModelEngine(
            persistence: makeTempStore(),
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        conflictTestEngine.updateProxyPort(proxyPort)
        conflictTestEngine.startProxy()
        if case .portConflict(let occupied, _) = conflictTestEngine.proxyState {
            XCTAssertEqual(occupied, proxyPort)
        } else {
            XCTFail("Expected portConflict when starting on occupied port \(proxyPort)")
        }

        // B. Streaming model=auto request under costFirst -> picks mock-fast-mini, estimates missing usage
        let streamURL = URL(string: "http://127.0.0.1:\(proxyPort)/v1/chat/completions")!
        var req = URLRequest(url: streamURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "auto",
            "stream": true,
            "messages": [["role": "user", "content": "Compare Raft vs Paxos architecture tradeoffs in detail."]]
        ])

        let (bytes, urlResp) = try await URLSession.shared.bytes(for: req)
        let httpResp = try XCTUnwrap(urlResp as? HTTPURLResponse)
        XCTAssertEqual(httpResp.statusCode, 200)
        XCTAssertEqual(httpResp.value(forHTTPHeaderField: "X-AutoModel-Executed-Model"), "mock-fast-mini")

        var sseText = ""
        for try await line in bytes.lines {
            sseText += line + "\n"
        }
        XCTAssertTrue(sseText.contains("data: [DONE]"))
        XCTAssertTrue(sseText.contains("\"mock-fast-mini\""))

        let firstReceipt = try XCTUnwrap(engine.callHistory.first)
        XCTAssertEqual(firstReceipt.status, .success)
        XCTAssertEqual(firstReceipt.executedModelID, "mock-fast-mini")
        XCTAssertEqual(firstReceipt.usageSource, .estimatedWhenMissing)
        XCTAssertNotNil(firstReceipt.usageEstimationMethod)
        XCTAssertNil(firstReceipt.comparison) // No historical samples for baseline yet!

        // C. Switch strategy to qualityFirst and call again -> chooses mock-coder-pro!
        engine.setStrategy(.qualityFirst)
        var req2 = URLRequest(url: streamURL)
        req2.httpMethod = "POST"
        req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req2.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "auto",
            "stream": false,
            "messages": [["role": "user", "content": "Compare Raft vs Paxos architecture tradeoffs in detail."]]
        ])
        let (data2, resp2) = try await URLSession.shared.data(for: req2)
        let http2 = try XCTUnwrap(resp2 as? HTTPURLResponse)
        XCTAssertEqual(http2.statusCode, 200)
        XCTAssertEqual(http2.value(forHTTPHeaderField: "X-AutoModel-Executed-Model"), "mock-coder-pro")
        let json2 = try XCTUnwrap(JSONSerialization.jsonObject(with: data2) as? [String: Any])
        XCTAssertEqual(json2["model"] as? String, "mock-coder-pro")

        let secondReceipt = try XCTUnwrap(engine.callHistory.first)
        XCTAssertEqual(secondReceipt.executedModelID, "mock-coder-pro")
        XCTAssertEqual(secondReceipt.usageSource, .upstreamReported)
        // Now mock-fast-mini has a real historical record, so historicalEstimate exists and is clearly labeled
        XCTAssertEqual(secondReceipt.comparison?.basis, .historicalEstimate)

        // D. Unsupported endpoints return 501; unknown model returns 404; unsupported param returns 400
        var embReq = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/embeddings")!)
        embReq.httpMethod = "POST"
        embReq.httpBody = Data("{}".utf8)
        let (_, embResp) = try await URLSession.shared.data(for: embReq)
        XCTAssertEqual((embResp as? HTTPURLResponse)?.statusCode, 501)

        var unknownReq = URLRequest(url: streamURL)
        unknownReq.httpMethod = "POST"
        unknownReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "nonexistent-model",
            "messages": [["role": "user", "content": "hi"]]
        ])
        let (_, unknownResp) = try await URLSession.shared.data(for: unknownReq)
        XCTAssertEqual((unknownResp as? HTTPURLResponse)?.statusCode, 404)

        // E. Upstream primary failure triggers fallback retry cleanly
        upstream.updateBehavior(.init(
            requiredAPIKey: "sk-super-secret-test-9999",
            failModelsWithStatus: ["mock-coder-pro": (500, "Simulated upstream overload")],
            artificialChunkDelayMs: 1
        ))
        let (_, retryResp) = try await URLSession.shared.data(for: req2)
        let retryHTTP = try XCTUnwrap(retryResp as? HTTPURLResponse)
        XCTAssertEqual(retryHTTP.statusCode, 200)
        XCTAssertEqual(retryHTTP.value(forHTTPHeaderField: "X-AutoModel-Executed-Model"), "mock-fast-mini")
        let retryReceipt = try XCTUnwrap(engine.callHistory.first)
        XCTAssertEqual(retryReceipt.attempts.count, 2)
        XCTAssertFalse(retryReceipt.attempts[0].succeeded)
        XCTAssertTrue(retryReceipt.attempts[1].succeeded)

        // F. Invalid API Key returns real 401 failure (never fake success)
        try engine.upsertProvider(provider, apiKey: "wrong-key-123")
        upstream.updateBehavior(.init(requiredAPIKey: "sk-super-secret-test-9999"))
        let (_, authFailResp) = try await URLSession.shared.data(for: req2)
        XCTAssertEqual((authFailResp as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(engine.callHistory.first?.status, .failed)

        // G. Keychain isolation: secrets NEVER appear in config.json, history.json, or exported JSON
        let configRaw = try String(contentsOf: store.configFileURL, encoding: .utf8)
        let historyRaw = try String(contentsOf: store.historyFileURL, encoding: .utf8)
        let exportData = try store.exportReceiptsJSON(records: engine.callHistory, secretsToRedact: keychain.allKnownSecretValues())
        let exportRaw = String(data: exportData, encoding: .utf8) ?? ""

        XCTAssertFalse(configRaw.contains("sk-super-secret-test-9999"))
        XCTAssertFalse(configRaw.contains("wrong-key-123"))
        XCTAssertFalse(historyRaw.contains("sk-super-secret-test-9999"))
        XCTAssertFalse(exportRaw.contains("sk-super-secret-test-9999"))
    }

    @MainActor
    func testUnsupportedParamsMissingPriceReceiptAndRealABTest() async throws {
        let store = makeTempStore()
        let keychain = InMemoryKeychainService()
        let upstream = LocalTestUpstreamServer(behavior: .init(artificialChunkDelayMs: 1))
        let upstreamPort = try upstream.start(port: 0)
        defer { upstream.stop() }

        let engine = AutoModelEngine(
            persistence: store,
            keychain: keychain,
            autoStartProxyIfConfigured: false
        )

        let provider = ProviderConfig(
            name: "LocalUpstream",
            baseURL: "http://127.0.0.1:\(upstreamPort)",
            isEnabled: true
        )
        try engine.upsertProvider(provider, apiKey: nil)

        // Discover models via real HTTP GET /v1/models
        let discovered = await engine.testProviderConnection(providerID: provider.id)
        switch discovered {
        case .success(let list):
            XCTAssertTrue(list.contains("mock-fast-mini"))
            XCTAssertTrue(list.contains("mock-coder-pro"))
        case .failure(let err):
            XCTFail("Expected discovery success, got \(err)")
        }

        // Unpriced economy model + priced pro model
        let unpricedMini = ModelConfig(
            providerID: provider.id,
            modelID: "mock-fast-mini",
            inputPricePerMillion: nil,
            outputPricePerMillion: nil,
            capabilities: [.chat],
            defaultRole: .fastEconomy,
            qualityScore: 65,
            speedScore: 95
        )
        let pricedPro = ModelConfig(
            providerID: provider.id,
            modelID: "mock-coder-pro",
            inputPricePerMillion: 2.0,
            outputPricePerMillion: 8.0,
            capabilities: [.chat, .coding],
            defaultRole: .coding,
            qualityScore: 92,
            speedScore: 70
        )
        engine.upsertModel(unpricedMini)
        engine.upsertModel(pricedPro)

        let proxyPort = LoopbackHTTPServer.findAvailablePort(startingFrom: 19_200)!
        engine.updateProxyPort(proxyPort)
        engine.startProxy()
        defer { engine.stopProxy() }

        // Unsupported `audio` parameter -> 400
        let url = URL(string: "http://127.0.0.1:\(proxyPort)/v1/chat/completions")!
        var audioReq = URLRequest(url: url)
        audioReq.httpMethod = "POST"
        audioReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "auto",
            "audio": ["voice": "alloy"],
            "messages": [["role": "user", "content": "hi"]]
        ])
        let (_, audioResp) = try await URLSession.shared.data(for: audioReq)
        XCTAssertEqual((audioResp as? HTTPURLResponse)?.statusCode, 400)

        // Pin unpriced model and verify costStatus == .missingPriceConfig
        engine.updatePolicy { $0.pinnedModelID = unpricedMini.id }
        let outcome = await engine.executeChatCompletion(
            payload: [
                "model": "auto",
                "stream": false,
                "messages": [["role": "user", "content": "Explain caching."]]
            ],
            source: .testBench,
            abBaselineModelUUID: pricedPro.id
        )
        XCTAssertEqual(outcome.httpStatusCode, 200)
        XCTAssertEqual(outcome.callRecord.costStatus, .missingPriceConfig)
        XCTAssertNil(outcome.callRecord.totalCostUSD)
        XCTAssertEqual(outcome.callRecord.comparison?.basis, .realABTest)
        XCTAssertEqual(outcome.callRecord.comparison?.baselineModelID, "mock-coder-pro")
        XCTAssertNotNil(outcome.callRecord.comparison?.latencyDifferenceMs)
    }

    func testMacOSKeychainRoundTrip() throws {
        let kc = MacOSKeychainService(service: "org.automodel.app.keychaintest.\(UUID().uuidString)")
        let providerID = UUID()
        defer { try? kc.clearAll() }

        XCTAssertFalse(kc.hasAPIKey(for: providerID))
        try kc.setAPIKey("sk-keychain-live-1234", for: providerID)
        XCTAssertTrue(kc.hasAPIKey(for: providerID))
        XCTAssertEqual(try kc.getAPIKey(for: providerID), "sk-keychain-live-1234")

        try kc.setAPIKey("sk-keychain-updated-5678", for: providerID)
        XCTAssertEqual(try kc.getAPIKey(for: providerID), "sk-keychain-updated-5678")

        try kc.deleteAPIKey(for: providerID)
        XCTAssertNil(try kc.getAPIKey(for: providerID))
        XCTAssertFalse(kc.hasAPIKey(for: providerID))
    }

    @MainActor
    func testLocalConfigDiscoveryAndAutoEvictionOfBrokenModels() async throws {
        let store = makeTempStore()
        let keychain = InMemoryKeychainService()

        // Start a mock upstream where two models work, one is retired (410), and one is out of credits (402)
        let upstream = LocalTestUpstreamServer(behavior: .init(
            requiredAPIKey: "sk-discovered-opencode-777",
            failModelsWithStatus: [
                "mock-retired-model": (410, "mock-retired-model was retired."),
                "mock-exhausted-model": (402, "insufficient_balance: coding_plan_exhausted")
            ],
            artificialChunkDelayMs: 1
        ))
        let livePort = try upstream.start(port: 0)
        defer { upstream.stop() }

        // Create a temporary simulated home directory containing .config/opencode/opencode.json
        // with one reachable provider (livePort) and one dead local provider (unused port)
        let deadPort = LoopbackHTTPServer.findAvailablePort(startingFrom: 19_800)!
        let fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeHome-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        let opencodeDir = fakeHome.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: opencodeDir, withIntermediateDirectories: true)

        let opencodeConfig: [String: Any] = [
            "provider": [
                "local-relay": [
                    "options": [
                        "baseURL": "http://127.0.0.1:\(livePort)/v1",
                        "apiKey": "sk-discovered-opencode-777"
                    ],
                    "models": [
                        "mock-fast-mini": [
                            "name": "Mock Fast Mini",
                            "cost": ["input": 0.1, "output": 0.4],
                            "limit": ["context": 128_000],
                            "modalities": ["input": ["text"], "output": ["text"]]
                        ],
                        "mock-coder-pro": [
                            "name": "Mock Coder Pro",
                            "cost": ["input": 2.0, "output": 8.0],
                            "limit": ["context": 200_000],
                            "reasoning": true,
                            "modalities": ["input": ["text", "image"], "output": ["text"]]
                        ],
                        "mock-retired-model": [
                            "name": "Mock Retired",
                            "cost": ["input": 0.05, "output": 0.1],
                            "limit": ["context": 128_000]
                        ],
                        "mock-exhausted-model": [
                            "name": "Mock Exhausted",
                            "cost": ["input": 0.05, "output": 0.1],
                            "limit": ["context": 128_000]
                        ]
                    ]
                ],
                "offline-local": [
                    "options": [
                        "baseURL": "http://127.0.0.1:\(deadPort)/v1"
                    ],
                    "models": [
                        "offline-gemma": [
                            "name": "Offline Gemma",
                            "limit": ["context": 32_000]
                        ]
                    ]
                ]
            ]
        ]
        let opencodeData = try JSONSerialization.data(withJSONObject: opencodeConfig, options: [.prettyPrinted])
        try opencodeData.write(to: opencodeDir.appendingPathComponent("opencode.json"))

        let engine = AutoModelEngine(
            persistence: store,
            keychain: keychain,
            autoStartProxyIfConfigured: false
        )

        let summary = await engine.discoverAndProbeLocalModels(
            homeDirectory: fakeHome,
            scanWellKnownLocalPorts: false
        )
        XCTAssertEqual(summary.discoveredProvidersCount, 2)
        XCTAssertEqual(summary.discoveredModelsCount, 5)
        XCTAssertEqual(summary.healthyModelsCount, 2)
        XCTAssertEqual(summary.evictedModelsCount, 3)

        // Discovered key stored in Keychain, never leaked in config.json
        let liveProvider = try XCTUnwrap(engine.config.providers.first { $0.name == "local-relay" })
        XCTAssertEqual(try keychain.getAPIKey(for: liveProvider.id), "sk-discovered-opencode-777")
        let configText = try String(contentsOf: store.configFileURL, encoding: .utf8)
        XCTAssertFalse(configText.contains("sk-discovered-opencode-777"))

        // Verify broken models were auto-evicted with exact status
        let retired = try XCTUnwrap(engine.config.models.first { $0.modelID == "mock-retired-model" })
        XCTAssertTrue(retired.isAutoEvicted)
        XCTAssertEqual(retired.availabilityStatus, .retired)

        let exhausted = try XCTUnwrap(engine.config.models.first { $0.modelID == "mock-exhausted-model" })
        XCTAssertTrue(exhausted.isAutoEvicted)
        XCTAssertEqual(exhausted.availabilityStatus, .insufficientCredits)

        let offline = try XCTUnwrap(engine.config.models.first { $0.modelID == "offline-gemma" })
        XCTAssertTrue(offline.isAutoEvicted)
        XCTAssertEqual(offline.availabilityStatus, .unavailable)

        // Verify healthy models survived with measured probe latency
        let healthyMini = try XCTUnwrap(engine.config.models.first { $0.modelID == "mock-fast-mini" })
        XCTAssertFalse(healthyMini.isAutoEvicted)
        XCTAssertEqual(healthyMini.availabilityStatus, .available)
        XCTAssertNotNil(healthyMini.lastProbeLatencyMs)

        // Routing with costFirst picks mock-fast-mini (even though retired/exhausted had lower prices!)
        // and records eviction reasons for the 3 excluded models
        engine.setStrategy(.costFirst)
        let outcome = await engine.executeChatCompletion(
            payload: [
                "model": "auto",
                "stream": false,
                "messages": [["role": "user", "content": "Hello"]]
            ],
            source: .externalProxy
        )
        XCTAssertEqual(outcome.httpStatusCode, 200)
        XCTAssertEqual(outcome.callRecord.executedModelID, "mock-fast-mini")
        let retiredEval = outcome.callRecord.decision.candidateEvaluations.first { $0.modelID == "mock-retired-model" }
        XCTAssertFalse(retiredEval?.passedHardConstraints ?? true)
        XCTAssertTrue(retiredEval?.exclusionReasons.contains(where: { $0.contains("自动测活剔除") }) ?? false)
    }

    // MARK: - 4. Three-Tier Configuration & Tier-Aware Routing Tests

    @MainActor
    func testThreeTierAutoConfigurationAndManualOverrideAndRouting() async throws {
        let store = makeTempStore()
        let keychain = InMemoryKeychainService()
        let engine = AutoModelEngine(
            persistence: store,
            keychain: keychain,
            autoStartProxyIfConfigured: false
        )

        let provider = ProviderConfig(name: "TestRelay", baseURL: "https://relay.example.com/v1", isEnabled: true, healthStatus: .healthy)
        try engine.upsertProvider(provider, apiKey: "sk-test-123")

        let flashModel = ModelConfig(
            providerID: provider.id,
            modelID: "mock-flash-mini",
            displayName: "Flash Mini",
            inputPricePerMillion: 0.08,
            outputPricePerMillion: 0.30,
            capabilities: [.chat, .tools],
            defaultRole: .fastEconomy,
            qualityScore: 68,
            speedScore: 96,
            lastProbeLatencyMs: 120
        )
        let mediumModel = ModelConfig(
            providerID: provider.id,
            modelID: "mock-coder-mid",
            displayName: "Coder Mid",
            inputPricePerMillion: 1.20,
            outputPricePerMillion: 4.50,
            capabilities: [.chat, .coding, .tools],
            defaultRole: .coding,
            qualityScore: 86,
            speedScore: 82,
            lastProbeLatencyMs: 450
        )
        let highModel = ModelConfig(
            providerID: provider.id,
            modelID: "mock-opus-high",
            displayName: "Opus High",
            inputPricePerMillion: 8.00,
            outputPricePerMillion: 24.00,
            capabilities: [.chat, .coding, .reasoning, .tools, .vision],
            defaultRole: .complexReasoning,
            qualityScore: 97,
            speedScore: 60,
            lastProbeLatencyMs: 1200
        )
        let evictedCheap = ModelConfig(
            providerID: provider.id,
            modelID: "mock-dead-free",
            displayName: "Dead Free",
            inputPricePerMillion: 0.01,
            outputPricePerMillion: 0.01,
            capabilities: [.chat],
            defaultRole: .fastEconomy,
            qualityScore: 70,
            speedScore: 99,
            availabilityStatus: .insufficientCredits,
            isAutoEvicted: true
        )

        engine.upsertModel(flashModel)
        engine.upsertModel(mediumModel)
        engine.upsertModel(highModel)
        engine.upsertModel(evictedCheap)

        // Auto-configured tiers should avoid evicted models and place Flash -> Low, Coder -> Medium, Opus -> High
        XCTAssertEqual(engine.config.policy.lowTierModelID, flashModel.id)
        XCTAssertEqual(engine.config.policy.mediumTierModelID, mediumModel.id)
        XCTAssertEqual(engine.config.policy.highTierModelID, highModel.id)

        // Explicit virtual tier aliases resolve directly to each configured tier
        let lowFeatures = RequestFeatureExtractor.extract(from: ["messages": [["role": "user", "content": "hi"]]])
        let explicitLow = engine.router.route(requestedModel: "auto/low", features: lowFeatures, providers: engine.config.providers, models: engine.config.models, policy: engine.config.policy)
        XCTAssertEqual(explicitLow.selectedModelID, "mock-flash-mini")

        let explicitMed = engine.router.route(requestedModel: "auto/medium", features: lowFeatures, providers: engine.config.providers, models: engine.config.models, policy: engine.config.policy)
        XCTAssertEqual(explicitMed.selectedModelID, "mock-coder-mid")

        let explicitHigh = engine.router.route(requestedModel: "auto/high", features: lowFeatures, providers: engine.config.providers, models: engine.config.models, policy: engine.config.policy)
        XCTAssertEqual(explicitHigh.selectedModelID, "mock-opus-high")

        // Under balanced mode, model=auto maps simple QA -> Low, coding -> Medium, architecture reasoning -> High
        engine.setStrategy(.balanced)
        let qaDecision = engine.router.route(requestedModel: "auto", features: lowFeatures, providers: engine.config.providers, models: engine.config.models, policy: engine.config.policy)
        XCTAssertEqual(qaDecision.selectedModelID, "mock-flash-mini")
        XCTAssertTrue(qaDecision.matchedRules.contains(where: { $0.contains("三档路由命中") && $0.contains("低档") }))

        let codeFeatures = RequestFeatureExtractor.extract(from: ["messages": [["role": "user", "content": "请重构这段 Swift func 函数，优化代码结构"]]])
        let codeDecision = engine.router.route(requestedModel: "auto", features: codeFeatures, providers: engine.config.providers, models: engine.config.models, policy: engine.config.policy)
        XCTAssertEqual(codeDecision.selectedModelID, "mock-coder-mid")
        XCTAssertTrue(codeDecision.matchedRules.contains(where: { $0.contains("三档路由命中") && $0.contains("中档") }))

        let archFeatures = RequestFeatureExtractor.extract(from: ["messages": [["role": "user", "content": "Compare Raft and Paxos architecture tradeoffs step by step."]]])
        let archDecision = engine.router.route(requestedModel: "auto", features: archFeatures, providers: engine.config.providers, models: engine.config.models, policy: engine.config.policy)
        XCTAssertEqual(archDecision.selectedModelID, "mock-opus-high")
        XCTAssertTrue(archDecision.matchedRules.contains(where: { $0.contains("三档路由命中") && $0.contains("高档") }))

        // User manually changes Low tier -> autoConfigureModelTiers(forceResetManual: false) must preserve manual override
        engine.setTierModel(tier: .low, modelUUID: mediumModel.id, isManual: true)
        engine.autoConfigureModelTiers(forceResetManual: false)
        XCTAssertEqual(engine.config.policy.lowTierModelID, mediumModel.id)
        XCTAssertTrue(engine.config.policy.lowTierIsManual)

        // If the manually assigned model becomes evicted, auto-maintenance self-heals Low back to healthy flashModel
        engine.updateModelAvailability(modelID: mediumModel.id, status: .unavailable, note: "timeout", autoEvicted: true)
        XCTAssertEqual(engine.config.policy.lowTierModelID, flashModel.id)
    }

    @MainActor
    func testSetStrategyAutomaticallyUpdatesThreeTierModels() async throws {
        let store = makeTempStore()
        let keychain = InMemoryKeychainService()
        let engine = AutoModelEngine(
            persistence: store,
            keychain: keychain,
            autoStartProxyIfConfigured: false
        )

        let provider = ProviderConfig(name: "MockStrategyProvider", baseURL: "https://mock.local/v1", isEnabled: true, healthStatus: .healthy)
        try engine.upsertProvider(provider, apiKey: "sk-test-strategy")

        let ultraCheap = ModelConfig(
            providerID: provider.id,
            modelID: "mock-nano-eco",
            displayName: "Nano Eco",
            inputPricePerMillion: 0.05,
            outputPricePerMillion: 0.15,
            capabilities: [.chat],
            defaultRole: .fastEconomy,
            qualityScore: 68,
            speedScore: 98,
            lastProbeLatencyMs: 110
        )
        let midEconomy = ModelConfig(
            providerID: provider.id,
            modelID: "mock-flash-coder",
            displayName: "Flash Coder",
            inputPricePerMillion: 0.25,
            outputPricePerMillion: 0.80,
            capabilities: [.chat, .coding, .tools],
            defaultRole: .coding,
            qualityScore: 80,
            speedScore: 90,
            lastProbeLatencyMs: 220
        )
        let strongCoder = ModelConfig(
            providerID: provider.id,
            modelID: "mock-sonnet-pro",
            displayName: "Sonnet Pro",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            capabilities: [.chat, .coding, .tools, .reasoning],
            defaultRole: .coding,
            qualityScore: 92,
            speedScore: 76,
            lastProbeLatencyMs: 650
        )
        let ultraFlagship = ModelConfig(
            providerID: provider.id,
            modelID: "mock-opus-terra",
            displayName: "Opus Terra",
            inputPricePerMillion: 15.0,
            outputPricePerMillion: 75.0,
            capabilities: [.chat, .coding, .tools, .reasoning],
            defaultRole: .complexReasoning,
            qualityScore: 99,
            speedScore: 55,
            lastProbeLatencyMs: 1400
        )

        for model in [ultraCheap, midEconomy, strongCoder, ultraFlagship] {
            engine.upsertModel(model)
        }

        // Switching to .costFirst should avoid the ultra-expensive flagship in High tier and pick cheaper models
        engine.setStrategy(.costFirst)
        XCTAssertEqual(engine.config.policy.activeStrategy, .costFirst)
        XCTAssertEqual(engine.config.policy.lowTierModelID, ultraCheap.id)
        XCTAssertNotEqual(engine.config.policy.highTierModelID, ultraFlagship.id)

        // Switching to .qualityFirst should automatically promote High tier to the ultraFlagship
        // and upgrade Low/Medium tiers toward higher-quality models
        engine.setStrategy(.qualityFirst)
        XCTAssertEqual(engine.config.policy.activeStrategy, .qualityFirst)
        XCTAssertEqual(engine.config.policy.highTierModelID, ultraFlagship.id)
        XCTAssertNotEqual(engine.config.policy.lowTierModelID, ultraCheap.id)
    }

    // MARK: - 5. Magpie-Style Multi-Agent Auto-Configuration & Restore Tests

    func testMagpieStyleAgentAutoConfigAndBackupRestore() async throws {
        let fm = FileManager.default
        let fakeHome = fm.temporaryDirectory.appendingPathComponent("AutoModelAgentHome-\(UUID().uuidString)", isDirectory: true)
        let backupDir = fm.temporaryDirectory.appendingPathComponent("AutoModelAgentBackups-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: fakeHome)
            try? fm.removeItem(at: backupDir)
        }

        // 1. Seed realistic pre-existing configs (Codex with Magpie + projects, OpenCode with MCP, Hermes with multiple providers, Claude Code with hooks)
        let codexDir = fakeHome.appendingPathComponent(".codex", isDirectory: true)
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let originalCodex = """
        wire_api = "chat"
        approval_policy = "never"
        model = "gpt-6.1-terra"
        # magpie: points at magpie's local gateway; Disconnect in magpie or `magpie uninstall` undoes it, or delete this line
        openai_base_url = "http://127.0.0.1:3425/backend-api/codex"

        [projects."/tmp/demo-project"]
        trust_level = "trusted"
        """
        try originalCodex.write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let opencodeDir = fakeHome.appendingPathComponent(".config/opencode", isDirectory: true)
        try fm.createDirectory(at: opencodeDir, withIntermediateDirectories: true)
        let originalOpenCodeObj: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "model": "magpie/auto/glm-5.3",
            "mcp": ["codegraph": ["enabled": true, "type": "local"]],
            "provider": [
                "magpie": [
                    "options": [
                        "baseURL": "http://127.0.0.1:3425/v1",
                        "apiKey": "magpie-key"
                    ],
                    "models": [
                        "auto/glm-5.3": ["name": "GLM 5.3"]
                    ]
                ]
            ]
        ]
        let originalOpenCodeData = try JSONSerialization.data(withJSONObject: originalOpenCodeObj, options: [.prettyPrinted, .sortedKeys])
        try originalOpenCodeData.write(to: opencodeDir.appendingPathComponent("opencode.json"))

        let hermesDir = fakeHome.appendingPathComponent(".hermes", isDirectory: true)
        try fm.createDirectory(at: hermesDir, withIntermediateDirectories: true)
        let originalHermes = """
        model:
          default: auto
          max_tokens: 8192
          provider: volcengine
          base_url: https://ark.cn-beijing.volces.com/api/plan/v3
        providers:
          volcengine:
            name: volcengine
            model: glm-5.3
        """
        try originalHermes.write(to: hermesDir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let claudeDir = fakeHome.appendingPathComponent(".claude", isDirectory: true)
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let originalClaudeObj: [String: Any] = [
            "hooks": ["PreToolUse": [["hooks": [["command": "/tmp/hook.sh", "type": "command"]]]]]
        ]
        let originalClaudeData = try JSONSerialization.data(withJSONObject: originalClaudeObj, options: [.prettyPrinted, .sortedKeys])
        try originalClaudeData.write(to: claudeDir.appendingPathComponent("settings.json"))

        let service = AgentConfigService(homeDirectory: fakeHome, backupDirectory: backupDir)

        // Apply custom bindings across all agents
        let codexBinding = AgentModelBinding(defaultModelOption: "auto/high")
        let codexStatus = try service.applyAgentConfig(kind: .codex, binding: codexBinding, proxyPort: 8765)
        XCTAssertTrue(codexStatus.isConnectedToAutoModel)
        XCTAssertTrue(codexStatus.hasBackup)
        let injectedCodex = try String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(injectedCodex.contains("model = \"auto/high\""))
        XCTAssertTrue(injectedCodex.contains("openai_base_url = \"http://127.0.0.1:8765/v1\""))
        XCTAssertTrue(injectedCodex.contains("[projects.\"/tmp/demo-project\"]"))
        XCTAssertTrue(injectedCodex.contains("trust_level = \"trusted\""))

        let openCodeBinding = AgentModelBinding(
            defaultModelOption: "auto",
            lowModelOption: "auto/low",
            mediumModelOption: "auto/medium",
            highModelOption: "mock-opus-high"
        )
        let openCodeStatus = try service.applyAgentConfig(
            kind: .opencode,
            binding: openCodeBinding,
            proxyPort: 8765,
            resolvedTierDisplayNames: [.low: "Flash Mini", .medium: "Coder Mid", .high: "Opus High"]
        )
        XCTAssertTrue(openCodeStatus.isConnectedToAutoModel)
        let injectedOCData = try Data(contentsOf: opencodeDir.appendingPathComponent("opencode.json"))
        let injectedOC = try XCTUnwrap(JSONSerialization.jsonObject(with: injectedOCData) as? [String: Any])
        XCTAssertEqual(injectedOC["model"] as? String, "automodel/auto")
        XCTAssertEqual(injectedOC["small_model"] as? String, "automodel/auto/low")
        XCTAssertNotNil(injectedOC["mcp"])
        let ocProviders = try XCTUnwrap(injectedOC["provider"] as? [String: Any])
        XCTAssertNotNil(ocProviders["magpie"]) // Preserved
        let amProvider = try XCTUnwrap(ocProviders["automodel"] as? [String: Any])
        let amModels = try XCTUnwrap(amProvider["models"] as? [String: Any])
        XCTAssertNotNil(amModels["auto/low"])
        XCTAssertNotNil(amModels["auto/medium"])
        XCTAssertNotNil(amModels["auto/high"])
        XCTAssertNotNil(amModels["mock-opus-high"])

        // Verify discovery skips self-injected "automodel" provider & 127.0.0.1:8765
        let rescan = await LocalModelDiscoveryService().scanLocalEnvironment(
            homeDirectory: fakeHome,
            excludeLoopbackPort: 8765,
            scanWellKnownLocalPorts: false
        )
        XCTAssertFalse(rescan.providers.contains(where: { $0.name.lowercased() == "automodel" }))
        XCTAssertFalse(rescan.providers.contains(where: { $0.baseURL.contains("127.0.0.1:8765") }))

        let hermesStatus = try service.applyAgentConfig(kind: .hermes, binding: AgentModelBinding(), proxyPort: 8765)
        XCTAssertTrue(hermesStatus.isConnectedToAutoModel)
        let injectedHermes = try String(contentsOf: hermesDir.appendingPathComponent("config.yaml"), encoding: .utf8)
        XCTAssertTrue(injectedHermes.contains("provider: automodel"))
        XCTAssertTrue(injectedHermes.contains("base_url: http://127.0.0.1:8765/v1"))
        XCTAssertTrue(injectedHermes.contains("max_tokens: 8192"))
        XCTAssertTrue(injectedHermes.contains("volcengine:"))

        let claudeStatus = try service.applyAgentConfig(kind: .claudeCode, binding: openCodeBinding, proxyPort: 8765)
        XCTAssertTrue(claudeStatus.isConnectedToAutoModel)
        let injectedClaudeData = try Data(contentsOf: claudeDir.appendingPathComponent("settings.json"))
        let injectedClaude = try XCTUnwrap(JSONSerialization.jsonObject(with: injectedClaudeData) as? [String: Any])
        XCTAssertNotNil(injectedClaude["hooks"])
        let claudeEnv = try XCTUnwrap(injectedClaude["env"] as? [String: Any])
        XCTAssertEqual(claudeEnv["OPENAI_BASE_URL"] as? String, "http://127.0.0.1:8765/v1")
        XCTAssertEqual(claudeEnv["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String, "auto/low")
        XCTAssertEqual(claudeEnv["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, "auto/medium")
        XCTAssertEqual(claudeEnv["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String, "mock-opus-high")

        let shellStatus = try service.applyAgentConfig(kind: .shellAndContinue, binding: openCodeBinding, proxyPort: 8765)
        XCTAssertTrue(shellStatus.isConnectedToAutoModel)
        let envScript = try String(contentsOf: fakeHome.appendingPathComponent(".automodel/agent-env.sh"), encoding: .utf8)
        XCTAssertTrue(envScript.contains("export OPENAI_BASE_URL=\"http://127.0.0.1:8765/v1\""))
        XCTAssertTrue(envScript.contains("export AUTOMODEL_HIGH_MODEL=\"mock-opus-high\""))

        // Re-applying after modifying binding must NOT overwrite the original pre-AutoModel backup
        _ = try service.applyAgentConfig(kind: .codex, binding: AgentModelBinding(defaultModelOption: "auto"), proxyPort: 8765)

        // Restore all agents cleanly -> exact original files restored, generated agent-env.sh deleted
        _ = try service.restoreAgentConfig(kind: .codex, proxyPort: 8765)
        _ = try service.restoreAgentConfig(kind: .opencode, proxyPort: 8765)
        _ = try service.restoreAgentConfig(kind: .hermes, proxyPort: 8765)
        _ = try service.restoreAgentConfig(kind: .claudeCode, proxyPort: 8765)
        _ = try service.restoreAgentConfig(kind: .shellAndContinue, proxyPort: 8765)

        XCTAssertEqual(try String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8), originalCodex)
        XCTAssertEqual(try Data(contentsOf: opencodeDir.appendingPathComponent("opencode.json")), originalOpenCodeData)
        XCTAssertEqual(try String(contentsOf: hermesDir.appendingPathComponent("config.yaml"), encoding: .utf8), originalHermes)
        XCTAssertEqual(try Data(contentsOf: claudeDir.appendingPathComponent("settings.json")), originalClaudeData)
        XCTAssertFalse(fm.fileExists(atPath: fakeHome.appendingPathComponent(".automodel/agent-env.sh").path))
    }

    @MainActor
    func testProtocolAdaptersAndEndpoints() async throws {
        // 1. Anthropic Messages request -> OpenAI Chat Completions & back
        let anthropicReqJSON: [String: Any] = [
            "model": "auto/low",
            "max_tokens": 512,
            "system": "You are a concise assistant.",
            "messages": [
                ["role": "user", "content": [["type": "text", "text": "Hello Claude proxy"]]]
            ],
            "tools": [
                [
                    "name": "get_weather",
                    "description": "Get weather",
                    "input_schema": ["type": "object", "properties": ["city": ["type": "string"]]]
                ]
            ]
        ]
        let chatReqResult = ProtocolAdapters.anthropicToOpenAIRequest(anthropicReqJSON, configuredModels: [])
        guard case .success(let chatReq) = chatReqResult else {
            return XCTFail("Expected anthropicToOpenAIRequest to succeed")
        }
        XCTAssertEqual(chatReq["model"] as? String, "auto/low")
        XCTAssertEqual(chatReq["max_tokens"] as? Int, 512)
        let anthropicMsgs = try XCTUnwrap(chatReq["messages"] as? [[String: Any]])
        XCTAssertEqual(anthropicMsgs.first?["role"] as? String, "system")
        XCTAssertEqual(anthropicMsgs.last?["role"] as? String, "user")
        XCTAssertEqual(anthropicMsgs.last?["content"] as? String, "Hello Claude proxy")
        XCTAssertEqual((chatReq["tools"] as? [[String: Any]])?.count, 1)

        // 2. OpenAI Responses request -> OpenAI Chat Completions
        let responsesReqJSON: [String: Any] = [
            "model": "auto",
            "instructions": "Be helpful.",
            "input": "Summarize Swift concurrency",
            "max_output_tokens": 256,
            "stream": false
        ]
        let respReqResult = ProtocolAdapters.responsesToChatRequest(responsesReqJSON)
        guard case .success(let convertedFromResponses) = respReqResult else {
            return XCTFail("Expected responsesToChatRequest to succeed")
        }
        XCTAssertEqual(convertedFromResponses["model"] as? String, "auto")
        XCTAssertEqual(convertedFromResponses["max_tokens"] as? Int, 256)
        let respMsgs = try XCTUnwrap(convertedFromResponses["messages"] as? [[String: Any]])
        XCTAssertEqual(respMsgs.first?["role"] as? String, "system")
        XCTAssertEqual(respMsgs.last?["content"] as? String, "Summarize Swift concurrency")

        // 3. Live local proxy /v1/messages & /v1/responses against LocalTestUpstreamServer
        let upstream = LocalTestUpstreamServer()
        let upstreamPort = try upstream.start()
        defer { upstream.stop() }

        let engine = AutoModelEngine(
            persistence: makeTempStore(),
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )

        let provider = ProviderConfig(name: "MockProto", baseURL: "http://127.0.0.1:\(upstreamPort)/v1")
        try engine.upsertProvider(provider, apiKey: "mock-key")
        let model = ModelConfig(
            providerID: provider.id,
            modelID: "mock-fast-mini",
            displayName: "Mock Eco",
            inputPricePerMillion: 0.2,
            outputPricePerMillion: 0.6,
            contextWindow: 64000,
            capabilities: [.chat, .tools],
            defaultRole: .fastEconomy
        )
        engine.upsertModel(model)
        engine.setTierModel(tier: .low, modelUUID: model.id, isManual: true)
        let proxyPort = LoopbackHTTPServer.findAvailablePort(startingFrom: 19_200)!
        engine.updateProxyPort(proxyPort)
        engine.startProxy()
        defer { engine.stopProxy() }
        XCTAssertEqual(engine.proxyState, .running(port: proxyPort))

        // Test POST /v1/messages (non-stream)
        var msgReq = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/messages")!)
        msgReq.httpMethod = "POST"
        msgReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        msgReq.setValue("test-anthropic-key", forHTTPHeaderField: "x-api-key")
        msgReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "auto/low",
            "max_tokens": 128,
            "messages": [["role": "user", "content": "Say hi"]]
        ])
        let (msgData, msgResp) = try await URLSession.shared.data(for: msgReq)
        XCTAssertEqual((msgResp as? HTTPURLResponse)?.statusCode, 200)
        let msgJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: msgData) as? [String: Any])
        XCTAssertEqual(msgJSON["type"] as? String, "message")
        XCTAssertEqual(msgJSON["role"] as? String, "assistant")
        let msgContent = try XCTUnwrap(msgJSON["content"] as? [[String: Any]])
        XCTAssertEqual(msgContent.first?["type"] as? String, "text")
        XCTAssertFalse((msgContent.first?["text"] as? String ?? "").isEmpty)
        XCTAssertEqual(engine.callHistory.first?.displayClientAgent, "Claude Code")
        XCTAssertEqual(engine.callHistory.first?.endpointPath, "/v1/messages")

        // Test POST /v1/responses (non-stream)
        var respReq = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!)
        respReq.httpMethod = "POST"
        respReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        respReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "auto",
            "input": "Say hello via responses"
        ])
        let (respData, respHTTP) = try await URLSession.shared.data(for: respReq)
        XCTAssertEqual((respHTTP as? HTTPURLResponse)?.statusCode, 200)
        let respJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: respData) as? [String: Any])
        XCTAssertEqual(respJSON["object"] as? String, "response")
        XCTAssertEqual(respJSON["status"] as? String, "completed")
        let outputItems = try XCTUnwrap(respJSON["output"] as? [[String: Any]])
        let firstMsgContent = try XCTUnwrap(outputItems.first?["content"] as? [[String: Any]])
        XCTAssertFalse((firstMsgContent.first?["text"] as? String ?? "").isEmpty)
        XCTAssertEqual(engine.callHistory.first?.displayClientAgent, "Codex")
        XCTAssertEqual(engine.callHistory.first?.endpointPath, "/v1/responses")
    }

    func testSystemPromptIsolatedIntentClassificationAndReasoningExtraction() throws {
        // System prompt containing coding keywords should NOT skew simple user QA into coding/reasoning
        let payload: [String: Any] = [
            "model": "auto",
            "stream": false,
            "messages": [
                ["role": "system", "content": "You are an expert software engineer. You can write code, debug stack traces, refactor modules, and run SQL."],
                ["role": "user", "content": "你好，今天天气怎么样？"]
            ]
        ]
        let features = RequestFeatureExtractor.extract(from: payload)
        XCTAssertEqual(features.detectedTaskType, .simpleQA)

        // Reasoning content extraction from OpenAI-compatible payload
        let raw = """
        {"choices":[{"message":{"role":"assistant","reasoning_content":"Let me think step by step.","content":"42"}}]}
        """.data(using: .utf8)!
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let parsed = UpstreamClient.extractAssistantAndReasoning(from: json)
        XCTAssertEqual(parsed.content, "42")
        XCTAssertEqual(parsed.reasoning, "Let me think step by step.")

        // AgentConfigService previewAgentConfig returns non-empty after diff without writing to disk
        let fm = FileManager.default
        let fakeHome = fm.temporaryDirectory.appendingPathComponent("automodel-preview-\(UUID().uuidString)")
        try fm.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fakeHome) }
        let service = AgentConfigService(homeDirectory: fakeHome)
        let preview = try service.previewAgentConfig(
            kind: .claudeCode,
            binding: AgentModelBinding(),
            proxyPort: 8765,
            resolvedTierDisplayNames: [.low: "Mock Low", .medium: "Mock Med", .high: "Mock High"]
        )
        XCTAssertTrue(preview.before.contains("尚不存在"))
        XCTAssertTrue(preview.after.contains("ANTHROPIC_BASE_URL"))
        XCTAssertTrue(preview.after.contains("http://127.0.0.1:8765"))
        XCTAssertFalse(fm.fileExists(atPath: fakeHome.appendingPathComponent(".claude/settings.json").path))
    }

    func testCallRecordComplexityAndSessionGroupingHelpers() throws {
        let lowFeatures = RequestFeatures(
            messageCount: 2,
            estimatedInputTokens: 60,
            requiresTools: false,
            requiresVision: false,
            requiresJSONMode: false,
            isStreaming: false,
            detectedTaskType: .simpleQA,
            conversationFingerprint: "sess_abc12345",
            isMultiTurn: false
        )
        let highFeatures = RequestFeatures(
            messageCount: 6,
            estimatedInputTokens: 4200,
            requiresTools: true,
            requiresVision: false,
            requiresJSONMode: false,
            isStreaming: true,
            detectedTaskType: .complexReasoning,
            conversationFingerprint: "sess_abc12345",
            isMultiTurn: true
        )

        let lowRecord = CallRecord(
            source: .externalProxy,
            status: .success,
            requestedModel: "auto",
            executedModelID: "glm-flash",
            executedModelDisplayName: "GLM Flash",
            executedProviderName: "Mock",
            httpStatusCode: 200,
            requestFeatures: lowFeatures,
            decision: RoutingDecision(
                requestedModel: "auto",
                isAutoRouted: true,
                matchedRules: ["三档路由命中 [低档]：任务「简单问答/摘要」"],
                strategyName: "均衡模式",
                policyVersion: 1,
                deciderPluginID: "deterministic",
                decisionDurationMs: 0.4
            ),
            attempts: [],
            routingDecisionMs: 0.4,
            upstreamFirstTokenMs: 120,
            totalCompletionMs: 450,
            finalUsage: nil,
            usageSource: .estimatedWhenMissing,
            usageEstimationMethod: nil,
            costStatus: .missingPriceConfig,
            primaryAttemptCostUSD: nil,
            retryAttemptsCostUSD: 0,
            totalCostUSD: nil
        )

        let highRecord = CallRecord(
            source: .externalProxy,
            status: .success,
            requestedModel: "auto",
            executedModelID: "gpt-astra",
            executedModelDisplayName: "GPT Astra",
            executedProviderName: "Codex",
            httpStatusCode: 200,
            requestFeatures: highFeatures,
            decision: RoutingDecision(
                requestedModel: "auto",
                isAutoRouted: true,
                matchedRules: ["三档路由命中 [高档]：任务「复杂推理与架构」"],
                strategyName: "均衡模式",
                policyVersion: 1,
                deciderPluginID: "deterministic",
                decisionDurationMs: 0.5
            ),
            attempts: [],
            routingDecisionMs: 0.5,
            upstreamFirstTokenMs: 280,
            totalCompletionMs: 1800,
            finalUsage: nil,
            usageSource: .upstreamReported,
            usageEstimationMethod: nil,
            costStatus: .missingPriceConfig,
            primaryAttemptCostUSD: nil,
            retryAttemptsCostUSD: 0,
            totalCostUSD: nil
        )

        let directRecord = CallRecord(
            source: .externalProxy,
            status: .success,
            requestedModel: "gpt-astra",
            executedModelID: "gpt-astra",
            executedModelDisplayName: "GPT Astra",
            executedProviderName: "Codex",
            httpStatusCode: 200,
            requestFeatures: lowFeatures,
            decision: RoutingDecision(
                requestedModel: "gpt-astra",
                isAutoRouted: false,
                matchedRules: ["显式指定模型"],
                strategyName: "均衡模式",
                policyVersion: 1,
                deciderPluginID: "deterministic",
                decisionDurationMs: 0.2
            ),
            attempts: [],
            routingDecisionMs: 0.2,
            upstreamFirstTokenMs: 200,
            totalCompletionMs: 800,
            finalUsage: nil,
            usageSource: .upstreamReported,
            usageEstimationMethod: nil,
            costStatus: .missingPriceConfig,
            primaryAttemptCostUSD: nil,
            retryAttemptsCostUSD: 0,
            totalCostUSD: nil
        )

        XCTAssertEqual(lowRecord.routingComplexityLevel, .low)
        XCTAssertEqual(highRecord.routingComplexityLevel, .high)
        XCTAssertEqual(directRecord.routingComplexityLevel, .direct)
        XCTAssertEqual(lowRecord.sessionGroupKey, highRecord.sessionGroupKey)
        XCTAssertEqual(lowRecord.sessionGroupKey, "sess_abc12345")
        XCTAssertTrue(lowRecord.humanReadableSummary.contains("GLM Flash"))
        XCTAssertTrue(lowRecord.humanReadableSummary.contains("简单问答/摘要"))
        XCTAssertTrue(directRecord.humanReadableSummary.contains("直连转发"))
    }

    func testMagpieStyleCodexClaudeAndProviderDiscovery() async throws {
        let fm = FileManager.default
        let fakeHome = fm.temporaryDirectory.appendingPathComponent("FakeMagpieHome-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: fakeHome) }

        // 1. ~/.codex/auth.json + ~/.codex/models_cache.json + ~/.codex/config.toml
        let codexDir = fakeHome.appendingPathComponent(".codex", isDirectory: true)
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let authJSON: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": "codex-oauth-access-token-123",
                "account_id": "acct_codex_999"
            ]
        ]
        try JSONSerialization.data(withJSONObject: authJSON).write(to: codexDir.appendingPathComponent("auth.json"))

        let modelsCacheJSON: [String: Any] = [
            "models": [
                ["slug": "gpt-6.1-terra", "visibility": "list"],
                ["slug": "gpt-6.1-sol", "visibility": "list"],
                ["slug": "gpt-5.6-sol", "visibility": "list"],
                ["slug": "codex-auto-review", "visibility": "list"],
                ["slug": "hidden-internal-model", "visibility": "hide"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: modelsCacheJSON).write(to: codexDir.appendingPathComponent("models_cache.json"))

        let codexToml = """
        model = "gpt-6.1-terra"
        openai_base_url = "http://127.0.0.1:3425/backend-api/codex"

        [model_providers.magpie]
        name = "magpie"
        base_url = "http://127.0.0.1:3425/v1"
        wire_api = "responses"

        [model_providers.my_relay]
        name = "My Codex Relay"
        base_url = "https://relay.example.com/v1"
        wire_api = "responses"
        experimental_bearer_token = "sk-codex-relay-888"
        """
        try codexToml.write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        // 2. ~/.config/magpie/providers.json
        let magpieDir = fakeHome.appendingPathComponent(".config/magpie", isDirectory: true)
        try fm.createDirectory(at: magpieDir, withIntermediateDirectories: true)
        let magpieProviders: [String: Any] = [
            "providers": [
                [
                    "id": "volcengine",
                    "name": "Volcengine Ark",
                    "key": "ark-key-123",
                    "chat": "https://ark.example.com/api/v3",
                    "models": ["glm-5.3", "deepseek-v4"],
                    "off": false
                ],
                [
                    "id": "disabled_one",
                    "name": "Disabled Provider",
                    "key": "dead-key",
                    "chat": "https://disabled.example.com/v1",
                    "models": ["m1"],
                    "off": true
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: magpieProviders).write(to: magpieDir.appendingPathComponent("providers.json"))

        // 3. ~/.claude/settings.json
        let claudeDir = fakeHome.appendingPathComponent(".claude", isDirectory: true)
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let claudeSettings: [String: Any] = [
            "env": [
                "ANTHROPIC_BASE_URL": "https://claude-relay.example.com",
                "ANTHROPIC_AUTH_TOKEN": "sk-ant-relay-555",
                "ANTHROPIC_MODEL": "claude-sonnet-4-6"
            ]
        ]
        try JSONSerialization.data(withJSONObject: claudeSettings).write(to: claudeDir.appendingPathComponent("settings.json"))

        let discovery = LocalModelDiscoveryService()
        let result = await discovery.scanLocalEnvironment(
            homeDirectory: fakeHome,
            excludeLoopbackPort: 8765,
            scanWellKnownLocalPorts: false
        )

        // Verify Codex ChatGPT subscription & models_cache.json
        let codexSub = result.providers.first(where: { $0.apiProtocol == .codexChatGPT })
        XCTAssertNotNil(codexSub)
        XCTAssertEqual(codexSub?.apiKey, "codex-oauth-access-token-123")
        XCTAssertEqual(codexSub?.accountID, "acct_codex_999")
        let codexSlugs = Set(codexSub?.models.map(\.modelID) ?? [])
        XCTAssertTrue(codexSlugs.contains("gpt-6.1-terra"))
        XCTAssertTrue(codexSlugs.contains("gpt-6.1-sol"))
        XCTAssertTrue(codexSlugs.contains("gpt-5.6-sol"))
        XCTAssertFalse(codexSlugs.contains("codex-auto-review"))
        XCTAssertFalse(codexSlugs.contains("hidden-internal-model"))

        // Verify [model_providers.my_relay] from config.toml (and magpie skipped)
        let codexRelay = result.providers.first(where: { $0.baseURL == "https://relay.example.com/v1" })
        XCTAssertNotNil(codexRelay)
        XCTAssertEqual(codexRelay?.apiProtocol, .openAIResponses)
        XCTAssertEqual(codexRelay?.apiKey, "sk-codex-relay-888")
        XCTAssertNil(result.providers.first(where: { $0.name == "magpie" }))

        // Verify Magpie providers.json (enabled imported, off: true skipped)
        let volc = result.providers.first(where: { $0.name == "Volcengine Ark" })
        XCTAssertNotNil(volc)
        XCTAssertEqual(volc?.apiKey, "ark-key-123")
        XCTAssertEqual(Set(volc?.models.map(\.modelID) ?? []), Set(["glm-5.3", "deepseek-v4"]))
        XCTAssertNil(result.providers.first(where: { $0.name == "Disabled Provider" }))

        // Verify Claude settings.json
        let claude = result.providers.first(where: { $0.apiProtocol == .anthropicMessages })
        XCTAssertNotNil(claude)
        XCTAssertEqual(claude?.apiKey, "sk-ant-relay-555")
        XCTAssertEqual(claude?.models.first?.modelID, "claude-sonnet-4-6")

        // Verify Chat -> Responses request + SSE stream translation
        let req = ProtocolAdapters.chatToResponsesRequest([
            "messages": [
                ["role": "system", "content": "Be concise"],
                ["role": "user", "content": "Hello"]
            ]
        ], modelID: "gpt-6.1-terra", forceStream: true, store: false, defaultInstructions: "Default")
        XCTAssertEqual(req["model"] as? String, "gpt-6.1-terra")
        XCTAssertEqual(req["instructions"] as? String, "Be concise")
        XCTAssertEqual(req["store"] as? Bool, false)
        XCTAssertEqual(req["stream"] as? Bool, true)

        let translator = ResponsesUpstreamStreamTranslator(modelName: "gpt-6.1-terra")
        let sseIn = """
        data: {"type":"response.output_text.delta","delta":"Hello "}

        data: {"type":"response.output_text.delta","delta":"Codex!"}

        data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}

        """
        let chunks = translator.processSSEBytes(Data(sseIn.utf8))
        XCTAssertEqual(translator.fullText, "Hello Codex!")
        XCTAssertEqual(translator.usage?.totalTokens, 15)
        XCTAssertFalse(chunks.isEmpty)
    }

    func testSubtaskCategoryAndEffortAutoRouting() {
        let router = ModelRouter()
        let pID = UUID()
        let provider = ProviderConfig(id: pID, name: "TestRelay", baseURL: "https://relay.example.com/v1")

        let fastModel = ModelConfig(
            providerID: pID,
            modelID: "fast-flash",
            displayName: "Fast Flash",
            inputPricePerMillion: 0.1,
            outputPricePerMillion: 0.2,
            capabilities: [.chat, .tools],
            defaultRole: .fastEconomy,
            qualityScore: 70,
            speedScore: 95
        )
        let reasonerModel = ModelConfig(
            providerID: pID,
            modelID: "deep-reasoner",
            displayName: "Deep Reasoner",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 12.0,
            capabilities: [.chat, .coding, .tools, .reasoning],
            defaultRole: .complexReasoning,
            qualityScore: 97,
            speedScore: 72
        )

        // 1. Exploration / search -> low effort -> fastModel
        let exploreFeatures = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "system", "content": "You are a coding assistant."],
                ["role": "user", "content": "grep where RoutingDecision is defined in Sources"]
            ]
        ], sessionHeader: "sess-effort-1")
        XCTAssertEqual(exploreFeatures.subtaskCategory, .explorationSearch)
        XCTAssertEqual(exploreFeatures.recommendedEffort, .low)

        let policy = RoutingPolicyConfig(
            policyVersion: 1,
            activeStrategy: .balanced,
            enableSessionStickiness: true,
            lowTierModelID: fastModel.id,
            mediumTierModelID: fastModel.id,
            highTierModelID: reasonerModel.id,
            preferTierMappingInAuto: true
        )
        let dExplore = router.route(requestedModel: "auto", features: exploreFeatures, providers: [provider], models: [fastModel, reasonerModel], policy: policy)
        XCTAssertEqual(dExplore.selectedModelID, "fast-flash")
        XCTAssertEqual(dExplore.selectedEffort, .low)
        XCTAssertEqual(dExplore.subtaskCategory, .explorationSearch)
        router.recordSuccessfulSessionModel(fingerprint: exploreFeatures.conversationFingerprint, modelUUID: fastModel.id, policyVersion: 1)

        // 2. Multi-turn escalation to deep debugging (crash / stack trace) -> breaks weak sticky fastModel & routes to reasoner with max effort
        let debugFeatures = RequestFeatureExtractor.extract(from: [
            "model": "auto",
            "messages": [
                ["role": "system", "content": "You are a coding assistant."],
                ["role": "user", "content": "grep where RoutingDecision is defined in Sources"],
                ["role": "assistant", "content": "Found in Models.swift"],
                ["role": "user", "content": "Here is a fatal crash stack trace deadlock when decoding RoutingDecision, debug root cause."]
            ]
        ], sessionHeader: "sess-effort-1")
        XCTAssertEqual(debugFeatures.subtaskCategory, .deepDebugging)
        XCTAssertEqual(debugFeatures.recommendedEffort, .max)

        let dDebug = router.route(requestedModel: "auto", features: debugFeatures, providers: [provider], models: [fastModel, reasonerModel], policy: policy)
        XCTAssertEqual(dDebug.selectedModelID, "deep-reasoner")
        XCTAssertEqual(dDebug.selectedEffort, .max)
        XCTAssertEqual(dDebug.subtaskCategory, .deepDebugging)
        XCTAssertNotNil(dDebug.routingReasonNote)
    }

    @MainActor
    func testRoutingImpactSummaryComputesRealSavingsAndSpeedAndLongTail() async throws {
        let store = makeTempStore()
        let keychain = InMemoryKeychainService()
        let engine = AutoModelEngine(
            persistence: store,
            keychain: keychain,
            autoStartProxyIfConfigured: false
        )

        let provider = ProviderConfig(name: "ImpactProvider", baseURL: "https://impact.local/v1", isEnabled: true, healthStatus: .healthy)
        try engine.upsertProvider(provider, apiKey: "sk-impact")

        let cheapModel = ModelConfig(
            providerID: provider.id,
            modelID: "mock-cheap",
            displayName: "Mock Cheap",
            inputPricePerMillion: 0.2,
            outputPricePerMillion: 0.6,
            capabilities: [.chat, .tools],
            defaultRole: .fastEconomy,
            qualityScore: 72,
            speedScore: 95
        )
        let highBaseline = ModelConfig(
            providerID: provider.id,
            modelID: "mock-opus-baseline",
            displayName: "Mock Opus",
            inputPricePerMillion: 10.0,
            outputPricePerMillion: 30.0,
            capabilities: [.chat, .coding, .reasoning, .tools],
            defaultRole: .complexReasoning,
            qualityScore: 98,
            speedScore: 55
        )
        engine.upsertModel(cheapModel)
        engine.upsertModel(highBaseline)
        engine.setTierModel(tier: .high, modelUUID: highBaseline.id, isManual: true)

        let baseFeatures = RequestFeatureExtractor.extract(from: ["messages": [["role": "user", "content": "hi"]]])
        let cheapDecision = engine.router.route(
            requestedModel: "mock-cheap",
            features: baseFeatures,
            providers: engine.config.providers,
            models: engine.config.models,
            policy: engine.config.policy
        )
        let highDecision = engine.router.route(
            requestedModel: "mock-opus-baseline",
            features: baseFeatures,
            providers: engine.config.providers,
            models: engine.config.models,
            policy: engine.config.policy
        )

        func makeRecord(model: ModelConfig, decision: RoutingDecision, promptTok: Int, compTok: Int, latencyMs: Double, retries: Int = 1) -> CallRecord {
            let cost = model.calculateCostUSD(promptTokens: promptTok, completionTokens: compTok) ?? 0
            let usage = TokenUsage(promptTokens: promptTok, completionTokens: compTok)
            let attempts = (0..<retries).map { idx in
                UpstreamAttemptRecord(
                    attemptIndex: idx + 1,
                    modelUUID: model.id,
                    modelID: model.modelID,
                    providerID: provider.id,
                    providerName: provider.name,
                    httpStatusCode: idx == retries - 1 ? 200 : 500,
                    succeeded: idx == retries - 1,
                    firstTokenMs: latencyMs * 0.25,
                    totalLatencyMs: latencyMs,
                    usage: idx == retries - 1 ? usage : nil,
                    usageSource: .upstreamReported,
                    usageEstimationMethod: nil,
                    costUSD: idx == retries - 1 ? cost : 0,
                    costStatus: .calculated,
                    errorMessage: nil
                )
            }
            return CallRecord(
                source: .externalProxy,
                status: .success,
                requestedModel: "auto",
                executedModelID: model.modelID,
                executedModelDisplayName: model.displayName,
                executedProviderName: provider.name,
                httpStatusCode: 200,
                requestFeatures: baseFeatures,
                decision: decision,
                attempts: attempts,
                routingDecisionMs: 2.0,
                upstreamFirstTokenMs: latencyMs * 0.25,
                totalCompletionMs: latencyMs,
                finalUsage: usage,
                usageSource: .upstreamReported,
                usageEstimationMethod: nil,
                costStatus: .calculated,
                primaryAttemptCostUSD: cost,
                retryAttemptsCostUSD: 0,
                totalCostUSD: cost
            )
        }

        // 4 cheap fast turns + 1 expensive slow high-tier turn
        let seededRecords = [
            makeRecord(model: cheapModel, decision: cheapDecision, promptTok: 10_000, compTok: 1_000, latencyMs: 1200),
            makeRecord(model: cheapModel, decision: cheapDecision, promptTok: 10_000, compTok: 1_000, latencyMs: 1400),
            makeRecord(model: cheapModel, decision: cheapDecision, promptTok: 10_000, compTok: 1_000, latencyMs: 1300),
            makeRecord(model: cheapModel, decision: cheapDecision, promptTok: 10_000, compTok: 1_000, latencyMs: 1500),
            makeRecord(model: highBaseline, decision: highDecision, promptTok: 20_000, compTok: 4_000, latencyMs: 9000, retries: 2)
        ]
        try store.saveHistory(seededRecords)

        let reloadedEngine = AutoModelEngine(
            persistence: store,
            keychain: keychain,
            autoStartProxyIfConfigured: false
        )

        let summary = try XCTUnwrap(reloadedEngine.routingImpactSummary())
        XCTAssertEqual(summary.baselineModelDisplayName, "Mock Opus")
        XCTAssertEqual(summary.evaluatedTurnCount, 5)
        XCTAssertGreaterThan(summary.costSavedUSD, 0.4)
        XCTAssertGreaterThan(summary.costSavingsPercent ?? 0, 50.0)
        XCTAssertGreaterThan(summary.speedGainPercent ?? 0, 60.0)
        XCTAssertGreaterThan(summary.speedSavedMsPerTurn ?? 0, 5000.0)
        XCTAssertEqual(summary.retryCount, 1)
        XCTAssertEqual(summary.successRatePercent, 100)
        // The single expensive high-tier turn accounts for >95% of total spend
        XCTAssertGreaterThan(summary.top10PercentCostSharePercent ?? 0, 90.0)
    }
}
