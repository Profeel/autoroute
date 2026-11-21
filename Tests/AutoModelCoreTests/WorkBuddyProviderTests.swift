import XCTest
@testable import AutoModelCore

final class WorkBuddyProviderTests: XCTestCase {
    private let apiKey = "ck_example12345678"

    @MainActor
    func testDiscoverImportAndRouteWorkBuddyCompletion() async throws {
        let apiKey = self.apiKey
        let upstream = LoopbackHTTPServer { request, writer in
            XCTAssertEqual(request.header("authorization"), "Bearer \(apiKey)")
            XCTAssertEqual(request.header("x-api-key"), apiKey)
            XCTAssertEqual(request.header("x-user-id"), "anonymous_12345678")
            XCTAssertEqual(request.header("x-product"), "SaaS")
            XCTAssertTrue(request.header("user-agent")?.contains("CLI/") == true)

            if request.path == "/v3/config" {
                XCTAssertEqual(request.method, "GET")
                writer.sendJSON(statusCode: 200, body: Data(#"{"code":0,"data":{"agents":[{"name":"desktop","models":["desktop-only"]},{"name":"cli","models":["auto","glm-test","glm-test"]}],"models":[{"id":"custom:alias|model"}]}}"#.utf8))
                return
            }

            XCTAssertEqual(request.path, "/v2/chat/completions")
            XCTAssertEqual(request.method, "POST")
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            XCTAssertEqual(payload?["stream"] as? Bool, true)
            XCTAssertEqual(payload?["model"] as? String, "glm-test")
            XCTAssertNil(payload?["max_completion_tokens"])
            let messages = payload?["messages"] as? [[String: Any]]
            XCTAssertEqual(messages?.first?["role"] as? String, "system")
            if payload?["max_tokens"] as? Int != 2 {
                XCTAssertEqual(payload?["max_tokens"] as? Int, 64)
                XCTAssertEqual(payload?["tool_choice"] as? String, "lookup")
            }
            guard writer.startChunkedStream() else { return }
            let stream = #"""
            data: {"id":"workbuddy-test","choices":[{"index":0,"delta":{"role":"assistant","reasoning":"think","tool_calls":[{"index":0,"id":"call_test","type":"function","function":{"name":"lookup","arguments":"{\"x\":"}}]}}]}

            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]},"finish_reason":"tool_calls"}]}

            data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}

            data: [DONE]


            """#
            _ = writer.writeStreamChunk(Data(stream.utf8))
            writer.finishStream()
        }
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkBuddyTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: directory),
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        let preset = try XCTUnwrap(ProviderPresetCatalog.preset(id: "workbuddy"))
        XCTAssertEqual(preset.baseURL, "https://copilot.tencent.com")
        XCTAssertEqual(ProviderPresetCatalog.preset(id: "workbuddy-ai")?.baseURL, "https://www.workbuddy.ai")
        let provider = try engine.addProviderFromPreset(
            preset, customBaseURL: "http://127.0.0.1:\(port)", apiKeys: [apiKey]
        ).provider
        XCTAssertEqual(provider.apiProtocol, .workBuddy)

        for _ in 0..<2 {
            let result = await engine.testProviderConnection(providerID: provider.id)
            XCTAssertEqual(try result.get(), ["glm-test", "custom:alias|model"])
        }
        XCTAssertEqual(engine.config.models.count, 2)
        let model = try XCTUnwrap(engine.config.models.first { $0.modelID == "glm-test" })
        XCTAssertTrue(model.capabilities.contains(.tools))
        let client = UpstreamClient()
        let probe = await client.probeModelHealth(provider: provider, model: model, apiKey: apiKey)
        XCTAssertTrue(probe.isAvailable, probe.note)

        let tools = [["type": "function", "function": ["name": "lookup", "parameters": ["type": "object"]]]] as [[String: Any]]
        let payload: [String: Any] = [
            "model": model.modelID,
            "stream": false,
            "max_completion_tokens": 64,
            "messages": [["role": "developer", "content": "test"], ["role": "user", "content": "lookup"]],
            "tools": tools,
            "tool_choice": ["type": "function", "function": ["name": "lookup"]]
        ]
        let response = await engine.executeChatCompletion(payload: payload, source: .testBench)
        XCTAssertEqual(response.httpStatusCode, 200, response.callRecord.errorMessage ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.responseBody) as? [String: Any])
        let choice = try XCTUnwrap((object["choices"] as? [[String: Any]])?.first)
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        let tool = try XCTUnwrap((message["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual(choice["finish_reason"] as? String, "tool_calls")
        XCTAssertEqual(message["reasoning_content"] as? String, "think")
        XCTAssertEqual((tool["function"] as? [String: String])?["arguments"], #"{"x":1}"#)
        XCTAssertEqual((object["usage"] as? [String: Int])?["total_tokens"], 8)

        let streamHeaders = expectation(description: "stream headers sent once")
        let toolCall = expectation(description: "tool call chunk forwarded")
        let streamDone = expectation(description: "stream terminator sent once")
        let streamResult = try await client.executeChatCompletion(
            provider: provider, model: model, apiKey: apiKey, originalPayload: payload,
            estimatedInputTokens: 5, stream: true,
            onStreamHeadersReady: { streamHeaders.fulfill() },
            onStreamChunk: { chunk in
                let text = String(decoding: chunk, as: UTF8.self)
                if text.contains("call_test") {
                    XCTAssertTrue(text.contains("glm-test"))
                    toolCall.fulfill()
                }
                if text == "data: [DONE]\n\n" { streamDone.fulfill() }
            }
        ).get()
        XCTAssertTrue(streamResult.hasToolCalls)
        XCTAssertEqual(streamResult.usage?.completionTokens, 3)
        await fulfillment(of: [streamHeaders, toolCall, streamDone], timeout: 1, enforceOrder: true)
    }

    func testStreamRejectsInvalidKeyBeforeForwarding() async throws {
        let apiKey = self.apiKey
        let upstream = LoopbackHTTPServer { _, writer in
            guard writer.startChunkedStream() else { return }
            _ = writer.writeStreamChunk(Data("data: {\"code\":401,\"msg\":\"Rejected \(apiKey) anonymous_12345678\"}\n\n".utf8))
            writer.finishStream()
        }
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }
        let provider = ProviderConfig(name: "WorkBuddy", baseURL: "http://127.0.0.1:\(port)", apiProtocol: .workBuddy)
        let model = ModelConfig(providerID: provider.id, modelID: "glm-test")
        let client = UpstreamClient()
        let result = await client.executeChatCompletion(
            provider: provider, model: model, apiKey: apiKey,
            originalPayload: ["messages": [["role": "user", "content": "hello"]]],
            estimatedInputTokens: 1, stream: true,
            onStreamHeadersReady: { XCTFail("Headers were sent for an upstream authentication error") },
            onStreamChunk: { _ in XCTFail("An upstream authentication error was sent as chat data") }
        )
        guard case .failure(.authError(401, let message)) = result else { return XCTFail("Expected authentication error") }
        XCTAssertFalse(message.contains(apiKey))
        XCTAssertFalse(message.contains("anonymous_12345678"))
        let missingKey = await client.fetchModels(provider: provider, apiKey: nil)
        guard case .failure(.authError(401, _)) = missingKey else { return XCTFail("Expected missing key error") }
    }
}
