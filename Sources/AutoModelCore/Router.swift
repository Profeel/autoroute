import CryptoKit
import Foundation

// MARK: - Pluggable Decision Interface

public struct ModelRuntimeMetrics: Sendable {
    public var averageLatencyMs: Double
    public var successRate: Double
    /// Measured spend per million reported tokens. Nil means there is not enough
    /// trustworthy usage/cost data to override configured pricing.
    public var averageCostPerMillionTokens: Double?
    public var sampleCount: Int
    public var cooldownUntil: Date?

    public init(
        averageLatencyMs: Double,
        successRate: Double,
        averageCostPerMillionTokens: Double? = nil,
        sampleCount: Int,
        cooldownUntil: Date? = nil
    ) {
        self.averageLatencyMs = averageLatencyMs
        self.successRate = successRate
        self.averageCostPerMillionTokens = averageCostPerMillionTokens
        self.sampleCount = sampleCount
        self.cooldownUntil = cooldownUntil
    }
}

public struct RoutingContext: Sendable {
    public var requestedModel: String
    public var features: RequestFeatures
    public var providers: [ProviderConfig]
    public var models: [ModelConfig]
    public var policy: RoutingPolicyConfig
    public var stickyModelID: UUID?
    public var consecutiveRoutineTurns: Int
    public var escalateNextTurn: Bool
    public var qualityFailureCount: Int
    public var lastFailureEffort: ReasoningEffort?
    public var runtimeMetricsByModelID: [UUID: ModelRuntimeMetrics]

    public init(
        requestedModel: String,
        features: RequestFeatures,
        providers: [ProviderConfig],
        models: [ModelConfig],
        policy: RoutingPolicyConfig,
        stickyModelID: UUID? = nil,
        consecutiveRoutineTurns: Int = 0,
        escalateNextTurn: Bool = false,
        qualityFailureCount: Int = 0,
        lastFailureEffort: ReasoningEffort? = nil,
        runtimeMetricsByModelID: [UUID: ModelRuntimeMetrics] = [:]
    ) {
        self.requestedModel = requestedModel
        self.features = features
        self.providers = providers
        self.models = models
        self.policy = policy
        self.stickyModelID = stickyModelID
        self.consecutiveRoutineTurns = consecutiveRoutineTurns
        self.escalateNextTurn = escalateNextTurn
        self.qualityFailureCount = qualityFailureCount
        self.lastFailureEffort = lastFailureEffort
        self.runtimeMetricsByModelID = runtimeMetricsByModelID
    }
}

/// Extension interface for future routing deciders (e.g. Jev, local SLM, custom plugins).
/// v1 uses `DeterministicLocalDeciderPlugin` locally without invoking any remote decider model.
public protocol RoutingDeciderPlugin: Sendable {
    var pluginID: String { get }
    var displayName: String { get }
    var summary: String { get }
    func decide(context: RoutingContext) -> RoutingDecision
}

// MARK: - Request Feature Extraction

public enum RequestFeatureExtractor {
    public static func extract(
        from payload: [String: Any],
        sessionHeader: String? = nil
    ) -> RequestFeatures {
        let messages = payload["messages"] as? [[String: Any]] ?? []
        let isStreaming = (payload["stream"] as? Bool) ?? false

        let toolsArray = payload["tools"] as? [Any]
        let functionsArray = payload["functions"] as? [Any]
        let requiresTools = (toolsArray?.isEmpty == false) || (functionsArray?.isEmpty == false)

        var requiresVision = false
        var combinedTextParts: [String] = []
        var userTextParts: [String] = []
        var assistantTextParts: [String] = []
        var nonSystemTextParts: [String] = []
        var firstSystemOrUserParts: [String] = []

        for (index, msg) in messages.enumerated() {
            let role = (msg["role"] as? String) ?? ""
            var textForMessage = ""

            if let strContent = msg["content"] as? String {
                textForMessage = strContent
            } else if let contentParts = msg["content"] as? [[String: Any]] {
                for part in contentParts {
                    let type = (part["type"] as? String) ?? ""
                    if type == "image_url" || type == "input_image" || part["image_url"] != nil {
                        requiresVision = true
                    }
                    if let text = part["text"] as? String {
                        textForMessage += (textForMessage.isEmpty ? "" : "\n") + text
                    }
                }
            }

            if !textForMessage.isEmpty {
                combinedTextParts.append(textForMessage)
                if role == "user" {
                    userTextParts.append(textForMessage)
                } else if role == "assistant" {
                    assistantTextParts.append(textForMessage)
                }
                if role != "system" {
                    nonSystemTextParts.append(textForMessage)
                }
                if index < 2 && (role == "system" || role == "user") {
                    firstSystemOrUserParts.append("\(role):\(textForMessage.prefix(500))")
                }
            }
        }

        let responseFormat = payload["response_format"] as? [String: Any]
        let formatType = responseFormat?["type"] as? String
        let requiresJSONMode = (formatType == "json_object" || formatType == "json_schema")

        let combinedText = combinedTextParts.joined(separator: "\n")
        let intentText: String
        if !userTextParts.isEmpty {
            intentText = userTextParts.suffix(2).joined(separator: "\n")
        } else if !nonSystemTextParts.isEmpty {
            intentText = nonSystemTextParts.suffix(2).joined(separator: "\n")
        } else {
            intentText = combinedText
        }
        let toolPayload = toolsArray ?? functionsArray
        let toolTokenOverhead = toolPayload.map { estimateStructuredPayloadTokens($0) } ?? 0
        let visionItemCount = messages.reduce(0) { count, message in
            guard let parts = message["content"] as? [[String: Any]] else { return count }
            return count + parts.reduce(0) { partCount, part in
                let type = (part["type"] as? String) ?? ""
                return partCount + ((type == "image_url" || type == "input_image" || part["image_url"] != nil) ? 1 : 0)
            }
        }
        let visionTokenOverhead = visionItemCount * 768
        let estimatedInputTokens = estimateTokens(
            text: combinedText,
            messageCount: messages.count,
            hasTools: requiresTools,
            hasVision: requiresVision,
            toolTokenOverhead: toolTokenOverhead,
            visionTokenOverhead: visionTokenOverhead
        )
        let intentTokens = estimateTokens(
            text: intentText,
            messageCount: min(2, messages.count),
            hasTools: requiresTools,
            hasVision: requiresVision,
            toolTokenOverhead: toolTokenOverhead,
            visionTokenOverhead: visionTokenOverhead
        )
        let detectedTaskType = classifyIntent(
            text: intentText,
            estimatedTokens: estimatedInputTokens,
            intentTokens: intentTokens,
            requiresTools: requiresTools,
            requiresVision: requiresVision
        )

        let clientProvidedEffort: ReasoningEffort? = {
            let raw = (payload["reasoning_effort"] as? String)
                ?? ((payload["reasoning"] as? [String: Any])?["effort"] as? String)
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !trimmed.isEmpty else {
                return nil
            }
            return ReasoningEffort(rawValue: trimmed)
        }()

        let latestMessageRole = ((messages.last?["role"] as? String) ?? "").lowercased()
        let recentToolNames = extractRecentAssistantToolNames(from: messages)
        let trailingToolOutputs = extractTrailingToolOutputs(from: messages)
        let latestSubtaskSource = userTextParts.last ?? nonSystemTextParts.last ?? ""
        // Anthropic can place tool results and user text in the same message. Its adapter
        // emits the tool result immediately before the normalized user message.
        let isUserTurnBoundary = latestMessageRole == "user"
            && (messages.dropLast().last?["role"] as? String) != "tool"
        let (subtaskCategory, recommendedEffort) = classifySubtaskAndEffort(
            text: latestSubtaskSource,
            latestMessageRole: latestMessageRole,
            recentToolNames: recentToolNames,
            trailingToolOutputs: trailingToolOutputs,
            estimatedTokens: estimatedInputTokens,
            intentTokens: estimateTextTokens(latestSubtaskSource),
            requiresTools: requiresTools,
            requiresVision: requiresVision
        )
        let subtaskSummary = extractSubtaskSummary(
            from: latestSubtaskSource,
            latestMessageRole: latestMessageRole,
            recentToolNames: recentToolNames,
            fallbackCategory: subtaskCategory,
            effort: recommendedEffort
        )

        let isMultiTurn = messages.count >= 3
        let firstAssistant = assistantTextParts.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint: String?
        if let explicitSession = sessionHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitSession.isEmpty {
            fingerprint = explicitSession
        } else if let userField = payload["user"] as? String, !userField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fingerprint = "user:\(userField)"
        } else if let firstUser = userTextParts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !firstUser.isEmpty {
            // Anchor on the first user turn so dynamic system prompt updates (time/memory/skills)
            // inside agents like Hermes do not split a single conversation into multiple sessions.
            // For very short generic openings ("hi", "你好"), disambiguate with the first assistant turn
            // so unrelated single-word chats do not collide on the same sticky bucket.
            if firstUser.count >= 12 {
                let seed = "user:\(firstUser.prefix(500))"
                let digest = SHA256.hash(data: Data(seed.utf8))
                fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            } else if let firstAssistant, !firstAssistant.isEmpty {
                let seed = "user:\(firstUser)|assistant:\(firstAssistant.prefix(200))"
                let digest = SHA256.hash(data: Data(seed.utf8))
                fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            } else {
                fingerprint = nil
            }
        } else if !firstSystemOrUserParts.isEmpty {
            let seed = firstSystemOrUserParts.joined(separator: "|")
            let digest = SHA256.hash(data: Data(seed.utf8))
            fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        } else {
            fingerprint = nil
        }

