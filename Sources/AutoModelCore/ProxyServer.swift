import Foundation

public final class ProxyServer: @unchecked Sendable {
    private weak var engine: AutoModelEngine?
    private var httpServer: LoopbackHTTPServer?

    public init(engine: AutoModelEngine) {
        self.engine = engine
    }

    public var isRunning: Bool {
        httpServer?.isRunning ?? false
    }

    public var currentPort: Int? {
        httpServer?.currentPort
    }

    @discardableResult
    public func start(port: Int) throws -> Int {
        stop()
        let server = LoopbackHTTPServer { [weak self] req, writer in
            guard let self else {
                writer.close()
                return
            }
            await self.handleRequest(req, writer: writer)
        }
        let actualPort = try server.start(port: port)
        self.httpServer = server
        return actualPort
    }

    public func stop() {
        httpServer?.stop()
        httpServer = nil
    }

    private func handleRequest(_ req: HTTPRequestMessage, writer: HTTPConnectionWriter) async {
        guard let engine else {
            writer.sendJSON(
                statusCode: 503,
                body: errorJSON(message: "AutoRoute engine is shutting down", type: "server_error", code: "engine_unavailable")
            )
            return
        }

        let securityContext = await MainActor.run { (engine.localAPIToken, engine.config.proxySettings.port, engine.localModelAPIKey) }
        if let rejection = LocalAPIRequestSecurity.rejection(
            for: req,
            port: securityContext.1,
            token: securityContext.0,
            modelAPIKey: securityContext.2
        ) {
            writer.sendJSON(
                statusCode: rejection.statusCode,
                headers: ["WWW-Authenticate": "Bearer realm=\"AutoRoute local API\""],
                body: errorJSON(message: rejection.message, type: "authentication_error", code: rejection.code)
            )
            return
        }

        // Authenticated preflight is acknowledged without granting browser CORS access.
        if req.method == "OPTIONS" {
            writer.sendJSON(statusCode: 204, body: Data())
            return
        }

        switch (req.method, req.path) {
        case ("GET", "/health"), ("GET", "/v1/health"):
            handleMinimalHealth(writer: writer)

        case ("GET", "/v1/models"):
            await handleListModels(engine: engine, writer: writer)

        case ("POST", "/v1/chat/completions"):
            await handleChatCompletions(req: req, engine: engine, writer: writer)

        case ("POST", "/v1/responses"):
            await handleResponsesAPI(req: req, engine: engine, writer: writer)

        case ("POST", "/v1/messages"):
            await handleAnthropicMessages(req: req, engine: engine, writer: writer)

        case ("POST", "/v1/embeddings"):
            writer.sendJSON(
                statusCode: 501,
                body: errorJSON(
                    message: "AutoRoute 暂未实现 Embeddings API (/v1/embeddings)。",
                    type: "not_implemented_error",
                    code: "unsupported_endpoint"
                )
            )

        case ("GET", "/api/local/status"):
            await handleHealth(engine: engine, writer: writer)

        case ("GET", "/api/local/receipts"):
            await handleLocalReceipts(engine: engine, writer: writer)

        case ("POST", "/api/local/strategy"):
            await handleSwitchStrategy(req: req, engine: engine, writer: writer)

        case ("POST", "/api/local/discover-and-probe"):
            await handleDiscoverAndProbe(engine: engine, writer: writer)

        case ("GET", "/api/local/models-health"):
            await handleModelsHealth(engine: engine, writer: writer)

        case ("POST", "/api/local/tiers"):
            await handleUpdateTiers(req: req, engine: engine, writer: writer)

        case ("GET", "/api/local/agents"):
            await handleListAgents(engine: engine, writer: writer)

        default:
            writer.sendJSON(
                statusCode: 404,
                body: errorJSON(
                    message: "未找到接口 \(req.method) \(req.path)。第一版仅支持 GET /health, GET /v1/models, POST /v1/chat/completions。",
                    type: "invalid_request_error",
                    code: "unknown_endpoint"
                )
            )
        }
    }

