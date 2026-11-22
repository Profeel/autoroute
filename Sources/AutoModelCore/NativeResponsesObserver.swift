import Foundation

/// Observes Responses SSE without altering any bytes sent to the caller.
struct NativeResponsesObserver {
    private var pending = Data()
    private var lines: [String] = []
    private(set) var text = ""
    private(set) var reasoning = ""
    private(set) var usage: TokenUsage?
    private(set) var hasToolCalls = false
    private(set) var completedResponse: [String: Any]?
    private(set) var responseID: String?
    private(set) var responseItemIDs: [String] = []
    private(set) var encryptedContents: [String] = []
    private(set) var errorMessage: String?
    var hasOutput: Bool { !text.isEmpty || !reasoning.isEmpty || hasToolCalls }

    mutating func append(_ data: Data) {
        pending.append(data)
        while let index = pending.firstIndex(of: 10) {
            var line = Data(pending[..<index])
            pending.removeSubrange(...index)
            if line.last == 13 { line.removeLast() }
            guard let string = String(data: line, encoding: .utf8) else { continue }
            if string.isEmpty {
                processFrame()
                lines.removeAll(keepingCapacity: true)
            } else {
                lines.append(string)
            }
        }
    }

    private mutating func processFrame() {
        let dataLines = lines.compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            return value
        }
        guard !dataLines.isEmpty, let data = dataLines.joined(separator: "\n").data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = event["type"] as? String ?? ""
        if type == "error" || type == "response.failed" || type == "response.incomplete" {
            let response = event["response"] as? [String: Any]
            let error = (event["error"] as? [String: Any]) ?? (response?["error"] as? [String: Any])
            errorMessage = (error?["message"] as? String) ?? "Responses stream terminated: \(type)"
        }
        if type == "response.output_text.delta", let delta = event["delta"] as? String { text += delta }
        if (type == "response.reasoning_text.delta" || type == "response.reasoning_summary_text.delta"),
           let delta = event["delta"] as? String { reasoning += delta }
        if type.contains("function_call") || type.contains("custom_tool_call") { hasToolCalls = true }
        if let item = event["item"] as? [String: Any] { observeItem(item, includeText: false) }
        if type == "response.completed", let response = event["response"] as? [String: Any] {
            if let status = response["status"] as? String, status != "completed" {
                errorMessage = "Responses stream terminated with status: \(status)"
                return
            }
            completedResponse = response
            observeResponse(response)
        }
    }

    mutating func observeResponse(_ response: [String: Any]) {
        responseID = response["id"] as? String
        responseItemIDs = (response["output"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        encryptedContents = (response["output"] as? [[String: Any]] ?? []).compactMap { $0["encrypted_content"] as? String }
        if let rawUsage = response["usage"] as? [String: Any],
           let parsed = TokenUsage.parse(from: rawUsage) {
            usage = parsed
        }
        let needsText = text.isEmpty
        let needsReasoning = reasoning.isEmpty
        for item in response["output"] as? [[String: Any]] ?? [] {
            observeItem(item, includeText: needsText, includeReasoning: needsReasoning)
        }
    }

    private mutating func observeItem(_ item: [String: Any], includeText: Bool, includeReasoning: Bool = false) {
        let type = item["type"] as? String ?? ""
        if type == "function_call" || type == "custom_tool_call" || type.hasSuffix("_call") { hasToolCalls = true }
        if includeText && type == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] where (part["type"] as? String) == "output_text" {
                text += part["text"] as? String ?? ""
            }
        }
        if includeReasoning && type == "reasoning" {
            for part in item["summary"] as? [[String: Any]] ?? [] { reasoning += part["text"] as? String ?? "" }
        }
    }
}