        return RequestFeatures(
            messageCount: messages.count,
            estimatedInputTokens: estimatedInputTokens,
            tokenEstimateConfidence: (requiresTools || requiresVision) ? .low : .medium,
            requiresTools: requiresTools,
            requiresVision: requiresVision,
            requiresJSONMode: requiresJSONMode,
            isStreaming: isStreaming,
            detectedTaskType: detectedTaskType,
            conversationFingerprint: fingerprint,
            isMultiTurn: isMultiTurn,
            subtaskCategory: subtaskCategory,
            recommendedEffort: recommendedEffort,
            subtaskSummary: subtaskSummary,
            clientProvidedEffort: clientProvidedEffort,
            hasClientProvidedEffort: payload["reasoning_effort"] != nil || (payload["reasoning"] as? [String: Any])?["effort"] != nil || payload["thinking"] != nil,
            isUserTurnBoundary: isUserTurnBoundary
        )
    }

    public static func estimateTokens(
        text: String,
        messageCount: Int = 1,
        hasTools: Bool = false,
        hasVision: Bool = false,
        toolTokenOverhead: Int = 0,
        visionTokenOverhead: Int = 0
    ) -> Int {
        let baseTokens = estimateTextTokens(text)
        let messageOverhead = max(0, messageCount) * 4
        let toolOverhead = hasTools ? max(250, toolTokenOverhead) : 0
        let visionOverhead = hasVision ? max(768, visionTokenOverhead) : 0
        return max(1, baseTokens + messageOverhead + toolOverhead + visionOverhead)
    }

    private static func estimateTextTokens(_ text: String) -> Int {
        var estimate = 0.0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if isCJK(value) {
                estimate += 1.5
            } else if value > 0x7F {
                // Emoji and other non-ASCII symbols are usually split into multiple tokens.
                estimate += 2.0
            } else if scalar.properties.isWhitespace {
                estimate += 0.25
            } else if isASCIIJsonOrCodePunctuation(value) {
                estimate += 0.45
            } else {
                estimate += 0.30
            }
        }
        return max(1, Int(ceil(estimate)))
    }

    private static func estimateStructuredPayloadTokens(_ payload: [Any]) -> Int {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return 0
        }
        return estimateTextTokens(text)
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2FA1F).contains(value)
    }

    private static func isASCIIJsonOrCodePunctuation(_ value: UInt32) -> Bool {
        "{}[]()<>:;,.'\"/=+-_*#|\\\\".unicodeScalars.contains { $0.value == value }
    }

    private static func classifyIntent(
        text: String,
        estimatedTokens: Int,
        intentTokens: Int,
        requiresTools: Bool,
        requiresVision: Bool
    ) -> TaskIntentType {
        if requiresVision {
            return .visionMultimodal
        }
        if requiresTools {
            return .toolCalling
        }
        let lower = text.lowercased()
        let codeSignals = [
            "```", "func ", "def ", "class ", "import ", "struct ", "select ", "swift", "python",
            "typescript", "javascript", "rust", "refactor", "debug", "stack trace", "compile",
            "单元测试", "重构", "代码", "报错", "实现一个", "函数", "接口", "sql"
        ]
        if codeSignals.contains(where: { lower.contains($0) }) {
            return .coding
        }

        let reasoningSignals = [
            "architecture", "prove", "derive", "tradeoff", "compare", "step by step", "analyze",
            "设计方案", "架构", "推导", "证明", "深度分析", "利弊", "系统设计", "方案对比", "迁移计划"
        ]
        if reasoningSignals.contains(where: { lower.contains($0) }) || intentTokens > 1500 {
            return .complexReasoning
        }

        if intentTokens < 120 {
            return .simpleQA
        }
        return .generalChat
    }

    private static func extractRecentAssistantToolNames(from messages: [[String: Any]]) -> [String] {
        for msg in messages.reversed() {
            let role = ((msg["role"] as? String) ?? "").lowercased()
            if role == "user" { break }
            if role == "assistant", let toolCalls = msg["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                return toolCalls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            }
        }
        return []
    }

    private static func extractTrailingToolOutputs(from messages: [[String: Any]]) -> [String] {
        var outputs: [String] = []
        for msg in messages.reversed() {
            let role = ((msg["role"] as? String) ?? "").lowercased()
            if role == "tool" {
                if let str = msg["content"] as? String, !str.isEmpty {
                    outputs.append(String(str.prefix(600)))
                }
            } else if role == "user" || role == "assistant" {
                break
            }
        }
        return outputs.reversed()
    }

    private static func classifySubtaskAndEffort(
        text: String,
        latestMessageRole: String = "user",
        recentToolNames: [String] = [],
        trailingToolOutputs: [String] = [],
        estimatedTokens: Int,
        intentTokens: Int,
        requiresTools: Bool,
        requiresVision: Bool
    ) -> (AgentSubtaskCategory, ReasoningEffort) {
        let lower = text.lowercased()

        // 1. Dynamic tool-loop step classification when the agent is continuing after tool calls/results
        if latestMessageRole == "tool" || (!trailingToolOutputs.isEmpty && latestMessageRole != "user") {
            let toolNamesLower = recentToolNames.map { $0.lowercased() }
            let joinedOutputsLower = trailingToolOutputs.joined(separator: "\n").lowercased()

            let toolErrorSignals = [
                "traceback", "exception", "timed out", "timeout", "error:", "\"error\"",
                "failed:", "not found", "403 forbidden", "status 403", "status 500",
                "selector not found", "报错", "失败", "超时"
            ]
            if toolErrorSignals.contains(where: { joinedOutputsLower.contains($0) }) {
                // Keep on Medium tier (.toolOrchestration) while boosting effort to high for error recovery
                return (.toolOrchestration, .high)
            }

            let lightweightReadTools = [
                "read_file", "view_file", "grep", "glob", "find", "list_dir", "ls", "search", "fetch"
            ]
            let lightweightBrowserTools = [
                "ego", "browser", "snapshot", "click", "scroll", "hover", "navigate", "open_url", "screenshot", "wait", "press_key"
            ]
            let allLightRead = !toolNamesLower.isEmpty && toolNamesLower.allSatisfy { name in
                lightweightReadTools.contains(where: { name.contains($0) })
            }
            if allLightRead {
                return (.explorationSearch, .low)
            }

            let allLightBrowser = !toolNamesLower.isEmpty && toolNamesLower.allSatisfy { name in
                lightweightBrowserTools.contains(where: { name.contains($0) })
                    || lightweightReadTools.contains(where: { name.contains($0) })
            }
            if allLightBrowser {
                // Routine ego-lite / browser execution stays on Medium tier while dropping effort to low
                return (.toolOrchestration, .low)
            }

            return (.toolOrchestration, .medium)
        }

        let debugSignals = [
            "stack trace", "traceback", "deadlock", "root cause", "segfault", "intermittent failure",
            "崩溃", "死锁", "根因", "偶发故障", "为什么失败", "无法编译"
        ]
        if debugSignals.contains(where: { lower.contains($0) }) {
            return (.deepDebugging, .high)
        }

        let planningSignals = [
            "architecture", "system design", "migration", "major refactor", "cross-service", "performance optimiz",
            "deep research", "quantitative analysis", "tradeoff", "架构", "系统设计", "迁移", "大规模重构",
            "跨模块", "性能优化", "深度分析", "深度研究", "定量分析", "方案对比", "重构方案"
        ]
        if planningSignals.contains(where: { lower.contains($0) }) {
            return (.architecturePlanning, .high)
        }
        if requiresVision || intentTokens >= 1_500 {
            return (.generalEngineering, .medium)
        }

        let browserSignals = [
            "ego-lite", "ego_lite", "ego-browser", "浏览器", "打开网页", "访问网页", "抓取网页", "x.com"
        ]
        if browserSignals.contains(where: { lower.contains($0) }) {
            return (.toolOrchestration, .medium)
        }

        let reviewSignals = [
            "code review", "review the", "audit", "verify", "git diff", "final check",
            "审核", "审查", "复核", "验收", "门禁", "最终检查", "校对"
        ]
        if reviewSignals.contains(where: { lower.contains($0) }) {
            return (requiresTools ? .toolOrchestration : .routineCoding, .high)
        }

        var instruction = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["please ", "请", "帮我"] where instruction.hasPrefix(prefix) {
            instruction = String(instruction.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let transformPrefixes = [
            "summarize ", "summarise ", "compact ", "tl;dr", "translate ", "condense ", "classify ", "tag ", "extract ",
            "摘要", "总结", "压缩", "提炼", "翻译", "生成标题", "分类", "打标签", "提取", "从以下"
        ]
        if intentTokens < 600, transformPrefixes.contains(where: { instruction.hasPrefix($0) }),
           !instruction.hasPrefix("从以下") || instruction.contains("提取") {
            return (.summarizationCompaction, .low)
        }

        let lookupPrefixes = [
            "grep ", "glob ", "read_file ", "find_by_name ", "list_dir ", "search for ", "locate ", "where is ",
            "查找", "检索", "列出", "读取", "搜索"
        ]
        if intentTokens < 300, lookupPrefixes.contains(where: { instruction.hasPrefix($0) }) {
            return (.explorationSearch, .low)
        }

        let scopedSignals = [
            "fix the typo", "fix this typo", "bug fix", "implement", "write test", "write a test", "unit test",
            "write a ", "draft ", "spec-driven", "refactor this ", "重构这段", "单元测试", "拼写错误", "修复这个",
            "实现", "撰写", "写一", "文档", "表格", "幻灯片"
        ]
        if scopedSignals.contains(where: { lower.contains($0) }) {
            return (.routineCoding, .medium)
        }
        if ["hello", "hi", "hey", "thanks", "你好", "谢谢"].contains(instruction) {
            return (.explorationSearch, .low)
        }
        return (.generalEngineering, .medium)
    }

    private static func extractSubtaskSummary(
        from text: String,
        latestMessageRole: String = "user",
        recentToolNames: [String] = [],
        fallbackCategory: AgentSubtaskCategory,
        effort: ReasoningEffort = .medium
    ) -> String {
        if (latestMessageRole == "tool" || !recentToolNames.isEmpty) && latestMessageRole != "user",
           !recentToolNames.isEmpty {
            let uniqueNames = Array(NSOrderedSet(array: recentToolNames)).compactMap { $0 as? String }
            let joined = uniqueNames.prefix(2).joined(separator: ", ")
            return "工具步: \(joined) (\(effort.rawValue))"
        }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("<system")
                    && !line.hasPrefix("</system")
                    && !line.hasPrefix("#")
                    && !line.hasPrefix("```")
            }
        guard let candidate = lines.first(where: { $0.count >= 4 }) ?? lines.first else {
            return fallbackCategory.displayName
        }
        return candidate.count > 44 ? String(candidate.prefix(43)) + "…" : candidate
    }
}

// MARK: - Built-in Deterministic Local Decider

public struct DeterministicLocalDeciderPlugin: RoutingDeciderPlugin, Sendable {
    public let pluginID = "builtin.deterministic.v1"
    public let displayName = "本机确定性路由器 (v1)"
    public let summary = "完全在本机基于硬约束与策略评分决策，不调用任何外部决策模型。"

    public init() {}

    public func decide(context: RoutingContext) -> RoutingDecision {
        let start = DispatchTime.now()
        let providersByID = Dictionary(uniqueKeysWithValues: context.providers.map { ($0.id, $0) })
        let trimmedRequested = context.requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)

        if let explicitTier = ModelTier.matchExplicitTier(requestedModel: trimmedRequested) {
            return decideAutoRoute(
                context: context,
                providersByID: providersByID,
                explicitTier: explicitTier,
                startTime: start
            )
        }

        let lower = trimmedRequested.lowercased()
        let isAuto = trimmedRequested.isEmpty || lower == "auto" || lower == "automodel/auto"

        if !isAuto {
            return decideExplicitModel(
                requestedModel: trimmedRequested,
                context: context,
                providersByID: providersByID,
                startTime: start
            )
        }

        return decideAutoRoute(
            context: context,
            providersByID: providersByID,
            explicitTier: nil,
            startTime: start
        )
    }

    private func decideExplicitModel(
        requestedModel: String,
        context: RoutingContext,
        providersByID: [UUID: ProviderConfig],
        startTime: DispatchTime
    ) -> RoutingDecision {
        var matchedModel: ModelConfig?
        for model in context.models {
            let providerName = providersByID[model.providerID]?.name ?? ""
            if model.modelID == requestedModel || "\(providerName)/\(model.modelID)" == requestedModel {
                matchedModel = model
                break
            }
        }
        if matchedModel == nil, requestedModel.hasPrefix("codex/") {
            let stripped = String(requestedModel.dropFirst("codex/".count))
            matchedModel = context.models.first(where: { m in
                m.modelID == stripped && providersByID[m.providerID]?.apiProtocol == .codexChatGPT
            })
        }

        guard let model = matchedModel else {
            let ms = elapsedMs(since: startTime)
            return RoutingDecision(
                requestedModel: requestedModel,
                isAutoRouted: false,
                strategyName: "显式指定模型",
                policyVersion: context.policy.policyVersion,
                deciderPluginID: pluginID,
                decisionDurationMs: ms,
                errorSummary: "未找到已配置的模型「\(requestedModel)」。请在「供应商与模型」页面添加该模型，或改用 model=\"auto\"。"
            )
        }

        let evaluation = evaluateHardConstraints(
            model: model,
            provider: providersByID[model.providerID],
            features: context.features,
            policy: context.policy,
            ignorePriceCap: true
        )

        let ms = elapsedMs(since: startTime)
        let provider = providersByID[model.providerID]
        let canonicalID = CanonicalModelNormalizer.canonicalID(for: model)

        if context.policy.enableAutoSameModelGrouping, !canonicalID.isEmpty {
            let groupMatches: [(ModelConfig, ProviderConfig, CandidateEvaluation)] = context.models.compactMap { candidate in
                guard CanonicalModelNormalizer.canonicalID(for: candidate) == canonicalID,
                      let candProvider = providersByID[candidate.providerID] else {
                    return nil
                }
                let eval = evaluateHardConstraints(
                    model: candidate,
                    provider: candProvider,
                    features: context.features,
                    policy: context.policy,
                    ignorePriceCap: true
                )
                guard eval.passedHardConstraints else { return nil }
                return (candidate, candProvider, eval)
            }
            .sorted { lhs, rhs in
                if lhs.0.id == model.id && rhs.0.id != model.id { return true }
                if rhs.0.id == model.id && lhs.0.id != model.id { return false }
                let lLat = lhs.0.lastProbeLatencyMs ?? .greatestFiniteMagnitude
                let rLat = rhs.0.lastProbeLatencyMs ?? .greatestFiniteMagnitude
                if lLat != rLat { return lLat < rLat }
                return lhs.1.name < rhs.1.name
            }

            if let primaryMatch = groupMatches.first {
                let peerIDs = groupMatches.dropFirst().map(\.0.id)
                var rules = evaluation.passedHardConstraints
                    ? ["显式指定模型，直接转发到 \(primaryMatch.1.name) / \(primaryMatch.0.modelID)"]
                    : ["原通道 \(provider?.name ?? "") 不可用，同模型自动分组切换至健康通道 \(primaryMatch.1.name) / \(primaryMatch.0.modelID)"]
                if !peerIDs.isEmpty {
                    rules.append("同模型自动分组「\(canonicalID)」已挂载 \(groupMatches.count) 个健康通道")
                }
                return RoutingDecision(
                    requestedModel: requestedModel,
                    isAutoRouted: !peerIDs.isEmpty || primaryMatch.0.id != model.id,
                    selectedModelUUID: primaryMatch.0.id,
                    selectedModelID: primaryMatch.0.modelID,
                    selectedDisplayName: primaryMatch.0.displayName,
                    selectedProviderID: primaryMatch.1.id,
                    selectedProviderName: primaryMatch.1.name,
                    orderedFallbackCandidateIDs: peerIDs,
                    candidateEvaluations: groupMatches.map(\.2),
                    matchedRules: rules,
                    strategyName: "显式指定模型",
                    policyVersion: context.policy.policyVersion,
                    deciderPluginID: pluginID,
                    decisionDurationMs: ms,
                    selectedEffort: context.features.clientProvidedEffort ?? context.features.recommendedEffort,
                    subtaskCategory: context.features.subtaskCategory,
                    routingReasonNote: "指定模型「\(primaryMatch.0.displayName)」· 通道 \(primaryMatch.1.name)",
                    canonicalGroupID: canonicalID
                )
            }
        }

        if !evaluation.passedHardConstraints {
            return RoutingDecision(
                requestedModel: requestedModel,
                isAutoRouted: false,
                selectedModelUUID: nil,
                selectedModelID: model.modelID,
                selectedDisplayName: model.displayName,
                selectedProviderID: provider?.id,
                selectedProviderName: provider?.name,
                candidateEvaluations: [evaluation],
                matchedRules: ["显式指定模型: \(model.modelID)", "未通过可用性检查"],
                strategyName: "显式指定模型",
                policyVersion: context.policy.policyVersion,
                deciderPluginID: pluginID,
                decisionDurationMs: ms,
                errorSummary: "指定模型「\(model.displayName)」当前不可用：\(evaluation.exclusionReasons.joined(separator: "；"))"
            )
        }

        return RoutingDecision(
            requestedModel: requestedModel,
            isAutoRouted: false,
            selectedModelUUID: model.id,
            selectedModelID: model.modelID,
            selectedDisplayName: model.displayName,
            selectedProviderID: provider?.id,
            selectedProviderName: provider?.name ?? "未知供应商",
            orderedFallbackCandidateIDs: [],
            candidateEvaluations: [evaluation],
            matchedRules: ["显式指定模型，跳过 auto 评分直接转发到 \(provider?.name ?? "") / \(model.modelID)"],
            strategyName: "显式指定模型",
            policyVersion: context.policy.policyVersion,
            deciderPluginID: pluginID,
            decisionDurationMs: ms,
            selectedEffort: context.features.clientProvidedEffort ?? context.features.recommendedEffort,
            subtaskCategory: context.features.subtaskCategory,
            routingReasonNote: "指定模型直连「\(model.displayName)」· 子任务「\(context.features.subtaskCategory.displayName)」"
        )
    }

    private func decideAutoRoute(
        context: RoutingContext,
        providersByID: [UUID: ProviderConfig],
        explicitTier: ModelTier?,
        startTime: DispatchTime
    ) -> RoutingDecision {
        let scoringStrategy: RoutingStrategyPreset
        if let explicitTier {
            switch explicitTier {
            case .low: scoringStrategy = .costFirst
            case .medium: scoringStrategy = .balanced
            case .high: scoringStrategy = .qualityFirst
            }
        } else {
            scoringStrategy = context.policy.activeStrategy
        }

        let subtask = context.features.subtaskCategory
        let initialEffort = context.features.clientProvidedEffort ?? Self.resolvedEffort(
            recommended: context.features.recommendedEffort,
            explicitTier: explicitTier,
            strategy: context.policy.activeStrategy
        )
        let previousModel = context.stickyModelID.flatMap { id in context.models.first { $0.id == id } }
        let previousProvider = previousModel.flatMap { providersByID[$0.providerID] }
        // An effort increase is meaningful only on a wire path that can inject it.
        let previousEligible = context.qualityFailureCount > 0 && (previousModel.map { model in
            evaluateHardConstraints(model: model, provider: previousProvider, features: context.features,
                policy: context.policy, ignorePriceCap: explicitTier != nil,
                runtimeMetrics: context.runtimeMetricsByModelID[model.id]).passedHardConstraints
        } ?? false)
        let effortOrder: [ReasoningEffort] = [.low, .medium, .high, .max]
        let raisedEffort: ReasoningEffort? = context.lastFailureEffort == .low ? .medium
            : (context.lastFailureEffort == .medium ? .high : nil)
        let canIncreaseEffort = context.policy.enablePhaseDowngradeHysteresis
            && context.qualityFailureCount == 1 && previousEligible
            && !context.features.hasClientProvidedEffort
            && previousModel.map { $0.capabilities.contains(.reasoning) || $0.defaultRole == .complexReasoning } == true
            && previousProvider.map { $0.apiProtocol != .anthropicMessages } == true
            && raisedEffort.map { (effortOrder.firstIndex(of: $0) ?? 0) > (effortOrder.firstIndex(of: initialEffort) ?? 0) } == true
        let targetEffort: ReasoningEffort = canIncreaseEffort ? (raisedEffort ?? initialEffort) : initialEffort

        var evaluations: [CandidateEvaluation] = []
        var passingModels: [(ModelConfig, ProviderConfig, Double, [String])] = []

        let stickyProviderID = context.stickyModelID.flatMap { sid in
            context.models.first(where: { $0.id == sid })?.providerID
        }

        for model in context.models {
            let provider = providersByID[model.providerID]
            let metrics = context.runtimeMetricsByModelID[model.id]
            var eval = evaluateHardConstraints(
                model: model,
                provider: provider,
                features: context.features,
                policy: context.policy,
                ignorePriceCap: explicitTier != nil,
                runtimeMetrics: metrics
            )

            if eval.passedHardConstraints, let validProvider = provider {
                let (score, breakdown) = scoreCandidate(
                    model: model,
                    features: context.features,
                    strategy: scoringStrategy,
                    targetEffort: targetEffort,
                    runtimeMetrics: metrics,
                    preferredProviderID: stickyProviderID
                )
                eval.score = score
                eval.scoreBreakdown = breakdown
                passingModels.append((model, validProvider, score, breakdown))
            }

            evaluations.append(eval)
        }

        let strategyLabel = explicitTier.map { "档位路由 · \($0.displayName)" } ?? context.policy.activeStrategy.displayName

        guard !passingModels.isEmpty else {
            let ms = elapsedMs(since: startTime)
            let reasonSummary = context.models.isEmpty
                ? "尚未配置任何可用模型。请先添加供应商和至少一个模型。"
                : "所有候选模型均未满足当前请求的硬约束条件。"
            return RoutingDecision(
                requestedModel: context.requestedModel,
                isAutoRouted: true,
                candidateEvaluations: evaluations,
                matchedRules: ["硬约束过滤后无可用候选模型"],
                strategyName: strategyLabel,
                policyVersion: context.policy.policyVersion,
                deciderPluginID: pluginID,
                decisionDurationMs: ms,
                errorSummary: reasonSummary,
                selectedEffort: targetEffort,
                subtaskCategory: subtask,
                routingReasonNote: reasonSummary
            )
        }

        // Effort-aware sorting: when high/max effort is required and at least one passing model has .reasoning,
        // scoreCandidate already boosts .reasoning models significantly.
        let sorted = passingModels.sorted { lhs, rhs in
            if abs(lhs.2 - rhs.2) > 0.0001 {
                return lhs.2 > rhs.2
            }
            return lhs.0.modelID < rhs.0.modelID
        }

        var matchedRules: [String] = []
        matchedRules.append("任务识别: \(subtask.displayName) (\(context.features.detectedTaskType.displayName), ~\(context.features.estimatedInputTokens) tokens)")
        matchedRules.append("思考程度路由: effort=\(targetEffort.rawValue) (\(targetEffort.displayName))")
        let hasReasoningCandidate = sorted.contains { $0.0.capabilities.contains(.reasoning) || $0.0.defaultRole == .complexReasoning }
        if targetEffort.requiresDeepReasoning && hasReasoningCandidate {
            matchedRules.append("思考程度筛选 [effort=\(targetEffort.rawValue)]：评分优先考虑具备深度推理 (reasoning) 能力的模型")
        }
        if context.features.requiresTools {
            matchedRules.append("硬约束: 要求支持工具调用 (tools)")
        }
        if context.features.requiresVision {
            matchedRules.append("硬约束: 要求支持视觉理解 (vision)")
        }
        matchedRules.append("策略预设: \(strategyLabel) (v\(context.policy.policyVersion))")

        var selectedTuple = sorted[0]
        var reasonNote = "\(subtask.displayName) · 思考程度 \(targetEffort.rawValue)：\(subtask.defaultRationale)"

        let baseTier = Self.targetTierForAuto(
            task: context.features.detectedTaskType,
            subtask: subtask,
            effort: targetEffort,
            strategy: context.policy.activeStrategy
        )
        let canSwitchPhase = context.features.isUserTurnBoundary != false
        let wantsRescue = canSwitchPhase && context.policy.enablePhaseDowngradeHysteresis
            && context.qualityFailureCount > 0 && !canIncreaseEffort
            && explicitTier == nil && context.policy.pinnedModelID == nil

        let configuredTierIDSet = Set([ModelTier.low, .medium, .high].flatMap { context.policy.modelIDs(for: $0) })
        let hasConfiguredPool = !configuredTierIDSet.isEmpty || context.policy.fallbackModelID != nil
        let enforceStrictTierPool = context.policy.strictThreeTierPoolOnly
            && (context.policy.preferTierMappingInAuto || explicitTier != nil)
            && hasConfiguredPool
        let stickyTuple = context.stickyModelID.flatMap { sid in sorted.first(where: { $0.0.id == sid }) }
        let tierOrder = ModelTier.allCases
        let stickyTiers: [ModelTier] = stickyTuple.map { sticky in
            let canonicalID = CanonicalModelNormalizer.canonicalID(for: sticky.0)
            return tierOrder.filter { tier in
                let ids = context.policy.modelIDs(for: tier)
                if ids.contains(sticky.0.id) { return true }
                guard context.policy.enableAutoSameModelGrouping else { return false }
                return !canonicalID.isEmpty && context.models.contains {
                    ids.contains($0.id) && CanonicalModelNormalizer.canonicalID(for: $0) == canonicalID
                }
            }
        } ?? []
        let stickyTier = stickyTiers.contains(baseTier) ? baseTier : stickyTiers.last
        let stickyTierIndex = stickyTier.flatMap { tierOrder.firstIndex(of: $0) }
        let rescueTier: ModelTier? = {
            guard wantsRescue, let index = stickyTierIndex, index + 1 < tierOrder.count else { return nil }
            let next = tierOrder[index + 1]
            guard let candidate = Self.resolveTierCandidate(poolIDs: context.policy.modelIDs(for: next),
                sorted: sorted, allModels: context.models, enableSameModelGrouping: context.policy.enableAutoSameModelGrouping),
                  candidate.tuple.0.id != stickyTuple?.0.id else { return nil }
            return next
        }()
        let targetTier = wantsRescue ? (rescueTier ?? stickyTier ?? baseTier) : baseTier
        var effectiveTier = explicitTier ?? targetTier
        let targetIndex = tierOrder.firstIndex(of: targetTier) ?? 0
        let tierPoolIDs = context.policy.modelIDs(for: targetTier)
        let resolvedTierCandidate = Self.resolveTierCandidate(
            poolIDs: tierPoolIDs,
            sorted: sorted,
            allModels: context.models,
            enableSameModelGrouping: context.policy.enableAutoSameModelGrouping
        )
        let canFollowTaskTier = canSwitchPhase && context.policy.enablePhaseDowngradeHysteresis
            && context.policy.activeStrategy == .balanced && context.policy.preferTierMappingInAuto
            && resolvedTierCandidate != nil
        let stickyNeedsTierUpgrade = !canIncreaseEffort && canFollowTaskTier
            && (stickyTierIndex ?? -1) < targetIndex
        let stickyNeedsEscalateToReasoning = !canIncreaseEffort && canSwitchPhase && context.policy.enablePhaseDowngradeHysteresis
            && (!context.policy.preferTierMappingInAuto || context.policy.modelIDs(for: targetTier).isEmpty)
            && context.policy.activeStrategy != .costFirst && targetEffort.requiresDeepReasoning
            && hasReasoningCandidate && (stickyTuple.map {
                !$0.0.capabilities.contains(.reasoning) && $0.0.defaultRole != .complexReasoning
            } ?? false)
        let stickyNeedsToolRescue = rescueTier != nil && !stickyTiers.contains(targetTier)
        let clearLightTask = context.features.subtaskCategory == .explorationSearch
            || context.features.subtaskCategory == .summarizationCompaction
        let stickyShouldDowngrade = canFollowTaskTier && context.qualityFailureCount == 0
            && (stickyTierIndex ?? -1) > targetIndex
            && (clearLightTask || context.consecutiveRoutineTurns >= 2)

        if let explicitTier {
            let tierPoolIDs = context.policy.modelIDs(for: explicitTier)
            if let tierTuple = Self.resolveTierCandidate(
                poolIDs: tierPoolIDs,
                sorted: sorted,
                allModels: context.models,
                enableSameModelGrouping: context.policy.enableAutoSameModelGrouping
            ) {
                selectedTuple = (canIncreaseEffort && stickyTiers.contains(explicitTier) ? stickyTuple : nil) ?? tierTuple.tuple
                let isPrimary = selectedTuple.0.id == tierPoolIDs.first
                if canIncreaseEffort && selectedTuple.0.id == stickyTuple?.0.id {
                    matchedRules.append("必需工具调用缺失：保留显式档位内的同一模型，思考强度提高至 \(targetEffort.rawValue)")
                } else if tierTuple.viaSameModelGroup {
                    matchedRules.append("显式档位路由 [\(explicitTier.displayName)]：主通道冷却中，同模型自动分组切换至「\(selectedTuple.1.name) / \(selectedTuple.0.displayName)」")
                } else {
                    matchedRules.append("显式档位路由 [\(explicitTier.displayName)]：请求「\(context.requestedModel)」-> 选用配置的\(explicitTier.shortName)\(isPrimary ? "" : "备选")模型「\(selectedTuple.0.displayName)」")
                }
                reasonNote = canIncreaseEffort ? "显式档位内保留原模型并提高思考强度至 \(targetEffort.rawValue)" : "显式指定 \(explicitTier.shortName) 档 · effort=\(targetEffort.rawValue)"
            } else if let controlledFallback = selectControlledFallback(
                for: explicitTier,
                policy: context.policy,
                sorted: sorted,
                enforceStrictTierPool: enforceStrictTierPool
            ) {
                selectedTuple = controlledFallback.tuple
                matchedRules.append("显式档位 [\(explicitTier.shortName)] 主备模型均受限，\(controlledFallback.ruleDescription)「\(selectedTuple.0.displayName)」")
                reasonNote = "原\(explicitTier.shortName)档受限，按受控回退选用「\(selectedTuple.0.displayName)」"
            } else if enforceStrictTierPool {
                let ms = elapsedMs(since: startTime)
                let msg = "显式档位「\(explicitTier.displayName)」及三档受控回退池内暂无满足当前硬约束的可用模型。"
                return RoutingDecision(
                    requestedModel: context.requestedModel,
                    isAutoRouted: true,
                    candidateEvaluations: evaluations,
                    matchedRules: matchedRules + ["严格三档池模式下，\(explicitTier.shortName)档与允许回退池均无可用模型"],
                    strategyName: strategyLabel,
                    policyVersion: context.policy.policyVersion,
                    deciderPluginID: pluginID,
                    decisionDurationMs: ms,
                    errorSummary: msg,
                    selectedEffort: targetEffort,
                    subtaskCategory: subtask,
                    routingReasonNote: msg
                )
            } else {
                selectedTuple = sorted[0]
                matchedRules.append("显式档位路由 [\(explicitTier.displayName)] 尚未指定模型，按档位偏好评分选中「\(selectedTuple.0.displayName)」")
                reasonNote = "按 \(explicitTier.shortName) 档位偏好评分 + effort=\(targetEffort.rawValue)"
            }
        } else if let pinnedID = context.policy.pinnedModelID,
                  let pinnedTuple = sorted.first(where: { $0.0.id == pinnedID }) {
            selectedTuple = pinnedTuple
            matchedRules.append("命中固定模型规则: 用户已固定「\(pinnedTuple.0.displayName)」")
            reasonNote = "命中用户固定模型规则「\(pinnedTuple.0.displayName)」· effort=\(targetEffort.rawValue)"
        } else if context.policy.enableSessionStickiness,
                  (context.features.isMultiTurn || context.qualityFailureCount > 0),
                  let stickyTuple,
                  !stickyNeedsTierUpgrade,
                  !stickyNeedsEscalateToReasoning,
                  !stickyNeedsToolRescue,
                  !stickyShouldDowngrade {
            selectedTuple = stickyTuple
            effectiveTier = stickyTier ?? effectiveTier
            matchedRules.append("命中多轮会话粘性: 保持与同会话上一轮一致的「\(stickyTuple.0.displayName)」以保留缓存收益")
            if canIncreaseEffort {
                matchedRules.append("必需工具调用缺失：保留同一模型，思考强度提高至 \(targetEffort.rawValue)")
                reasonNote = "必需工具调用缺失，同模型提高思考强度至 \(targetEffort.rawValue)"
            } else {
                reasonNote = wantsRescue && rescueTier == nil
                    ? "必需工具调用缺失，但相邻高档不可用或已到最高档，保留当前模型"
                    : canSwitchPhase
                    ? "保持会话缓存稳定 (粘性) · \(subtask.displayName) · effort=\(targetEffort.rawValue)"
                    : "工具或上游状态续接，保留同一模型 · effort=\(targetEffort.rawValue)"
            }
        } else {
            let stickyWasEscalated = context.policy.enableSessionStickiness
                && context.features.isMultiTurn && stickyTuple != nil
                && (stickyNeedsTierUpgrade || stickyNeedsEscalateToReasoning || stickyNeedsToolRescue)

            if context.policy.preferTierMappingInAuto, let resolved = resolvedTierCandidate {
                let tierTuple = resolved.tuple
                selectedTuple = tierTuple
                let isPrimary = tierTuple.0.id == tierPoolIDs.first
                if resolved.viaSameModelGroup {
                    matchedRules.append("三档路由命中 [\(targetTier.displayName)]：主通道不可用，同模型自动分组切换至「\(tierTuple.1.name) / \(tierTuple.0.displayName)」")
                } else {
                    matchedRules.append("三档路由命中 [\(targetTier.displayName)]：任务「\(subtask.displayName)」(effort=\(targetEffort.rawValue)) + 策略「\(context.policy.activeStrategy.displayName)」-> 选用\(targetTier.shortName)\(isPrimary ? "" : "备选")模型「\(tierTuple.0.displayName)」")
                }
                if stickyShouldDowngrade {
                    reasonNote = clearLightTask ? "新一轮轻量任务，降档至「\(tierTuple.0.displayName)」" : "连续常规任务，降档至「\(tierTuple.0.displayName)」"
                    matchedRules.append(clearLightTask ? "用户新一轮轻量任务：切换至\(targetTier.shortName)" : "防抖降档：连续 \(context.consecutiveRoutineTurns) 轮常规任务，切换至\(targetTier.shortName)")
                } else if stickyNeedsToolRescue {
                    reasonNote = "连续无有效工具调用/空转，自动升档破局至「\(tierTuple.0.displayName)」"
                    matchedRules.append("语义软升级：检测到前序轮次工具调用空转，自动升至「\(tierTuple.0.displayName)」")
                } else if stickyWasEscalated {
                    reasonNote = "子任务升级为「\(subtask.displayName)」(effort=\(targetEffort.rawValue))，切换至\(targetTier.shortName)模型"
                } else {
                    reasonNote = "识别「\(subtask.displayName)」+ effort=\(targetEffort.rawValue)，命中\(targetTier.shortName)\(isPrimary ? "" : "备选")模型"
                }
            } else if context.policy.preferTierMappingInAuto,
                      let tierModelID = context.policy.modelID(for: targetTier),
                      let blockedModel = context.models.first(where: { $0.id == tierModelID }) {
                if let controlledFallback = selectControlledFallback(
                    for: targetTier,
                    policy: context.policy,
                    sorted: sorted,
                    enforceStrictTierPool: enforceStrictTierPool
                ) {
                    selectedTuple = controlledFallback.tuple
                    matchedRules.append("目标档位 [\(targetTier.shortName)] 的模型「\(blockedModel.displayName)」未满足本请求硬约束，\(controlledFallback.ruleDescription)「\(selectedTuple.0.displayName)」")
                    reasonNote = "「\(subtask.displayName)」(effort=\(targetEffort.rawValue)) 改用受控回退候选"
                } else {
                    let ms = elapsedMs(since: startTime)
                    let msg = "严格三档池模式下，目标档位「\(targetTier.displayName)」及允许回退池内暂无满足当前硬约束的可用模型。"
                    return RoutingDecision(
                        requestedModel: context.requestedModel,
                        isAutoRouted: true,
                        candidateEvaluations: evaluations,
                        matchedRules: matchedRules + ["严格三档池过滤后无可用档位模型"],
                        strategyName: strategyLabel,
                        policyVersion: context.policy.policyVersion,
                        deciderPluginID: pluginID,
                        decisionDurationMs: ms,
                        errorSummary: msg,
                        selectedEffort: targetEffort,
                        subtaskCategory: subtask,
                        routingReasonNote: msg
                    )
                }
            } else {
                if enforceStrictTierPool {
                    if let strictFirst = sorted.first(where: { configuredTierIDSet.contains($0.0.id) || $0.0.id == context.policy.fallbackModelID }) {
                        selectedTuple = strictFirst
                    } else {
                        let ms = elapsedMs(since: startTime)
                        let msg = "严格三档池模式下，已配置三档及兜底模型均不满足当前硬约束。"
                        return RoutingDecision(
                            requestedModel: context.requestedModel,
                            isAutoRouted: true,
                            candidateEvaluations: evaluations,
                            matchedRules: matchedRules + ["严格三档池内无可用模型"],
                            strategyName: strategyLabel,
                            policyVersion: context.policy.policyVersion,
                            deciderPluginID: pluginID,
                            decisionDurationMs: ms,
                            errorSummary: msg,
                            selectedEffort: targetEffort,
                            subtaskCategory: subtask,
                            routingReasonNote: msg
                        )
                    }
                }
                matchedRules.append("综合评分最高: 「\(selectedTuple.0.displayName)」(\(String(format: "%.1f", selectedTuple.2)) 分)")
                reasonNote = stickyWasEscalated
                    ? "子任务升级为「\(subtask.displayName)」(effort=\(targetEffort.rawValue))，经推理能力筛选切换"
                    : "「\(subtask.displayName)」+ effort=\(targetEffort.rawValue) 综合评分最高"
            }
        }

        // Build ordered fallback candidate IDs:
        // 0. Same-canonical-model healthy channels across other providers (when enableAutoSameModelGrouping is on)
        // 1. Same-tier backup models (prefer same provider for prompt-cache continuity)
        // 2. Explicit global fallback model
        // 3. Adjacent configured tiers' primary+backup pools
        // 4. Remaining healthy candidates (omitted when strictThreeTierPoolOnly is enabled)
        var fallbackIDs: [UUID] = []
        let activeProviderID = selectedTuple.1.id
        let selectedCanonicalID = CanonicalModelNormalizer.canonicalID(for: selectedTuple.0)
        if context.policy.enableAutoSameModelGrouping, !selectedCanonicalID.isEmpty {
            let sameGroupPeers = sorted
                .filter {
                    $0.0.id != selectedTuple.0.id
                        && CanonicalModelNormalizer.canonicalID(for: $0.0) == selectedCanonicalID
                }
                .sorted { lhs, rhs in
                    let lLat = lhs.0.lastProbeLatencyMs ?? .greatestFiniteMagnitude
                    let rLat = rhs.0.lastProbeLatencyMs ?? .greatestFiniteMagnitude
                    if lLat != rLat { return lLat < rLat }
                    return lhs.2 > rhs.2
                }
            for peer in sameGroupPeers where !fallbackIDs.contains(peer.0.id) {
                fallbackIDs.append(peer.0.id)
            }
            if !sameGroupPeers.isEmpty {
                matchedRules.append("同模型自动分组「\(selectedCanonicalID)」已挂载 \(sameGroupPeers.count + 1) 个可用通道")
            }
        }
        if context.policy.preferTierMappingInAuto || explicitTier != nil {
            let sameTierBackups = context.policy.modelIDs(for: effectiveTier)
                .filter { $0 != selectedTuple.0.id }
                .compactMap { tid in sorted.first(where: { $0.0.id == tid }) }
                .sorted { lhs, rhs in
                    let lSame = lhs.1.id == activeProviderID
                    let rSame = rhs.1.id == activeProviderID
                    if lSame != rSame { return lSame }
                    return false
                }
            for candidate in sameTierBackups where !fallbackIDs.contains(candidate.0.id) {
                fallbackIDs.append(candidate.0.id)
            }
        }
        if let configuredFallbackID = context.policy.fallbackModelID,
           configuredFallbackID != selectedTuple.0.id,
           !fallbackIDs.contains(configuredFallbackID),
           sorted.contains(where: { $0.0.id == configuredFallbackID }) {
            fallbackIDs.append(configuredFallbackID)
        }
        if context.policy.preferTierMappingInAuto || explicitTier != nil {
            for tier in Self.orderedAdjacentTiers(for: effectiveTier) {
                for tid in context.policy.modelIDs(for: tier) where tid != selectedTuple.0.id && !fallbackIDs.contains(tid) {
                    if sorted.contains(where: { $0.0.id == tid }) {
                        fallbackIDs.append(tid)
                    }
                }
            }
        }
        if !enforceStrictTierPool {
            for item in sorted where item.0.id != selectedTuple.0.id && !fallbackIDs.contains(item.0.id) {
                fallbackIDs.append(item.0.id)
            }
        } else {
            matchedRules.append("已开启「严格仅限三档及备选」，回退队列不越界选用其他模型")
        }

        let ms = elapsedMs(since: startTime)

        return RoutingDecision(
            requestedModel: context.requestedModel,
            isAutoRouted: true,
            selectedModelUUID: selectedTuple.0.id,
            selectedModelID: selectedTuple.0.modelID,
            selectedDisplayName: selectedTuple.0.displayName,
            selectedProviderID: selectedTuple.1.id,
            selectedProviderName: selectedTuple.1.name,
            orderedFallbackCandidateIDs: fallbackIDs,
            candidateEvaluations: evaluations,
            matchedRules: matchedRules,
            strategyName: strategyLabel,
            policyVersion: context.policy.policyVersion,
            deciderPluginID: pluginID,
            decisionDurationMs: ms,
            selectedEffort: targetEffort,
            subtaskCategory: subtask,
            routingReasonNote: reasonNote,
            canonicalGroupID: context.policy.enableAutoSameModelGrouping && !selectedCanonicalID.isEmpty ? selectedCanonicalID : nil
        )
    }

    private static func resolveTierCandidate(
        poolIDs: [UUID],
        sorted: [(ModelConfig, ProviderConfig, Double, [String])],
        allModels: [ModelConfig],
        enableSameModelGrouping: Bool
    ) -> (tuple: (ModelConfig, ProviderConfig, Double, [String]), viaSameModelGroup: Bool)? {
        for tid in poolIDs {
            if let direct = sorted.first(where: { $0.0.id == tid }) {
                return (direct, false)
            }
            if enableSameModelGrouping,
               let targetModel = allModels.first(where: { $0.id == tid }) {
                let canonical = CanonicalModelNormalizer.canonicalID(for: targetModel)
                if !canonical.isEmpty {
                    let peers = sorted
                        .filter { CanonicalModelNormalizer.canonicalID(for: $0.0) == canonical }
                        .sorted { lhs, rhs in
                            let lLat = lhs.0.lastProbeLatencyMs ?? .greatestFiniteMagnitude
                            let rLat = rhs.0.lastProbeLatencyMs ?? .greatestFiniteMagnitude
                            if lLat != rLat { return lLat < rLat }
                            return lhs.2 > rhs.2
                        }
                    if let peer = peers.first {
                        return (peer, true)
                    }
                }
            }
        }
        return nil
    }

    private static func orderedAdjacentTiers(for tier: ModelTier) -> [ModelTier] {
        switch tier {
        case .high: return [.medium, .low]
        case .medium: return [.high, .low]
        case .low: return [.medium, .high]
        }
    }

    private func selectControlledFallback(
        for tier: ModelTier,
        policy: RoutingPolicyConfig,
        sorted: [(ModelConfig, ProviderConfig, Double, [String])],
        enforceStrictTierPool: Bool
    ) -> (tuple: (ModelConfig, ProviderConfig, Double, [String]), ruleDescription: String)? {
        if let fallbackID = policy.fallbackModelID,
           let fallbackTuple = sorted.first(where: { $0.0.id == fallbackID }) {
            return (fallbackTuple, "已改用全局兜底模型")
        }
        for adjacentTier in Self.orderedAdjacentTiers(for: tier) {
            if let peerTuple = policy.modelIDs(for: adjacentTier)
                .compactMap({ pid in sorted.first(where: { $0.0.id == pid }) })
                .first {
                return (peerTuple, "已按受控相邻档位 [\(adjacentTier.shortName)] 改用")
            }
        }
        if !enforceStrictTierPool, let firstSorted = sorted.first {
            return (firstSorted, "已按综合评分自动回退至")
        }
        return nil
    }

    public static func resolvedEffort(
        recommended: ReasoningEffort,
        explicitTier: ModelTier?,
        strategy: RoutingStrategyPreset
    ) -> ReasoningEffort {
        if let explicitTier {
            switch explicitTier {
            case .low: return .low
            case .medium: return .medium
            case .high: return recommended == .max ? .max : .high
            }
        }
        switch strategy {
        case .costFirst:
            return (recommended == .low) ? .low : .medium
        case .balanced:
            return recommended
        case .qualityFirst:
            if recommended == .low { return .medium }
            return recommended
        }
    }

    public static func targetTierForAuto(
        task: TaskIntentType,
        subtask: AgentSubtaskCategory? = nil,
        effort: ReasoningEffort? = nil,
        strategy: RoutingStrategyPreset
    ) -> ModelTier {
        if let effort {
            switch strategy {
            case .costFirst:
                return .low
            case .balanced:
                // Let subtask category govern the tier so routine/review/tool-recovery steps
                // can boost reasoning effort on Medium tier without needlessly escalating to High flagship.
                if let subtask { return subtask.recommendedTier }
                if effort.requiresDeepReasoning { return .high }
            case .qualityFirst:
                if effort == .low { return .medium }
                return .high
            }
        }
        switch strategy {
        case .costFirst:
            return .low
        case .balanced:
            switch task {
            case .simpleQA, .generalChat, .coding, .toolCalling, .visionMultimodal, .longContext:
                return .medium
            case .complexReasoning:
                return .high
            }
        case .qualityFirst:
            switch task {
            case .simpleQA:
                return .medium
            case .generalChat, .coding, .toolCalling, .visionMultimodal, .complexReasoning, .longContext:
                return .high
            }
        }
    }

    private func evaluateHardConstraints(
        model: ModelConfig,
        provider: ProviderConfig?,
        features: RequestFeatures,
        policy: RoutingPolicyConfig,
        ignorePriceCap: Bool,
        runtimeMetrics: ModelRuntimeMetrics? = nil
    ) -> CandidateEvaluation {
        var exclusions: [String] = []

        guard let provider else {
            exclusions.append("所属供应商不存在")
            return CandidateEvaluation(
                modelUUID: model.id,
                modelID: model.modelID,
                displayName: model.displayName,
                providerID: model.providerID,
                providerName: "未知供应商",
                passedHardConstraints: false,
                exclusionReasons: exclusions
            )
        }

        if !provider.isEnabled {
            exclusions.append("供应商「\(provider.name)」已禁用")
        }
        if provider.healthStatus == .authError || provider.healthStatus == .networkError {
            let detail = provider.lastErrorMessage.map { "：\($0)" } ?? ""
            exclusions.append("所属供应商「\(provider.name)」当前不可达或鉴权失败（\(provider.healthStatus.displayName)）\(detail)")
        }
        if !model.isEnabled {
            exclusions.append("模型已被用户禁用")
        }
        if model.isAutoEvicted || model.availabilityStatus != .available {
            let note = model.lastAvailabilityNote.map { "：\($0)" } ?? ""
            if model.isAutoEvicted {
                exclusions.append("已被自动测活剔除（\(model.availabilityStatus.displayName)）\(note)")
            } else {
                exclusions.append("模型状态为「\(model.availabilityStatus.displayName)」\(note)")
            }
        }
        if let cooldownUntil = runtimeMetrics?.cooldownUntil, cooldownUntil > Date() {
            let secs = max(1, Int(ceil(cooldownUntil.timeIntervalSinceNow)))
            exclusions.append("处于瞬时限流/抖动短暂冷却中（约 \(secs)s 后自动恢复）")
        }
        if features.requiresTools && !model.capabilities.contains(.tools) {
            exclusions.append("请求包含 tools，但模型未配置工具调用能力")
        }
        if features.requiresVision && !model.capabilities.contains(.vision) {
            exclusions.append("请求包含图像内容，但模型未配置视觉能力")
        }
        if features.estimatedInputTokens > model.contextWindow {
            let uncertaintyRatio = features.tokenEstimateConfidence == .low ? 0.15 : 0.08
            let uncertaintySlack = max(256, Int(Double(model.contextWindow) * uncertaintyRatio))
            if features.estimatedInputTokens > model.contextWindow + uncertaintySlack {
                exclusions.append("估算输入 \(features.estimatedInputTokens) tokens 明确超过上下文上限 \(model.contextWindow)（含 \(Int(uncertaintyRatio * 100))% 估算缓冲）")
            }
        }

        if !ignorePriceCap {
            if let maxIn = policy.maxInputPricePerMillion {
                if let inPrice = model.inputPricePerMillion {
                    if inPrice > maxIn {
                        exclusions.append(String(format: "输入单价 $%.2f/M 超过上限 $%.2f/M", inPrice, maxIn))
                    }
                } else {
                    exclusions.append("已设置输入价格上限，但模型未配置价格")
                }
            }
            if let maxOut = policy.maxOutputPricePerMillion {
                if let outPrice = model.outputPricePerMillion {
                    if outPrice > maxOut {
                        exclusions.append(String(format: "输出单价 $%.2f/M 超过上限 $%.2f/M", outPrice, maxOut))
                    }
                } else {
                    exclusions.append("已设置输出价格上限，但模型未配置价格")
                }
            }
        }

        return CandidateEvaluation(
            modelUUID: model.id,
            modelID: model.modelID,
            displayName: model.displayName,
            providerID: provider.id,
            providerName: provider.name,
            passedHardConstraints: exclusions.isEmpty,
            exclusionReasons: exclusions
        )
    }

    private func scoreCandidate(
        model: ModelConfig,
        features: RequestFeatures,
        strategy: RoutingStrategyPreset,
        targetEffort: ReasoningEffort = .medium,
        runtimeMetrics: ModelRuntimeMetrics? = nil,
        preferredProviderID: UUID? = nil
    ) -> (Double, [String]) {
        var breakdown: [String] = []
        var quality = Double(model.qualityScore)
        if let metrics = runtimeMetrics, metrics.sampleCount >= 2 {
            // Adjust quality slightly based on observed reliability
            let reliabilityShift = (metrics.successRate - 0.85) * 20.0
            quality = min(100.0, max(1.0, quality + reliabilityShift))
        }
        let speed: Double
        if let metrics = runtimeMetrics, metrics.sampleCount >= 2 {
            let observedSpeed = min(100.0, max(10.0, 100.0 - metrics.averageLatencyMs / 65.0))
            speed = Double(model.speedScore) * 0.4 + observedSpeed * 0.6
        } else if let probeMs = model.lastProbeLatencyMs {
            let measuredSpeed = min(100.0, max(10.0, 100.0 - probeMs / 45.0))
            speed = Double(model.speedScore) * 0.5 + measuredSpeed * 0.5
        } else {
            speed = Double(model.speedScore)
        }

        let costScore: Double
        let configuredCost = model.blendedPricePerMillion
        let observedCost = runtimeMetrics.flatMap { metrics in
            metrics.sampleCount >= 2 ? metrics.averageCostPerMillionTokens : nil
        }
        if let blended = observedCost ?? configuredCost {
            // Once two measured samples exist, the real unit cost wins over a
            // stale catalog price. A missing price remains explicitly unknown.
            costScore = 100.0 / (1.0 + max(0.0, blended) * 0.5)
            if let observedCost {
                breakdown.append(String(format: "成本分 %.1f (近况实测 $%.2f/M)", costScore, observedCost))
            } else {
                breakdown.append(String(format: "成本分 %.1f (配置单价 $%.2f/M)", costScore, blended))
            }
        } else {
            // Unpriced models get a conservative cost score so known-priced models are preferred in costFirst
            switch model.defaultRole {
            case .fastEconomy: costScore = 25.0
            case .general: costScore = 12.0
            case .coding, .vision: costScore = 10.0
            case .complexReasoning: costScore = 5.0
            }
            breakdown.append(String(format: "成本分 %.1f (未配置单价，按默认用途「%@」保守排序)", costScore, model.defaultRole.displayName))
        }

        let taskFitScore = taskAffinityBonus(model: model, task: features.detectedTaskType)
        breakdown.append(String(format: "任务匹配 %.1f (%@)", taskFitScore, features.detectedTaskType.displayName))
        if let probeMs = model.lastProbeLatencyMs {
            breakdown.append(String(format: "质量分 %.0f / 速度分 %.0f (实测测活 %.0f ms)", quality, speed, probeMs))
        } else {
            breakdown.append(String(format: "质量分 %.0f / 速度分 %.0f", quality, speed))
        }

        var totalScore: Double
        switch strategy {
        case .costFirst:
            // Prioritize low price strongly, with light tie-breaking by speed and task fit
            totalScore = costScore * 0.68 + speed * 0.16 + taskFitScore * 0.10 + quality * 0.06
        case .balanced:
            totalScore = costScore * 0.30 + quality * 0.32 + speed * 0.18 + taskFitScore * 0.20
        case .qualityFirst:
            totalScore = quality * 0.62 + taskFitScore * 0.26 + speed * 0.08 + costScore * 0.04
        }

        // Effort-aware refinement bonus/filtering weight
        switch targetEffort {
        case .low:
            if model.speedScore >= 80 || model.defaultRole == .fastEconomy {
                totalScore += 6.0
                breakdown.append("Effort[low] 加分 +6.0 (极速响应)")
            }
        case .medium:
            if model.capabilities.contains(.coding) || model.capabilities.contains(.tools) {
                totalScore += 3.0
            }
        case .high, .max:
            if model.capabilities.contains(.reasoning) || model.defaultRole == .complexReasoning {
                let boost = (targetEffort == .max) ? 18.0 : 12.0
                totalScore += boost
                breakdown.append(String(format: "Effort[%@] 加分 +%.0f (具备深度推理能力)", targetEffort.rawValue, boost))
            } else if strategy != .costFirst {
                totalScore -= 8.0
                breakdown.append("Effort[\(targetEffort.rawValue)] 降权 -8.0 (非推理主力模型)")
            }
        }

        if let preferredProviderID, model.providerID == preferredProviderID {
            totalScore += 18.0
            breakdown.append("同供应商缓存亲和 +18.0")
        }

        return (totalScore, breakdown)
    }

    private func taskAffinityBonus(model: ModelConfig, task: TaskIntentType) -> Double {
        var score = 50.0
        switch task {
        case .simpleQA:
            if model.defaultRole == .fastEconomy { score += 45 }
            else if model.defaultRole == .general { score += 30 }
        case .generalChat:
            if model.defaultRole == .general { score += 40 }
            else if model.defaultRole == .fastEconomy { score += 25 }
        case .coding:
            if model.defaultRole == .coding { score += 40 }
            if model.capabilities.contains(.coding) { score += 20 }
        case .complexReasoning:
            if model.defaultRole == .complexReasoning { score += 40 }
            if model.capabilities.contains(.reasoning) { score += 20 }
        case .toolCalling:
            if model.capabilities.contains(.tools) { score += 30 }
            if model.defaultRole == .coding || model.defaultRole == .general { score += 15 }
        case .visionMultimodal:
            if model.capabilities.contains(.vision) { score += 40 }
            if model.defaultRole == .vision { score += 15 }
        case .longContext:
            if model.contextWindow >= 128_000 { score += 35 }
            else if model.contextWindow >= 32_000 { score += 20 }
        }
        return min(100.0, score)
    }

    private func elapsedMs(since start: DispatchTime) -> Double {
        let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000.0
    }
}

