import XCTest
@testable import AutoModelCore

final class FallbackPolicyTests: XCTestCase {
    func testRetryAfterParsesSecondsDatesAndRejectsInvalidValues() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(UpstreamClient.parseRetryAfter(" 12 ", now: now), 12)
        XCTAssertEqual(UpstreamClient.parseRetryAfter("Thu, 01 Jan 1970 00:00:30 GMT", now: now), 30)
        XCTAssertEqual(UpstreamClient.parseRetryAfter("Thu, 01 Jan 1970 00:00:00 GMT", now: now.addingTimeInterval(60)), 0)
        for raw in ["-1", "NaN", "Infinity", "1.5", "junk", ""] {
            XCTAssertNil(UpstreamClient.parseRetryAfter(raw, now: now), raw)
        }
        XCTAssertNil(UpstreamClient.parseRetryAfter(nil))
    }

    func testLegacyPolicyGetsBoundedFallbackDefaults() throws {
        let data = Data("{\"enableRetryOnUpstreamFailure\":true}".utf8)
        let policy = try JSONDecoder().decode(RoutingPolicyConfig.self, from: data)

        XCTAssertEqual(policy.maxUpstreamAttempts, 3)
        XCTAssertEqual(policy.maxRequestDurationSeconds, 120)
    }

    @MainActor
    func testMaxAttemptsStopsFallbackQueue() async throws {
        let counter = RequestCounter()
        let upstream = LoopbackHTTPServer { _, writer in
            await counter.increment()
            writer.sendJSON(
                statusCode: 500,
                body: Data("{\"error\":{\"message\":\"temporary upstream failure\"}}".utf8)
            )
        }
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }

        let engine = try makeEngine(port: port)
        engine.updatePolicy {
            $0.enableRetryOnUpstreamFailure = true
            $0.strictThreeTierPoolOnly = false
            $0.maxUpstreamAttempts = 1
            $0.maxRequestDurationSeconds = 5
        }

        let outcome = await engine.executeChatCompletion(
            payload: [
                "model": "auto",
                "messages": [["role": "user", "content": "retry boundary"]]
            ],
            source: .testBench
        )

        let requestCount = await counter.value
        XCTAssertEqual(outcome.httpStatusCode, 500)
        XCTAssertEqual(outcome.callRecord.attempts.count, 1)
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testCumulativeDeadlineStopsBeforeAnotherCandidate() async throws {
        let counter = RequestCounter()
        let upstream = LoopbackHTTPServer { _, writer in
            await counter.increment()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            writer.sendJSON(
                statusCode: 200,
                body: Data("{\"id\":\"deadline\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"late\"},\"finish_reason\":\"stop\"}]}".utf8)
            )
        }
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }

        let engine = try makeEngine(port: port)
        engine.updatePolicy {
            $0.enableRetryOnUpstreamFailure = true
            $0.strictThreeTierPoolOnly = false
            $0.maxUpstreamAttempts = 3
            $0.maxRequestDurationSeconds = 1
        }

        let started = ContinuousClock.now
        let outcome = await engine.executeChatCompletion(
            payload: [
                "model": "auto",
                "messages": [["role": "user", "content": "deadline boundary"]]
            ],
            source: .testBench
        )
        let elapsed = started.duration(to: .now)
        let requestCount = await counter.value

        XCTAssertEqual(outcome.httpStatusCode, 504)
        XCTAssertEqual(outcome.callRecord.attempts.count, 1)
        XCTAssertEqual(requestCount, 1)
        XCTAssertLessThan(elapsed, .seconds(2), "The request-level deadline must not wait for the provider timeout")
    }

    @MainActor
    func testRetryAfterWaitsBeforeSameProviderFallback() async throws {
        let counter = RequestCounter()
        let upstream = LoopbackHTTPServer { _, writer in
            await counter.increment()
            let count = await counter.value
            writer.sendJSON(statusCode: count == 1 ? 429 : 200,
                headers: count == 1 ? ["Retry-After": "1"] : [:],
                body: Data((count == 1 ? "{}" : "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}").utf8))
        }
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }
        let engine = try makeEngine(port: port)
        engine.updatePolicy {
            $0.enableRetryOnUpstreamFailure = true
            $0.strictThreeTierPoolOnly = false
            $0.maxUpstreamAttempts = 3
            $0.maxRequestDurationSeconds = 5
        }
        let start = ContinuousClock.now
        let outcome = await engine.executeChatCompletion(payload: [
            "model": "auto", "messages": [["role": "user", "content": "retry boundary"]]
        ], source: .testBench)
        XCTAssertEqual(outcome.httpStatusCode, 200)
        XCTAssertEqual(outcome.callRecord.attempts.count, 2)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .seconds(1))
        let data = try JSONEncoder().encode(outcome.callRecord.attempts[0])
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(metadata["retryAfterSeconds"] as? Double, 1)
    }

    @MainActor
    func testRetryAfterBeyondDeadlineSkipsSameProvider() async throws {
        let counter = RequestCounter()
        let upstream = LoopbackHTTPServer { _, writer in
            await counter.increment()
            writer.sendJSON(statusCode: 429, headers: ["Retry-After": "30"], body: Data("{}".utf8))
        }
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }
        let engine = try makeEngine(port: port)
        engine.updatePolicy {
            $0.enableRetryOnUpstreamFailure = true
            $0.strictThreeTierPoolOnly = false
            $0.maxRequestDurationSeconds = 1
        }
        let outcome = await engine.executeChatCompletion(payload: [
            "model": "auto", "messages": [["role": "user", "content": "retry boundary"]]
        ], source: .testBench)
        let count = await counter.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(outcome.httpStatusCode, 429)
        XCTAssertTrue(outcome.callRecord.decision.matchedRules.contains { $0.contains("Retry-After") && $0.contains("deadline") })
    }

    @MainActor
    private func makeEngine(port: Int) throws -> AutoModelEngine {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteFallbackPolicy-\(UUID().uuidString)", isDirectory: true)
        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: directory),
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )
        let provider = ProviderConfig(
            name: "Fallback policy test upstream",
            baseURL: "http://127.0.0.1:\(port)",
            isEnabled: true,
            timeoutSeconds: 5,
            healthStatus: .healthy
        )
        try engine.upsertProvider(provider, apiKey: "test-key")
        let first = ModelConfig(providerID: provider.id, modelID: "fallback-first", capabilities: [.chat], availabilityStatus: .available)
        let second = ModelConfig(providerID: provider.id, modelID: "fallback-second", capabilities: [.chat], availabilityStatus: .available)
        engine.upsertModel(first)
        engine.upsertModel(second)
        engine.setTierModel(tier: .low, modelUUID: first.id)
        engine.setTierModel(tier: .medium, modelUUID: second.id)
        return engine
    }
}

private actor RequestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
