import CFNetwork
import Foundation

public struct ClientStreamDisconnectedError: Error, Sendable {
    public init() {}
}

public enum UpstreamError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case clientDisconnected
    case requestDeadlineExceeded
    case authError(statusCode: Int, message: String)
    case modelUnavailable(statusCode: Int, message: String, availability: ModelAvailabilityStatus)
    case networkError(message: String)
    case httpError(statusCode: Int, rawBody: Data, message: String, retryAfterSeconds: Double? = nil)
    case invalidResponse(message: String)

    public var retryAfterSeconds: Double? {
        if case .httpError(429, _, _, let delay) = self { return delay }
        return nil
    }

    public var statusCode: Int {
        switch self {
        case .invalidURL: return 400
        case .clientDisconnected: return 499
        case .requestDeadlineExceeded: return 504
        case .authError(let code, _): return code
        case .modelUnavailable(let code, _, _): return code
        case .networkError: return 502
        case .httpError(let code, _, _, _): return code
        case .invalidResponse: return 502
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "无效的供应商 URL: \(url)"
        case .clientDisconnected:
            return "客户端已断开流式连接"
        case .requestDeadlineExceeded:
            return "请求达到累计上游 deadline"
        case .authError(_, let msg):
            return "鉴权失败 (API Key 无效或无权限): \(msg)"
        case .modelUnavailable(_, let msg, _):
            return "模型不可用: \(msg)"
        case .networkError(let msg):
            return "网络连接失败: \(msg)"
        case .httpError(let code, _, let msg, _):
            return "上游返回 HTTP \(code): \(msg)"
        case .invalidResponse(let msg):
            return "上游响应格式异常: \(msg)"
        }
    }
}

public struct UpstreamCompletionResult: Sendable {
    public var statusCode: Int
    public var responseBody: Data
    public var assistantText: String
    public var reasoningText: String?
    public var usage: TokenUsage?
    public var usageSource: UsageDataSource
    public var usageEstimationMethod: String?
    public var firstTokenMs: Double?
    public var totalLatencyMs: Double
    public var hasToolCalls: Bool

    public init(
        statusCode: Int,
        responseBody: Data,
        assistantText: String,
        reasoningText: String?,
        usage: TokenUsage?,
        usageSource: UsageDataSource,
        usageEstimationMethod: String?,
        firstTokenMs: Double?,
        totalLatencyMs: Double,
        hasToolCalls: Bool = false
    ) {
        self.statusCode = statusCode
        self.responseBody = responseBody
        self.assistantText = assistantText
        self.reasoningText = reasoningText
        self.usage = usage
        self.usageSource = usageSource
        self.usageEstimationMethod = usageEstimationMethod
        self.firstTokenMs = firstTokenMs
        self.totalLatencyMs = totalLatencyMs
        self.hasToolCalls = hasToolCalls
    }
}

public struct ModelProbeResult: Sendable {
    public var isAvailable: Bool
    public var availability: ModelAvailabilityStatus
    public var latencyMs: Double
    public var note: String
    public var isTransientFailure: Bool

    public init(
        isAvailable: Bool,
        availability: ModelAvailabilityStatus,
        latencyMs: Double,
        note: String,
        isTransientFailure: Bool = false
    ) {
        self.isAvailable = isAvailable
        self.availability = availability
        self.latencyMs = latencyMs
        self.note = note
        self.isTransientFailure = isTransientFailure
    }
}

public enum ProviderReachabilityOutcome: Sendable {
    case reachable(discoveredModelIDs: [String])
    case reachableNoModelList
    case unreachable(ProviderHealthStatus, String)
}

public final class UpstreamClient: @unchecked Sendable {
    private let session: URLSession
    private let proxySessionsLock = NSLock()
    private var proxySessionsByURL: [String: URLSession] = [:]

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    deinit {
        let sessions = proxySessionsLock.withLock { () -> [URLSession] in
            let all = Array(proxySessionsByURL.values)
            proxySessionsByURL.removeAll()
            return all
        }
        for s in sessions {
            s.invalidateAndCancel()
        }
    }

    private func resolvedSession(for provider: ProviderConfig) -> URLSession {
        guard let rawProxy = provider.proxyURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawProxy.isEmpty,
              let proxyURL = URL(string: rawProxy),
              let scheme = proxyURL.scheme?.lowercased(),
              let host = proxyURL.host, !host.isEmpty else {
            return session
        }

        let port = proxyURL.port ?? (scheme == "socks5" || scheme == "socks" ? 1080 : (scheme == "https" ? 443 : 8080))
        let cacheKey = "\(scheme)://\(host):\(port)"
        return proxySessionsLock.withLock {
            if let existing = proxySessionsByURL[cacheKey] {
                return existing
            }
            let cfg = URLSessionConfiguration.ephemeral
            cfg.waitsForConnectivity = false
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            var proxyDict: [AnyHashable: Any] = [:]
            if scheme == "socks5" || scheme == "socks" {
                proxyDict[kCFNetworkProxiesSOCKSEnable as String] = 1
                proxyDict[kCFNetworkProxiesSOCKSProxy as String] = host
                proxyDict[kCFNetworkProxiesSOCKSPort as String] = port
            } else if scheme == "http" || scheme == "https" {
                proxyDict[kCFNetworkProxiesHTTPEnable as String] = 1
                proxyDict[kCFNetworkProxiesHTTPProxy as String] = host
                proxyDict[kCFNetworkProxiesHTTPPort as String] = port
                proxyDict[kCFNetworkProxiesHTTPSEnable as String] = 1
                proxyDict[kCFNetworkProxiesHTTPSProxy as String] = host
                proxyDict[kCFNetworkProxiesHTTPSPort as String] = port
            }
            cfg.connectionProxyDictionary = proxyDict
            let created = URLSession(configuration: cfg)
            proxySessionsByURL[cacheKey] = created
            return created
        }
    }