// MARK: - Router Coordinator (with Session Stickiness Cache & Plugin Registry)

public final class ModelRouter: @unchecked Sendable {
    private struct SessionStickinessKey: Hashable {
        var fingerprint: String
        var modeKey: String
    }

    private struct SessionStickinessState {
        var modelUUID: UUID
        var policyVersion: Int
        var consecutiveRoutineTurns: Int
        var qualityFailureCount: Int
        var lastFailureEffort: ReasoningEffort?
        var qualityRecoveryKey: String?
        var wasMultiTurn: Bool
        var lastAccessedAt: Date
    }

    private static let stickinessTTLSeconds: TimeInterval = 7200
    private static let maxStickinessEntries = 500

    private let lock = NSLock()
    private var sessionStickinessMap: [SessionStickinessKey: SessionStickinessState] = [:]
    private var plugins: [String: any RoutingDeciderPlugin] = [:]

    public init(plugins: [any RoutingDeciderPlugin] = [DeterministicLocalDeciderPlugin()]) {
        for plugin in plugins {
            self.plugins[plugin.pluginID] = plugin
        }
    }

    public func registerPlugin(_ plugin: any RoutingDeciderPlugin) {
        lock.lock()
        defer { lock.unlock() }
        plugins[plugin.pluginID] = plugin
    }

