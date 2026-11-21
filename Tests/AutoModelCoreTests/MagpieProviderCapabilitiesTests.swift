import XCTest
@testable import AutoModelCore

final class MagpieProviderCapabilitiesTests: XCTestCase {

    private final class RequestCaptureBox: @unchecked Sendable {
        struct CapturedRequest {
            let authorization: String?
            let customTenant: String?
            let referer: String?
            let traceID: String?
            let apiKeyHeader: String?
            let cookie: String?
            let blockedClientHeader: String?
        }

        private let lock = NSLock()
        private var records: [CapturedRequest] = []

        func append(_ req: HTTPRequestMessage) -> Int {
            lock.lock()
            defer { lock.unlock() }
            records.append(CapturedRequest(
                authorization: req.header("authorization"),
                customTenant: req.header("x-custom-tenant"),
                referer: req.header("referer"),
                traceID: req.header("x-trace-id"),
                apiKeyHeader: req.header("x-api-key"),
                cookie: req.header("cookie"),
                blockedClientHeader: req.header("x-blocked-client")
            ))
            return records.count
        }

        func snapshot() -> [CapturedRequest] {
            lock.lock()
            defer { lock.unlock() }
            return records
        }
    }

    private func makeTempDir(_ name: String = UUID().uuidString) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoModelMagpieTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func makeEngine(dir: URL, keychain: InMemoryKeychainService = InMemoryKeychainService()) -> AutoModelEngine {
        AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: dir),
            keychain: keychain,
            alertNotifier: NoOpSystemAlertNotifier(),
            autoStartProxyIfConfigured: false
        )
    }

    private func makeOpenAIChatSuccessJSON(content: String, model: String = "gpt-4o-mini") -> Data {
        let obj: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString.prefix(8))",
            "object": "chat.completion",
            "created": 1_700_000_000,
            "model": model,
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": content
                    ],
                    "finish_reason": "stop"
                ]
            ],
            "usage": [
                "prompt_tokens": 12,
                "completion_tokens": 6,
                "total_tokens": 18
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    private func sendProxyChatRequest(
        port: Int,
        localToken: String,
        model: String = "auto",
        extraHeaders: [String: String] = [:]
    ) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "ping"]
            ],
            "stream": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, data)
    }

    // MARK: - 1. Preset Catalog & Preset Seeding

    @MainActor
    func testPresetCatalogCompletenessAndAddProviderFromPreset() throws {
        let presets = ProviderPresetCatalog.allPresets
        XCTAssertGreaterThanOrEqual(presets.count, 15)

        let ids = presets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Preset IDs must be unique")

        for preset in presets {
            let parsed = URL(string: preset.baseURL)
            XCTAssertNotNil(parsed?.host, "Preset \(preset.id) must have valid URL")
            XCTAssertFalse(preset.name.isEmpty)
        }

        let openrouter = try XCTUnwrap(ProviderPresetCatalog.preset(id: "openrouter"))
        XCTAssertFalse(openrouter.defaultHeaders.isEmpty)
        XCTAssertFalse(openrouter.recommendedModels.isEmpty)
        XCTAssertEqual(
            ProviderPresetCatalog.matchPreset(baseURL: "https://openrouter.ai/api/v1", name: nil)?.id,
            "openrouter"
        )

        let dir = makeTempDir("presets")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = InMemoryKeychainService()
        let engine = makeEngine(dir: dir, keychain: keychain)

        let added = try engine.addProviderFromPreset(
            openrouter,
            apiKeys: ["sk-or-secret-1", "sk-or-secret-2"],
            proxyURL: "http://127.0.0.1:7890",
            passThroughHeaderNames: ["X-Trace-Id"],
            keyRotationStrategy: .roundRobin,
            seedRecommendedModels: true
        )

        XCTAssertEqual(added.provider.presetID, "openrouter")
        XCTAssertEqual(added.provider.configuredKeyCount, 2)
        XCTAssertEqual(added.provider.proxyURL, "http://127.0.0.1:7890")
        XCTAssertEqual(added.provider.passThroughHeaderNames, ["X-Trace-Id"])
        for (k, v) in openrouter.defaultHeaders {
            XCTAssertEqual(added.provider.customHeaders[k], v)
        }
        XCTAssertEqual(added.seededModelCount, openrouter.recommendedModels.count)
        XCTAssertEqual(
            engine.config.models.filter { $0.providerID == added.provider.id }.count,
            openrouter.recommendedModels.count
        )
        XCTAssertEqual(try keychain.getAPIKeys(for: added.provider.id), ["sk-or-secret-1", "sk-or-secret-2"])

        let configURL = dir.appendingPathComponent("config.json")
        let configText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(configText.contains("sk-or-secret-1"))
        XCTAssertFalse(configText.contains("sk-or-secret-2"))
    }

    // MARK: - 2. Key Pool Codec, Router & Secret Redaction

    func testKeyPoolCodecBackwardsCompatibilityRouterAndRedaction() throws {
        // Single-key storage stays raw unprefixed string for backwards compatibility
        XCTAssertEqual(APIKeyPoolCodec.encode(["sk-single-123"]), "sk-single-123")
        XCTAssertEqual(APIKeyPoolCodec.decode("sk-single-123"), ["sk-single-123"])
        XCTAssertEqual(APIKeyPoolCodec.decode(""), [])
        XCTAssertEqual(APIKeyPoolCodec.decode(nil), [])

        // Multi-key normalization + pool codec round-trip
        let normalized = APIKeyPoolCodec.normalize(["  sk-a ", "", "sk-b", "sk-a", "\nsk-c\t"])
        XCTAssertEqual(normalized, ["sk-a", "sk-b", "sk-c"])
        let encoded = APIKeyPoolCodec.encode(normalized)
        XCTAssertTrue(encoded.hasPrefix("autoroute-keypool-v1:"))
        XCTAssertEqual(APIKeyPoolCodec.decode(encoded), ["sk-a", "sk-b", "sk-c"])

        // Keychain allKnownSecretValues expands pool entries for SecretRedactor
        let pid = UUID()
        let keychain = InMemoryKeychainService()
        try keychain.setAPIKeys(["sk-pool-alpha-999", "sk-pool-beta-888"], for: pid)
        XCTAssertEqual(try keychain.getAPIKeys(for: pid), ["sk-pool-alpha-999", "sk-pool-beta-888"])
        let knownSecrets = keychain.allKnownSecretValues()
        XCTAssertTrue(knownSecrets.contains("sk-pool-alpha-999"))
        XCTAssertTrue(knownSecrets.contains("sk-pool-beta-888"))

        let redacted = SecretRedactor.redact(
            "Upstream error using sk-pool-alpha-999 then sk-pool-beta-888",
            secrets: knownSecrets
        )
        XCTAssertFalse(redacted.contains("sk-pool-alpha-999"))
        XCTAssertFalse(redacted.contains("sk-pool-beta-888"))

        // Router priority vs round-robin + cooldown skipping
        let router = ProviderKeyPoolRouter()
        let keys = ["k1", "k2", "k3"]
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(router.orderedKeys(for: pid, keys: keys, strategy: .roundRobin, now: now), ["k1", "k2", "k3"])
        XCTAssertEqual(router.orderedKeys(for: pid, keys: keys, strategy: .roundRobin, now: now), ["k2", "k3", "k1"])
        XCTAssertEqual(router.orderedKeys(for: pid, keys: keys, strategy: .priorityFailover, now: now), ["k1", "k2", "k3"])

        router.markRateLimited(providerID: pid, key: "k1", cooldownSeconds: 60, now: now)
        XCTAssertTrue(router.isCooling(providerID: pid, key: "k1", now: now.addingTimeInterval(10)))
        XCTAssertEqual(
            router.orderedKeys(for: pid, keys: keys, strategy: .priorityFailover, now: now.addingTimeInterval(10)),
            ["k2", "k3", "k1"]
        )
        router.clearCooldown(providerID: pid, key: "k1")
        XCTAssertFalse(router.isCooling(providerID: pid, key: "k1", now: now.addingTimeInterval(10)))
    }

    // MARK: - 3. Multi-Key Failover (429 / 401) End-to-End

    @MainActor
    func testMultiKeyInPoolFailoverOn429And401EndToEnd() async throws {
        let dir = makeTempDir("keypool-failover")
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = RequestCaptureBox()

        let upstream = LoopbackHTTPServer { req, writer in
            _ = capture.append(req)
            let auth = req.header("authorization") ?? ""
            if auth == "Bearer sk-key-1-rate-limited" {
                let err = Data(#"{"error":{"message":"Rate limit reached for key 1","type":"rate_limit_error"}}"#.utf8)
                writer.sendJSON(statusCode: 429, body: err)
            } else if auth == "Bearer sk-key-1-invalid" {
                let err = Data(#"{"error":{"message":"Invalid key 1","type":"authentication_error"}}"#.utf8)
                writer.sendJSON(statusCode: 401, body: err)
            } else {
                writer.sendJSON(statusCode: 200, body: self.makeOpenAIChatSuccessJSON(content: "served by \(auth)"))
            }
        }
        let upstreamPort = try upstream.start(port: 0)
        defer { upstream.stop() }

        let keychain = InMemoryKeychainService()
        let engine = makeEngine(dir: dir, keychain: keychain)

        let provider = ProviderConfig(
            name: "MultiKey Relay",
            baseURL: "http://127.0.0.1:\(upstreamPort)/v1",
            healthStatus: .healthy,
            keyRotationStrategy: .priorityFailover
        )
        try engine.upsertProvider(provider, apiKeys: ["sk-key-1-rate-limited", "sk-key-2-healthy"])

        let model = ModelConfig(
            providerID: provider.id,
            modelID: "gpt-4o-mini",
            capabilities: [.chat, .tools],
            availabilityStatus: .available
        )
        engine.upsertModel(model)

        let proxyPort = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 24_600))
        engine.updateProxyPort(proxyPort)
        engine.startProxy()
        defer { engine.stopProxy() }
        guard case .running = engine.proxyState else {
            return XCTFail("Proxy failed to start")
        }

        // Request 1: key 1 hits 429 -> engine immediately fails over in-pool to key 2 and returns 200 OK
        let (status1, data1) = try await sendProxyChatRequest(port: proxyPort, localToken: engine.localAPIToken)
        XCTAssertEqual(status1, 200)
        XCTAssertTrue(String(data: data1, encoding: .utf8)?.contains("sk-key-2-healthy") == true)

        // Request 2: key 1 is cooled down, so router sends directly to key 2 on first try
        let countBeforeReq2 = capture.snapshot().count
        let (status2, _) = try await sendProxyChatRequest(port: proxyPort, localToken: engine.localAPIToken)
        XCTAssertEqual(status2, 200)
        let afterReq2 = capture.snapshot()
        XCTAssertEqual(afterReq2.count - countBeforeReq2, 1, "Cooled key 1 should be skipped on subsequent request")
        XCTAssertEqual(afterReq2.last?.authorization, "Bearer sk-key-2-healthy")

        // Now test 401 in-pool failover: replace key 1 with an invalid key -> fails over to key 2 without marking provider authError
        try engine.upsertProvider(provider, apiKeys: ["sk-key-1-invalid", "sk-key-2-healthy"])
        let (status3, data3) = try await sendProxyChatRequest(port: proxyPort, localToken: engine.localAPIToken)
        XCTAssertEqual(status3, 200)
        XCTAssertTrue(String(data: data3, encoding: .utf8)?.contains("sk-key-2-healthy") == true)

        let updatedProvider = try XCTUnwrap(engine.config.providers.first { $0.id == provider.id })
        XCTAssertEqual(updatedProvider.healthStatus, .healthy)
        let updatedModel = try XCTUnwrap(engine.config.models.first { $0.id == model.id })
        XCTAssertEqual(updatedModel.availabilityStatus, .available)
    }

    // MARK: - 4. Custom Headers & Pass-Through Whitelist Security

    @MainActor
    func testCustomHeadersAndPassThroughWhitelistBlocksSensitiveLocalAuth() async throws {
        let dir = makeTempDir("headers-passthrough")
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = RequestCaptureBox()

        let upstream = LoopbackHTTPServer { req, writer in
            _ = capture.append(req)
            writer.sendJSON(statusCode: 200, body: self.makeOpenAIChatSuccessJSON(content: "headers verified"))
        }
        let upstreamPort = try upstream.start(port: 0)
        defer { upstream.stop() }

        let engine = makeEngine(dir: dir)
        let provider = ProviderConfig(
            name: "Custom Header Provider",
            baseURL: "http://127.0.0.1:\(upstreamPort)/v1",
            healthStatus: .healthy,
            customHeaders: [
                "X-Custom-Tenant": "tenant-42",
                "Referer": "https://autoroute.local"
            ],
            // Deliberately include restricted headers in whitelist to verify security stripping!
            passThroughHeaderNames: ["X-Trace-Id", "Authorization", "x-api-key", "Cookie"]
        )
        try engine.upsertProvider(provider, apiKeys: ["sk-upstream-secret-999"])
        engine.upsertModel(ModelConfig(
            providerID: provider.id,
            modelID: "gpt-4o-mini",
            capabilities: [.chat],
            availabilityStatus: .available
        ))

        let proxyPort = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 24_700))
        engine.updateProxyPort(proxyPort)
        engine.startProxy()
        defer { engine.stopProxy() }

        let (status, _) = try await sendProxyChatRequest(
            port: proxyPort,
            localToken: engine.localAPIToken,
            extraHeaders: [
                "X-Trace-Id": "trace-abc-123",
                "Cookie": "session=super-secret-cookie",
                "X-Blocked-Client": "should-never-forward"
            ]
        )
        XCTAssertEqual(status, 200)

        let req = try XCTUnwrap(capture.snapshot().last)
        XCTAssertEqual(req.customTenant, "tenant-42")
        XCTAssertEqual(req.referer, "https://autoroute.local")
        XCTAssertEqual(req.traceID, "trace-abc-123")
        XCTAssertEqual(req.authorization, "Bearer sk-upstream-secret-999")
        XCTAssertNil(req.apiKeyHeader)
        XCTAssertNil(req.cookie)
        XCTAssertNil(req.blockedClientHeader)
    }

    // MARK: - 5. Magpie providers.json Import & Sanitized Template Export

    @MainActor
    func testMagpieProvidersJSONImportAndSanitizedExport() throws {
        let dir = makeTempDir("magpie-import-export")
        defer { try? FileManager.default.removeItem(at: dir) }

        let magpieJSON: [String: Any] = [
            "providers": [
                [
                    "id": "proxy-multi",
                    "name": "Multi Key Relay",
                    "keys": ["sk-imp-1", "sk-imp-2"],
                    "chat": "https://relay.example.com/v1",
                    "proxy": "http://127.0.0.1:8888",
                    "headers": [
                        "X-Title": "MagpieApp",
                        "Authorization": "Bearer secret-header-leak"
                    ],
                    "passHeaders": ["X-Request-Id"],
                    "models": ["gpt-4o", "deepseek-chat"],
                    "contexts": [
                        "*": 128000,
                        "deepseek-chat": 65536
                    ]
                ],
                [
                    "id": "claude-relay",
                    "key": "sk-ant-imp",
                    "anthropic": "https://claude-relay.example.com",
                    "models": ["claude-3-7-sonnet"]
                ],
                [
                    "id": "disabled-provider",
                    "off": true,
                    "keys": ["sk-disabled"],
                    "chat": "https://disabled.example.com/v1",
                    "models": ["gpt-4o"]
                ],
                [
                    "id": "automodel",
                    "keys": ["sk-loop"],
                    "chat": "http://127.0.0.1:18789/v1",
                    "models": ["automodel"]
                ]
            ]
        ]
        let importData = try JSONSerialization.data(withJSONObject: magpieJSON)

        let keychain = InMemoryKeychainService()
        let engine = makeEngine(dir: dir, keychain: keychain)
        let result = try engine.importProvidersFromMagpieJSON(importData)

        XCTAssertEqual(result.addedProvidersCount, 2)
        XCTAssertEqual(result.addedModelsCount, 3)
        XCTAssertEqual(Set(result.importedProviderNames), ["Multi Key Relay", "claude-relay"])

        let multi = try XCTUnwrap(engine.config.providers.first { $0.name == "Multi Key Relay" })
        XCTAssertEqual(multi.configuredKeyCount, 2)
        XCTAssertEqual(try keychain.getAPIKeys(for: multi.id), ["sk-imp-1", "sk-imp-2"])
        XCTAssertEqual(multi.proxyURL, "http://127.0.0.1:8888")
        XCTAssertEqual(multi.passThroughHeaderNames, ["X-Request-Id"])
        XCTAssertEqual(multi.customHeaders["X-Title"], "MagpieApp")

        let gpt4o = try XCTUnwrap(engine.config.models.first { $0.providerID == multi.id && $0.modelID == "gpt-4o" })
        XCTAssertEqual(gpt4o.contextWindow, 128_000)
        let deepseek = try XCTUnwrap(engine.config.models.first { $0.providerID == multi.id && $0.modelID == "deepseek-chat" })
        XCTAssertEqual(deepseek.contextWindow, 65_536)

        let claude = try XCTUnwrap(engine.config.providers.first { $0.name == "claude-relay" })
        XCTAssertEqual(claude.apiProtocol, .anthropicMessages)
        XCTAssertEqual(try keychain.getAPIKeys(for: claude.id), ["sk-ant-imp"])

        // Export sanitized template -> must never expose keys or Authorization custom headers
        let exportedData = try engine.exportSanitizedProvidersJSON()
        let exportedText = try XCTUnwrap(String(data: exportedData, encoding: .utf8))
        XCTAssertTrue(exportedText.contains("Multi Key Relay"))
        XCTAssertTrue(exportedText.contains("MagpieApp"))
        XCTAssertFalse(exportedText.contains("sk-imp-1"))
        XCTAssertFalse(exportedText.contains("sk-imp-2"))
        XCTAssertFalse(exportedText.contains("sk-ant-imp"))
        XCTAssertFalse(exportedText.contains("secret-header-leak"))

        // Re-import exported portable template into a fresh engine
        let dir2 = makeTempDir("magpie-reimport")
        defer { try? FileManager.default.removeItem(at: dir2) }
        let engine2 = makeEngine(dir: dir2)
        let reimport = try engine2.importProvidersFromMagpieJSON(exportedData)
        XCTAssertEqual(reimport.addedProvidersCount, 2)
        XCTAssertEqual(reimport.addedModelsCount, 3)
        let reimportedMulti = try XCTUnwrap(engine2.config.providers.first { $0.name == "Multi Key Relay" })
        XCTAssertEqual(reimportedMulti.proxyURL, "http://127.0.0.1:8888")
        XCTAssertEqual(reimportedMulti.passThroughHeaderNames, ["X-Request-Id"])
    }
}
