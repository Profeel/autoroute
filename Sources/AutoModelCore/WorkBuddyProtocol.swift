import Foundation

// WorkBuddy uses a separate product catalog and a streaming Chat Completions endpoint.
enum WorkBuddyProtocol {
    static let configPath = "/v3/config"
    static let chatPath = "/v2/chat/completions"
    static let redirectPolicy = RedirectPolicy()

    final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            let original = task.originalRequest?.url
            let destination = request.url
            let sameOrigin = original?.scheme == destination?.scheme && original?.host == destination?.host
                && original?.port == destination?.port
            completionHandler(sameOrigin ? request : nil)
        }
    }

    static func applyHeaders(to request: inout URLRequest, key: String) {
        let international = request.url?.host?.lowercased() == "www.workbuddy.ai"
        let appName = international ? "workbuddy-ai" : "WorkBuddy"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.setValue("anonymous_\(key.suffix(8))", forHTTPHeaderField: "X-User-Id")
        request.setValue(nil, forHTTPHeaderField: "X-Domain")
        request.setValue("SaaS", forHTTPHeaderField: "X-Product")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("WorkBuddy/5.9.3 \(appName)/5.9.3 CLI/2.165.0", forHTTPHeaderField: "User-Agent")
    }

    static func secretValues(for key: String) -> [String] {
        [key, "anonymous_\(key.suffix(8))"]
    }

    static func missingKeyError() -> UpstreamError {
        .authError(statusCode: 401, message: "请在 WorkBuddy 的 API Keys 页面创建并配置此版本的 API Key。")
    }

    static func modelIDs(from config: [String: Any]) -> [String]? {
        guard let data = config["data"] as? [String: Any],
              let agents = data["agents"] as? [[String: Any]],
              let cli = agents.first(where: { $0["name"] as? String == "cli" }),
              let cliIDs = cli["models"] as? [String] else { return nil }
        let enterpriseIDs = (data["models"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }
            .filter { $0.hasPrefix("custom:") }
        let reserved: Set<String> = ["auto", "auto/auto", "workbuddy/auto", "workbuddy-ai/auto"]
        var seen = Set<String>()
        return (cliIDs + enterpriseIDs).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !reserved.contains($0.lowercased()) && seen.insert($0).inserted
        }
    }

    static func chatPayload(from payload: [String: Any]) -> [String: Any] {
        var result = payload
        if let limit = result.removeValue(forKey: "max_completion_tokens"), result["max_tokens"] == nil {
            result["max_tokens"] = limit
        }
        if let messages = result["messages"] as? [[String: Any]], !messages.isEmpty {
            var normalizedMessages = messages.map { original in
                var message = original
                if message["role"] as? String == "developer" { message["role"] = "system" }
                if message["role"] as? String == "assistant",
                   let reasoning = message.removeValue(forKey: "reasoning_content"), message["reasoning"] == nil {
                    message["reasoning"] = reasoning
                }
                return message
            }
            if normalizedMessages.first?["role"] as? String != "system" {
                normalizedMessages.insert(["role": "system", "content": "You are a helpful assistant."], at: 0)
            }
            result["messages"] = normalizedMessages
        }
        if let choice = result["tool_choice"] as? [String: Any] {
            if choice["type"] as? String == "function" {
                result["tool_choice"] = (choice["function"] as? [String: Any])?["name"] as? String ?? "auto"
            } else {
                result["tool_choice"] = choice["type"] as? String
            }
        }
        if (result["tool_choice"] as? String)?.lowercased() == "none" {
            result.removeValue(forKey: "tool_choice")
            result.removeValue(forKey: "tools")
            result.removeValue(forKey: "functions")
        }
        return result
    }

    static func error(from object: [String: Any], secrets: [String]) -> UpstreamError? {
        let code = object["code"] as? Int ?? (object["code"] as? String).flatMap(Int.init)
        let nested = object["error"] as? [String: Any]
        let hasError = object["error"].map { !($0 is NSNull) } ?? false
        guard hasError || code.map({ $0 != 0 }) == true else { return nil }
        let message = (nested?["message"] as? String) ?? (object["error"] as? String)
            ?? (object["msg"] as? String) ?? (object["message"] as? String) ?? "WorkBuddy 返回错误"
        let cleanMessage = SecretRedactor.redact(message, secrets: secrets)
        let status = (nested?["status"] as? Int) ?? (nested?["code"] as? Int) ?? code ?? 502
        if status == 401 || status == 403 {
            return .authError(statusCode: status, message: cleanMessage)
        }
        return .httpError(statusCode: (400...599).contains(status) ? status : 502, rawBody: Data(), message: cleanMessage)
    }
}

