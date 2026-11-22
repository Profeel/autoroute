import XCTest
@testable import AutoModelCore

private actor ContinuationCapture {
    private(set) var credentials: [String] = []
    private(set) var bodies: [Data] = []
    func add(credential: String, body: Data) -> Int {
        credentials.append(credential)
        bodies.append(body)
        return credentials.count
    }
}

final class ContinuationSafetyTests: XCTestCase {
    @MainActor
    func testResponsesContinuationBindsOriginAndNeverRotatesKeyOrProvider() async throws {
        let primary = ContinuationCapture(), backup = ContinuationCapture()
        let server = LoopbackHTTPServer { request, writer in
            let n = await primary.add(credential: request.header("authorization") ?? "", body: request.body)
            let body = n == 1
                ? "{\"id\":\"resp_origin\",\"status\":\"completed\",\"output\":[{\"id\":\"item_origin\",\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}"
                : "{\"error\":{\"message\":\"limited\"}}"
            writer.sendJSON(statusCode: n == 1 ? 200 : 429, body: Data(body.utf8))
        }
        let backupServer = LoopbackHTTPServer { request, writer in
            _ = await backup.add(credential: request.header("authorization") ?? "", body: request.body)
            writer.sendJSON(statusCode: 200, body: Data("{\"id\":\"wrong\",\"status\":\"completed\",\"output\":[]}".utf8))
        }
        let port = try server.start(port: 0), backupPort = try backupServer.start(port: 0)
        defer { server.stop(); backupServer.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AutoModelEngine(persistence: LocalPersistenceStore(baseDirectoryURL: root), keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        let p1 = ProviderConfig(name: "origin", baseURL: "http://127.0.0.1:\(port)", healthStatus: .healthy, apiProtocol: .openAIResponses)
        let p2 = ProviderConfig(name: "backup", baseURL: "http://127.0.0.1:\(backupPort)", healthStatus: .healthy, apiProtocol: .openAIResponses)
        try engine.upsertProvider(p1, apiKeys: ["key-one", "key-two"])
        try engine.upsertProvider(p2, apiKey: "other-key")
        let m1 = ModelConfig(providerID: p1.id, modelID: "origin-model", capabilities: [.chat])
        let m2 = ModelConfig(providerID: p2.id, modelID: "backup-model", capabilities: [.chat])
        engine.upsertModel(m1); engine.upsertModel(m2)
        engine.setTierModel(tier: .medium, modelUUID: m1.id)
        engine.updatePolicy { $0.fallbackModelID = m2.id; $0.strictThreeTierPoolOnly = false }

        let first: [String: Any] = ["model": "auto", "store": true, "input": "hello"]
        let created = await engine.executeChatCompletion(payload: NativeResponsesRouting.routingPayload(first), source: .testBench, nativeResponsesPayload: first)
        XCTAssertEqual(created.httpStatusCode, 200)
        let continued: [String: Any] = ["model": "auto", "previous_response_id": "resp_origin", "input": "continue"]
        let result = await engine.executeChatCompletion(payload: NativeResponsesRouting.routingPayload(continued), source: .testBench, nativeResponsesPayload: continued)
        XCTAssertEqual(result.httpStatusCode, 429)
        let used = await primary.credentials
        XCTAssertEqual(used.count, 2)
        XCTAssertEqual(used.first, used.last)
        let backupCalls = await backup.credentials
        XCTAssertTrue(backupCalls.isEmpty)
        XCTAssertEqual(result.callRecord.attempts.count, 1)
    }

    @MainActor
    func testUnknownReferencesAndChangedEndpointFailWithoutSending() async throws {
        let capture = ContinuationCapture()
        let server = LoopbackHTTPServer { request, writer in
            _ = await capture.add(credential: request.header("authorization") ?? "", body: request.body)
            writer.sendJSON(statusCode: 200, body: Data("{\"id\":\"known\",\"status\":\"completed\",\"output\":[{\"id\":\"item_known\",\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]},{\"id\":\"reasoning_known\",\"type\":\"reasoning\",\"encrypted_content\":\"opaque_known\"}]}".utf8))
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AutoModelEngine(persistence: LocalPersistenceStore(baseDirectoryURL: root), keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        var provider = ProviderConfig(name: "origin", baseURL: "http://127.0.0.1:\(port)", healthStatus: .healthy, apiProtocol: .openAIResponses)
        try engine.upsertProvider(provider, apiKey: "key")
        let model = ModelConfig(providerID: provider.id, modelID: "model", capabilities: [.chat])
        engine.upsertModel(model)
        engine.setTierModel(tier: .medium, modelUUID: model.id)
        let first: [String: Any] = ["model": "auto", "store": true, "input": "hello"]
        let created = await engine.executeChatCompletion(payload: NativeResponsesRouting.routingPayload(first), source: .testBench, nativeResponsesPayload: first)
        XCTAssertEqual(created.httpStatusCode, 200)
        let item: [String: Any] = ["model": "auto", "input": [["type": "item_reference", "id": "item_known"], ["role": "user", "content": "continue"]]]
        let accepted = await engine.executeChatCompletion(payload: NativeResponsesRouting.routingPayload(item), source: .testBench, nativeResponsesPayload: item)
        XCTAssertEqual(accepted.httpStatusCode, 200)
        let encrypted: [String: Any] = ["model": "auto", "input": [["type": "reasoning", "encrypted_content": "opaque_known"], ["role": "user", "content": "continue"]]]
        let encryptedResult = await engine.executeChatCompletion(payload: NativeResponsesRouting.routingPayload(encrypted), source: .testBench, nativeResponsesPayload: encrypted)
        XCTAssertEqual(encryptedResult.httpStatusCode, 200)
        let unknown: [String: Any] = ["model": "auto", "previous_response_id": "unknown", "input": "continue"]
        let rejected = await engine.executeChatCompletion(payload: NativeResponsesRouting.routingPayload(unknown), source: .testBench, nativeResponsesPayload: unknown)
        XCTAssertEqual(rejected.callRecord.status, .rejected)
        XCTAssertTrue(String(data: rejected.responseBody, encoding: .utf8)?.contains("完整上下文") == true)
        provider.baseURL = "http://127.0.0.1:1"
        try engine.upsertProvider(provider, apiKey: nil)
        let changed: [String: Any] = ["model": "auto", "previous_response_id": "known", "input": "continue"]
        let changedResult = await engine.executeChatCompletion(payload: NativeResponsesRouting.routingPayload(changed), source: .testBench, nativeResponsesPayload: changed)
        XCTAssertEqual(changedResult.callRecord.status, .rejected)
        let requests = await capture.bodies
        XCTAssertEqual(requests.count, 3)
    }

    @MainActor
    func testStoreTrueRejectsCodexOnlyProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AutoModelEngine(persistence: LocalPersistenceStore(baseDirectoryURL: root), keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        let provider = ProviderConfig(name: "codex", baseURL: "http://127.0.0.1:1", healthStatus: .healthy, apiProtocol: .codexChatGPT)
        try engine.upsertProvider(provider, apiKey: nil)
        let model = ModelConfig(providerID: provider.id, modelID: "model", capabilities: [.chat])
        engine.upsertModel(model)
        let payload: [String: Any] = ["model": "auto", "store": true, "input": "hello"]
        let outcome = await engine.executeChatCompletion(payload: NativeResponsesRouting.routingPayload(payload), source: .testBench, nativeResponsesPayload: payload)
        XCTAssertEqual(outcome.callRecord.status, .rejected)
        XCTAssertTrue(String(data: outcome.responseBody, encoding: .utf8)?.contains("没有可用的 OpenAI Responses") == true)
    }

    @MainActor
    func testExplicitNativeSourceAcceptsExternalResourceAndKeepsItOnWire() async throws {
        let capture = ContinuationCapture()
        let server = LoopbackHTTPServer { request, writer in
            _ = await capture.add(credential: request.header("authorization") ?? "", body: request.body)
            writer.sendJSON(statusCode: 200, body: Data("{\"id\":\"result\",\"status\":\"completed\",\"output\":[]}".utf8))
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AutoModelEngine(persistence: LocalPersistenceStore(baseDirectoryURL: root), keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        let provider = ProviderConfig(name: "native", baseURL: "http://127.0.0.1:\(port)", healthStatus: .healthy, apiProtocol: .openAIResponses)
        try engine.upsertProvider(provider, apiKey: "one-key")
        let model = ModelConfig(providerID: provider.id, modelID: "native-model", capabilities: [.chat])
        engine.upsertModel(model)
        let request: [String: Any] = ["model": "native/native-model", "conversation": "external-conversation", "input": "continue"]
        XCTAssertTrue(NativeResponsesRouting.isRequired(request))
        let outcome = await engine.executeChatCompletion(payload: NativeResponsesRouting.routingPayload(request), source: .testBench, nativeResponsesPayload: request)
        XCTAssertEqual(outcome.httpStatusCode, 200)
        let bodies = await capture.bodies
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bodies.first)) as? [String: Any])
        XCTAssertEqual(object["conversation"] as? String, "external-conversation")
        let opaque: [String: Any] = ["model": "native/native-model", "reasoning": ["effort": "high"],
                                     "input": [["type": "item_reference", "id": "external-item"]]]
        let fallbackRouting = NativeResponsesRouting.routingPayload(opaque)
        let second = await engine.executeChatCompletion(payload: fallbackRouting, source: .testBench, nativeResponsesPayload: opaque)
        XCTAssertEqual(second.httpStatusCode, 200)
        XCTAssertEqual(second.callRecord.requestFeatures.clientProvidedEffort, .high)
    }

    @MainActor
    func testAnthropicSignedToolContinuationKeepsModelAndCredential() async throws {
        let capture = ContinuationCapture(), backup = ContinuationCapture()
        let server = LoopbackHTTPServer { request, writer in
            let count = await capture.add(credential: request.header("x-api-key") ?? "", body: request.body)
            let body = count == 1
                ? "{\"id\":\"msg1\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"reason\",\"signature\":\"signature-one\"},{\"type\":\"tool_use\",\"id\":\"tool1\",\"name\":\"read\",\"input\":{}}]}"
                : "{\"error\":{\"message\":\"limited\"}}"
            writer.sendJSON(statusCode: count == 1 ? 200 : 429, body: Data(body.utf8))
        }
        let backupServer = LoopbackHTTPServer { request, writer in
            _ = await backup.add(credential: request.header("x-api-key") ?? "", body: request.body)
            writer.sendJSON(statusCode: 200, body: Data("{\"content\":[]}".utf8))
        }
        let port = try server.start(port: 0), backupPort = try backupServer.start(port: 0)
        defer { server.stop(); backupServer.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AutoModelEngine(persistence: LocalPersistenceStore(baseDirectoryURL: root), keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        let p1 = ProviderConfig(name: "native", baseURL: "http://127.0.0.1:\(port)", healthStatus: .healthy, apiProtocol: .anthropicMessages)
        let p2 = ProviderConfig(name: "other", baseURL: "http://127.0.0.1:\(backupPort)", healthStatus: .healthy, apiProtocol: .anthropicMessages)
        try engine.upsertProvider(p1, apiKeys: ["key-one", "key-two"])
        try engine.upsertProvider(p2, apiKey: "other-key")
        let m1 = ModelConfig(providerID: p1.id, modelID: "native-model", capabilities: [.chat, .tools])
        let m2 = ModelConfig(providerID: p2.id, modelID: "other-model", capabilities: [.chat, .tools])
        engine.upsertModel(m1); engine.upsertModel(m2)
        engine.setTierModel(tier: .medium, modelUUID: m1.id)
        engine.updatePolicy { $0.fallbackModelID = m2.id; $0.strictThreeTierPoolOnly = false }
        let tools: [[String: Any]] = [["name": "read", "input_schema": ["type": "object"]]]
        let first: [String: Any] = ["model": "auto", "thinking": ["type": "enabled", "budget_tokens": 1024], "tools": tools,
                                    "messages": [["role": "user", "content": "Read the relevant file"]]]
        let firstRouting = try ProtocolAdapters.anthropicToOpenAIRequest(first, configuredModels: engine.config.models).get()
        let created = await engine.executeChatCompletion(payload: firstRouting, source: .testBench, sessionHeader: "signed-session", nativeAnthropicPayload: first)
        XCTAssertEqual(created.httpStatusCode, 200)
        let next: [String: Any] = ["model": "auto", "tools": tools, "messages": [
            ["role": "user", "content": "Read the relevant file"],
            ["role": "assistant", "content": [["type": "thinking", "thinking": "reason", "signature": "signature-one"], ["type": "tool_use", "id": "tool1", "name": "read", "input": [:]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tool1", "content": "done"]]]
        ]]
        let nextRouting = try ProtocolAdapters.anthropicToOpenAIRequest(next, configuredModels: engine.config.models).get()
        let result = await engine.executeChatCompletion(payload: nextRouting, source: .testBench, sessionHeader: "signed-session", nativeAnthropicPayload: next)
        XCTAssertEqual(result.httpStatusCode, 429)
        let used = await capture.credentials
        XCTAssertEqual(used.count, 2)
        XCTAssertEqual(used.first, used.last)
        let backupCalls = await backup.credentials
        XCTAssertTrue(backupCalls.isEmpty)
        XCTAssertEqual(result.callRecord.attempts.count, 1)
    }

    func testSignedThinkingReferencesAndStreamingCapture() {
        let payload: [String: Any] = ["messages": [
            ["role": "assistant", "content": [["type": "thinking", "thinking": "x", "signature": "sig"], ["type": "redacted_thinking", "data": "opaque"]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "ok"]]]
        ]]
        XCTAssertTrue(NativeAnthropicRouting.hasNativeFeatures(payload))
        XCTAssertEqual(NativeAnthropicRouting.opaqueContinuation(payload).tokens, ["sig", "opaque"])
        var observer = NativeAnthropicObserver()
        observer.observeEvent(["type": "content_block_delta", "index": 1, "delta": ["type": "signature_delta", "signature": "sig"]])
        observer.observeEvent(["type": "content_block_start", "index": 2, "content_block": ["type": "redacted_thinking", "data": "opaque"]])
        XCTAssertEqual(Set(observer.opaqueTokens), Set(["sig", "opaque"]))
    }

    @MainActor
    func testRequiredToolFailureChangesNextMatchingRequestWithoutAutomaticReplay() async throws {
        let capture = ContinuationCapture()
        let server = LoopbackHTTPServer { request, writer in
            let count = await capture.add(credential: request.header("authorization") ?? "", body: request.body)
            let message = count == 3
                ? "{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]}"
                : "{\"role\":\"assistant\",\"content\":\"No tool was called\"}"
            writer.sendJSON(statusCode: 200, body: Data("{\"choices\":[{\"message\":\(message)}]}".utf8))
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AutoModelEngine(persistence: LocalPersistenceStore(baseDirectoryURL: root), keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        let provider = ProviderConfig(name: "chat", baseURL: "http://127.0.0.1:\(port)", healthStatus: .healthy)
        try engine.upsertProvider(provider, apiKey: "key")
        let medium = ModelConfig(providerID: provider.id, modelID: "scoped", capabilities: [.chat, .tools, .reasoning])
        let high = ModelConfig(providerID: provider.id, modelID: "advanced", capabilities: [.chat, .tools, .reasoning])
        engine.upsertModel(medium); engine.upsertModel(high)
        engine.setTierModel(tier: .medium, modelUUID: medium.id)
        engine.setTierModel(tier: .high, modelUUID: high.id)
        let payload: [String: Any] = ["model": "auto", "messages": [["role": "user", "content": "Implement the requested function"]],
            "tool_choice": "required", "tools": [["type": "function", "function": ["name": "read", "parameters": ["type": "object"]]]]]
        var outcomes: [AutoModelEngine.ExecutionOutcome] = []
        for _ in 0..<3 {
            outcomes.append(await engine.executeChatCompletion(payload: payload, source: .testBench, sessionHeader: "quality-flow"))
        }
        XCTAssertEqual(outcomes.map { $0.callRecord.executedModelID }, ["scoped", "scoped", "advanced"])
        XCTAssertEqual(outcomes.map { $0.callRecord.decision.selectedEffort }, [.medium, .high, .medium])
        let bodies = await capture.bodies
        XCTAssertEqual(bodies.count, 3, "Quality feedback must not replay the request automatically")
        let sent = try bodies.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertEqual(sent[1]["reasoning_effort"] as? String, "high")
        XCTAssertTrue(outcomes.allSatisfy { $0.callRecord.attempts.count == 1 })
    }
}
