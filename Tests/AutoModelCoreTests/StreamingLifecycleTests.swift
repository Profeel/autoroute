import XCTest
@testable import AutoModelCore

final class StreamingLifecycleTests: XCTestCase {
    func testClientDisconnectStopsForwardingAndReturnsTerminalError() async throws {
        let secondWriteFailed = XCTestExpectation(description: "upstream observes the closed client socket")
        let upstream = LoopbackHTTPServer { _, writer in
            guard writer.startChunkedStream() else { return }
            let first = "data: {\"id\":\"disconnect-test\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"first\"},\"finish_reason\":null}]}\n\n"
            _ = writer.writeStreamChunk(Data(first.utf8))

            try? await Task.sleep(nanoseconds: 100_000_000)
            let second = Data(repeating: 0x78, count: 64 * 1024)
            for _ in 0..<256 {
                if !writer.writeStreamChunk(second) {
                    secondWriteFailed.fulfill()
                    break
                }
            }
            writer.finishStream()
        }
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }

        let provider = ProviderConfig(
            name: "Streaming cancellation test upstream",
            baseURL: "http://127.0.0.1:\(port)",
            isEnabled: true,
            timeoutSeconds: 5,
            healthStatus: .healthy
        )
        let model = ModelConfig(
            providerID: provider.id,
            modelID: "disconnect-test-model",
            capabilities: [.chat],
            availabilityStatus: .available
        )

        let client = UpstreamClient()
        let result = await client.executeChatCompletion(
            provider: provider,
            model: model,
            apiKey: nil,
            originalPayload: [
                "model": model.modelID,
                "stream": true,
                "messages": [["role": "user", "content": "test"]]
            ],
            estimatedInputTokens: 1,
            stream: true,
            onStreamChunk: { _ in
                throw ClientStreamDisconnectedError()
            }
        )

        guard case .failure(.clientDisconnected) = result else {
            return XCTFail("Expected a terminal clientDisconnected result, got \(result)")
        }
        await fulfillment(of: [secondWriteFailed], timeout: 2)
    }

    @MainActor
    func testEngineDoesNotTryFallbackAfterClientDisconnect() async throws {
        final class RequestCount: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.withLock { value += 1 } }
            func get() -> Int { lock.withLock { value } }
        }
        let requestCount = RequestCount()
        let upstream = LoopbackHTTPServer { _, writer in
            requestCount.increment()
            guard writer.startChunkedStream() else { return }
            let chunk = "data: {\"id\":\"engine-disconnect\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"first\"},\"finish_reason\":null}]}\n\n"
            _ = writer.writeStreamChunk(Data(chunk.utf8))
            try? await Task.sleep(nanoseconds: 100_000_000)
            writer.finishStream()
        }
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteStreamingLifecycle-\(UUID().uuidString)", isDirectory: true)
        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: directory),
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        let provider = ProviderConfig(
            name: "Engine streaming cancellation upstream",
            baseURL: "http://127.0.0.1:\(port)",
            isEnabled: true,
            timeoutSeconds: 5,
            healthStatus: .healthy
        )
        try engine.upsertProvider(provider, apiKey: "test-key")
        let firstModel = ModelConfig(providerID: provider.id, modelID: "first-model", capabilities: [.chat], availabilityStatus: .available)
        let secondModel = ModelConfig(providerID: provider.id, modelID: "second-model", capabilities: [.chat], availabilityStatus: .available)
        engine.upsertModel(firstModel)
        engine.upsertModel(secondModel)
        engine.setTierModel(tier: .low, modelUUID: firstModel.id)
        engine.setTierModel(tier: .medium, modelUUID: secondModel.id)
        engine.updatePolicy {
            $0.enableRetryOnUpstreamFailure = true
            $0.strictThreeTierPoolOnly = false
        }

        let outcome = await engine.executeChatCompletion(
            payload: [
                "model": "auto",
                "stream": true,
                "messages": [["role": "user", "content": "hello"]]
            ],
            source: .testBench,
            onStreamChunk: { _ in
                throw ClientStreamDisconnectedError()
            }
        )

        let attemptSummary = outcome.callRecord.attempts.map { attempt in
            "\(attempt.modelID): \(attempt.errorMessage ?? "nil")"
        }
        XCTAssertEqual(outcome.httpStatusCode, 499, "status=\(outcome.httpStatusCode), error=\(outcome.callRecord.errorMessage ?? "nil")")
        XCTAssertEqual(outcome.callRecord.attempts.count, 1, "attempts=\(attemptSummary)")
        XCTAssertEqual(requestCount.get(), 1, "A client disconnect must not consume a fallback candidate; attempts=\(attemptSummary)")
    }
}