    public func availablePlugins() -> [any RoutingDeciderPlugin] {
        lock.lock()
        defer { lock.unlock() }
        return Array(plugins.values).sorted { $0.pluginID < $1.pluginID }
    }

    private static func stickinessModeKey(requestedModel: String, explicitTier: ModelTier? = nil) -> String {
        if let tier = explicitTier ?? ModelTier.matchExplicitTier(requestedModel: requestedModel) {
            return "tier:\(tier.rawValue)"
        }
        return "auto"
    }

    private func pruneStickinessLocked(now: Date) {
        sessionStickinessMap = sessionStickinessMap.filter {
            now.timeIntervalSince($0.value.lastAccessedAt) <= Self.stickinessTTLSeconds
        }
        if sessionStickinessMap.count > Self.maxStickinessEntries {
            let overflow = sessionStickinessMap.count - Self.maxStickinessEntries
            let oldestKeys = sessionStickinessMap
                .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
                .prefix(overflow)
                .map(\.key)
            for key in oldestKeys {
                sessionStickinessMap.removeValue(forKey: key)
            }
        }
    }

    public func route(
        requestedModel: String,
        features: RequestFeatures,
        providers: [ProviderConfig],
        models: [ModelConfig],
        policy: RoutingPolicyConfig,
        runtimeMetricsByModelID: [UUID: ModelRuntimeMetrics] = [:],
        stickinessNamespace: String? = nil,
        qualityRecoveryKey: String? = nil
    ) -> RoutingDecision {
        let baseModeKey = Self.stickinessModeKey(requestedModel: requestedModel)
        let modeKey = stickinessNamespace.map { "agent:\($0)|\(baseModeKey)" } ?? baseModeKey
        let now = Date()
        let sessionSnapshot: (stickyID: UUID?, routineCount: Int, failures: Int, failedEffort: ReasoningEffort?) = lock.withLock {
            pruneStickinessLocked(now: now)
            guard policy.enableSessionStickiness,
                  let fp = features.conversationFingerprint else {
                return (nil, 0, 0, nil)
            }
            let key = SessionStickinessKey(fingerprint: fp, modeKey: modeKey)
            guard var cached = sessionStickinessMap[key],
                  cached.policyVersion == policy.policyVersion else {
                return (nil, 0, 0, nil)
            }
            let matchesFailure = qualityRecoveryKey != nil && qualityRecoveryKey == cached.qualityRecoveryKey
            if !matchesFailure && features.isUserTurnBoundary != false {
                cached.qualityFailureCount = 0
                cached.lastFailureEffort = nil
                cached.qualityRecoveryKey = nil
                sessionStickinessMap[key] = cached
            }
            guard features.isMultiTurn || matchesFailure else { return (nil, 0, 0, nil) }
            let isRoutineBoundary = features.isUserTurnBoundary != false
                && features.subtaskCategory.recommendedTier != .high
            let routineCount = isRoutineBoundary ? (cached.consecutiveRoutineTurns + 1) : 0
            cached.lastAccessedAt = now
            sessionStickinessMap[key] = cached
            return (cached.modelUUID, routineCount, matchesFailure ? cached.qualityFailureCount : 0,
                    matchesFailure ? cached.lastFailureEffort : nil)
        }

        let decider: any RoutingDeciderPlugin = lock.withLock {
            plugins[policy.activeDeciderPluginID] ?? DeterministicLocalDeciderPlugin()
        }

        let context = RoutingContext(
            requestedModel: requestedModel,
            features: features,
            providers: providers,
            models: models,
            policy: policy,
            stickyModelID: sessionSnapshot.stickyID,
            consecutiveRoutineTurns: sessionSnapshot.routineCount,
            escalateNextTurn: sessionSnapshot.failures > 0,
            qualityFailureCount: sessionSnapshot.failures,
            lastFailureEffort: sessionSnapshot.failedEffort,
            runtimeMetricsByModelID: runtimeMetricsByModelID
        )

        return decider.decide(context: context)
    }

