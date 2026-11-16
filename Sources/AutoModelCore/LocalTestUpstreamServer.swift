import Foundation

/// Optional local loopback OpenAI-compatible test upstream (`127.0.0.1`) used for
/// automated integration tests and offline routing/streaming/error simulation.
public final class LocalTestUpstreamServer: @unchecked Sendable {
    public struct BehaviorConfig: Sendable {
        public var requiredAPIKey: String?
        public var failModelsWithStatus: [String: (status: Int, message: String)] = [:]
        public var omitUsageForModels: Set<String> = []
        public var artificialChunkDelayMs: Int = 15

        public init(
            requiredAPIKey: String? = nil,
            failModelsWithStatus: [String: (status: Int, message: String)] = [:],
            omitUsageForModels: Set<String> = [],
            artificialChunkDelayMs: Int = 15
        ) {
            self.requiredAPIKey = requiredAPIKey
            self.failModelsWithStatus = failModelsWithStatus
            self.omitUsageForModels = omitUsageForModels
            self.artificialChunkDelayMs = artificialChunkDelayMs
        }
    }

    private let behaviorLock = NSLock()
    private var behavior: BehaviorConfig
    private var server: LoopbackHTTPServer?

    public init(behavior: BehaviorConfig = BehaviorConfig()) {
        self.behavior = behavior
    }

    public var isRunning: Bool {
        server?.isRunning ?? false
    }

    public var port: Int? {
        server?.currentPort
    }

    public var baseURLString: String? {
        guard let port else { return nil }
        return "http://127.0.0.1:\(port)"
    }

    public func updateBehavior(_ newBehavior: BehaviorConfig) {
        behaviorLock.withLock {
            self.behavior = newBehavior
        }
    }

