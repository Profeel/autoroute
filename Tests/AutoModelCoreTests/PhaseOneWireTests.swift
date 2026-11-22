import XCTest
@testable import AutoModelCore

private actor WireBodyCapture {
    private(set) var bodies: [Data] = []
    func append(_ body: Data) -> Int { bodies.append(body); return bodies.count }
}

private final class WireMetadataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: WireRequestMetadata?
    func set(_ value: WireRequestMetadata) { lock.withLock { stored = value } }
    var value: WireRequestMetadata? { lock.withLock { stored } }
}

final class PhaseOneWireTests: XCTestCase {
    func testResponsesConversionPreservesReasoningAndCacheKey() throws {
        let source: [String: Any] = ["model": "auto", "input": "hi",
            "reasoning": ["effort": "xhigh", "summary": "auto"], "prompt_cache_key": "private-key"]
        let chat = try ProtocolAdapters.responsesToChatRequest(source).get()
        let responses = ProtocolAdapters.chatToResponsesRequest(chat, modelID: "routed", forceStream: false)
        let reasoning = try XCTUnwrap(responses["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "xhigh")
        XCTAssertEqual(reasoning["summary"] as? String, "auto")
        XCTAssertEqual(responses["prompt_cache_key"] as? String, "private-key")
        XCTAssertNil(responses["_autoroute_responses_reasoning"])
        XCTAssertTrue(NativeResponsesRouting.isRequired(["input": "hi", "prompt_cache_retention": "24h"]))
        let prewarm: [String: Any] = ["input": "hi", "prompt_cache_options": ["prewarm": true]]
        XCTAssertTrue(NativeResponsesRouting.isRequired(prewarm))
        XCTAssertEqual((NativeResponsesRouting.wirePayload(prewarm)["prompt_cache_options"] as? [String: Any])?["prewarm"] as? Bool, true)
        let breakpoint: [String: Any] = ["input": [["role": "user", "content": [["type": "input_text", "text": "hi", "prompt_cache_breakpoint": ["mode": "explicit"]]]]]]
        XCTAssertTrue(NativeResponsesRouting.isRequired(breakpoint))
        let toolSchema: [String: Any] = ["input": "hi", "tools": [["type": "function", "parameters": ["properties": ["prompt_cache_breakpoint": ["type": "string"]]]]]]
        XCTAssertFalse(NativeResponsesRouting.isRequired(toolSchema))
    }

    func testCacheZeroAndMissingRemainDistinct() throws {
        let zero = try XCTUnwrap(TokenUsage.parse(from: ["input_tokens": 100, "output_tokens": 1,
            "input_tokens_details": ["cached_tokens": 0]]))
        let missing = try XCTUnwrap(TokenUsage.parse(from: ["input_tokens": 100, "output_tokens": 1]))
        XCTAssertEqual(zero.cachedInputTokens, 0)
        XCTAssertEqual(zero.cacheHitRate, 0)
        XCTAssertNil(missing.cachedInputTokens)
        var observer = NativeAnthropicObserver()
        observer.observeResponse(["usage": ["input_tokens": 12, "output_tokens": 2]])
        XCTAssertNil(observer.usage?.cachedInputTokens)
        observer.observeEvent(["type": "message_delta", "usage": ["cache_read_input_tokens": 0]])
        XCTAssertEqual(observer.usage?.cachedInputTokens, 0)
        let encoded = try JSONEncoder().encode(zero)
        XCTAssertEqual(try JSONDecoder().decode(TokenUsage.self, from: encoded).cachedInputTokens, 0)
    }

    func testConvertedResponsesWireKeepsClientEffortAndCacheUsage() async throws {
        let bodies = WireBodyCapture(), metadata = WireMetadataCapture()
        let server = LoopbackHTTPServer { request, writer in
            _ = await bodies.append(request.body)
            writer.sendJSON(statusCode: 200, body: Data("{\"id\":\"r\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":4,\"output_tokens\":2,\"input_tokens_details\":{\"cached_tokens\":0}}}".utf8))
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let provider = ProviderConfig(name: "responses", baseURL: "http://127.0.0.1:\(port)", apiProtocol: .openAIResponses)
        let model = ModelConfig(providerID: provider.id, modelID: "model", capabilities: [.reasoning])
        let chat = try ProtocolAdapters.responsesToChatRequest(["input": "hi", "reasoning": ["effort": "xhigh", "summary": "auto"], "prompt_cache_key": "secret-cache-key"]).get()
        let result = await UpstreamClient().executeChatCompletion(provider: provider, model: model, apiKey: nil,
            originalPayload: chat, estimatedInputTokens: 0, stream: false, resolvedEffort: .low,
            hasClientProvidedEffort: true, onWireRequest: { metadata.set($0) })
        XCTAssertEqual(try result.get().usage?.cachedInputTokens, 0)
        let captured = await bodies.bodies
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(captured.first)) as? [String: Any])
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "xhigh")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["summary"] as? String, "auto")
        XCTAssertEqual(body["prompt_cache_key"] as? String, "secret-cache-key")
        XCTAssertEqual(metadata.value, WireRequestMetadata(effortValue: "xhigh", effortSource: .client))
        let persisted = String(data: try JSONEncoder().encode(XCTUnwrap(metadata.value)), encoding: .utf8) ?? ""
        XCTAssertFalse(persisted.contains("secret-cache-key"))
    }

    func testAnthropicNativePreservesControlsAndFallbackReportsCacheLoss() async throws {
        let bodies = WireBodyCapture(), metadata = WireMetadataCapture()
        let server = LoopbackHTTPServer { request, writer in
            _ = await bodies.append(request.body)
            if request.path.contains("messages") {
                writer.sendJSON(statusCode: 200, body: Data("{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"usage\":{\"input_tokens\":3,\"output_tokens\":1,\"cache_read_input_tokens\":0}}".utf8))
            } else {
                writer.sendJSON(statusCode: 200, body: Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}".utf8))
            }
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let native = ProviderConfig(name: "anthropic", baseURL: "http://127.0.0.1:\(port)", apiProtocol: .anthropicMessages)
        let model = ModelConfig(providerID: native.id, modelID: "claude-sonnet-5-5")
        let payload: [String: Any] = ["messages": [["role": "user", "content": "hello"]], "max_tokens": 50,
            "cache_control": ["type": "ephemeral"], "output_config": ["effort": "xhigh"]]
        XCTAssertTrue(NativeAnthropicRouting.hasNativeFeatures(payload))
        let converted = try ProtocolAdapters.anthropicToOpenAIRequest(payload, configuredModels: [model]).get()
        let result = await UpstreamClient().executeChatCompletion(provider: native, model: model, apiKey: nil,
            originalPayload: converted, estimatedInputTokens: 1, stream: false, nativeAnthropicPayload: payload,
            resolvedEffort: .low, onWireRequest: { metadata.set($0) })
        XCTAssertEqual(try result.get().usage?.cachedInputTokens, 0)
        let firstBodies = await bodies.bodies
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(firstBodies.first)) as? [String: Any])
        XCTAssertNotNil(first["cache_control"])
        XCTAssertEqual((first["output_config"] as? [String: Any])?["effort"] as? String, "xhigh")
        XCTAssertEqual(metadata.value?.effortSource, .client)
        XCTAssertEqual(metadata.value?.omittedCacheHints, [])

        let chatProvider = ProviderConfig(name: "chat", baseURL: "http://127.0.0.1:\(port)")
        let chatModel = ModelConfig(providerID: chatProvider.id, modelID: "chat")
        var fallbackPayload = payload
        fallbackPayload.removeValue(forKey: "output_config")
        let fallback = try ProtocolAdapters.anthropicToOpenAIRequest(fallbackPayload, configuredModels: [chatModel]).get()
        _ = try await UpstreamClient().executeChatCompletion(provider: chatProvider, model: chatModel, apiKey: nil,
            originalPayload: fallback, estimatedInputTokens: 1, stream: false, nativeAnthropicPayload: fallbackPayload,
            resolvedEffort: .high, onWireRequest: { metadata.set($0) }).get()
        XCTAssertEqual(metadata.value?.effortSource, .absent)
        XCTAssertEqual(metadata.value?.omittedCacheHints, ["Anthropic cache_control"])

        let blocked = await UpstreamClient().executeChatCompletion(provider: chatProvider, model: chatModel, apiKey: nil,
            originalPayload: converted, estimatedInputTokens: 1, stream: false, nativeAnthropicPayload: payload, resolvedEffort: .high)
        guard case .failure(.incompatibleRequest) = blocked else { return XCTFail("Explicit Anthropic effort must not be silently dropped") }
        let allBodies = await bodies.bodies
        XCTAssertEqual(allBodies.count, 2)
    }

    func testConvertedCacheOptionsRequireSupportedModelsAndPrewarmIsNotDowngraded() async throws {
        let bodies = WireBodyCapture(), metadata = WireMetadataCapture()
        let server = LoopbackHTTPServer { request, writer in
            _ = await bodies.append(request.body)
            writer.sendJSON(statusCode: 200, body: Data("{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}".utf8))
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let provider = ProviderConfig(name: "responses", baseURL: "http://127.0.0.1:\(port)", apiProtocol: .openAIResponses)
        let old = ModelConfig(providerID: provider.id, modelID: "gpt-5.4", capabilities: [.chat], defaultRole: .complexReasoning)
        let new = ModelConfig(providerID: provider.id, modelID: "gpt-6.2-sol", capabilities: [.chat])
        let base: [String: Any] = ["messages": [["role": "user", "content": "hello"]]]
        var older = base
        older["prompt_cache_retention"] = "24h"
        older["prompt_cache_options"] = ["mode": "implicit"]
        _ = try await UpstreamClient().executeChatCompletion(provider: provider, model: old, apiKey: nil,
            originalPayload: older, estimatedInputTokens: 1, stream: false, resolvedEffort: .high,
            onWireRequest: { metadata.set($0) }).get()
        XCTAssertEqual(metadata.value?.effortSource, .absent, "A reasoning role alone is not an effort capability")
        XCTAssertEqual(metadata.value?.omittedCacheHints, ["prompt_cache_options"])
        var inMemory = base
        inMemory["prompt_cache_retention"] = "in_memory"
        _ = try await UpstreamClient().executeChatCompletion(provider: provider, model: old, apiKey: nil,
            originalPayload: inMemory, estimatedInputTokens: 1, stream: false).get()
        var newer = base
        newer["prompt_cache_options"] = ["ttl": "12h"]
        _ = try await UpstreamClient().executeChatCompletion(provider: provider, model: new, apiKey: nil,
            originalPayload: newer, estimatedInputTokens: 1, stream: false,
            onWireRequest: { metadata.set($0) }).get()
        XCTAssertEqual(metadata.value?.omittedCacheHints, [])
        let allBodies = await bodies.bodies
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: allBodies[0]) as? [String: Any])
        let memoryBody = try XCTUnwrap(JSONSerialization.jsonObject(with: allBodies[1]) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: allBodies[2]) as? [String: Any])
        XCTAssertEqual(first["prompt_cache_retention"] as? String, "24h")
        XCTAssertEqual(memoryBody["prompt_cache_retention"] as? String, "in_memory")
        XCTAssertNil(first["prompt_cache_options"])
        XCTAssertNil(first["reasoning"])
        XCTAssertEqual((second["prompt_cache_options"] as? [String: Any])?["ttl"] as? String, "12h")
        let unsupported = ModelConfig(providerID: provider.id, modelID: "gpt-5.5")
        let rejectedRetention = await UpstreamClient().executeChatCompletion(provider: provider, model: unsupported, apiKey: nil,
            originalPayload: inMemory, estimatedInputTokens: 1, stream: false)
        guard case .failure(.incompatibleRequest) = rejectedRetention else { return XCTFail("Unsupported retention must not be silently dropped") }
        let rejectedTTL = await UpstreamClient().executeChatCompletion(provider: provider, model: old, apiKey: nil,
            originalPayload: newer, estimatedInputTokens: 1, stream: false)
        guard case .failure(.incompatibleRequest) = rejectedTTL else { return XCTFail("Unsupported TTL must not be silently dropped") }
        newer["prompt_cache_options"] = ["prewarm": true]
        let rejected = await UpstreamClient().executeChatCompletion(provider: provider, model: new, apiKey: nil,
            originalPayload: newer, estimatedInputTokens: 1, stream: false)
        guard case .failure(.incompatibleRequest) = rejected else { return XCTFail("Chat prewarm must not become a generation") }
        let after = await bodies.bodies
        XCTAssertEqual(after.count, 3)
    }

    func testNativeResponsesPrewarmPreservesAliasAndCacheControls() async throws {
        let bodies = WireBodyCapture(), metadata = WireMetadataCapture()
        let server = LoopbackHTTPServer { request, writer in
            _ = await bodies.append(request.body)
            writer.sendJSON(statusCode: 200, body: Data("{\"id\":\"prewarm\",\"status\":\"completed\",\"output\":[]}".utf8))
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let provider = ProviderConfig(name: "responses", baseURL: "http://127.0.0.1:\(port)", apiProtocol: .openAIResponses)
        let model = ModelConfig(providerID: provider.id, modelID: "gpt-6.2-sol", capabilities: [.reasoning])
        let payload: [String: Any] = ["input": "hello", "reasoning_effort": "xhigh", "reasoning": ["summary": "auto"],
            "prompt_cache_options": ["prewarm": true]]
        _ = try await UpstreamClient().executeChatCompletion(provider: provider, model: model, apiKey: nil,
            originalPayload: [:], estimatedInputTokens: 1, stream: false, nativeResponsesPayload: payload,
            resolvedEffort: .low, onWireRequest: { metadata.set($0) }).get()
        let allBodies = await bodies.bodies
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(allBodies.first)) as? [String: Any])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "xhigh")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["summary"] as? String, "auto")
        XCTAssertEqual((body["prompt_cache_options"] as? [String: Any])?["prewarm"] as? Bool, true)
        XCTAssertEqual(metadata.value?.effortSource, .client)
    }

    func testClientEffortToAnthropicAndPrivateLabels() async throws {
        let bodies = WireBodyCapture(), metadata = WireMetadataCapture()
        let server = LoopbackHTTPServer { request, writer in
            _ = await bodies.append(request.body)
            writer.sendJSON(statusCode: 200, body: Data("{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}".utf8))
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let provider = ProviderConfig(name: "anthropic", baseURL: "http://127.0.0.1:\(port)", apiProtocol: .anthropicMessages)
        let supported = ModelConfig(providerID: provider.id, modelID: "claude-sonnet-5-5")
        let unsupported = ModelConfig(providerID: provider.id, modelID: "claude-3-haiku-20240307")
        let payload: [String: Any] = ["reasoning_effort": "privateTokenLikeValue", "messages": [
            ["role": "user", "content": "first"], ["role": "assistant", "content": "answer"], ["role": "user", "content": "next"]]]
        _ = try await UpstreamClient().executeChatCompletion(provider: provider, model: supported, apiKey: nil,
            originalPayload: payload, estimatedInputTokens: 1, stream: false, resolvedEffort: .low,
            onWireRequest: { metadata.set($0) }).get()
        let captured = await bodies.bodies
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(captured.first)) as? [String: Any])
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "privateTokenLikeValue")
        XCTAssertEqual(metadata.value?.effortSource, .client)
        XCTAssertEqual(metadata.value?.effortValue, "非标准值")
        let rejected = await UpstreamClient().executeChatCompletion(provider: provider, model: unsupported, apiKey: nil,
            originalPayload: payload, estimatedInputTokens: 1, stream: false, resolvedEffort: .high)
        guard case .failure(.incompatibleRequest) = rejected else { return XCTFail("Unsupported Anthropic effort must be rejected") }
        let after = await bodies.bodies
        XCTAssertEqual(after.count, 1)
    }

    func testResponsesReasoningEnvelopeDoesNotLeakToChatWire() async throws {
        let bodies = WireBodyCapture()
        let server = LoopbackHTTPServer { request, writer in
            _ = await bodies.append(request.body)
            writer.sendJSON(statusCode: 200, body: Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}".utf8))
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let provider = ProviderConfig(name: "chat", baseURL: "http://127.0.0.1:\(port)")
        let model = ModelConfig(providerID: provider.id, modelID: "model", capabilities: [.reasoning])
        let payload = try ProtocolAdapters.responsesToChatRequest(["input": "hello", "reasoning": ["effort": "xhigh", "summary": "auto"]]).get()
        _ = try await UpstreamClient().executeChatCompletion(provider: provider, model: model, apiKey: nil,
            originalPayload: payload, estimatedInputTokens: 1, stream: false, resolvedEffort: .low).get()
        let captured = await bodies.bodies
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(captured.first)) as? [String: Any])
        XCTAssertEqual(body["reasoning_effort"] as? String, "xhigh")
        XCTAssertNil(body["reasoning"])
        XCTAssertNil(body["_autoroute_responses_reasoning"])
    }

    func testExplicitThinkingSurvivesConversionAndSuppressesAutomaticEffort() async throws {
        let bodies = WireBodyCapture(), metadata = WireMetadataCapture()
        let server = LoopbackHTTPServer { request, writer in
            _ = await bodies.append(request.body)
            writer.sendJSON(statusCode: 200, body: Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}".utf8))
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let chat = ProviderConfig(name: "chat", baseURL: "http://127.0.0.1:\(port)")
        let responses = ProviderConfig(name: "responses", baseURL: "http://127.0.0.1:\(port)", apiProtocol: .openAIResponses)
        let model = ModelConfig(providerID: chat.id, modelID: "deepseek-flash", capabilities: [.reasoning])
        let payload = try ProtocolAdapters.responsesToChatRequest(["input": "hello", "thinking": ["type": "disabled"]]).get()
        XCTAssertTrue(RequestFeatureExtractor.extract(from: payload, sessionHeader: nil).hasClientProvidedEffort)
        _ = try await UpstreamClient().executeChatCompletion(provider: chat, model: model, apiKey: nil,
            originalPayload: payload, estimatedInputTokens: 1, stream: false, resolvedEffort: .high,
            onWireRequest: { metadata.set($0) }).get()
        let captured = await bodies.bodies
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(captured.first)) as? [String: Any])
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual(metadata.value?.effortValue, "thinking: disabled")
        XCTAssertEqual(metadata.value?.effortSource, .client)
        let rejected = await UpstreamClient().executeChatCompletion(provider: responses, model: model, apiKey: nil,
            originalPayload: payload, estimatedInputTokens: 1, stream: false, resolvedEffort: .high)
        guard case .failure(.incompatibleRequest) = rejected else { return XCTFail("Thinking must not be lost during conversion") }
        let after = await bodies.bodies
        XCTAssertEqual(after.count, 1)
    }

    @MainActor
    func testAttemptReceiptsIncludeFailedAndSuccessfulWireMetadata() async throws {
        let bodies = WireBodyCapture()
        let server = LoopbackHTTPServer { request, writer in
            let count = await bodies.append(request.body)
            let response = count == 1 ? "{\"error\":{\"message\":\"rate limited\"}}" : "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1,\"prompt_tokens_details\":{\"cached_tokens\":0}}}"
            writer.sendJSON(statusCode: count == 1 ? 429 : 200, body: Data(response.utf8))
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AutoModelEngine(persistence: LocalPersistenceStore(baseDirectoryURL: root), keychain: InMemoryKeychainService(), autoStartProxyIfConfigured: false)
        let provider = ProviderConfig(name: "chat", baseURL: "http://127.0.0.1:\(port)", healthStatus: .healthy)
        try engine.upsertProvider(provider, apiKeys: ["key-one", "key-two"])
        let model = ModelConfig(providerID: provider.id, modelID: "routed", capabilities: [.chat, .reasoning])
        engine.upsertModel(model)
        engine.setTierModel(tier: .medium, modelUUID: model.id)
        let outcome = await engine.executeChatCompletion(payload: ["model": "auto/medium", "reasoning_effort": "xhigh", "messages": [["role": "user", "content": "hello"]]], source: .testBench)
        XCTAssertEqual(outcome.httpStatusCode, 200)
        XCTAssertEqual(outcome.callRecord.attempts.count, 2)
        XCTAssertEqual(outcome.callRecord.attempts.map { $0.wireMetadata?.effortValue }, ["xhigh", "xhigh"])
        XCTAssertEqual(outcome.callRecord.attempts.map { $0.wireMetadata?.effortSource }, [.client, .client])
        XCTAssertNil(outcome.callRecord.attempts.first?.usage)
        XCTAssertEqual(outcome.callRecord.attempts.last?.usage?.cachedInputTokens, 0)
        XCTAssertEqual(outcome.headers["X-AutoModel-Effort"], outcome.callRecord.decision.selectedEffort.rawValue)
        let encoded = try JSONEncoder().encode(outcome.callRecord.attempts[0])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "wireMetadata")
        let decoded = try JSONDecoder().decode(UpstreamAttemptRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.wireMetadata)
    }
}