    public func recordSuccessfulSessionModel(
        fingerprint: String?,
        modelUUID: UUID,
        policyVersion: Int,
        isRoutineSubtask: Bool = false,
        wasToolStarved: Bool = false,
        selectedEffort: ReasoningEffort = .medium,
        qualityRecoveryKey: String? = nil,
        requestedModel: String = "auto",
        explicitTier: ModelTier? = nil,
        isMultiTurn: Bool = true,
        stickinessNamespace: String? = nil,
        isUserTurnBoundary: Bool = true
    ) {
        guard let fingerprint, !fingerprint.isEmpty else { return }
        let baseModeKey = Self.stickinessModeKey(requestedModel: requestedModel, explicitTier: explicitTier)
        let modeKey = stickinessNamespace.map { "agent:\($0)|\(baseModeKey)" } ?? baseModeKey
        let key = SessionStickinessKey(fingerprint: fingerprint, modeKey: modeKey)
        let now = Date()
        lock.withLock {
            let prev = sessionStickinessMap[key]
            // Never let a stray single-turn sidecar/background call hijack an active multi-turn sticky session
            if !isMultiTurn,
               let prev,
               prev.policyVersion == policyVersion,
               prev.wasMultiTurn,
               prev.modelUUID != modelUUID {
                return
            }
            let sameModel = prev?.modelUUID == modelUUID && prev?.policyVersion == policyVersion
            var routineCount = sameModel ? (prev?.consecutiveRoutineTurns ?? 0) : 0
            if isUserTurnBoundary {
                routineCount = isRoutineSubtask && sameModel ? min(2, routineCount + 1) : 0
            }
            let nextWasMultiTurn = isMultiTurn || (sameModel && (prev?.wasMultiTurn ?? false))
            sessionStickinessMap[key] = SessionStickinessState(
                modelUUID: modelUUID,
                policyVersion: policyVersion,
                consecutiveRoutineTurns: routineCount,
                qualityFailureCount: wasToolStarved && qualityRecoveryKey != nil
                    ? min(2, (prev?.policyVersion == policyVersion && prev?.qualityRecoveryKey == qualityRecoveryKey ? (prev?.qualityFailureCount ?? 0) : 0) + 1) : 0,
                lastFailureEffort: wasToolStarved && qualityRecoveryKey != nil ? selectedEffort : nil,
                qualityRecoveryKey: wasToolStarved ? qualityRecoveryKey : nil,
                wasMultiTurn: nextWasMultiTurn,
                lastAccessedAt: now
            )
            pruneStickinessLocked(now: now)
        }
    }

    public func clearSessionStickiness() {
        lock.withLock {
            sessionStickinessMap.removeAll()
        }
    }
}
