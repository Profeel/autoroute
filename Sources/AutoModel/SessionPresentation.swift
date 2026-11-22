import AutoModelCore
import Foundation
import SwiftUI

/// Stable visual language for the recorded Agent identity.
enum AgentPresentation {
    static func symbol(for kind: AgentKind?) -> String {
        switch kind {
        case .codex: return "terminal.fill"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .hermes: return "sparkles"
        case .claudeCode: return "bubble.left.and.bubble.right.fill"
        case .deepseekHarness: return "wave.3.right"
        case .shellAndContinue: return "command"
        case nil: return "person.crop.circle"
        }
    }

    static func color(for kind: AgentKind?) -> Color {
        switch kind {
        case .codex: return .orange
        case .opencode: return .purple
        case .hermes: return .blue
        case .claudeCode: return .indigo
        case .deepseekHarness: return .teal
        case .shellAndContinue: return .pink
        case nil: return .secondary
        }
    }
}

/// Shared titles and grouping for the history and sidebar.
enum SessionPresentation {
    struct Session {
        let key: String
        let taskTitle: String?
        let agent: AgentKind?
        var records: [CallRecord]

        var displayTitle: String {
            taskTitle ?? records.first.map {
                $0.hasConversationFingerprint ? "会话 \($0.shortSessionLabel)" : "单次调用"
            } ?? "会话"
        }
    }

    static func sessions(from records: [CallRecord]) -> [Session] {
        let grouped = Dictionary(grouping: records, by: \.sessionGroupKey)
        let initial = grouped.map { key, records in
            let chronological = records.sorted { $0.timestamp < $1.timestamp }
            return Session(
                key: key,
                taskTitle: chronological.lazy.compactMap { taskTitle(in: $0.requestPreview) }.first,
                agent: chronological.reversed().lazy.compactMap(agentKind).first,
                records: chronological
            )
        }.sorted { ($0.records.first?.timestamp ?? .distantPast) < ($1.records.first?.timestamp ?? .distantPast) }

        return initial
    }

    static func taskTitle(in preview: String?) -> String? {
        guard let preview else { return nil }
        let roles = ["user", "assistant", "system", "developer", "tool", "function", "unknown"]
        var userMessages: [[String]] = []
        var isUser = false
        for line in preview.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let role = roles.first(where: { text.hasPrefix("[\($0)]") }) {
                isUser = role == "user"
                if isUser {
                    userMessages.append([String(text.dropFirst(role.count + 2))])
                }
            } else if isUser {
                userMessages[userMessages.count - 1].append(text)
            }
        }
        return userMessages.lazy.compactMap(title(from:)).first
    }

    private static func title(from lines: [String]) -> String? {
        var metadataEnd: String?
        var inCodeBlock = false
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            let lower = text.lowercased()
            if let end = metadataEnd {
                if lower.contains(end) { metadataEnd = nil }
                continue
            }
            if text.hasPrefix("```") || text.hasPrefix("~~~") {
                inCodeBlock.toggle()
                continue
            }
            guard !inCodeBlock, !text.isEmpty else { continue }
            if lower.hasPrefix("turns to summarize:") || lower.hasPrefix("summarize the conversation")
                || lower.hasPrefix("[context compaction") || lower.hasPrefix("[prior context")
                || lower.hasPrefix("[context summary") || lower.hasPrefix("--- context warnings ---") {
                return nil
            }
            if let tag = ["environment_context", "system-reminder", "runtime_context", "project_context", "system_reminder"]
                .first(where: { lower.hasPrefix("<\($0)>") || lower.hasPrefix("<\($0) ") }) {
                let end = "</\(tag)>"
                if !lower.contains(end) { metadataEnd = end }
                continue
            }
            if lower.hasPrefix("@folder:") || lower.hasPrefix("@file:")
                || text.range(of: #"^(?:\[[\w-]+\]|</?[\w-]+>|[-*_]{3,})$"#, options: .regularExpression) != nil {
                continue
            }
            let cleaned = text
                .replacingOccurrences(of: #"^(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let end = cleaned.range(of: #"[。！？]|[.!?](?=\s|$)"#, options: .regularExpression)?.lowerBound ?? cleaned.endIndex
            let sentence = cleaned[..<end].trimmingCharacters(in: .whitespaces)
            guard sentence.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            return sentence.count > 100 ? String(sentence.prefix(99)) + "…" : sentence
        }
        return nil
    }

    private static func agentKind(for record: CallRecord) -> AgentKind? {
        if let agentID = record.decision.agentID,
           let kind = AgentKind(rawValue: agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return kind
        }
        let client = record.displayClientAgent.lowercased()
        if client.contains("codex") { return .codex }
        if client.contains("opencode") { return .opencode }
        if client.contains("hermes") { return .hermes }
        if client.contains("claude") { return .claudeCode }
        if client.contains("deepseek harness") { return .deepseekHarness }
        if client == "shell" || client == "continue" || client.hasPrefix("shell / continue") { return .shellAndContinue }

        // Older records can retain the Hermes system prompt even when the SDK sent no client name.
        if record.source == .externalProxy,
           client == "python sdk",
           record.requestPreview?.split(whereSeparator: \.isNewline).contains(where: { line in
               line.hasPrefix("[system]") && AgentKind.isHermesSystemPrompt(String(line.dropFirst("[system]".count)))
           }) == true {
            return .hermes
        }
        return nil
    }
}
