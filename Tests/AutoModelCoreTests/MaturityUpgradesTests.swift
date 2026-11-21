import Darwin
import Foundation
import XCTest
@testable import AutoModelCore

final class MaturityUpgradesTests: XCTestCase {
    private func makeTempDir(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - 1. SQLite WAL Storage, Analytics & 7-Day Metrics Past 500 Cap

    @MainActor
    func testSQLiteWALPreservesOver500RecordsAndAccurate7DayMetricsAndTrends() async throws {
        let dir = makeTempDir("AutoRouteSQLite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LocalPersistenceStore(baseDirectoryURL: dir)
        let now = Date()
        let cal = Calendar.current
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: now)!
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!

        func makeRec(at date: Date, agent: String?, modelID: String, cost: Double, cached: Int) -> CallRecord {
            let usage = TokenUsage(promptTokens: 1000, completionTokens: 200, cachedInputTokens: cached)
            return CallRecord(
                timestamp: date,
                source: .externalProxy,
                status: .success,
                requestedModel: "auto",
                executedModelID: modelID,
                executedModelDisplayName: modelID,
                executedProviderName: "p1",
                httpStatusCode: 200,
                requestFeatures: RequestFeatureExtractor.extract(from: [
                    "model": "auto",
                    "messages": [["role": "user", "content": "hi"]]
                ]),
                decision: RoutingDecision(
                    requestedModel: "auto",
                    isAutoRouted: true,
                    strategyName: "均衡模式",
                    policyVersion: 1,
                    deciderPluginID: "builtin.deterministic.v1",
                    decisionDurationMs: 1.5,
                    agentID: agent
                ),
                attempts: [],
                routingDecisionMs: 1.5,
                upstreamFirstTokenMs: 20,
                totalCompletionMs: 40,
                finalUsage: usage,
                usageSource: .upstreamReported,
                usageEstimationMethod: nil,
                costStatus: .calculated,
                primaryAttemptCostUSD: cost,
                retryAttemptsCostUSD: 0,
                totalCostUSD: cost,
                executionOrigin: .real
            )
        }

        // Seed 520 records spanning 3 calendar days (older days would be evicted by a 500-record cap).
        var seed: [CallRecord] = []
        seed.append(makeRec(at: twoDaysAgo, agent: "codex", modelID: "model-a", cost: 0.05, cached: 800))
        seed.append(makeRec(at: yesterday, agent: "claude_code", modelID: "model-b", cost: 0.08, cached: 500))
        for idx in 0..<518 {
            seed.append(makeRec(
                at: now.addingTimeInterval(-Double(idx) * 0.01),
                agent: idx % 2 == 0 ? "codex" : "claude_code",
                modelID: "model-a",
                cost: 0.01,
                cached: 700
            ))
        }
        try store.saveHistory(seed)

        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            alertNotifier: NoOpSystemAlertNotifier(),
            autoStartProxyIfConfigured: false
        )
        XCTAssertEqual(engine.callHistory.count, 500, "UI callHistory remains bounded at 500")
        XCTAssertEqual(engine.totalStoredRecordCount(), 520, "SQLite retains all 520 records")

        // 7-day active days must see all 3 days via SQLite, not collapse to 1 day.
        let metrics = engine.localProductMetrics(now: now)
        XCTAssertEqual(metrics.activeDaysLast7, 3)
        XCTAssertEqual(metrics.realRouteSampleCount, 520)

        let trends = engine.dailyUsageTrends(days: 7, now: now)
        XCTAssertEqual(trends.count, 7)
        XCTAssertEqual(trends.map(\.callCount).reduce(0, +), 520)

        let byAgent = engine.usageBreakdownByAgent(days: 7, now: now)
        XCTAssertEqual(byAgent.count, 2)
        let byModel = engine.usageBreakdownByModel(days: 7, now: now)
        XCTAssertEqual(byModel.count, 2)

        // Prune records older than 1 day should delete twoDaysAgo.
        let deleted = try store.pruneHistory(olderThanDays: 1, now: now)
        XCTAssertGreaterThanOrEqual(deleted, 1)
    }

    // MARK: - 2. Prompt Caching Token Parsing & Discounted Pricing

