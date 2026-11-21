import XCTest
@testable import AutoModelCore

private actor NativeCapture {
    var request: Data = Data()
    var forwarded = Data()
    func setRequest(_ value: Data) { request = value }
    func append(_ value: Data) { forwarded.append(value) }
}

final class NativeResponsesTests: XCTestCase {
    func testNativeCodexStreamingPreservesPayloadAndBytes() async throws {
        let capture = NativeCapture()
        let wire = Data("event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"你好\"}\r\n\r\nevent: response.completed\r\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"output\":[{\"type\":\"custom_tool_call\",\"name\":\"apply_patch\",\"input\":\"x\"}],\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}}\r\n\r\n".utf8)
        let server = LoopbackHTTPServer { request, writer in
            await capture.setRequest(request.body)
            writer.startChunkedStream()
            for byte in wire { _ = writer.writeStreamChunk(Data([byte])) }
            writer.finishStream()
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let provider = ProviderConfig(name: "test", baseURL: "http://127.0.0.1:\(port)", apiProtocol: .codexChatGPT)
        let model = ModelConfig(providerID: provider.id, modelID: "routed")
        let input: [[String: Any]] = [["type": "message", "role": "user", "content": "hi", "additional_tools": [["type": "namespace", "name": "x", "tools": [["type": "custom", "name": "patch"]]]]], ["type": "custom_tool_call_output", "call_id": "orphan", "output": "ok"]]
        let result = await UpstreamClient().executeChatCompletion(provider: provider, model: model, apiKey: nil, originalPayload: [:], estimatedInputTokens: 1, stream: true, nativeResponsesPayload: ["model": "auto", "input": input, "reasoning": ["summary": "auto"]], onStreamChunk: { await capture.append($0) })
        let value = try result.get()
        XCTAssertEqual(value.assistantText, "你好")
        XCTAssertTrue(value.hasToolCalls)
        XCTAssertEqual(value.usage?.promptTokens, 7)
        let forwarded = await capture.forwarded
        XCTAssertEqual(forwarded, wire)
        let requestData = await capture.request
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        XCTAssertEqual(request["model"] as? String, "routed")
        XCTAssertEqual(request["store"] as? Bool, false)
        XCTAssertEqual(request["stream"] as? Bool, true)
        XCTAssertTrue(NSDictionary(dictionary: ["input": request["input"]!]).isEqual(to: ["input": input]))
        XCTAssertNil(request["tools"])
    }

    func testCodexNonstreamAndStreamErrors() async throws {
        for (wire, shouldSucceed) in [
            ("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"ok\",\"status\":\"completed\",\"output\":[]}}\n\n", true),
            ("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"failed\"}}}\n\n", false),
            ("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n", false)
        ] {
            let server = LoopbackHTTPServer { _, writer in
                writer.startChunkedStream()
                _ = writer.writeStreamChunk(Data(wire.utf8))
                writer.finishStream()
            }
            let port = try server.start(port: 0)
            let provider = ProviderConfig(name: "test", baseURL: "http://127.0.0.1:\(port)", apiProtocol: .codexChatGPT)
            let model = ModelConfig(providerID: provider.id, modelID: "routed")
            let result = await UpstreamClient().executeChatCompletion(provider: provider, model: model, apiKey: nil, originalPayload: [:], estimatedInputTokens: 0, stream: false, nativeResponsesPayload: ["input": "hi"])
            server.stop()
            if shouldSucceed {
                let value = try result.get()
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: value.responseBody) as? [String: Any])
                XCTAssertEqual(object["id"] as? String, "ok")
            } else if case .success = result { XCTFail("Expected stream failure") }
        }
    }

    func testOpenAIResponsesJSONAndEffortMerge() async throws {
        let capture = NativeCapture()
        let response = Data("{\"id\":\"native\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}],\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}".utf8)
        let server = LoopbackHTTPServer { request, writer in
            await capture.setRequest(request.body)
            writer.sendJSON(statusCode: 200, body: response)
        }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let provider = ProviderConfig(name: "test", baseURL: "http://127.0.0.1:\(port)", apiProtocol: .openAIResponses)
        let model = ModelConfig(providerID: provider.id, modelID: "routed", capabilities: [.reasoning])
        let result = await UpstreamClient().executeChatCompletion(provider: provider, model: model, apiKey: nil, originalPayload: [:], estimatedInputTokens: 0, stream: false, nativeResponsesPayload: ["input": "hi", "reasoning": ["summary": "auto"]], resolvedEffort: .high)
        let value = try result.get()
        XCTAssertEqual(value.responseBody, response)
        XCTAssertEqual(value.assistantText, "answer")
        let data = await capture.request
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasoning = try XCTUnwrap(object["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["summary"] as? String, "auto")
        XCTAssertEqual(reasoning["effort"] as? String, "high")
    }

    func testUnsupportedProviderFailsBeforeNetworking() async {
        let provider = ProviderConfig(name: "test", baseURL: "http://127.0.0.1:1", apiProtocol: .openAIChatCompletions)
        let model = ModelConfig(providerID: provider.id, modelID: "test")
        let result = await UpstreamClient().executeChatCompletion(provider: provider, model: model, apiKey: nil, originalPayload: [:], estimatedInputTokens: 0, stream: false, nativeResponsesPayload: ["input": "hi"])
        guard case .failure(.httpError(let code, _, _, _)) = result else { return XCTFail("expected HTTP error") }
        XCTAssertEqual(code, 400)
    }
}