    private func handleMinimalHealth(writer: HTTPConnectionWriter) {
        let data = (try? JSONSerialization.data(withJSONObject: ["status": "ok", "app": "AutoRoute"], options: [.sortedKeys])) ?? Data()
        writer.sendJSON(statusCode: 200, body: data)
    }

    private func handleHealth(engine: AutoModelEngine, writer: HTTPConnectionWriter) async {
        let info = await MainActor.run { () -> [String: Any] in
            var tiersDict: [String: Any] = [:]
            for tier in ModelTier.allCases {
                if let m = engine.model(for: tier) {
                    tiersDict[tier.rawValue] = [
                        "model_uuid": m.id.uuidString,
                        "model_id": m.modelID,
                        "display_name": m.displayName,
                        "manual": engine.config.policy.isManual(for: tier)
                    ]
                }
            }
            let todayUsage = engine.todayUsageSummary()
            return [
                "status": "ok",
                "app": "AutoRoute",
                "bind": "127.0.0.1",
                "port": engine.config.proxySettings.port,
                "active_strategy": engine.config.policy.activeStrategy.rawValue,
                "active_strategy_name": engine.config.policy.activeStrategy.displayName,
                "policy_version": engine.config.policy.policyVersion,
                "provider_count": engine.config.providers.count,
                "model_count": engine.config.models.count,
                "receipt_count": engine.callHistory.count,
                "today_call_count": todayUsage.callCount,
                "today_tokens": todayUsage.totalTokens,
                "tiers": tiersDict
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])) ?? Data()
        writer.sendJSON(statusCode: 200, body: data)
    }

    private func handleListModels(engine: AutoModelEngine, writer: HTTPConnectionWriter) async {
        let modelList = await MainActor.run { () -> [[String: Any]] in
            let providersByID = Dictionary(uniqueKeysWithValues: engine.config.providers.map { ($0.id, $0) })
            let nowEpoch = Int(Date().timeIntervalSince1970)
            var items: [[String: Any]] = [
                [
                    "id": "auto",
                    "object": "model",
                    "created": nowEpoch,
                    "owned_by": "automodel-router"
                ],
                [
                    "id": "auto/low",
                    "object": "model",
                    "created": nowEpoch,
                    "owned_by": "automodel-tier"
                ],
                [
                    "id": "auto/medium",
                    "object": "model",
                    "created": nowEpoch,
                    "owned_by": "automodel-tier"
                ],
                [
                    "id": "auto/high",
                    "object": "model",
                    "created": nowEpoch,
                    "owned_by": "automodel-tier"
                ]
            ]
            if let window = engine.autoCatalogContextWindow() {
                items[0]["context_length"] = window
            }
            for kind in AgentKind.allCases {
                let alias = "auto/agent/\(kind.rawValue)"
                for suffix in ["", "/low", "/medium", "/high"] {
                    items.append([
                        "id": "\(alias)\(suffix)",
                        "object": "model",
                        "created": nowEpoch,
                        "owned_by": "autoroute-agent"
                    ])
                }
            }
            for model in engine.config.models where model.isEnabled && !model.isAutoEvicted && model.availabilityStatus == .available {
                let provider = providersByID[model.providerID]
                if provider?.isEnabled == true && provider?.healthStatus != .authError && provider?.healthStatus != .networkError {
                    items.append([
                        "id": model.modelID,
                        "object": "model",
                        "created": nowEpoch,
                        "owned_by": provider?.name ?? "custom"
                    ])
                }
            }
            return items
        }

        let payload: [String: Any] = ["object": "list", "data": modelList]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        writer.sendJSON(statusCode: 200, body: data)
    }

    private func handleChatCompletions(
        req: HTTPRequestMessage,
        engine: AutoModelEngine,
        writer: HTTPConnectionWriter
    ) async {
        guard let jsonObj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            writer.sendJSON(
                statusCode: 400,
                body: errorJSON(
                    message: "请求体必须是有效的 JSON 对象。",
                    type: "invalid_request_error",
                    code: "invalid_json"
                )
            )
            return
        }

        guard jsonObj["_autoroute_responses_reasoning"] == nil else {
            writer.sendJSON(statusCode: 400, body: errorJSON(message: "请求使用了 AutoRoute 保留字段。", type: "invalid_request_error", code: "reserved_parameter"))
            return
        }

        let isStream = (jsonObj["stream"] as? Bool) ?? false
        let sessionHeader = sessionHeader(from: req)
        let clientName = detectClientAgent(req: req, endpointPath: "/v1/chat/completions", payload: jsonObj)
        let agentHeader = req.header("X-AutoModel-Agent")
        let streamStarted = StreamFlagBox()

        let headersCallback: (@Sendable ([String: String]) async throws -> Void)? = isStream ? { @Sendable headers in
            streamStarted.markStarted()
            guard writer.startChunkedStream(statusCode: 200, headers: headers) else {
                throw ClientStreamDisconnectedError()
            }
        } : nil

        let chunkCallback: (@Sendable (Data) async throws -> Void)? = isStream ? { @Sendable chunkData in
            guard writer.writeStreamChunk(chunkData) else {
                throw ClientStreamDisconnectedError()
            }
        } : nil

        let outcome = await engine.executeChatCompletion(
            payload: jsonObj,
            source: .externalProxy,
            sessionHeader: sessionHeader,
            clientName: clientName,
            endpointPath: "/v1/chat/completions",
            agentHeader: agentHeader,
            clientHeaders: req.headers,
            onStreamHeadersReady: headersCallback,
            onStreamChunk: chunkCallback
        )

        if isStream && streamStarted.wasStarted {
            writer.finishStream()
        } else {
            let headers = outcome.headers
            writer.sendJSON(
                statusCode: outcome.httpStatusCode,
                headers: headers,
                body: outcome.responseBody
            )
        }
    }

    private func handleAnthropicMessages(
        req: HTTPRequestMessage,
        engine: AutoModelEngine,
        writer: HTTPConnectionWriter
    ) async {
        guard let rawJSON = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            writer.sendJSON(
                statusCode: 400,
                body: errorJSON(message: "请求体必须是有效的 JSON 对象。", type: "invalid_request_error", code: "invalid_json")
            )
            return
        }

        let configuredModels = await MainActor.run { engine.config.models }
        let openAIPayload: [String: Any]
        switch ProtocolAdapters.anthropicToOpenAIRequest(rawJSON, configuredModels: configuredModels) {
        case .success(let converted):
            openAIPayload = converted
        case .failure(let err):
            if case .badRequest(let status, let code, let message) = err {
                writer.sendJSON(statusCode: status, body: errorJSON(message: message, type: "invalid_request_error", code: code))
            }
            return
        }

        let isStream = (openAIPayload["stream"] as? Bool) ?? false
        let sessionHeader = sessionHeader(from: req)
        let clientName = detectClientAgent(req: req, endpointPath: "/v1/messages", payload: openAIPayload)
        let agentHeader = req.header("X-AutoModel-Agent")
        let streamStarted = StreamFlagBox()
        let nativeAnthropicStream = StreamFlagBox()
        let translator = AnthropicStreamTranslator()
        let passthroughHeaders = NativeAnthropicRouting.passthroughHeaders(from: req)

        let headersCallback: (@Sendable ([String: String]) async throws -> Void)? = isStream ? { @Sendable headers in
            if headers["X-AutoModel-Wire-Format"] == "anthropic-native" {
                nativeAnthropicStream.markStarted()
            }
            streamStarted.markStarted()
            guard writer.startChunkedStream(statusCode: 200, headers: headers) else {
                throw ClientStreamDisconnectedError()
            }
        } : nil

        let chunkCallback: (@Sendable (Data) async throws -> Void)? = isStream ? { @Sendable chunkData in
            if nativeAnthropicStream.wasStarted {
                guard writer.writeStreamChunk(chunkData) else {
                    throw ClientStreamDisconnectedError()
                }
            } else {
                for eventData in translator.translateChunk(chunkData) {
                    guard writer.writeStreamChunk(eventData) else {
                        throw ClientStreamDisconnectedError()
                    }
                }
            }
        } : nil

        let outcome = await engine.executeChatCompletion(
            payload: openAIPayload,
            source: .externalProxy,
            sessionHeader: sessionHeader,
            clientName: clientName,
            endpointPath: "/v1/messages",
            agentHeader: agentHeader,
            nativeAnthropicPayload: rawJSON,
            nativeAnthropicHeaders: passthroughHeaders,
            clientHeaders: req.headers,
            onStreamHeadersReady: headersCallback,
            onStreamChunk: chunkCallback
        )

        let isNativeAnthropicResponse = outcome.headers["X-AutoModel-Wire-Format"] == "anthropic-native"
        if isStream && streamStarted.wasStarted {
            if !nativeAnthropicStream.wasStarted {
                for tailEvent in translator.finishEvents() {
                    _ = writer.writeStreamChunk(tailEvent)
                }
            }
            writer.finishStream()
        } else if isNativeAnthropicResponse {
            writer.sendJSON(statusCode: outcome.httpStatusCode, headers: outcome.headers, body: outcome.responseBody)
        } else if outcome.httpStatusCode == 200,
                  let openAIObj = try? JSONSerialization.jsonObject(with: outcome.responseBody) as? [String: Any] {
            let anthropicObj = ProtocolAdapters.openAIToAnthropicResponse(
                openAIObj,
                fallbackModel: outcome.callRecord.executedModelID ?? "auto"
            )
            let outData = (try? JSONSerialization.data(withJSONObject: anthropicObj, options: [])) ?? outcome.responseBody
            let headers = outcome.headers
            writer.sendJSON(statusCode: 200, headers: headers, body: outData)
        } else {
            let headers = outcome.headers
            writer.sendJSON(statusCode: outcome.httpStatusCode, headers: headers, body: outcome.responseBody)
        }
    }

    private func handleResponsesAPI(
        req: HTTPRequestMessage,
        engine: AutoModelEngine,
        writer: HTTPConnectionWriter
    ) async {
        guard let rawJSON = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            writer.sendJSON(
                statusCode: 400,
                body: errorJSON(message: "请求体必须是有效的 JSON 对象。", type: "invalid_request_error", code: "invalid_json")
            )
            return
        }

        let useNativeResponses = NativeResponsesRouting.isRequired(rawJSON)
        let openAIPayload: [String: Any]
        if useNativeResponses {
            openAIPayload = NativeResponsesRouting.routingPayload(rawJSON)
        } else {
            switch ProtocolAdapters.responsesToChatRequest(rawJSON) {
            case .success(let converted):
                openAIPayload = converted
            case .failure(let err):
                if case .badRequest(let status, let code, let message) = err {
                    writer.sendJSON(statusCode: status, body: errorJSON(message: message, type: "invalid_request_error", code: code))
                }
                return
            }
        }

        let isStream = (openAIPayload["stream"] as? Bool) ?? false
        let sessionHeader = sessionHeader(from: req)
        let clientName = detectClientAgent(req: req, endpointPath: "/v1/responses", payload: openAIPayload)
        let agentHeader = req.header("X-AutoModel-Agent")
        let streamStarted = StreamFlagBox()
        let translator = ResponsesStreamTranslator()

        let headersCallback: (@Sendable ([String: String]) async throws -> Void)? = isStream ? { @Sendable headers in
            streamStarted.markStarted()
            guard writer.startChunkedStream(statusCode: 200, headers: headers) else {
                throw ClientStreamDisconnectedError()
            }
        } : nil

        let chunkCallback: (@Sendable (Data) async throws -> Void)? = isStream ? { @Sendable chunkData in
            if useNativeResponses {
                guard writer.writeStreamChunk(chunkData) else {
                    throw ClientStreamDisconnectedError()
                }
            } else {
                for eventData in translator.translateChunk(chunkData) {
                    guard writer.writeStreamChunk(eventData) else {
                        throw ClientStreamDisconnectedError()
                    }
                }
            }
        } : nil

        let outcome = await engine.executeChatCompletion(
            payload: openAIPayload,
            source: .externalProxy,
            sessionHeader: sessionHeader,
            clientName: clientName,
            endpointPath: "/v1/responses",
            agentHeader: agentHeader,
            nativeResponsesPayload: useNativeResponses ? NativeResponsesRouting.wirePayload(rawJSON) : nil,
            clientHeaders: req.headers,
            onStreamHeadersReady: headersCallback,
            onStreamChunk: chunkCallback
        )

        if isStream && streamStarted.wasStarted {
            if !useNativeResponses {
                for tailEvent in translator.finishEvents() {
                    _ = writer.writeStreamChunk(tailEvent)
                }
            }
            writer.finishStream()
        } else if useNativeResponses {
            writer.sendJSON(statusCode: outcome.httpStatusCode, headers: outcome.headers, body: outcome.responseBody)
        } else if outcome.httpStatusCode == 200,
                  let openAIObj = try? JSONSerialization.jsonObject(with: outcome.responseBody) as? [String: Any] {
            let responsesObj = ProtocolAdapters.chatToResponsesResponse(
                openAIObj,
                fallbackModel: outcome.callRecord.executedModelID ?? "auto"
            )
            let outData = (try? JSONSerialization.data(withJSONObject: responsesObj, options: [])) ?? outcome.responseBody
            let headers = outcome.headers
            writer.sendJSON(statusCode: 200, headers: headers, body: outData)
        } else {
            let headers = outcome.headers
            writer.sendJSON(statusCode: outcome.httpStatusCode, headers: headers, body: outcome.responseBody)
        }
    }

    private func handleLocalReceipts(engine: AutoModelEngine, writer: HTTPConnectionWriter) async {
        let data = await MainActor.run { () -> Data in
            let secrets = engine.keychain.allKnownSecretValues()
            let slice = Array(engine.callHistory.prefix(50))
            return (try? engine.persistence.exportReceiptsJSON(records: slice, secretsToRedact: secrets)) ?? Data("[]".utf8)
        }
        writer.sendJSON(statusCode: 200, body: data)
    }

    private func handleSwitchStrategy(
        req: HTTPRequestMessage,
        engine: AutoModelEngine,
        writer: HTTPConnectionWriter
    ) async {
        guard let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let strategyRaw = json["strategy"] as? String,
              let preset = RoutingStrategyPreset(rawValue: strategyRaw) else {
            writer.sendJSON(
                statusCode: 400,
                body: errorJSON(
                    message: "strategy 参数无效，允许值: cost_first, balanced, quality_first",
                    type: "invalid_request_error",
                    code: "invalid_strategy"
                )
            )
            return
        }

        let updatedInfo = await MainActor.run { () -> [String: Any] in
            engine.setStrategy(preset)
            return [
                "active_strategy": engine.config.policy.activeStrategy.rawValue,
                "active_strategy_name": engine.config.policy.activeStrategy.displayName,
                "policy_version": engine.config.policy.policyVersion
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: updatedInfo)) ?? Data()
        writer.sendJSON(statusCode: 200, body: data)
    }

    private func handleDiscoverAndProbe(engine: AutoModelEngine, writer: HTTPConnectionWriter) async {
        let summary = await engine.discoverAndProbeLocalModels()
        let payload = await buildModelsHealthPayload(engine: engine, summary: summary)
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        writer.sendJSON(statusCode: 200, body: data)
    }

    private func handleModelsHealth(engine: AutoModelEngine, writer: HTTPConnectionWriter) async {
        let summary = await MainActor.run { engine.lastDiscoverySummary }
        let payload = await buildModelsHealthPayload(engine: engine, summary: summary)
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        writer.sendJSON(statusCode: 200, body: data)
    }

    private func buildModelsHealthPayload(engine: AutoModelEngine, summary: DiscoveryAndProbeSummary?) async -> [String: Any] {
        await MainActor.run {
            let providersByID = Dictionary(uniqueKeysWithValues: engine.config.providers.map { ($0.id, $0) })
            var healthy: [[String: Any]] = []
            var evicted: [[String: Any]] = []

            for model in engine.config.models {
                let providerName = providersByID[model.providerID]?.name ?? "unknown"
                var item: [String: Any] = [
                    "model_id": model.modelID,
                    "display_name": model.displayName,
                    "provider": providerName,
                    "availability": model.availabilityStatus.rawValue,
                    "is_auto_evicted": model.isAutoEvicted,
                    "discovered_source": model.discoveredSource ?? "manual",
                    "note": model.lastAvailabilityNote ?? ""
                ]
                if let latency = model.lastProbeLatencyMs {
                    item["probe_latency_ms"] = Int(latency.rounded())
                }
                if model.isAutoEvicted || model.availabilityStatus != .available {
                    evicted.append(item)
                } else {
                    healthy.append(item)
                }
            }

            var tiersDict: [String: Any] = [:]
            for tier in ModelTier.allCases {
                if let m = engine.model(for: tier) {
                    tiersDict[tier.rawValue] = [
                        "model_uuid": m.id.uuidString,
                        "model_id": m.modelID,
                        "display_name": m.displayName,
                        "manual": engine.config.policy.isManual(for: tier)
                    ]
                }
            }

            var result: [String: Any] = [
                "provider_count": engine.config.providers.count,
                "healthy_count": healthy.count,
                "evicted_count": evicted.count,
                "healthy_models": healthy,
                "evicted_models": evicted,
                "tiers": tiersDict
            ]
            if let summary {
                result["summary"] = [
                    "discovered_providers": summary.discoveredProvidersCount,
                    "discovered_models": summary.discoveredModelsCount,
                    "probed_models": summary.probedModelsCount,
                    "healthy_models": summary.healthyModelsCount,
                    "evicted_models": summary.evictedModelsCount,
                    "sources_scanned": summary.sourcesScanned
                ]
            }
            return result
        }
    }

    private func handleUpdateTiers(req: HTTPRequestMessage, engine: AutoModelEngine, writer: HTTPConnectionWriter) async {
        guard let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            writer.sendJSON(statusCode: 400, body: errorJSON(message: "JSON 无效", type: "invalid_request_error", code: "invalid_json"))
            return
        }

        let payload = await MainActor.run { () -> [String: Any] in
            if let autoReset = json["auto_reset"] as? Bool, autoReset {
                engine.autoConfigureModelTiers(forceResetManual: true)
            } else {
                for tier in ModelTier.allCases {
                    if let targetModelID = json[tier.rawValue] as? String {
                        if let match = engine.config.models.first(where: { $0.modelID == targetModelID }) {
                            engine.setTierModel(tier: tier, modelUUID: match.id, isManual: true)
                        }
                    }
                }
            }

            var tiersDict: [String: Any] = [:]
            for tier in ModelTier.allCases {
                if let m = engine.model(for: tier) {
                    tiersDict[tier.rawValue] = [
                        "model_id": m.modelID,
                        "display_name": m.displayName,
                        "manual": engine.config.policy.isManual(for: tier)
                    ]
                }
            }
            return [
                "policy_version": engine.config.policy.policyVersion,
                "tiers": tiersDict
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        writer.sendJSON(statusCode: 200, body: data)
    }

    private func handleListAgents(engine: AutoModelEngine, writer: HTTPConnectionWriter) async {
        let items = await MainActor.run { () -> [[String: Any]] in
            engine.refreshAgentStatuses()
            return engine.agentStatuses.map { s in
                [
                    "kind": s.kind.rawValue,
                    "display_name": s.kind.displayName,
                    "config_path": s.configFilePath,
                    "installed": s.isInstalled,
                    "connected": s.isConnectedToAutoModel,
                    "has_backup": s.hasBackup,
                    "current_base_url": s.currentBaseURL ?? "",
                    "current_model": s.currentModelSummary ?? ""
                ]
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["agents": items], options: [.sortedKeys])) ?? Data()
        writer.sendJSON(statusCode: 200, body: data)
    }

    private func detectClientAgent(
        req: HTTPRequestMessage,
        endpointPath: String,
        payload: [String: Any]? = nil
    ) -> String {
        if let explicit = req.header("X-AutoModel-Agent") ?? req.header("X-Client-Name") ?? req.header("X-Title") {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let lower = trimmed.lowercased()
                if lower.contains("hermes") { return "Hermes Agent" }
                if lower.contains("openclaw") { return "OpenClaw" }
                if lower.contains("deepseek") || lower == "dsh" { return "DeepSeek Harness" }
                return trimmed
            }
        }
        if let sessionID = req.header("X-Hermes-Session-Id"),
           !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AgentKind.hermes.displayName
        }
        let referer = (req.header("HTTP-Referer") ?? req.header("Referer") ?? "").lowercased()
        if referer.contains("hermes") { return "Hermes Agent" }
        if referer.contains("openclaw") { return "OpenClaw" }
        if referer.contains("opencode") { return "OpenCode" }
        if referer.contains("deepseek") { return "DeepSeek Harness" }

        let ua = (req.header("User-Agent") ?? "").lowercased()
        if ua.contains("claude") { return "Claude Code" }
        if ua.contains("codex") { return "Codex" }
        if ua.contains("opencode") { return "OpenCode" }
        if ua.contains("hermes") { return "Hermes Agent" }
        if ua.contains("deepseek-harness") || ua.contains("deepseek harness") || ua.contains("dsh/") { return "DeepSeek Harness" }
        if ua.contains("openclaw") { return "OpenClaw" }
        if ua.contains("cursor") { return "Cursor" }
        if ua.contains("cline") || ua.contains("roo") { return "Cline" }
        if ua.contains("continue") { return "Continue" }
        if ua.contains("curl") { return "curl" }

        // Identify Hermes by its built-in system prompt when the SDK supplies no client label.
        if let payload {
            var instructions = [payload["system"] as? String].compactMap { $0 }
            if let messages = payload["messages"] as? [[String: Any]] {
                for message in messages.prefix(2) where (message["role"] as? String) == "system" {
                    if let text = message["content"] as? String {
                        instructions.append(text)
                    } else if let parts = message["content"] as? [[String: Any]] {
                        instructions.append(contentsOf: parts.compactMap { $0["text"] as? String })
                    }
                }
            }
            if instructions.contains(where: AgentKind.isHermesSystemPrompt) {
                return AgentKind.hermes.displayName
            }
            let legacyHints = instructions.map { String($0.prefix(1200)) }
                + [payload["user"] as? String ?? ""]
                + ((payload["metadata"] as? [String: Any])?.values.map { "\($0)" } ?? [])
            let joined = legacyHints.joined(separator: " ").lowercased()
            if joined.contains("openclaw") { return "OpenClaw" }
            if joined.contains("opencode") { return "OpenCode" }
        }

        if ua.contains("python") || ua.contains("httpx") || ua.contains("aiohttp") { return "Python SDK" }

        switch endpointPath {
        case "/v1/messages": return "Claude Code"
        case "/v1/responses": return "Codex"
        default: return "外部客户端"
        }
    }

    private func sessionHeader(from req: HTTPRequestMessage) -> String? {
        ["X-AutoModel-Session", "X-Hermes-Session-Id", "X-OpenAI-Conversation-Id"]
            .lazy.compactMap { req.header($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func errorJSON(message: String, type: String, code: String) -> Data {
        let payload: [String: Any] = [
            "error": [
                "message": message,
                "type": type,
                "code": code
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}

private final class StreamFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func markStarted() {
        lock.withLock { started = true }
    }

    var wasStarted: Bool {
        lock.withLock { started }
    }
}