    func testPromptCachingTokenParsingAndPricingAccuracy() throws {
        // OpenAI Chat Completions format
        let openAIUsage = try XCTUnwrap(TokenUsage.parse(from: [
            "prompt_tokens": 10_000,
            "completion_tokens": 1_000,
            "total_tokens": 11_000,
            "prompt_tokens_details": ["cached_tokens": 8_000]
        ]))
        XCTAssertEqual(openAIUsage.promptTokens, 10_000)
        XCTAssertEqual(openAIUsage.cachedInputTokens, 8_000)
        XCTAssertEqual(try XCTUnwrap(openAIUsage.cacheHitRate), 0.8, accuracy: 0.0001)

        // Anthropic Messages format (cache_read & cache_creation reported outside input_tokens)
        let anthropicUsage = try XCTUnwrap(TokenUsage.parse(from: [
            "input_tokens": 1_000,
            "cache_read_input_tokens": 8_000,
            "cache_creation_input_tokens": 1_000,
            "output_tokens": 500
        ]))
        XCTAssertEqual(anthropicUsage.promptTokens, 10_000)
        XCTAssertEqual(anthropicUsage.cachedInputTokens, 8_000)
        XCTAssertEqual(anthropicUsage.cacheCreationTokens, 1_000)
        XCTAssertEqual(anthropicUsage.totalTokens, 10_500)
        XCTAssertEqual(try XCTUnwrap(anthropicUsage.cacheHitRate), 0.8, accuracy: 0.0001)

        // Claude family default cache discounts (0.10x read, 1.25x write)
        let claude = ModelConfig(
            providerID: UUID(),
            modelID: "claude-sonnet-4-20250514",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0
        )
        // uncached 1000 * $3 + read 8000 * $0.30 + create 1000 * $3.75 + out 500 * $15
        // = 0.003 + 0.0024 + 0.00375 + 0.0075 = 0.01665
        let claudeCost = try XCTUnwrap(claude.calculateCostUSD(usage: anthropicUsage))
        XCTAssertEqual(claudeCost, 0.01665, accuracy: 0.00001)

        // Explicit cache price override takes precedence
        var custom = claude
        custom.cachedInputPricePerMillion = 0.5
        custom.cacheCreationPricePerMillion = 4.0
        let customCost = try XCTUnwrap(custom.calculateCostUSD(usage: anthropicUsage))
        // 0.003 + 0.004 + 0.004 + 0.0075 = 0.0185
        XCTAssertEqual(customCost, 0.0185, accuracy: 0.00001)
    }

    // MARK: - 3. Native Anthropic /v1/messages Passthrough (Non-Stream & Streaming)