    private func applyProviderHeaders(
        to request: inout URLRequest,
        provider: ProviderConfig,
        clientHeaders: [String: String] = [:]
    ) {
        let hopByHop: Set<String> = ["host", "content-length", "transfer-encoding", "connection"]
        let blockedPassThrough: Set<String> = ["authorization", "x-api-key", "cookie", "host", "content-length", "transfer-encoding", "connection"]

        for key in provider.customHeaders.keys.sorted() {
            let lower = key.lowercased()
            guard !hopByHop.contains(lower), let val = provider.customHeaders[key], !val.isEmpty else { continue }
            request.setValue(val, forHTTPHeaderField: key)
        }

        if !provider.passThroughHeaderNames.isEmpty && !clientHeaders.isEmpty {
            let clientLowered: [String: (name: String, value: String)] = Dictionary(
                clientHeaders.map { ($0.key.lowercased(), ($0.key, $0.value)) },
                uniquingKeysWith: { first, _ in first }
            )
            for allowedName in provider.passThroughHeaderNames {
                let lower = allowedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !lower.isEmpty, !blockedPassThrough.contains(lower),
                      let matched = clientLowered[lower], !matched.value.isEmpty else { continue }
                request.setValue(matched.value, forHTTPHeaderField: allowedName.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // MARK: - Provider Model Discovery / Connectivity Check

    public func fetchModels(
        provider: ProviderConfig,
        apiKey: String?,
        secretsToRedact: [String] = []
    ) async -> Result<[String], UpstreamError> {
        await fetchModels(provider: provider, apiKey: apiKey, timeoutSeconds: min(20, max(5, provider.timeoutSeconds)), secretsToRedact: secretsToRedact)
    }

    private func fetchModels(
        provider: ProviderConfig,
        apiKey: String?,
        timeoutSeconds: Double,
        secretsToRedact: [String]
    ) async -> Result<[String], UpstreamError> {
        if provider.apiProtocol == .codexChatGPT {
            // Codex ChatGPT OAuth backend (/backend-api/codex) does not expose /v1/models;
            // models are discovered from ~/.codex/models_cache.json and validated via /responses.
            return .success([])
        }

        let workBuddy = provider.apiProtocol == .workBuddy
        let path = workBuddy ? WorkBuddyProtocol.configPath : "/v1/models"
        guard let url = provider.endpointURL(path: path) else {
            return .failure(.invalidURL(provider.baseURL))
        }

        var secrets = secretsToRedact
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyProviderHeaders(to: &request, provider: provider)
        if workBuddy {
            guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                return .failure(WorkBuddyProtocol.missingKeyError())
            }
            WorkBuddyProtocol.applyHeaders(to: &request, key: key)
            secrets.append(contentsOf: WorkBuddyProtocol.secretValues(for: key))
        } else if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            if provider.apiProtocol == .anthropicMessages {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        do {
            let (data, response) = try await resolvedSession(for: provider).data(
                for: request, delegate: workBuddy ? WorkBuddyProtocol.redirectPolicy : nil
            )
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse(message: "未收到有效的 HTTP 响应"))
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                let msg = extractErrorMessage(from: data, secrets: secrets) ?? "Unauthorized"
                return .failure(.authError(statusCode: http.statusCode, message: msg))
            }
            guard (200...299).contains(http.statusCode) else {
                let msg = extractErrorMessage(from: data, secrets: secrets) ?? "HTTP \(http.statusCode)"
                return .failure(.httpError(statusCode: http.statusCode, rawBody: workBuddy ? Data() : data, message: msg))
            }

            if workBuddy {
                guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .failure(.invalidResponse(message: "WorkBuddy /v3/config 响应格式无效"))
                }
                if let error = WorkBuddyProtocol.error(from: config, secrets: secrets) { return .failure(error) }
                guard let ids = WorkBuddyProtocol.modelIDs(from: config), !ids.isEmpty else {
                    return .failure(.invalidResponse(message: "WorkBuddy 未返回可调用的 CLI 模型，请检查 API Key 及账号权限。"))
                }
                return .success(ids)
            }

            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataList = obj["data"] as? [[String: Any]] else {
                return .failure(.invalidResponse(message: "上游 /v1/models 返回格式不是 OpenAI 兼容列表"))
            }

            let ids = dataList.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
            return .success(ids)
        } catch {
            let cleanMsg = SecretRedactor.redact(mapNetworkError(error), secrets: secrets)
            return .failure(.networkError(message: cleanMsg))
        }
    }

    // MARK: - Chat Completions Execution (Non-Streaming & Streaming)

    public func executeChatCompletion(
        provider: ProviderConfig,
        model: ModelConfig,
        apiKey: String?,
        originalPayload: [String: Any],
        estimatedInputTokens: Int,
        stream: Bool,
        nativeResponsesPayload: [String: Any]? = nil,
        nativeAnthropicPayload: [String: Any]? = nil,
        nativeAnthropicHeaders: [String: String] = [:],
        clientHeaders: [String: String] = [:],
        resolvedEffort: ReasoningEffort? = nil,
        clientProvidedEffort: ReasoningEffort? = nil,
        secretsToRedact: [String] = [],
        onStreamHeadersReady: (@Sendable () async throws -> Void)? = nil,
        onStreamChunk: (@Sendable (Data) async throws -> Void)? = nil
    ) async -> Result<UpstreamCompletionResult, UpstreamError> {
        if let nativeResponsesPayload {
            guard provider.apiProtocol == .codexChatGPT || provider.apiProtocol == .openAIResponses else {
                let message = "Native Responses requests require a Responses-compatible provider"
                return .failure(.httpError(statusCode: 400, rawBody: Data(), message: message))
            }
            return await executeNativeResponsesCompletion(
                provider: provider, model: model, apiKey: apiKey,
                payload: nativeResponsesPayload, estimatedInputTokens: estimatedInputTokens,
                stream: stream, clientHeaders: clientHeaders,
                resolvedEffort: resolvedEffort, clientProvidedEffort: clientProvidedEffort,
                secretsToRedact: secretsToRedact, onStreamHeadersReady: onStreamHeadersReady, onStreamChunk: onStreamChunk
            )
        }
        if let nativeAnthropicPayload, provider.apiProtocol == .anthropicMessages {
            return await executeNativeAnthropicCompletion(
                provider: provider,
                model: model,
                apiKey: apiKey,
                payload: NativeAnthropicRouting.applyingInitialEffort(
                    to: nativeAnthropicPayload, modelID: model.modelID, effort: resolvedEffort
                ),
                passthroughHeaders: nativeAnthropicHeaders,
                clientHeaders: clientHeaders,
                estimatedInputTokens: estimatedInputTokens,
                stream: stream,
                secretsToRedact: secretsToRedact,
                onStreamHeadersReady: onStreamHeadersReady,
                onStreamChunk: onStreamChunk
            )
        }
        let preparedPayload = Self.injectReasoningEffortIfEligible(
            payload: originalPayload,
            model: model,
            resolvedEffort: resolvedEffort,
            clientProvidedEffort: clientProvidedEffort
        )

        switch provider.apiProtocol {
        case .codexChatGPT, .openAIResponses:
            return await executeResponsesCompletion(
                provider: provider,
                model: model,
                apiKey: apiKey,
                originalPayload: preparedPayload,
                estimatedInputTokens: estimatedInputTokens,
                callerRequestedStream: stream,
                clientHeaders: clientHeaders,
                secretsToRedact: secretsToRedact,
                onStreamHeadersReady: onStreamHeadersReady,
                onStreamChunk: onStreamChunk
            )
        case .anthropicMessages:
            return await executeAnthropicCompletion(
                provider: provider,
                model: model,
                apiKey: apiKey,
                originalPayload: preparedPayload,
                estimatedInputTokens: estimatedInputTokens,
                stream: stream,
                clientHeaders: clientHeaders,
                secretsToRedact: secretsToRedact,
                onStreamHeadersReady: onStreamHeadersReady,
                onStreamChunk: onStreamChunk
            )
        case .openAIChatCompletions, .workBuddy:
            break
        }

        let workBuddy = provider.apiProtocol == .workBuddy
        let path = workBuddy ? WorkBuddyProtocol.chatPath : "/v1/chat/completions"
        guard let url = provider.endpointURL(path: path) else {
            return .failure(.invalidURL(provider.baseURL))
        }

        let upstreamStreams = stream || workBuddy
        var upstreamPayload = workBuddy ? WorkBuddyProtocol.chatPayload(from: preparedPayload) : preparedPayload
        upstreamPayload["model"] = model.modelID
        upstreamPayload["stream"] = upstreamStreams

        guard let bodyData = try? JSONSerialization.data(withJSONObject: upstreamPayload, options: []) else {
            return .failure(.invalidResponse(message: "无法序列化上游请求 JSON"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = max(5.0, provider.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(upstreamStreams ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        applyProviderHeaders(to: &request, provider: provider, clientHeaders: clientHeaders)
        var secrets = secretsToRedact
        if workBuddy {
            guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                return .failure(WorkBuddyProtocol.missingKeyError())
            }
            WorkBuddyProtocol.applyHeaders(to: &request, key: key)
            secrets.append(contentsOf: WorkBuddyProtocol.secretValues(for: key))
        } else if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let startTime = DispatchTime.now()
        let activeSession = resolvedSession(for: provider)

        do {
            if !upstreamStreams {
                let (data, response) = try await activeSession.data(for: request)
                let totalMs = elapsedMs(since: startTime)
                guard let http = response as? HTTPURLResponse else {
                    return .failure(.invalidResponse(message: "上游未返回 HTTP 响应"))
                }

                if !(200...299).contains(http.statusCode) {
                    return .failure(classifyHTTPError(response: http, data: data, secrets: secretsToRedact))
                }

                // Parse OpenAI response to extract assistant text, usage, and normalize model field
                var parsedObj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                if parsedObj["model"] == nil || (parsedObj["model"] as? String)?.isEmpty == true {
                    parsedObj["model"] = model.modelID
                }

                let (assistantText, reasoningText) = Self.extractAssistantAndReasoning(from: parsedObj)
                let reportedUsage = extractUsage(from: parsedObj)
                let finalUsage: TokenUsage?
                let usageSource: UsageDataSource
                let estimationNote: String?

                if let reportedUsage {
                    finalUsage = reportedUsage
                    usageSource = .upstreamReported
                    estimationNote = nil
                } else {
                    let textForEst = assistantText.isEmpty ? (reasoningText ?? "") : assistantText
                    let estOut = RequestFeatureExtractor.estimateTokens(text: textForEst, messageCount: 0)
                    finalUsage = TokenUsage(promptTokens: estimatedInputTokens, completionTokens: estOut)
                    usageSource = .estimatedWhenMissing
                    estimationNote = "上游响应未包含 usage 字段，按本地字符数 (~3.2 chars/token) 估算"
                }

                let outData = (try? JSONSerialization.data(withJSONObject: parsedObj, options: [])) ?? data
                return .success(UpstreamCompletionResult(
                    statusCode: http.statusCode,
                    responseBody: outData,
                    assistantText: assistantText,
                    reasoningText: reasoningText,
                    usage: finalUsage,
                    usageSource: usageSource,
                    usageEstimationMethod: estimationNote,
                    firstTokenMs: totalMs,
                    totalLatencyMs: totalMs,
                    hasToolCalls: Self.responseContainsToolCalls(parsedObj)
                ))
            } else {
                // Streaming SSE request
                let (asyncBytes, response) = try await activeSession.bytes(
                    for: request, delegate: workBuddy ? WorkBuddyProtocol.redirectPolicy : nil
                )
                guard let http = response as? HTTPURLResponse else {
                    return .failure(.invalidResponse(message: "上游未返回 HTTP 响应"))
                }

                if !(200...299).contains(http.statusCode) {
                    var errorBytes = Data()
                    for try await byte in asyncBytes {
                        errorBytes.append(byte)
                        if errorBytes.count > 65_536 { break }
                    }
                    let error = classifyHTTPError(response: http, data: errorBytes, secrets: secrets)
                    if workBuddy, case .httpError(let status, _, let message, let retryAfter) = error {
                        return .failure(.httpError(statusCode: status, rawBody: Data(), message: message, retryAfterSeconds: retryAfter))
                    }
                    return .failure(error)
                }

                if !workBuddy, let onStreamHeadersReady {
                    try await onStreamHeadersReady()
                }

                var workBuddyResponse = WorkBuddyChatStream()
                var forwardedWorkBuddyHeaders = false
                var firstTokenMs: Double?
                var accumulatedText = ""
                var accumulatedReasoning = ""
                var reportedUsage: TokenUsage?
                var observedStreamToolCalls = false
                var lineBuffer = Data()

                func processLine(_ lineData: Data) async throws {
                    guard let line = String(data: lineData, encoding: .utf8) else {
                        if !workBuddy, let onStreamChunk { try await onStreamChunk(lineData + Data([0x0A])) }
                        return
                    }

                    let trimmed = line.trimmingCharacters(in: .newlines)
                    if trimmed.hasPrefix("data:") {
                        let payloadPart = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payloadPart == "[DONE]" {
                            if workBuddy {
                                workBuddyResponse.sawDone = true
                                return
                            }
                            if let onStreamChunk {
                                try await onStreamChunk(Data("data: [DONE]\n\n".utf8))
                            }
                            return
                        }

                        if let jsonData = payloadPart.data(using: .utf8),
                           var chunkObj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                            if workBuddy {
                                if let error = WorkBuddyProtocol.error(from: chunkObj, secrets: secrets) { throw error }
                                guard chunkObj["choices"] is [[String: Any]] || chunkObj["usage"] is [String: Any] else { return }
                                workBuddyResponse.append(chunkObj, collectResponse: !stream)
                                if stream && !forwardedWorkBuddyHeaders {
                                    try await onStreamHeadersReady?()
                                    forwardedWorkBuddyHeaders = true
                                }
                            }
                            // Ensure executed model is identifiable in chunk JSON
                            chunkObj["model"] = model.modelID

                            let (deltaContent, deltaReasoning) = extractStreamDeltaParts(from: chunkObj)
                            if let deltaContent, !deltaContent.isEmpty {
                                if firstTokenMs == nil {
                                    firstTokenMs = elapsedMs(since: startTime)
                                }
                                accumulatedText += deltaContent
                            }
                            if let deltaReasoning, !deltaReasoning.isEmpty {
                                if firstTokenMs == nil {
                                    firstTokenMs = elapsedMs(since: startTime)
                                }
                                accumulatedReasoning += deltaReasoning
                            }
                            if Self.streamChunkContainsToolCalls(chunkObj) {
                                observedStreamToolCalls = true
                            }
                            if firstTokenMs == nil, chunkObj["choices"] != nil, hasAnyChoiceDelta(chunkObj) {
                                firstTokenMs = elapsedMs(since: startTime)
                            }

                            if let chunkUsage = extractUsage(from: chunkObj) {
                                reportedUsage = chunkUsage
                            }

                            if let rewrittenData = try? JSONSerialization.data(withJSONObject: chunkObj, options: []),
                               let rewrittenStr = String(data: rewrittenData, encoding: .utf8) {
                                if stream, let onStreamChunk {
                                    try await onStreamChunk(Data("data: \(rewrittenStr)\n\n".utf8))
                                }
                                return
                            }
                        }

                        if !workBuddy, let onStreamChunk {
                            try await onStreamChunk(Data((trimmed + "\n\n").utf8))
                        }
                    } else if workBuddy {
                        if let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                           let error = WorkBuddyProtocol.error(from: object, secrets: secrets) { throw error }
                    } else if trimmed.isEmpty {
                        // Already emitted \n\n after data lines; ignore extra blank delimiters unless non-data SSE fields used
                    } else {
                        if let onStreamChunk {
                            try await onStreamChunk(Data((trimmed + "\n").utf8))
                        }
                    }
                }

                for try await byte in asyncBytes {
                    if byte == 0x0A { // '\n'
                        try await processLine(lineBuffer)
                        lineBuffer.removeAll(keepingCapacity: true)
                        if workBuddyResponse.sawDone { break }
                    } else if byte != 0x0D { // ignore '\r'
                        lineBuffer.append(byte)
                    }
                }
                if !lineBuffer.isEmpty {
                    try await processLine(lineBuffer)
                }

                var responseBody = Data()
                if workBuddy {
                    guard workBuddyResponse.isComplete else {
                        return .failure(.invalidResponse(message: "WorkBuddy 上游流未返回完整的聊天响应"))
                    }
                    if stream {
                        try await onStreamChunk?(Data("data: [DONE]\n\n".utf8))
                    } else {
                        responseBody = try workBuddyResponse.response(modelID: model.modelID)
                    }
                }

                let totalMs = elapsedMs(since: startTime)
                let finalUsage: TokenUsage?
                let usageSource: UsageDataSource
                let estimationNote: String?

                if let reportedUsage {
                    finalUsage = reportedUsage
                    usageSource = .upstreamReported
                    estimationNote = nil
                } else {
                    let textForEst = accumulatedText.isEmpty ? accumulatedReasoning : accumulatedText
                    let estOut = RequestFeatureExtractor.estimateTokens(text: textForEst, messageCount: 0)
                    finalUsage = TokenUsage(promptTokens: estimatedInputTokens, completionTokens: estOut)
                    usageSource = .estimatedWhenMissing
                    estimationNote = "上游流式响应未返回 usage 字段，按本地字符数 (~3.2 chars/token) 估算"
                }

                return .success(UpstreamCompletionResult(
                    statusCode: http.statusCode,
                    responseBody: responseBody,
                    assistantText: accumulatedText,
                    reasoningText: accumulatedReasoning.isEmpty ? nil : accumulatedReasoning,
                    usage: finalUsage,
                    usageSource: usageSource,
                    usageEstimationMethod: estimationNote,
                    firstTokenMs: firstTokenMs ?? totalMs,
                    totalLatencyMs: totalMs,
                    hasToolCalls: observedStreamToolCalls
                ))
            }
        } catch is ClientStreamDisconnectedError {
            return .failure(.clientDisconnected)
        } catch is CancellationError {
            return .failure(.clientDisconnected)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.clientDisconnected)
        } catch let error as UpstreamError {
            return .failure(error)
        } catch {
            let cleanMsg = SecretRedactor.redact(mapNetworkError(error), secrets: secrets)
            return .failure(.networkError(message: cleanMsg))
        }
    }

    // MARK: - Helpers

    static func parseRetryAfter(_ raw: String?, now: Date = Date()) -> Double? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let seconds = Double(value), seconds.isFinite else { return nil }
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private func classifyHTTPError(response: HTTPURLResponse, data: Data, secrets: [String]) -> UpstreamError {
        let statusCode = response.statusCode
        let retryAfter = statusCode == 429
            ? Self.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            : nil
        let msg = extractErrorMessage(from: data, secrets: secrets) ?? "HTTP \(statusCode)"
        let lower = msg.lowercased()
        if statusCode == 401 || statusCode == 403 {
            return .authError(statusCode: statusCode, message: msg)
        }
        if lower.contains("retired") || lower.contains("deprecated") || statusCode == 410 {
            return .modelUnavailable(statusCode: statusCode, message: msg, availability: .retired)
        }
        let hasBillingSignal = (statusCode != 429) && (lower.contains("credit") || lower.contains("balance") || lower.contains("subscribe") || lower.contains("billing"))
        let hasQuotaExhausted = (statusCode != 429) && (lower.contains("quota") || lower.contains("insufficient") || lower.contains("exhausted"))
        if statusCode == 402 || hasBillingSignal || hasQuotaExhausted {
            return .modelUnavailable(statusCode: statusCode, message: msg, availability: .insufficientCredits)
        }
        return .httpError(statusCode: statusCode, rawBody: data, message: msg, retryAfterSeconds: retryAfter)
    }

    private func classifyProbeFailure(_ err: UpstreamError, latencyMs: Double, isCodex: Bool = false) -> ModelProbeResult {
        switch err {
        case .modelUnavailable(_, let msg, let avail):
            return ModelProbeResult(
                isAvailable: false,
                availability: avail,
                latencyMs: latencyMs,
                note: "自动测活剔除 (\(avail.displayName)): \(msg)",
                isTransientFailure: false
            )
        case .authError(let code, let msg):
            let hint = isCodex
                ? "Codex 登录态失效或已过期 (\(code)): \(msg)"
                : "自动测活剔除 (鉴权失败 HTTP \(code)): \(msg)"
            return ModelProbeResult(
                isAvailable: false,
                availability: .unavailable,
                latencyMs: latencyMs,
                note: hint,
                isTransientFailure: false
            )
        case .httpError(let code, _, let msg, _):
            let isTransient = (code == 429 || code == 408 || code >= 500)
            let prefix = isTransient ? "测活瞬时限流/抖动" : "自动测活剔除"
            return ModelProbeResult(
                isAvailable: false,
                availability: .unavailable,
                latencyMs: latencyMs,
                note: "\(prefix) (HTTP \(code)): \(msg)",
                isTransientFailure: isTransient
            )
        case .networkError(let msg), .invalidResponse(let msg):
            return ModelProbeResult(
                isAvailable: false,
                availability: .unavailable,
                latencyMs: latencyMs,
                note: "测活瞬时网络/响应异常：\(msg)",
                isTransientFailure: true
            )
        case .clientDisconnected:
            return ModelProbeResult(
                isAvailable: false,
                availability: .unavailable,
                latencyMs: latencyMs,
                note: "测活时客户端已断开连接",
                isTransientFailure: true
            )
        case .requestDeadlineExceeded:
            return ModelProbeResult(
                isAvailable: false,
                availability: .unavailable,
                latencyMs: latencyMs,
                note: "测活达到累计 deadline",
                isTransientFailure: true
            )
        case .invalidURL(let url):
            return ModelProbeResult(
                isAvailable: false,
                availability: .unavailable,
                latencyMs: latencyMs,
                note: "自动测活剔除：无效的供应商 URL \(url)",
                isTransientFailure: false
            )
        }
    }

    private func classifyProbeNetworkError(_ error: Error, latencyMs: Double, secrets: [String]) -> ModelProbeResult {
        let cleanMsg = SecretRedactor.redact(mapNetworkError(error), secrets: secrets)
        return ModelProbeResult(
            isAvailable: false,
            availability: .unavailable,
            latencyMs: latencyMs,
            note: "测活瞬时网络异常：\(cleanMsg)",
            isTransientFailure: true
        )
    }

    // MARK: - Active Health Probing

    public func checkProviderReachability(
        provider: ProviderConfig,
        apiKey: String?,
        timeoutSeconds: Double = 3.0,
        secretsToRedact: [String] = []
    ) async -> ProviderReachabilityOutcome {
        if provider.apiProtocol == .workBuddy {
            let result = await fetchModels(provider: provider, apiKey: apiKey, timeoutSeconds: max(1.5, timeoutSeconds), secretsToRedact: secretsToRedact)
            switch result {
            case .success(let ids): return .reachable(discoveredModelIDs: ids)
            case .failure(let error):
                let health: ProviderHealthStatus
                switch error {
                case .authError: health = .authError
                case .networkError, .invalidURL: health = .networkError
                default: health = .serverError
                }
                return .unreachable(health, error.localizedDescription)
            }
        }
        guard let url = provider.endpointURL(path: "/v1/models") else {
            return .unreachable(.networkError, "无效的 Base URL: \(provider.baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = max(1.5, timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyProviderHeaders(to: &request, provider: provider)
        if provider.apiProtocol == .codexChatGPT {
            if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return .reachableNoModelList
            }
            return .unreachable(.authError, "Codex ~/.codex/auth.json 缺少有效的 access_token")
        }
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            if provider.apiProtocol == .anthropicMessages {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        do {
            let (data, response) = try await resolvedSession(for: provider).data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable(.networkError, "未收到有效 HTTP 响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                let msg = extractErrorMessage(from: data, secrets: secretsToRedact) ?? "HTTP \(http.statusCode)"
                return .unreachable(.authError, "鉴权失败 (HTTP \(http.statusCode)): \(msg)")
            }
            if (200...299).contains(http.statusCode) {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataList = obj["data"] as? [[String: Any]] {
                    let ids = dataList.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
                    return .reachable(discoveredModelIDs: ids)
                }
                return .reachableNoModelList
            }
            if http.statusCode == 404 {
                // Some relays omit /v1/models while serving /v1/chat/completions
                return .reachableNoModelList
            }
            let msg = extractErrorMessage(from: data, secrets: secretsToRedact) ?? "HTTP \(http.statusCode)"
            return .unreachable(.serverError, "上游 HTTP \(http.statusCode): \(msg)")
        } catch {
            let clean = SecretRedactor.redact(mapNetworkError(error), secrets: secretsToRedact)
            return .unreachable(.networkError, clean)
        }
    }

    public func probeModelHealth(
        provider: ProviderConfig,
        model: ModelConfig,
        apiKey: String?,
        timeoutSeconds: Double = 6.0,
        secretsToRedact: [String] = []
    ) async -> ModelProbeResult {
        switch provider.apiProtocol {
        case .codexChatGPT, .openAIResponses:
            return await probeResponsesModel(
                provider: provider,
                model: model,
                apiKey: apiKey,
                timeoutSeconds: timeoutSeconds,
                secretsToRedact: secretsToRedact
            )
        case .anthropicMessages:
            return await probeAnthropicModel(
                provider: provider,
                model: model,
                apiKey: apiKey,
                timeoutSeconds: timeoutSeconds,
                secretsToRedact: secretsToRedact
            )
        case .workBuddy:
            var probeProvider = provider
            probeProvider.timeoutSeconds = timeoutSeconds
            let start = DispatchTime.now()
            let result = await executeChatCompletion(
                provider: probeProvider,
                model: model,
                apiKey: apiKey,
                originalPayload: ["messages": [["role": "user", "content": "hi"]], "max_tokens": 2],
                estimatedInputTokens: 1,
                stream: false,
                secretsToRedact: secretsToRedact
            )
            let latencyMs = elapsedMs(since: start)
            switch result {
            case .success:
                return ModelProbeResult(isAvailable: true, availability: .available, latencyMs: latencyMs, note: "实测可用 (\(Int(latencyMs)) ms)")
            case .failure(let error):
                return classifyProbeFailure(error, latencyMs: latencyMs)
            }
        case .openAIChatCompletions:
            break
        }

        guard let url = provider.endpointURL(path: "/v1/chat/completions") else {
            return ModelProbeResult(isAvailable: false, availability: .unavailable, latencyMs: 0, note: "自动测活剔除：无效的供应商 URL")
        }

        let probePayload: [String: Any] = [
            "model": model.modelID,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 2,
            "stream": false
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: probePayload, options: []) else {
            return ModelProbeResult(isAvailable: false, availability: .unavailable, latencyMs: 0, note: "自动测活剔除：无法构造探测请求")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = max(2.0, timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyProviderHeaders(to: &request, provider: provider)
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let start = DispatchTime.now()
        do {
            let (data, response) = try await resolvedSession(for: provider).data(for: request)
            let latencyMs = elapsedMs(since: start)
            guard let http = response as? HTTPURLResponse else {
                return ModelProbeResult(isAvailable: false, availability: .unavailable, latencyMs: latencyMs, note: "自动测活剔除：上游未返回有效 HTTP 响应")
            }

            if (200...299).contains(http.statusCode) {
                return ModelProbeResult(
                    isAvailable: true,
                    availability: .available,
                    latencyMs: latencyMs,
                    note: "实测可用 (\(Int(latencyMs)) ms)"
                )
            }

            let err = classifyHTTPError(response: http, data: data, secrets: secretsToRedact)
            return classifyProbeFailure(err, latencyMs: latencyMs)
        } catch {
            let latencyMs = elapsedMs(since: start)
            return classifyProbeNetworkError(error, latencyMs: latencyMs, secrets: secretsToRedact)
        }
    }

    private func extractErrorMessage(from data: Data, secrets: [String]) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errDict = obj["error"] as? [String: Any], let msg = errDict["message"] as? String {
                return SecretRedactor.redact(msg, secrets: secrets)
            }
            if let msg = obj["message"] as? String {
                return SecretRedactor.redact(msg, secrets: secrets)
            }
            if let errStr = obj["error"] as? String {
                return SecretRedactor.redact(errStr, secrets: secrets)
            }
        }
        if let raw = String(data: data, encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SecretRedactor.redact(String(raw.prefix(400)), secrets: secrets)
        }
        return nil
    }

    private func mapNetworkError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "请求上游超时 (Timeout)"
            case .notConnectedToInternet, .networkConnectionLost:
                return "当前无网络连接，请检查网络设置"
            case .cannotConnectToHost, .cannotFindHost:
                return "无法连接到上游服务器，请检查 Base URL 与服务是否启动"
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    public static func extractAssistantAndReasoning(from json: [String: Any]) -> (content: String, reasoning: String?) {
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else {
            return ("", nil)
        }
        if let msg = first["message"] as? [String: Any] {
            let reasoning = (msg["reasoning_content"] as? String) ?? (msg["reasoning"] as? String)
            if let content = msg["content"] as? String, !content.isEmpty {
                return (content, reasoning?.isEmpty == false ? reasoning : nil)
            }
            if let toolCalls = msg["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                let names = toolCalls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                return ("[tool_calls: \(names.joined(separator: ", "))]", reasoning?.isEmpty == false ? reasoning : nil)
            }
            return ("", reasoning?.isEmpty == false ? reasoning : nil)
        }
        return ("", nil)
    }

    private func extractStreamDeltaParts(from json: [String: Any]) -> (content: String?, reasoning: String?) {
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else {
            return (nil, nil)
        }
        if let delta = first["delta"] as? [String: Any] {
            let content = delta["content"] as? String
            let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
            return (content, reasoning)
        }
        return (nil, nil)
    }

    private func hasAnyChoiceDelta(_ json: [String: Any]) -> Bool {
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else {
            return false
        }
        if let delta = first["delta"] as? [String: Any] {
            return delta["tool_calls"] != nil || delta["function_call"] != nil || delta["role"] != nil || delta["content"] != nil || delta["reasoning_content"] != nil
        }
        return false
    }

    private static func streamChunkContainsToolCalls(_ json: [String: Any]) -> Bool {
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else {
            return false
        }
        if let delta = first["delta"] as? [String: Any] {
            if let toolCalls = delta["tool_calls"] as? [Any], !toolCalls.isEmpty { return true }
            if delta["function_call"] != nil { return true }
        }
        if let finish = first["finish_reason"] as? String, finish == "tool_calls" {
            return true
        }
        return false
    }

    private static func responseContainsToolCalls(_ json: [String: Any]) -> Bool {
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first,
              let msg = first["message"] as? [String: Any] else {
            return false
        }
        if let toolCalls = msg["tool_calls"] as? [Any], !toolCalls.isEmpty { return true }
        return msg["function_call"] != nil
    }

    private static func injectReasoningEffortIfEligible(
        payload: [String: Any],
        model: ModelConfig,
        resolvedEffort: ReasoningEffort?,
        clientProvidedEffort: ReasoningEffort?
    ) -> [String: Any] {
        guard clientProvidedEffort == nil,
              let resolvedEffort,
              payload["reasoning_effort"] == nil,
              payload["reasoning"] == nil,
              model.capabilities.contains(.reasoning) || model.defaultRole == .complexReasoning else {
            return payload
        }
        var updated = payload
        updated["reasoning_effort"] = resolvedEffort.upstreamEffortValue
        return updated
    }

    private func extractUsage(from json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any] else {
            return nil
        }
        return TokenUsage.parse(from: usage)
    }

    private func elapsedMs(since start: DispatchTime) -> Double {
        let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000.0
    }

    // MARK: - Responses API & Codex ChatGPT OAuth Upstream

    private func buildResponsesRequest(
        provider: ProviderConfig,
        url: URL,
        bodyData: Data,
        apiKey: String?,
        timeout: Double,
        clientHeaders: [String: String] = [:]
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = max(2.0, timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyProviderHeaders(to: &request, provider: provider, clientHeaders: clientHeaders)
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if provider.apiProtocol == .codexChatGPT {
            if let acct = provider.accountID?.trimmingCharacters(in: .whitespacesAndNewlines), !acct.isEmpty {
                request.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
            request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        }
        return request
    }

    private func executeNativeResponsesCompletion(
        provider: ProviderConfig, model: ModelConfig, apiKey: String?, payload: [String: Any],
        estimatedInputTokens: Int, stream: Bool, clientHeaders: [String: String] = [:], resolvedEffort: ReasoningEffort?,
        clientProvidedEffort: ReasoningEffort?, secretsToRedact: [String],
        onStreamHeadersReady: (@Sendable () async throws -> Void)?,
        onStreamChunk: (@Sendable (Data) async throws -> Void)?
    ) async -> Result<UpstreamCompletionResult, UpstreamError> {
        let isCodex = provider.apiProtocol == .codexChatGPT
        guard let url = provider.endpointURL(path: isCodex ? "/responses" : "/v1/responses") else {
            return .failure(.invalidURL(provider.baseURL))
        }
        var body = payload
        body["model"] = model.modelID
        body["stream"] = isCodex || stream
        if isCodex {
            body["store"] = false
            if body["instructions"] == nil { body["instructions"] = "You are a helpful assistant." }
            for unsupportedKey in ["max_output_tokens", "max_tokens", "temperature", "top_p", "frequency_penalty", "presence_penalty"] {
                body.removeValue(forKey: unsupportedKey)
            }
        }
        if clientProvidedEffort == nil, let resolvedEffort,
           model.capabilities.contains(.reasoning) || model.defaultRole == .complexReasoning {
            if body["reasoning_effort"] == nil {
                if var reasoning = body["reasoning"] as? [String: Any] {
                    if reasoning["effort"] == nil { reasoning["effort"] = resolvedEffort.upstreamEffortValue }
                    body["reasoning"] = reasoning
                } else if body["reasoning"] == nil {
                    body["reasoning"] = ["effort": resolvedEffort.upstreamEffortValue]
                }
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.invalidResponse(message: "无法序列化 Responses 上游请求 JSON"))
        }
        let request = buildResponsesRequest(provider: provider, url: url, bodyData: data, apiKey: apiKey, timeout: provider.timeoutSeconds, clientHeaders: clientHeaders)
        let start = DispatchTime.now()
        do {
            let (bytes, response) = try await resolvedSession(for: provider).bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse(message: "上游未返回 HTTP 响应"))
            }
            guard (200...299).contains(http.statusCode) else {
                var error = Data()
                for try await byte in bytes { error.append(byte); if error.count > 65_536 { break } }
                return .failure(classifyHTTPError(response: http, data: error, secrets: secretsToRedact))
            }
            let isSSE = isCodex || stream || (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/event-stream")
            var observer = NativeResponsesObserver()
            var firstToken: Double?
            var responseBody = Data()
            if isSSE {
                if stream, let onStreamHeadersReady { try await onStreamHeadersReady() }
                var buffer = Data()
                for try await byte in bytes {
                    buffer.append(byte)
                    // Deliver batches promptly without rewriting the upstream bytes.
                    if byte == 10 || buffer.count >= 4096 {
                        if stream, let onStreamChunk { try await onStreamChunk(buffer) }
                        observer.append(buffer)
                        if firstToken == nil && observer.hasOutput { firstToken = elapsedMs(since: start) }
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty {
                    if stream, let onStreamChunk { try await onStreamChunk(buffer) }
                    observer.append(buffer)
                }
                if let error = observer.errorMessage {
                    return .failure(.httpError(statusCode: 502, rawBody: Data(), message: SecretRedactor.redact(error, secrets: secretsToRedact)))
                }
                guard let completed = observer.completedResponse else {
                    return .failure(.invalidResponse(message: "上游 Responses 流未完成"))
                }
                if !stream { responseBody = try JSONSerialization.data(withJSONObject: completed) }
            } else {
                for try await byte in bytes { responseBody.append(byte) }
                guard let object = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] else {
                    return .failure(.invalidResponse(message: "上游 Responses JSON 无效"))
                }
                if let status = object["status"] as? String, status == "failed" || status == "incomplete" {
                    return .failure(.invalidResponse(message: "上游 Responses 响应未完成: \(status)"))
                }
                observer.observeResponse(object)
            }
            let total = elapsedMs(since: start)
            let reported = observer.usage
            let usage = reported ?? TokenUsage(promptTokens: estimatedInputTokens, completionTokens: RequestFeatureExtractor.estimateTokens(text: observer.text.isEmpty ? observer.reasoning : observer.text, messageCount: 0))
            return .success(UpstreamCompletionResult(statusCode: http.statusCode, responseBody: responseBody,
                assistantText: observer.text, reasoningText: observer.reasoning.isEmpty ? nil : observer.reasoning,
                usage: usage, usageSource: reported == nil ? .estimatedWhenMissing : .upstreamReported,
                usageEstimationMethod: reported == nil ? "上游未返回 usage，按本地字符数估算" : nil,
                firstTokenMs: firstToken ?? total, totalLatencyMs: total, hasToolCalls: observer.hasToolCalls))
        } catch {
            return .failure(.networkError(message: SecretRedactor.redact(mapNetworkError(error), secrets: secretsToRedact)))
        }
    }

    private func executeResponsesCompletion(
        provider: ProviderConfig,
        model: ModelConfig,
        apiKey: String?,
        originalPayload: [String: Any],
        estimatedInputTokens: Int,
        callerRequestedStream: Bool,
        clientHeaders: [String: String] = [:],
        secretsToRedact: [String],
        onStreamHeadersReady: (@Sendable () async throws -> Void)?,
        onStreamChunk: (@Sendable (Data) async throws -> Void)?
    ) async -> Result<UpstreamCompletionResult, UpstreamError> {
        let path = (provider.apiProtocol == .codexChatGPT) ? "/responses" : "/v1/responses"
        guard let url = provider.endpointURL(path: path) else {
            return .failure(.invalidURL(provider.baseURL))
        }

        let isCodex = provider.apiProtocol == .codexChatGPT
        let upstreamPayload = ProtocolAdapters.chatToResponsesRequest(
            originalPayload,
            modelID: model.modelID,
            forceStream: isCodex || callerRequestedStream,
            store: isCodex ? false : nil,
            defaultInstructions: isCodex ? "You are a helpful assistant." : nil
        )
        guard let bodyData = try? JSONSerialization.data(withJSONObject: upstreamPayload, options: []) else {
            return .failure(.invalidResponse(message: "无法序列化 Responses 上游请求 JSON"))
        }

        let request = buildResponsesRequest(
            provider: provider,
            url: url,
            bodyData: bodyData,
            apiKey: apiKey,
            timeout: provider.timeoutSeconds,
            clientHeaders: clientHeaders
        )
        let startTime = DispatchTime.now()

        do {
            let (asyncBytes, response) = try await resolvedSession(for: provider).bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse(message: "上游未返回 HTTP 响应"))
            }
            if !(200...299).contains(http.statusCode) {
                var errorBytes = Data()
                for try await byte in asyncBytes {
                    errorBytes.append(byte)
                    if errorBytes.count > 65_536 { break }
                }
                return .failure(classifyHTTPError(response: http, data: errorBytes, secrets: secretsToRedact))
            }

            // Non-streaming /v1/responses may return plain JSON instead of SSE
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if !isCodex && !callerRequestedStream && !contentType.contains("text/event-stream") {
                var fullData = Data()
                for try await byte in asyncBytes { fullData.append(byte) }
                let totalMs = elapsedMs(since: startTime)
                let respObj = (try? JSONSerialization.jsonObject(with: fullData) as? [String: Any]) ?? [:]
                let chatObj = ProtocolAdapters.responsesJSONToChatCompletion(respObj, fallbackModel: model.modelID)
                let (assistantText, reasoningText) = Self.extractAssistantAndReasoning(from: chatObj)
                let reportedUsage = extractUsage(from: chatObj)
                let finalUsage = reportedUsage ?? TokenUsage(
                    promptTokens: estimatedInputTokens,
                    completionTokens: RequestFeatureExtractor.estimateTokens(text: assistantText, messageCount: 0)
                )
                let outData = (try? JSONSerialization.data(withJSONObject: chatObj, options: [])) ?? fullData
                return .success(UpstreamCompletionResult(
                    statusCode: http.statusCode,
                    responseBody: outData,
                    assistantText: assistantText,
                    reasoningText: reasoningText,
                    usage: finalUsage,
                    usageSource: reportedUsage != nil ? .upstreamReported : .estimatedWhenMissing,
                    usageEstimationMethod: reportedUsage == nil ? "上游未返回 usage，按本地字符数估算" : nil,
                    firstTokenMs: totalMs,
                    totalLatencyMs: totalMs,
                    hasToolCalls: Self.responseContainsToolCalls(chatObj)
                ))
            }

            if callerRequestedStream, let onStreamHeadersReady {
                try await onStreamHeadersReady()
            }

            let translator = ResponsesUpstreamStreamTranslator(modelName: model.modelID)
            var firstTokenMs: Double?
            var buffer = Data()

            for try await byte in asyncBytes {
                buffer.append(byte)
                if byte == 0x0A {
                    let chunks = translator.processSSEBytes(buffer)
                    buffer.removeAll(keepingCapacity: true)
                    if !chunks.isEmpty && firstTokenMs == nil {
                        firstTokenMs = elapsedMs(since: startTime)
                    }
                    if callerRequestedStream, let onStreamChunk {
                        for c in chunks { try await onStreamChunk(c) }
                    }
                }
            }
            if !buffer.isEmpty {
                let chunks = translator.processSSEBytes(buffer)
                if callerRequestedStream, let onStreamChunk {
                    for c in chunks { try await onStreamChunk(c) }
                }
            }
            if callerRequestedStream, let onStreamChunk {
                for c in translator.finishChunks() { try await onStreamChunk(c) }
            }

            if let errMsg = translator.errorMessage, translator.fullText.isEmpty {
                return .failure(.httpError(statusCode: 502, rawBody: Data(), message: SecretRedactor.redact(errMsg, secrets: secretsToRedact)))
            }

            let totalMs = elapsedMs(since: startTime)
            let reportedUsage = translator.usage
            let finalUsage = reportedUsage ?? TokenUsage(
                promptTokens: estimatedInputTokens,
                completionTokens: RequestFeatureExtractor.estimateTokens(text: translator.fullText, messageCount: 0)
            )

            var responseBody = Data()
            if !callerRequestedStream {
                var chatObj: [String: Any]
                if let respObj = translator.completedResponseObject {
                    chatObj = ProtocolAdapters.responsesJSONToChatCompletion(respObj, fallbackModel: model.modelID)
                    if var choices = chatObj["choices"] as? [[String: Any]], !choices.isEmpty,
                       var msg = choices[0]["message"] as? [String: Any] {
                        if ((msg["content"] as? String) ?? "").isEmpty && !translator.fullText.isEmpty {
                            msg["content"] = translator.fullText
                        }
                        if ((msg["reasoning_content"] as? String) ?? "").isEmpty && !translator.fullReasoning.isEmpty {
                            msg["reasoning_content"] = translator.fullReasoning
                        }
                        choices[0]["message"] = msg
                        chatObj["choices"] = choices
                    }
                } else {
                    var msg: [String: Any] = ["role": "assistant", "content": translator.fullText]
                    if !translator.fullReasoning.isEmpty { msg["reasoning_content"] = translator.fullReasoning }
                    chatObj = [
                        "id": "chatcmpl-\(UUID().uuidString.prefix(12))",
                        "object": "chat.completion",
                        "created": Int(Date().timeIntervalSince1970),
                        "model": model.modelID,
                        "choices": [["index": 0, "message": msg, "finish_reason": "stop"]],
                        "usage": [
                            "prompt_tokens": finalUsage.promptTokens,
                            "completion_tokens": finalUsage.completionTokens,
                            "total_tokens": finalUsage.totalTokens
                        ]
                    ]
                }
                responseBody = (try? JSONSerialization.data(withJSONObject: chatObj, options: [])) ?? Data()
            }

            return .success(UpstreamCompletionResult(
                statusCode: http.statusCode,
                responseBody: responseBody,
                assistantText: translator.fullText,
                reasoningText: translator.fullReasoning.isEmpty ? nil : translator.fullReasoning,
                usage: finalUsage,
                usageSource: reportedUsage != nil ? .upstreamReported : .estimatedWhenMissing,
                usageEstimationMethod: reportedUsage == nil ? "上游未返回 usage，按本地字符数估算" : nil,
                firstTokenMs: firstTokenMs ?? totalMs,
                totalLatencyMs: totalMs,
                hasToolCalls: translator.hasToolCalls
            ))
        } catch is ClientStreamDisconnectedError {
            return .failure(.clientDisconnected)
        } catch is CancellationError {
            return .failure(.clientDisconnected)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.clientDisconnected)
        } catch {
            let cleanMsg = SecretRedactor.redact(mapNetworkError(error), secrets: secretsToRedact)
            return .failure(.networkError(message: cleanMsg))
        }
    }

    private func probeResponsesModel(
        provider: ProviderConfig,
        model: ModelConfig,
        apiKey: String?,
        timeoutSeconds: Double,
        secretsToRedact: [String]
    ) async -> ModelProbeResult {
        let path = (provider.apiProtocol == .codexChatGPT) ? "/responses" : "/v1/responses"
        guard let url = provider.endpointURL(path: path) else {
            return ModelProbeResult(isAvailable: false, availability: .unavailable, latencyMs: 0, note: "自动测活剔除：无效的供应商 URL")
        }

        let isCodex = provider.apiProtocol == .codexChatGPT
        let probePayload: [String: Any] = [
            "model": model.modelID,
            "instructions": "You are a helpful assistant.",
            "input": [[
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "hi"]]
            ]],
            "store": false,
            "stream": true
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: probePayload, options: []) else {
            return ModelProbeResult(isAvailable: false, availability: .unavailable, latencyMs: 0, note: "自动测活剔除：无法构造探测请求")
        }

        let request = buildResponsesRequest(
            provider: provider,
            url: url,
            bodyData: bodyData,
            apiKey: apiKey,
            timeout: max(4.0, timeoutSeconds)
        )
        let start = DispatchTime.now()
        do {
            let (asyncBytes, response) = try await resolvedSession(for: provider).bytes(for: request)
            let latencyMs = elapsedMs(since: start)
            guard let http = response as? HTTPURLResponse else {
                return ModelProbeResult(isAvailable: false, availability: .unavailable, latencyMs: latencyMs, note: "自动测活剔除：上游未返回有效 HTTP 响应")
            }

            if (200...299).contains(http.statusCode) {
                var sample = Data()
                for try await byte in asyncBytes {
                    sample.append(byte)
                    if sample.count >= 512 { break }
                }
                let text = String(data: sample, encoding: .utf8) ?? ""
                if text.contains("response.failed") || text.contains("\"error\"") {
                    let msg = extractErrorMessage(from: sample, secrets: secretsToRedact) ?? "model probe failed"
                    return ModelProbeResult(isAvailable: false, availability: .unavailable, latencyMs: latencyMs, note: "自动测活剔除：\(msg)")
                }
                return ModelProbeResult(
                    isAvailable: true,
                    availability: .available,
                    latencyMs: latencyMs,
                    note: isCodex ? "Codex 订阅实测可用 (\(Int(latencyMs)) ms)" : "实测可用 (\(Int(latencyMs)) ms)"
                )
            }

            var errData = Data()
            for try await byte in asyncBytes {
                errData.append(byte)
                if errData.count > 16_384 { break }
            }
            let err = classifyHTTPError(response: http, data: errData, secrets: secretsToRedact)
            return classifyProbeFailure(err, latencyMs: latencyMs, isCodex: isCodex)
        } catch {
            let latencyMs = elapsedMs(since: start)
            return classifyProbeNetworkError(error, latencyMs: latencyMs, secrets: secretsToRedact)
        }
    }

    // MARK: - Anthropic Messages Upstream

    private func executeNativeAnthropicCompletion(
        provider: ProviderConfig,
        model: ModelConfig,
        apiKey: String?,
        payload: [String: Any],
        passthroughHeaders: [String: String],
        clientHeaders: [String: String] = [:],
        estimatedInputTokens: Int,
        stream: Bool,
        secretsToRedact: [String],
        onStreamHeadersReady: (@Sendable () async throws -> Void)?,
        onStreamChunk: (@Sendable (Data) async throws -> Void)?
    ) async -> Result<UpstreamCompletionResult, UpstreamError> {
        guard let url = provider.endpointURL(path: "/v1/messages") else {
            return .failure(.invalidURL(provider.baseURL))
        }
        var body = payload
        body["model"] = model.modelID
        body["stream"] = stream
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            return .failure(.invalidResponse(message: "无法序列化原生 Anthropic 上游请求 JSON"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = max(5.0, provider.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(passthroughHeaders["anthropic-version"] ?? "2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let beta = passthroughHeaders["anthropic-beta"], !beta.isEmpty {
            request.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        }
        applyProviderHeaders(to: &request, provider: provider, clientHeaders: clientHeaders)
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }

        let startTime = DispatchTime.now()
        do {
            let (bytes, response) = try await resolvedSession(for: provider).bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse(message: "上游未返回 HTTP 响应"))
            }
            guard (200...299).contains(http.statusCode) else {
                var errData = Data()
                for try await byte in bytes {
                    errData.append(byte)
                    if errData.count > 65_536 { break }
                }
                return .failure(classifyHTTPError(response: http, data: errData, secrets: secretsToRedact))
            }

            let isSSE = stream || (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/event-stream")
            var observer = NativeAnthropicObserver()
            var firstTokenMs: Double?
            var responseBody = Data()

            if isSSE {
                if stream, let onStreamHeadersReady {
                    try await onStreamHeadersReady()
                }
                var buffer = Data()
                for try await byte in bytes {
                    buffer.append(byte)
                    if byte == 10 || buffer.count >= 4096 {
                        if stream, let onStreamChunk {
                            try await onStreamChunk(buffer)
                        }
                        observer.append(buffer)
                        if firstTokenMs == nil && observer.hasOutput {
                            firstTokenMs = elapsedMs(since: startTime)
                        }
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty {
                    if stream, let onStreamChunk {
                        try await onStreamChunk(buffer)
                    }
                    observer.append(buffer)
                }
                if let err = observer.errorMessage {
                    return .failure(.httpError(statusCode: 502, rawBody: Data(), message: SecretRedactor.redact(err, secrets: secretsToRedact)))
                }
            } else {
                for try await byte in bytes {
                    responseBody.append(byte)
                }
                guard let obj = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] else {
                    return .failure(.invalidResponse(message: "上游 Anthropic JSON 无效"))
                }
                observer.observeResponse(obj)
            }

            let totalMs = elapsedMs(since: startTime)
            let reported = observer.usage
            let finalUsage = reported ?? TokenUsage(
                promptTokens: estimatedInputTokens,
                completionTokens: RequestFeatureExtractor.estimateTokens(
                    text: observer.text.isEmpty ? observer.reasoning : observer.text,
                    messageCount: 0
                )
            )
            return .success(UpstreamCompletionResult(
                statusCode: http.statusCode,
                responseBody: responseBody,
                assistantText: observer.text,
                reasoningText: observer.reasoning.isEmpty ? nil : observer.reasoning,
                usage: finalUsage,
                usageSource: reported != nil ? .upstreamReported : .estimatedWhenMissing,
                usageEstimationMethod: reported == nil ? "上游未返回 usage，按本地字符数估算" : nil,
                firstTokenMs: firstTokenMs ?? totalMs,
                totalLatencyMs: totalMs,
                hasToolCalls: observer.hasToolCalls
            ))
        } catch is ClientStreamDisconnectedError {
            return .failure(.clientDisconnected)
        } catch is CancellationError {
            return .failure(.clientDisconnected)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.clientDisconnected)
        } catch {
            let cleanMsg = SecretRedactor.redact(mapNetworkError(error), secrets: secretsToRedact)
            return .failure(.networkError(message: cleanMsg))
        }
    }

    private func executeAnthropicCompletion(
        provider: ProviderConfig,
        model: ModelConfig,
        apiKey: String?,
        originalPayload: [String: Any],
        estimatedInputTokens: Int,
        stream: Bool,
        clientHeaders: [String: String] = [:],
        secretsToRedact: [String],
        onStreamHeadersReady: (@Sendable () async throws -> Void)?,
        onStreamChunk: (@Sendable (Data) async throws -> Void)?
    ) async -> Result<UpstreamCompletionResult, UpstreamError> {
        guard let url = provider.endpointURL(path: "/v1/messages") else {
            return .failure(.invalidURL(provider.baseURL))
        }
        let chatEffort = (originalPayload["reasoning_effort"] as? String).flatMap(ReasoningEffort.init(rawValue:))
        let upstreamPayload = NativeAnthropicRouting.applyingInitialEffort(
            to: ProtocolAdapters.chatToAnthropicRequest(originalPayload, modelID: model.modelID, stream: false),
            modelID: model.modelID,
            effort: chatEffort
        )
        guard let bodyData = try? JSONSerialization.data(withJSONObject: upstreamPayload, options: []) else {
            return .failure(.invalidResponse(message: "无法序列化 Anthropic 上游请求"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = max(5.0, provider.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyProviderHeaders(to: &request, provider: provider, clientHeaders: clientHeaders)
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }

        let startTime = DispatchTime.now()
        do {
            let (data, response) = try await resolvedSession(for: provider).data(for: request)
            let totalMs = elapsedMs(since: startTime)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse(message: "上游未返回 HTTP 响应"))
            }
            if !(200...299).contains(http.statusCode) {
                return .failure(classifyHTTPError(response: http, data: data, secrets: secretsToRedact))
            }

            let rawObj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let chatObj = ProtocolAdapters.anthropicJSONToChatCompletion(rawObj, fallbackModel: model.modelID)
            let (assistantText, reasoningText) = Self.extractAssistantAndReasoning(from: chatObj)
            let reportedUsage = extractUsage(from: rawObj) ?? extractUsage(from: chatObj)
            let finalUsage = reportedUsage ?? TokenUsage(
                promptTokens: estimatedInputTokens,
                completionTokens: RequestFeatureExtractor.estimateTokens(text: assistantText, messageCount: 0)
            )
            let outData = (try? JSONSerialization.data(withJSONObject: chatObj, options: [])) ?? data

            if stream, let onStreamHeadersReady, let onStreamChunk {
                try await onStreamHeadersReady()
                let chunkObj: [String: Any] = [
                    "id": chatObj["id"] ?? "chatcmpl-\(UUID().uuidString.prefix(8))",
                    "object": "chat.completion.chunk",
                    "created": Int(Date().timeIntervalSince1970),
                    "model": model.modelID,
                    "choices": [[
                        "index": 0,
                        "delta": ["role": "assistant", "content": assistantText],
                        "finish_reason": "stop"
                    ]],
                    "usage": [
                        "prompt_tokens": finalUsage.promptTokens,
                        "completion_tokens": finalUsage.completionTokens,
                        "total_tokens": finalUsage.totalTokens
                    ]
                ]
                if let cData = try? JSONSerialization.data(withJSONObject: chunkObj, options: []),
                   let cStr = String(data: cData, encoding: .utf8) {
                    try await onStreamChunk(Data("data: \(cStr)\n\n".utf8))
                }
                try await onStreamChunk(Data("data: [DONE]\n\n".utf8))
            }

            return .success(UpstreamCompletionResult(
                statusCode: http.statusCode,
                responseBody: outData,
                assistantText: assistantText,
                reasoningText: reasoningText,
                usage: finalUsage,
                usageSource: reportedUsage != nil ? .upstreamReported : .estimatedWhenMissing,
                usageEstimationMethod: reportedUsage == nil ? "上游未返回 usage，按本地字符数估算" : nil,
                firstTokenMs: totalMs,
                totalLatencyMs: totalMs,
                hasToolCalls: Self.responseContainsToolCalls(chatObj)
            ))
        } catch is ClientStreamDisconnectedError {
            return .failure(.clientDisconnected)
        } catch is CancellationError {
            return .failure(.clientDisconnected)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.clientDisconnected)
        } catch {
            let cleanMsg = SecretRedactor.redact(mapNetworkError(error), secrets: secretsToRedact)
            return .failure(.networkError(message: cleanMsg))
        }
    }

    private func probeAnthropicModel(
        provider: ProviderConfig,
        model: ModelConfig,
        apiKey: String?,
        timeoutSeconds: Double,
        secretsToRedact: [String]
    ) async -> ModelProbeResult {
        guard let url = provider.endpointURL(path: "/v1/messages") else {
            return ModelProbeResult(isAvailable: false, availability: .unavailable, latencyMs: 0, note: "自动测活剔除：无效的供应商 URL")
        }
        let payload: [String: Any] = [
            "model": model.modelID,
            "max_tokens": 2,
            "messages": [["role": "user", "content": "hi"]]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return ModelProbeResult(isAvailable: false, availability: .unavailable, latencyMs: 0, note: "自动测活剔除：无法构造探测请求")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = max(2.0, timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyProviderHeaders(to: &request, provider: provider)
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        let start = DispatchTime.now()
        do {
            let (data, response) = try await resolvedSession(for: provider).data(for: request)
            let latencyMs = elapsedMs(since: start)
            guard let http = response as? HTTPURLResponse else {
                return ModelProbeResult(isAvailable: false, availability: .unavailable, latencyMs: latencyMs, note: "自动测活剔除：上游未返回有效 HTTP 响应")
            }
            if (200...299).contains(http.statusCode) {
                return ModelProbeResult(isAvailable: true, availability: .available, latencyMs: latencyMs, note: "实测可用 (\(Int(latencyMs)) ms)")
            }
            let err = classifyHTTPError(response: http, data: data, secrets: secretsToRedact)
            return classifyProbeFailure(err, latencyMs: latencyMs)
        } catch {
            let latencyMs = elapsedMs(since: start)
            return classifyProbeNetworkError(error, latencyMs: latencyMs, secrets: secretsToRedact)
        }
    }
}
