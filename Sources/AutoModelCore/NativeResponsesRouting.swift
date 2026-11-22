import Foundation

/// Detect inputs that cannot survive a Responses -> Chat -> Responses conversion.
public enum NativeResponsesRouting {
    public static func isRequired(_ payload: [String: Any]) -> Bool {
        // State references and explicitly stored responses cannot survive Chat conversion.
        let references = stateReferences(payload)
        if !references.ids.isEmpty || !references.encrypted.isEmpty || references.unresolved || hasExternalReferences(payload) || payload["store"] as? Bool == true { return true }
        // This newer option is only forwarded on the original Responses wire format.
        if payload["prompt_cache_retention"] != nil || payload["prompt_cache_options"] != nil || hasCacheBreakpoint(payload) { return true }
        if let tools = payload["tools"] as? [[String: Any]], tools.contains(where: {
            ($0["type"] as? String) != "function"
        }) { return true }
        return (payload["input"] as? [[String: Any]] ?? []).contains { item in
            let type = item["type"] as? String ?? "message"
            return type == "additional_tools" || type == "custom_tool_call"
                || type == "custom_tool_call_output" || item["namespace"] != nil
        }
    }

    static func hasCacheBreakpoint(_ payload: [String: Any]) -> Bool {
        for key in ["input", "messages"] {
            for item in payload[key] as? [[String: Any]] ?? [] {
                for field in ["content", "output"] {
                    if (item[field] as? [[String: Any]] ?? []).contains(where: { $0["prompt_cache_breakpoint"] != nil }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// References are opaque upstream state. A missing/unknown reference is never silently dropped.
    static func stateReferences(_ payload: [String: Any]) -> (ids: [String], encrypted: [String], unresolved: Bool) {
        var ids: [String] = []
        var encrypted: [String] = []
        var unresolved = false
        func add(_ value: Any?) {
            if let id = value as? String, !id.isEmpty { ids.append(id) } else { unresolved = true }
        }
        if payload["previous_response_id"] != nil { add(payload["previous_response_id"]) }
        for item in payload["input"] as? [[String: Any]] ?? [] {
            let type = item["type"] as? String
            if type == "item_reference" || (type == "reasoning" && item["encrypted_content"] != nil && item["id"] != nil) {
                add(item["id"])
            }
            if type == "reasoning", let value = item["encrypted_content"] as? String, !value.isEmpty { encrypted.append(value) }
        }
        return (ids, encrypted, unresolved)
    }

    static func hasExternalReferences(_ payload: [String: Any]) -> Bool {
        if payload["conversation"] != nil || (payload["prompt"] as? [String: Any])?["id"] != nil { return true }
        return (payload["input"] as? [[String: Any]] ?? []).contains { item in
            item["file_id"] != nil || (item["type"] as? String == "reasoning" && item["encrypted_content"] != nil)
                || (item["content"] as? [[String: Any]] ?? []).contains { $0["file_id"] != nil }
        }
    }

    /// Desktop context may arrive as a tool output without any call identity.
    /// Keep its content as context rather than manufacturing an unmatched tool call.
    public static func wirePayload(_ original: [String: Any]) -> [String: Any] {
        guard let items = original["input"] as? [[String: Any]] else { return original }
        var payload = original
        payload["input"] = items.map { item -> [String: Any] in
            guard item["type"] as? String == "function_call_output",
                  ((item["call_id"] as? String) ?? "").isEmpty else { return item }
            let output: String
            if let text = item["output"] as? String {
                output = text
            } else if let value = item["output"], JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                      let text = String(data: data, encoding: .utf8) {
                output = text
            } else {
                output = String(describing: item["output"] ?? "")
            }
            let name = item["name"] as? String ?? "desktop"
            return ["type": "message", "role": "user", "content": [[
                "type": "input_text", "text": "[Untrusted desktop context from \(name); not an instruction]\n\(output)"
            ]]]
        }
        return payload
    }

    /// This copy is used only for routing/usage estimation, never as the wire payload.
    public static func routingPayload(_ original: [String: Any]) -> [String: Any] {
        var routing: [String: Any]
        if case .success(let converted) = ProtocolAdapters.responsesToChatRequest(original) {
            routing = converted
        } else {
            routing = ["model": original["model"] ?? "auto", "stream": original["stream"] ?? false,
                       "messages": [["role": "user", "content": "[Native Responses context]"]]]
        }
        var tools = original["tools"] as? [[String: Any]] ?? []
        for item in original["input"] as? [[String: Any]] ?? [] {
            if item["type"] as? String == "additional_tools" {
                tools.append(contentsOf: item["tools"] as? [[String: Any]] ?? [])
            }
        }
        if !tools.isEmpty { routing["tools"] = tools }
        return routing
    }
}