    @MainActor
    func testNativeAnthropicPassthroughPreservesCacheControlThinkingAndSSE() async throws {
        let dir = makeTempDir("AutoRouteNativeAnthropic")
        defer { try? FileManager.default.removeItem(at: dir) }

        final class CapturedBox: @unchecked Sendable {
            private let lock = NSLock()
            var betaHeader: String?
            var hasCacheControl = false
            var hasThinking = false
            func record(beta: String?, cacheControl: Bool, thinking: Bool) {
                lock.withLock {
                    betaHeader = beta
                    hasCacheControl = cacheControl
                    hasThinking = thinking
                }
            }
        }
        let captured = CapturedBox()

        let upstream = LoopbackHTTPServer { req, writer in
            let bodyJSON = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
            let isStream = (bodyJSON["stream"] as? Bool) ?? false
            let hasThinking = bodyJSON["thinking"] != nil
            let sysBlocks = bodyJSON["system"] as? [[String: Any]] ?? []
            let hasCache = sysBlocks.contains { $0["cache_control"] != nil }
            captured.record(beta: req.header("anthropic-beta"), cacheControl: hasCache, thinking: hasThinking)

            if isStream {
                _ = writer.startChunkedStream(statusCode: 200)
                let events = [
                    #"event: message_start\ndata: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-4","usage":{"input_tokens":200,"cache_read_input_tokens":800,"cache_creation_input_tokens":0,"output_tokens":1}}}"#,
                    #"event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
                    #"event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"step 1"}}"#,
                    #"event: content_block_start\ndata: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
                    #"event: content_block_delta\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello native!"}}"#,
                    #"event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":25}}"#,
                    #"event: message_stop\ndata: {"type":"message_stop"}"#
                ]
                for ev in events {
                    let wire = ev.replacingOccurrences(of: #"\n"#, with: "\n") + "\n\n"
                    _ = writer.writeStreamChunk(Data(wire.utf8))
                }
                writer.finishStream()
            } else {
                let resp: [String: Any] = [
                    "id": "msg_sync",
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-sonnet-4",
                    "content": [
                        ["type": "thinking", "thinking": "deep thought"],
                        ["type": "text", "text": "Native sync answer"]
                    ],
                    "stop_reason": "end_turn",
                    "usage": [
                        "input_tokens": 100,
                        "cache_read_input_tokens": 900,
                        "cache_creation_input_tokens": 0,
                        "output_tokens": 50
                    ]
                ]
                let data = try! JSONSerialization.data(withJSONObject: resp)
                writer.sendJSON(statusCode: 200, body: data)
            }
        }
        let upstreamPort = try upstream.start(port: 0)
        defer { upstream.stop() }

        let store = LocalPersistenceStore(baseDirectoryURL: dir)
        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            alertNotifier: NoOpSystemAlertNotifier(),
            autoStartProxyIfConfigured: false
        )
        let provider = ProviderConfig(
            name: "Anthropic Native",
            baseURL: "http://127.0.0.1:\(upstreamPort)",
            healthStatus: .healthy,
            apiProtocol: .anthropicMessages
        )
        try engine.upsertProvider(provider, apiKey: "sk-ant-test")
        let model = ModelConfig(
            providerID: provider.id,
            modelID: "claude-sonnet-4",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            capabilities: [.chat, .reasoning, .tools],
            availabilityStatus: .available
        )
        engine.upsertModel(model)

        let proxyPort = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 24_100))
        engine.updateProxyPort(proxyPort)
        engine.startProxy()
        defer { engine.stopProxy() }
        guard case .running = engine.proxyState else {
            return XCTFail("Proxy failed to start")
        }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        // 1) Non-streaming native passthrough
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(engine.localAPIToken, forHTTPHeaderField: "x-api-key")
        req.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "auto",
            "max_tokens": 1024,
            "thinking": ["type": "enabled", "budget_tokens": 512],
            "system": [["type": "text", "text": "You are Claude", "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": "Hello"]],
            "stream": false
        ])
        let (syncData, syncResp) = try await session.data(for: req)
        let syncHTTP = try XCTUnwrap(syncResp as? HTTPURLResponse)
        XCTAssertEqual(syncHTTP.statusCode, 200)
        XCTAssertEqual(syncHTTP.value(forHTTPHeaderField: "X-AutoModel-Wire-Format"), "anthropic-native")
        XCTAssertTrue(captured.hasCacheControl)
        XCTAssertTrue(captured.hasThinking)
        XCTAssertEqual(captured.betaHeader, "prompt-caching-2024-07-31")

        let syncJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: syncData) as? [String: Any])
        XCTAssertEqual(syncJSON["id"] as? String, "msg_sync")

        let lastRecord = try XCTUnwrap(engine.callHistory.first)
        XCTAssertEqual(lastRecord.finalUsage?.promptTokens, 1000)
        XCTAssertEqual(lastRecord.finalUsage?.cachedInputTokens, 900)
        XCTAssertEqual(try XCTUnwrap(lastRecord.finalUsage?.cacheHitRate), 0.9, accuracy: 0.0001)

        // 2) Streaming native passthrough
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "auto",
            "max_tokens": 1024,
            "thinking": ["type": "enabled", "budget_tokens": 512],
            "system": [["type": "text", "text": "You are Claude", "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": "Stream hello"]],
            "stream": true
        ])
        let (streamData, streamResp) = try await session.data(for: req)
        let streamHTTP = try XCTUnwrap(streamResp as? HTTPURLResponse)
        XCTAssertEqual(streamHTTP.statusCode, 200)
        let streamText = String(decoding: streamData, as: UTF8.self)
        XCTAssertTrue(streamText.contains("thinking_delta"))
        XCTAssertTrue(streamText.contains("Hello native!"))

        let streamRecord = try XCTUnwrap(engine.callHistory.first)
        XCTAssertEqual(streamRecord.finalUsage?.promptTokens, 1000)
        XCTAssertEqual(streamRecord.finalUsage?.cachedInputTokens, 800)
        XCTAssertEqual(streamRecord.finalUsage?.completionTokens, 25)
    }

    // MARK: - 4. Proactive Alerts & Throttling

    @MainActor
    func testAlertNotifierThrottlingAndBudgetAuthAlerts() async throws {
        let throttler = MacOSSystemAlertNotifier(throttleSeconds: 600)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let ev1 = SystemAlertEvent(category: .budgetWarning, dedupKey: "global", title: "t", body: "b", timestamp: t0)
        XCTAssertTrue(throttler.shouldDeliver(event: ev1))
        XCTAssertFalse(throttler.shouldDeliver(event: SystemAlertEvent(category: .budgetWarning, dedupKey: "global", title: "t", body: "b", timestamp: t0.addingTimeInterval(30))))
        XCTAssertTrue(throttler.shouldDeliver(event: SystemAlertEvent(category: .budgetWarning, dedupKey: "global", title: "t", body: "b", timestamp: t0.addingTimeInterval(601))))

        let dir = makeTempDir("AutoRouteAlerts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let notifier = NoOpSystemAlertNotifier()
        let store = LocalPersistenceStore(baseDirectoryURL: dir)
        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            alertNotifier: notifier,
            autoStartProxyIfConfigured: false
        )
        engine.updateGlobalBudget(MonthlyBudgetLimit(limitUSD: 0.0, warningThreshold: 0.8))
        let outcome = await engine.executeChatCompletion(
            payload: ["model": "auto", "messages": [["role": "user", "content": "hi"]]],
            source: .externalProxy
        )
        XCTAssertEqual(outcome.httpStatusCode, 429)
        XCTAssertTrue(notifier.events.contains { $0.category == .budgetHardLimit })

        // Disabling notifications suppresses further alerts
        let countBefore = notifier.events.count
        engine.setSystemNotificationsEnabled(false)
        _ = await engine.executeChatCompletion(
            payload: ["model": "auto", "messages": [["role": "user", "content": "hi2"]]],
            source: .externalProxy
        )
        XCTAssertEqual(notifier.events.count, countBefore)
    }

    // MARK: - 5. HTTP/1.1 Keep-Alive, Chunked Request Body & TrafficLimiter

    func testLoopbackServerKeepAliveAndChunkedRequestBody() throws {
        let server = LoopbackHTTPServer { req, writer in
            let bodyStr = String(decoding: req.body, as: UTF8.self)
            let payload = #"{"path":"\#(req.path)","body":"\#(bodyStr)"}"#
            writer.sendJSON(statusCode: 200, body: Data(payload.utf8))
        }
        let port = try server.start(port: 0)
        defer { server.stop() }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connectRes, 0)

        func sendRaw(_ str: String) {
            let data = Data(str.utf8)
            data.withUnsafeBytes { buf in
                _ = Darwin.send(fd, buf.baseAddress, data.count, 0)
            }
        }
        var readBuf = Data()
        func readResponse() -> String {
            var tmp = [UInt8](repeating: 0, count: 4096)
            let sep = Data("\r\n\r\n".utf8)
            while readBuf.range(of: sep) == nil {
                let n = Darwin.recv(fd, &tmp, tmp.count, 0)
                if n <= 0 { break }
                readBuf.append(contentsOf: tmp[0..<n])
            }
            guard let sepRange = readBuf.range(of: sep) else {
                let out = String(decoding: readBuf, as: UTF8.self)
                readBuf.removeAll()
                return out
            }
            let headerStr = String(decoding: readBuf[readBuf.startIndex..<sepRange.lowerBound], as: UTF8.self)
            let contentLen = headerStr.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            let headerLen = readBuf.distance(from: readBuf.startIndex, to: sepRange.upperBound)
            let totalNeeded = headerLen + contentLen
            while readBuf.count < totalNeeded {
                let n = Darwin.recv(fd, &tmp, tmp.count, 0)
                if n <= 0 { break }
                readBuf.append(contentsOf: tmp[0..<n])
            }
            let frame = Data(readBuf.prefix(totalNeeded))
            readBuf = Data(readBuf.dropFirst(min(readBuf.count, totalNeeded)))
            return String(decoding: frame, as: UTF8.self)
        }

        // Request 1: chunked POST over HTTP/1.1 keep-alive
        sendRaw(
            "POST /first HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(port)\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "Connection: keep-alive\r\n\r\n" +
            "5;ext=1\r\nhello\r\n" +
            "6\r\n world\r\n" +
            "0\r\nX-Trailer: ok\r\n\r\n"
        )
        let resp1 = readResponse()
        XCTAssertTrue(resp1.contains("HTTP/1.1 200 OK"))
        XCTAssertTrue(resp1.lowercased().contains("connection: keep-alive"))
        XCTAssertTrue(resp1.contains(#""body":"hello world""#))

        // Request 2 on the EXACT same TCP socket!
        sendRaw(
            "GET /second HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(port)\r\n" +
            "Connection: close\r\n\r\n"
        )
        let resp2 = readResponse()
        XCTAssertTrue(resp2.contains("HTTP/1.1 200 OK"))
        XCTAssertTrue(resp2.contains(#""path":"/second""#))
    }

    @MainActor
    func testTrafficLimiterSpillsOverloadedPrimaryToSameTierBackup() async throws {
        let dir = makeTempDir("AutoRouteTrafficLimiter")
        defer { try? FileManager.default.removeItem(at: dir) }

        let upstream = LoopbackHTTPServer { req, writer in
            let obj = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
            let m = (obj["model"] as? String) ?? "unknown"
            let resp = #"{"id":"1","object":"chat.completion","model":"\#(m)","choices":[{"index":0,"message":{"role":"assistant","content":"from \#(m)"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#
            writer.sendJSON(statusCode: 200, body: Data(resp.utf8))
        }
        let port = try upstream.start(port: 0)
        defer { upstream.stop() }

        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: dir),
            keychain: InMemoryKeychainService(),
            alertNotifier: NoOpSystemAlertNotifier(),
            autoStartProxyIfConfigured: false
        )
        let p1 = ProviderConfig(name: "P1", baseURL: "http://127.0.0.1:\(port)", healthStatus: .healthy, maxConcurrentRequests: 1)
        let p2 = ProviderConfig(name: "P2", baseURL: "http://127.0.0.1:\(port)", healthStatus: .healthy, maxConcurrentRequests: 10)
        try engine.upsertProvider(p1, apiKey: nil)
        try engine.upsertProvider(p2, apiKey: nil)

        let primary = ModelConfig(providerID: p1.id, modelID: "primary-model", inputPricePerMillion: 1, outputPricePerMillion: 2, maxRequestsPerMinute: 1, capabilities: [.chat], availabilityStatus: .available)
        let backup = ModelConfig(providerID: p2.id, modelID: "backup-model", inputPricePerMillion: 1, outputPricePerMillion: 2, capabilities: [.chat], availabilityStatus: .available)
        engine.upsertModel(primary)
        engine.upsertModel(backup)
        engine.setTierModel(tier: .low, modelUUID: primary.id, isManual: true)
        engine.addTierBackupModel(tier: .low, modelUUID: backup.id)

        // First call uses primary (hitting its soft RPM cap of 1)
        let first = await engine.executeChatCompletion(
            payload: ["model": "auto/low", "messages": [["role": "user", "content": "one"]]],
            source: .externalProxy
        )
        XCTAssertEqual(first.callRecord.executedModelID, "primary-model")

        // Second call immediately spills to backup-model before hitting upstream 429!
        let second = await engine.executeChatCompletion(
            payload: ["model": "auto/low", "messages": [["role": "user", "content": "two"]]],
            source: .externalProxy
        )
        XCTAssertEqual(second.callRecord.executedModelID, "backup-model")
        XCTAssertTrue(second.callRecord.decision.matchedRules.contains { $0.contains("软限流") })
    }

    // MARK: - 6. Semantic Version & UpdateCheckService

    func testSemanticVersionComparisonAndUpdateChecker() async throws {
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion(parsing: "0.1.0")), try XCTUnwrap(SemanticVersion(parsing: "0.2.0")))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion(parsing: "0.1.2")), try XCTUnwrap(SemanticVersion(parsing: "0.1.10")))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion(parsing: "0.2.0-rc.1")), try XCTUnwrap(SemanticVersion(parsing: "0.2.0")))

        let mockReleaseServer = LoopbackHTTPServer { req, writer in
            switch req.path {
            case "/latest-newer":
                writer.sendJSON(statusCode: 200, body: Data(#"{"tag_name":"v0.2.0","html_url":"https://github.com/Profeel/autoroute/releases/tag/v0.2.0","body":"SQLite + Prompt Cache"}"#.utf8))
            case "/latest-same":
                writer.sendJSON(statusCode: 200, body: Data(#"{"tag_name":"v0.1.0","html_url":"https://github.com/Profeel/autoroute/releases/tag/v0.1.0","body":""}"#.utf8))
            default:
                writer.sendJSON(statusCode: 404, body: Data(#"{"message":"Not Found"}"#.utf8))
            }
        }
        let port = try mockReleaseServer.start(port: 0)
        defer { mockReleaseServer.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let newer = await UpdateCheckService.checkForUpdates(
            currentVersion: "0.1.0",
            endpointURL: URL(string: "http://127.0.0.1:\(port)/latest-newer")!,
            session: session
        )
        if case .updateAvailable(let cur, let release) = newer {
            XCTAssertEqual(cur, "0.1.0")
            XCTAssertEqual(release.version, "0.2.0")
        } else {
            XCTFail("Expected updateAvailable, got \(newer)")
        }

        let same = await UpdateCheckService.checkForUpdates(
            currentVersion: "0.1.0",
            endpointURL: URL(string: "http://127.0.0.1:\(port)/latest-same")!,
            session: session
        )
        XCTAssertEqual(same, .upToDate(currentVersion: "0.1.0"))

        let missing = await UpdateCheckService.checkForUpdates(
            currentVersion: "0.1.0",
            endpointURL: URL(string: "http://127.0.0.1:\(port)/missing")!,
            session: session
        )
        XCTAssertEqual(missing, .noPublishedRelease(currentVersion: "0.1.0"))
    }
}
