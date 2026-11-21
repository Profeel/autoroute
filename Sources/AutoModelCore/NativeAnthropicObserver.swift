import Foundation

/// Helpers for native Anthropic `/v1/messages` passthrough routing.
public enum NativeAnthropicRouting {
    /// Returns true if the request uses Anthropic-native features (`cache_control`, `thinking`,
    /// or Anthropic built-in tool types) that benefit from direct passthrough without OpenAI translation.
    public static func hasNativeFeatures(_ payload: [String: Any]) -> Bool {
        if payload["thinking"] != nil { return true }
        if let systemBlocks = payload["system"] as? [[String: Any]],
           systemBlocks.contains(where: { $0["cache_control"] != nil }) {
            return true
        }
        if let tools = payload["tools"] as? [[String: Any]] {
            for tool in tools {
                if tool["cache_control"] != nil { return true }
                if let type = tool["type"] as? String, !type.isEmpty, type != "custom" {
                    return true
                }
            }
        }
        if let messages = payload["messages"] as? [[String: Any]] {
            for msg in messages {
                if let blocks = msg["content"] as? [[String: Any]],
                   blocks.contains(where: { $0["cache_control"] != nil || ($0["type"] as? String) == "thinking" }) {
                    return true
                }
            }
        }
        return false
    }

    /// Apply automatic effort only to known model IDs at the start of a conversation.
    /// Leave continuation payloads and client-supplied thinking controls intact.
    static func applyingInitialEffort(
        to payload: [String: Any], modelID: String, effort: ReasoningEffort?
    ) -> [String: Any] {
        let supportedIDs: Set<String> = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2"]
        guard let effort, supportedIDs.contains(modelID),
              let messages = payload["messages"] as? [[String: Any]], messages.count == 1,
              messages.first?["role"] as? String == "user",
              payload["thinking"] == nil else { return payload }
        var outputConfig = payload["output_config"] as? [String: Any] ?? [:]
        guard outputConfig["effort"] == nil else { return payload }
        outputConfig["effort"] = effort.rawValue
        var updated = payload
        updated["output_config"] = outputConfig
        return updated
    }

    /// Extracts safe Anthropic protocol headers from an incoming proxy request for upstream passthrough.
    public static func passthroughHeaders(from req: HTTPRequestMessage) -> [String: String] {
        var headers: [String: String] = [:]
        if let version = req.header("anthropic-version"), !version.isEmpty {
            headers["anthropic-version"] = version
        }
        if let beta = req.header("anthropic-beta"), !beta.isEmpty {
            headers["anthropic-beta"] = beta
        }
        return headers
    }
}

/// Observes raw Anthropic Messages SSE chunks or JSON responses without altering wire bytes.
struct NativeAnthropicObserver {
    private var sseBuffer = ""
    private var inputTokens = 0
    private var outputTokens = 0
    private var cacheReadTokens = 0
    private var cacheCreationTokens = 0
    private var sawAnyUsage = false

    private(set) var text = ""
    private(set) var reasoning = ""
    private(set) var hasToolCalls = false
    private(set) var sawMessageStop = false
    private(set) var errorMessage: String?

    var hasOutput: Bool { !text.isEmpty || !reasoning.isEmpty || hasToolCalls }

    var usage: TokenUsage? {
        guard sawAnyUsage else { return nil }
        let totalPrompt = max(0, inputTokens) + max(0, cacheReadTokens) + max(0, cacheCreationTokens)
        let out = max(0, outputTokens)
        return TokenUsage(
            promptTokens: totalPrompt,
            completionTokens: out,
            totalTokens: totalPrompt + out,
            cachedInputTokens: cacheReadTokens > 0 ? cacheReadTokens : nil,
            cacheCreationTokens: cacheCreationTokens > 0 ? cacheCreationTokens : nil
        )
    }

    mutating func append(_ chunk: Data) {
        guard let str = String(data: chunk, encoding: .utf8) else { return }
        sseBuffer += str
        while let range = sseBuffer.range(of: "\n") {
            let line = String(sseBuffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            sseBuffer = String(sseBuffer[range.upperBound...])
            guard line.hasPrefix("data:") else { continue }
            let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            observeEvent(event)
        }
    }

    mutating func observeEvent(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        switch type {
        case "message_start":
            if let message = event["message"] as? [String: Any],
               let rawUsage = message["usage"] as? [String: Any] {
                mergeUsage(rawUsage)
            }
        case "content_block_start":
            if let block = event["content_block"] as? [String: Any] {
                let btype = block["type"] as? String ?? ""
                if btype == "tool_use" || btype == "server_tool_use" {
                    hasToolCalls = true
                }
            }
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any] {
                let dtype = delta["type"] as? String ?? ""
                if dtype == "text_delta", let t = delta["text"] as? String {
                    text += t
                } else if dtype == "thinking_delta", let t = delta["thinking"] as? String {
                    reasoning += t
                } else if dtype == "input_json_delta" {
                    hasToolCalls = true
                }
            }
        case "message_delta":
            if let rawUsage = event["usage"] as? [String: Any] {
                mergeUsage(rawUsage)
            }
        case "message_stop":
            sawMessageStop = true
        case "error":
            let errObj = event["error"] as? [String: Any]
            errorMessage = (errObj?["message"] as? String) ?? (event["message"] as? String) ?? "Anthropic stream error"
        default:
            break
        }
    }

    mutating func observeResponse(_ response: [String: Any]) {
        if let rawUsage = response["usage"] as? [String: Any] {
            mergeUsage(rawUsage)
        }
        if let contentBlocks = response["content"] as? [[String: Any]] {
            for block in contentBlocks {
                let btype = block["type"] as? String ?? ""
                if btype == "text", let t = block["text"] as? String {
                    text += t
                } else if btype == "thinking", let t = block["thinking"] as? String {
                    reasoning += t
                } else if btype == "tool_use" || btype == "server_tool_use" {
                    hasToolCalls = true
                }
            }
        }
        sawMessageStop = true
    }

    private mutating func mergeUsage(_ raw: [String: Any]) {
        if let inp = raw["input_tokens"] as? Int {
            inputTokens = max(inputTokens, inp)
            sawAnyUsage = true
        }
        if let out = raw["output_tokens"] as? Int {
            outputTokens = max(outputTokens, out)
            sawAnyUsage = true
        }
        if let read = raw["cache_read_input_tokens"] as? Int {
            cacheReadTokens = max(cacheReadTokens, read)
            sawAnyUsage = true
        }
        if let create = raw["cache_creation_input_tokens"] as? Int {
            cacheCreationTokens = max(cacheCreationTokens, create)
            sawAnyUsage = true
        }
    }
}