    @discardableResult
    public func start(port: Int = 0) throws -> Int {
        let httpServer = LoopbackHTTPServer { [weak self] req, writer in
            guard let self else {
                writer.close()
                return
            }
            await self.handle(req: req, writer: writer)
        }
        let actualPort = try httpServer.start(port: port)
        self.server = httpServer
        return actualPort
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    private func handle(req: HTTPRequestMessage, writer: HTTPConnectionWriter) async {
        let currentBehavior = behaviorLock.withLock { self.behavior }

        if let expectedKey = currentBehavior.requiredAPIKey, !expectedKey.isEmpty {
            let auth = req.header("Authorization") ?? ""
            if auth != "Bearer \(expectedKey)" {
                sendError(writer: writer, status: 401, message: "Invalid API key provided.")
                return
            }
        }

        if req.method == "GET" && (req.path == "/v1/models" || req.path == "/models") {
            let payload: [String: Any] = [
                "object": "list",
                "data": [
                    ["id": "mock-fast-mini", "object": "model", "owned_by": "local-test"],
                    ["id": "mock-coder-pro", "object": "model", "owned_by": "local-test"],
                    ["id": "mock-vision-max", "object": "model", "owned_by": "local-test"]
                ]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                writer.sendJSON(statusCode: 200, body: data)
            } else {
                writer.close()
            }
            return
        }

        if req.method == "POST" && (req.path == "/v1/chat/completions" || req.path == "/chat/completions") {
            guard let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let model = json["model"] as? String else {
                sendError(writer: writer, status: 400, message: "Missing model or invalid JSON body")
                return
            }

            if let forcedFailure = currentBehavior.failModelsWithStatus[model] {
                sendError(writer: writer, status: forcedFailure.status, message: forcedFailure.message)
                return
            }

            let stream = (json["stream"] as? Bool) ?? false
            let messages = json["messages"] as? [[String: Any]] ?? []
            let lastUserText = extractLastUserText(messages)
            let promptTokens = max(8, lastUserText.count / 3 + messages.count * 5)
            let replyText = "[\(model)] 已收到请求：\(lastUserText.prefix(80))"
            let completionTokens = max(6, replyText.count / 3)
            let omitUsage = currentBehavior.omitUsageForModels.contains(model)

            if !stream {
                var resp: [String: Any] = [
                    "id": "chatcmpl-\(UUID().uuidString.prefix(8))",
                    "object": "chat.completion",
                    "created": Int(Date().timeIntervalSince1970),
                    "model": model,
                    "choices": [
                        [
                            "index": 0,
                            "message": [
                                "role": "assistant",
                                "content": replyText
                            ],
                            "finish_reason": "stop"
                        ]
                    ]
                ]
                if !omitUsage {
                    resp["usage"] = [
                        "prompt_tokens": promptTokens,
                        "completion_tokens": completionTokens,
                        "total_tokens": promptTokens + completionTokens
                    ]
                }
                if let data = try? JSONSerialization.data(withJSONObject: resp) {
                    writer.sendJSON(statusCode: 200, body: data)
                } else {
                    writer.close()
                }
                return
            } else {
                writer.startChunkedStream(statusCode: 200)
                let id = "chatcmpl-\(UUID().uuidString.prefix(8))"
                let created = Int(Date().timeIntervalSince1970)
                let pieces = splitIntoChunks(replyText, chunkSize: 10)
                let delayNs = UInt64(max(0, currentBehavior.artificialChunkDelayMs)) * 1_000_000

                for (index, piece) in pieces.enumerated() {
                    if delayNs > 0 {
                        try? await Task.sleep(nanoseconds: delayNs)
                    }
                    var delta: [String: Any] = ["content": piece]
                    if index == 0 { delta["role"] = "assistant" }
                    let chunkObj: [String: Any] = [
                        "id": id,
                        "object": "chat.completion.chunk",
                        "created": created,
                        "model": model,
                        "choices": [
                            [
                                "index": 0,
                                "delta": delta,
                                "finish_reason": NSNull()
                            ]
                        ]
                    ]
                    if let chunkData = try? JSONSerialization.data(withJSONObject: chunkObj),
                       let chunkStr = String(data: chunkData, encoding: .utf8) {
                        _ = writer.writeStreamChunk(Data("data: \(chunkStr)\n\n".utf8))
                    }
                }

                var finalChunk: [String: Any] = [
                    "id": id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [
                        [
                            "index": 0,
                            "delta": [:],
                            "finish_reason": "stop"
                        ]
                    ]
                ]
                if !omitUsage {
                    finalChunk["usage"] = [
                        "prompt_tokens": promptTokens,
                        "completion_tokens": completionTokens,
                        "total_tokens": promptTokens + completionTokens
                    ]
                }
                if let finalData = try? JSONSerialization.data(withJSONObject: finalChunk),
                   let finalStr = String(data: finalData, encoding: .utf8) {
                    _ = writer.writeStreamChunk(Data("data: \(finalStr)\n\n".utf8))
                }
                _ = writer.writeStreamChunk(Data("data: [DONE]\n\n".utf8))
                writer.finishStream()
                return
            }
        }

        sendError(writer: writer, status: 404, message: "Not found")
    }

    private func sendError(writer: HTTPConnectionWriter, status: Int, message: String) {
        let obj: [String: Any] = [
            "error": [
                "message": message,
                "type": status == 401 ? "authentication_error" : "api_error",
                "code": status == 401 ? "invalid_api_key" : "upstream_error"
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        writer.sendJSON(statusCode: status, body: data)
    }

    private func extractLastUserText(_ messages: [[String: Any]]) -> String {
        for msg in messages.reversed() {
            if let str = msg["content"] as? String, !str.isEmpty {
                return str
            }
            if let arr = msg["content"] as? [[String: Any]] {
                let text = arr.compactMap { $0["text"] as? String }.joined(separator: " ")
                if !text.isEmpty { return text }
            }
        }
        return "hello"
    }

    private func splitIntoChunks(_ text: String, chunkSize: Int) -> [String] {
        guard !text.isEmpty else { return [""] }
        var result: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let next = text.index(idx, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[idx..<next]))
            idx = next
        }
        return result
    }
}