/// Builds a regular Chat Completions response for callers that requested JSON.
struct WorkBuddyChatStream {
    private struct Choice {
        var message: [String: Any] = ["role": "assistant"]
        var tools: [Int: [String: Any]] = [:]
        var finishReason: String?

        mutating func append(_ choice: [String: Any]) {
            let delta = choice["delta"] as? [String: Any] ?? [:]
            for field in ["content", "refusal"] {
                if let text = delta[field] as? String { message[field] = (message[field] as? String ?? "") + text }
            }
            if let text = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) {
                message["reasoning_content"] = (message["reasoning_content"] as? String ?? "") + text
            }
            if let parts = delta["tool_calls"] as? [[String: Any]] {
                for (offset, part) in parts.enumerated() {
                    let index = part["index"] as? Int ?? offset
                    var call = tools[index] ?? ["type": "function"]
                    if let id = part["id"] as? String, !id.isEmpty { call["id"] = id }
                    call["function"] = mergedFunction(call["function"], part["function"])
                    tools[index] = call
                }
            }
            if let function = delta["function_call"] as? [String: Any] {
                message["function_call"] = mergedFunction(message["function_call"], function)
            }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
        }

        private func mergedFunction(_ current: Any?, _ delta: Any?) -> [String: String] {
            var function = current as? [String: String] ?? ["arguments": ""]
            if let parts = delta as? [String: Any] {
                if let name = parts["name"] as? String, !name.isEmpty { function["name"] = name }
                if let args = parts["arguments"] as? String { function["arguments", default: ""] += args }
            }
            return function
        }

        func json(index: Int) -> [String: Any] {
            var completed = message
            if completed["content"] == nil { completed["content"] = NSNull() }
            if !tools.isEmpty { completed["tool_calls"] = tools.keys.sorted().compactMap { tools[$0] } }
            let hasTools = !tools.isEmpty || completed["function_call"] != nil
            return ["index": index, "message": completed, "finish_reason": finishReason ?? (hasTools ? "tool_calls" : "stop")]
        }
    }

    private var choices: [Int: Choice] = [:]
    private var id: String?
    private var created: Int?
    private var usage: [String: Any]?
    var sawDone = false

    var isComplete: Bool {
        !choices.isEmpty && (sawDone || choices.values.allSatisfy { $0.finishReason != nil })
    }

    mutating func append(_ chunk: [String: Any], collectResponse: Bool) {
        if collectResponse {
            id = id ?? (chunk["id"] as? String)
            created = created ?? (chunk["created"] as? Int)
            if let reported = chunk["usage"] as? [String: Any] { usage = reported }
        }
        for (offset, choice) in (chunk["choices"] as? [[String: Any]] ?? []).enumerated() {
            let index = choice["index"] as? Int ?? offset
            if collectResponse {
                choices[index, default: Choice()].append(choice)
            } else {
                var state = choices[index] ?? Choice()
                state.finishReason = (choice["finish_reason"] as? String) ?? state.finishReason
                choices[index] = state
            }
        }
    }

    func response(modelID: String) throws -> Data {
        var object: [String: Any] = [
            "id": id ?? "chatcmpl-\(UUID().uuidString)",
            "created": created ?? Int(Date().timeIntervalSince1970),
            "object": "chat.completion",
            "model": modelID,
            "choices": choices.keys.sorted().compactMap { choices[$0]?.json(index: $0) }
        ]
        if let usage { object["usage"] = usage }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
