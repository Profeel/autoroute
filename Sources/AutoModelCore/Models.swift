import Foundation

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Provider & Model Configuration

public enum ProviderHealthStatus: String, Codable, CaseIterable, Sendable {
    case unknown
    case checking
    case healthy
    case authError
    case networkError
    case serverError

    public var displayName: String {
        switch self {
        case .unknown: return "未测试"
        case .checking: return "检测中"
        case .healthy: return "连接正常"
        case .authError: return "密钥错误"
        case .networkError: return "无网络/不可达"
        case .serverError: return "上游异常"
        }
    }
}

public enum ProviderProtocol: String, Codable, CaseIterable, Hashable, Sendable {
    case openAIChatCompletions = "openai_chat"
    case openAIResponses = "openai_responses"
    case codexChatGPT = "codex_chatgpt"
    case anthropicMessages = "anthropic_messages"
    case workBuddy = "workbuddy"

    public var displayName: String {
        switch self {
        case .openAIChatCompletions: return "OpenAI Chat"
        case .openAIResponses: return "OpenAI Responses"
        case .codexChatGPT: return "Codex 订阅 (ChatGPT)"
        case .anthropicMessages: return "Anthropic Messages"
        case .workBuddy: return "WorkBuddy API Key"
        }
    }
}

public enum ProviderKeyRotationStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    case roundRobin = "round_robin"
    case priorityFailover = "priority_failover"

    public var displayName: String {
        switch self {
        case .roundRobin: return "轮询均衡"
        case .priorityFailover: return "主备顺延"
        }
    }
}

/// OpenAI-compatible or local agent subscription provider configuration.
/// Deliberately omits `apiKey` from Codable storage; keys live strictly in Keychain.
public struct ProviderConfig: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var isEnabled: Bool
    public var timeoutSeconds: Double
    public var healthStatus: ProviderHealthStatus
    public var lastErrorMessage: String?
    public var lastCheckedAt: Date?
    public var createdAt: Date
    public var discoveredSource: String?
    public var apiProtocol: ProviderProtocol
    public var accountID: String?
    /// Optional per-provider concurrency cap; nil means unlimited.
    public var maxConcurrentRequests: Int?
    /// Optional built-in preset identifier (e.g. "deepseek", "anthropic", "openrouter").
    public var presetID: String?
    /// Custom upstream HTTP headers added on every request (non-secret metadata or gateway routing headers).
    public var customHeaders: [String: String]
    /// Client request header names allowed to pass through to upstream (e.g. "X-Session-Id").
    public var passThroughHeaderNames: [String]
    /// Optional per-provider HTTP/HTTPS/SOCKS5 proxy URL (e.g. "http://127.0.0.1:7890").
    public var proxyURL: String?
    /// Key rotation strategy when multiple API keys are stored in Keychain for this provider.
    public var keyRotationStrategy: ProviderKeyRotationStrategy
    /// Non-sensitive count of keys configured in Keychain (allows UI badges without background Keychain reads).
    public var configuredKeyCount: Int
    /// Non-sensitive metadata summaries for Codex/ChatGPT subscription accounts in this provider's pool.
    public var subscriptionAccounts: [CodexAccountSummary]
    /// Human-readable discovery origin label (e.g. "本机发现 ~/.antigravity").
    public var discoverySourceLabel: String?
    /// Whether this provider was discovered automatically from local configuration.
    public var isAutoDiscovered: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, isEnabled, timeoutSeconds, healthStatus, lastErrorMessage, lastCheckedAt, createdAt, discoveredSource, apiProtocol, accountID, maxConcurrentRequests
        case presetID, customHeaders, passThroughHeaderNames, proxyURL, keyRotationStrategy, configuredKeyCount, subscriptionAccounts
        case discoverySourceLabel, isAutoDiscovered
    }

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        isEnabled: Bool = true,
        timeoutSeconds: Double = 60.0,
        healthStatus: ProviderHealthStatus = .unknown,
        lastErrorMessage: String? = nil,
        lastCheckedAt: Date? = nil,
        createdAt: Date = Date(),
        discoveredSource: String? = nil,
        apiProtocol: ProviderProtocol = .openAIChatCompletions,
        accountID: String? = nil,
        maxConcurrentRequests: Int? = nil,
        presetID: String? = nil,
        customHeaders: [String: String] = [:],
        passThroughHeaderNames: [String] = [],
        proxyURL: String? = nil,
        keyRotationStrategy: ProviderKeyRotationStrategy = .roundRobin,
        configuredKeyCount: Int = 0,
        subscriptionAccounts: [CodexAccountSummary] = [],
        discoverySourceLabel: String? = nil,
        isAutoDiscovered: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.isEnabled = isEnabled
        self.timeoutSeconds = timeoutSeconds
        self.healthStatus = healthStatus
        self.lastErrorMessage = lastErrorMessage
        self.lastCheckedAt = lastCheckedAt
        self.createdAt = createdAt
        self.discoveredSource = discoveredSource
        self.apiProtocol = apiProtocol
        self.accountID = accountID
        self.maxConcurrentRequests = maxConcurrentRequests.flatMap { $0 > 0 ? $0 : nil }
        self.presetID = presetID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.customHeaders = customHeaders
        self.passThroughHeaderNames = passThroughHeaderNames
        self.proxyURL = proxyURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.keyRotationStrategy = keyRotationStrategy
        self.configuredKeyCount = max(0, configuredKeyCount)
        self.subscriptionAccounts = subscriptionAccounts
        self.discoverySourceLabel = discoverySourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.isAutoDiscovered = isAutoDiscovered
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 60.0
        healthStatus = try c.decodeIfPresent(ProviderHealthStatus.self, forKey: .healthStatus) ?? .unknown
        lastErrorMessage = try c.decodeIfPresent(String.self, forKey: .lastErrorMessage)
        lastCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        discoveredSource = try c.decodeIfPresent(String.self, forKey: .discoveredSource)
        apiProtocol = try c.decodeIfPresent(ProviderProtocol.self, forKey: .apiProtocol) ?? .openAIChatCompletions
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
        let rawMaxConc = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentRequests)
        maxConcurrentRequests = rawMaxConc.flatMap { $0 > 0 ? $0 : nil }
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        customHeaders = try c.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        passThroughHeaderNames = try c.decodeIfPresent([String].self, forKey: .passThroughHeaderNames) ?? []
        proxyURL = try c.decodeIfPresent(String.self, forKey: .proxyURL)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        keyRotationStrategy = try c.decodeIfPresent(ProviderKeyRotationStrategy.self, forKey: .keyRotationStrategy) ?? .roundRobin
        configuredKeyCount = max(0, try c.decodeIfPresent(Int.self, forKey: .configuredKeyCount) ?? 0)
        subscriptionAccounts = try c.decodeIfPresent([CodexAccountSummary].self, forKey: .subscriptionAccounts) ?? []
        discoverySourceLabel = try c.decodeIfPresent(String.self, forKey: .discoverySourceLabel)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        isAutoDiscovered = try c.decodeIfPresent(Bool.self, forKey: .isAutoDiscovered) ?? false
    }

    /// Normalized base URL without trailing slash or trailing `/v1` duplication.
    public var normalizedBaseURL: String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/v1") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed
    }

    public func endpointURL(path: String) -> URL? {
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        if apiProtocol == .codexChatGPT {
            let base = normalizedBaseURL
            if cleanPath == "/responses" || cleanPath == "/v1/responses" {
                return URL(string: "\(base)/responses")
            }
        }
        return URL(string: "\(normalizedBaseURL)\(cleanPath)")
    }
}

public enum ModelCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case chat
    case reasoning
    case coding
    case tools
    case vision
    case jsonMode

    public var displayName: String {
        switch self {
        case .chat: return "通用对话"
        case .reasoning: return "深度推理"
        case .coding: return "代码工程"
        case .tools: return "工具调用"
        case .vision: return "视觉图像"
        case .jsonMode: return "结构化输出"
        }
    }
}

public enum ModelDefaultUsage: String, Codable, CaseIterable, Sendable {
    case general = "general"
    case fastEconomy = "fast_economy"
    case coding = "coding"
    case complexReasoning = "complex_reasoning"
    case vision = "vision"

    public var displayName: String {
        switch self {
        case .general: return "日常通用"
        case .fastEconomy: return "轻量低价"
        case .coding: return "代码开发"
        case .complexReasoning: return "复杂推理"
        case .vision: return "多模态视觉"
        }
    }
}

public enum ModelAvailabilityStatus: String, Codable, CaseIterable, Sendable {
    case available
    case unavailable
    case retired
    case insufficientCredits

    public var displayName: String {
        switch self {
        case .available: return "可用"
        case .unavailable: return "不可用"
        case .retired: return "已下线"
        case .insufficientCredits: return "额度不足"
        }
    }
}

public struct ModelConfig: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var providerID: UUID
    public var modelID: String
    public var displayName: String
    public var isEnabled: Bool
    /// USD per 1M input tokens. nil means user has not configured pricing.
    public var inputPricePerMillion: Double?
    /// USD per 1M output tokens. nil means user has not configured pricing.
    public var outputPricePerMillion: Double?
    /// Optional USD per 1M prompt-cache read tokens. nil uses family default or inputPricePerMillion.
    public var cachedInputPricePerMillion: Double?
    /// Optional USD per 1M prompt-cache creation tokens. nil uses family default or inputPricePerMillion.
    public var cacheCreationPricePerMillion: Double?
    /// Optional soft RPM cap used to spill traffic to same-tier backups before hitting upstream 429.
    public var maxRequestsPerMinute: Int?
    public var contextWindow: Int
    /// Operator-verified context on this provider and model, including any upstream routing paths.
    /// Legacy routing estimates and import defaults leave this unset.
    public var verifiedContextWindow: Int?
    public var capabilities: Set<ModelCapability>
    public var defaultRole: ModelDefaultUsage
    /// 1...100 subjective quality rating configured by user or template
    public var qualityScore: Int
    /// 1...100 subjective speed rating configured by user or template
    public var speedScore: Int
    public var availabilityStatus: ModelAvailabilityStatus
    public var lastAvailabilityNote: String?
    public var discoveredSource: String?
    public var isAutoEvicted: Bool
    public var lastProbeLatencyMs: Double?
    public var lastProbedAt: Date?
    /// Optional explicit canonical model identifier overriding automatic normalization (e.g. "claude-3.7-sonnet").
    public var canonicalModelID: String?

    public init(
        id: UUID = UUID(),
        providerID: UUID,
        modelID: String,
        displayName: String? = nil,
        isEnabled: Bool = true,
        inputPricePerMillion: Double? = nil,
        outputPricePerMillion: Double? = nil,
        cachedInputPricePerMillion: Double? = nil,
        cacheCreationPricePerMillion: Double? = nil,
        maxRequestsPerMinute: Int? = nil,
        contextWindow: Int = 128_000,
        verifiedContextWindow: Int? = nil,
        capabilities: Set<ModelCapability> = [.chat],
        defaultRole: ModelDefaultUsage = .general,
        qualityScore: Int = 75,
        speedScore: Int = 75,
        availabilityStatus: ModelAvailabilityStatus = .available,
        lastAvailabilityNote: String? = nil,
        discoveredSource: String? = nil,
        isAutoEvicted: Bool = false,
        lastProbeLatencyMs: Double? = nil,
        lastProbedAt: Date? = nil,
        canonicalModelID: String? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = (displayName?.isEmpty == false) ? displayName! : modelID
        self.isEnabled = isEnabled
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cachedInputPricePerMillion = cachedInputPricePerMillion
        self.cacheCreationPricePerMillion = cacheCreationPricePerMillion
        self.maxRequestsPerMinute = maxRequestsPerMinute.flatMap { $0 > 0 ? $0 : nil }
        self.contextWindow = max(1024, contextWindow)
        self.verifiedContextWindow = verifiedContextWindow
        self.capabilities = capabilities
        self.defaultRole = defaultRole
        self.qualityScore = min(100, max(1, qualityScore))
        self.speedScore = min(100, max(1, speedScore))
        self.availabilityStatus = availabilityStatus
        self.lastAvailabilityNote = lastAvailabilityNote
        self.discoveredSource = discoveredSource
        self.isAutoEvicted = isAutoEvicted
        self.lastProbeLatencyMs = lastProbeLatencyMs
        self.lastProbedAt = lastProbedAt
        self.canonicalModelID = canonicalModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id, providerID, modelID, displayName, isEnabled
        case inputPricePerMillion, outputPricePerMillion
        case cachedInputPricePerMillion, cacheCreationPricePerMillion, maxRequestsPerMinute
        case contextWindow, verifiedContextWindow
        case capabilities, defaultRole, qualityScore, speedScore
        case availabilityStatus, lastAvailabilityNote
        case discoveredSource, isAutoEvicted, lastProbeLatencyMs, lastProbedAt
        case canonicalModelID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        providerID = try c.decode(UUID.self, forKey: .providerID)
        modelID = try c.decode(String.self, forKey: .modelID)
        displayName = try c.decode(String.self, forKey: .displayName)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        inputPricePerMillion = try c.decodeIfPresent(Double.self, forKey: .inputPricePerMillion)
        outputPricePerMillion = try c.decodeIfPresent(Double.self, forKey: .outputPricePerMillion)
        cachedInputPricePerMillion = try c.decodeIfPresent(Double.self, forKey: .cachedInputPricePerMillion)
        cacheCreationPricePerMillion = try c.decodeIfPresent(Double.self, forKey: .cacheCreationPricePerMillion)
        let rawRPM = try c.decodeIfPresent(Int.self, forKey: .maxRequestsPerMinute)
        maxRequestsPerMinute = rawRPM.flatMap { $0 > 0 ? $0 : nil }
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 128_000
        verifiedContextWindow = try c.decodeIfPresent(Int.self, forKey: .verifiedContextWindow)
        capabilities = try c.decodeIfPresent(Set<ModelCapability>.self, forKey: .capabilities) ?? [.chat]
        defaultRole = try c.decodeIfPresent(ModelDefaultUsage.self, forKey: .defaultRole) ?? .general
        qualityScore = try c.decodeIfPresent(Int.self, forKey: .qualityScore) ?? 75
        speedScore = try c.decodeIfPresent(Int.self, forKey: .speedScore) ?? 75
        availabilityStatus = try c.decodeIfPresent(ModelAvailabilityStatus.self, forKey: .availabilityStatus) ?? .available
        lastAvailabilityNote = try c.decodeIfPresent(String.self, forKey: .lastAvailabilityNote)
        discoveredSource = try c.decodeIfPresent(String.self, forKey: .discoveredSource)
        isAutoEvicted = try c.decodeIfPresent(Bool.self, forKey: .isAutoEvicted) ?? false
        lastProbeLatencyMs = try c.decodeIfPresent(Double.self, forKey: .lastProbeLatencyMs)
        lastProbedAt = try c.decodeIfPresent(Date.self, forKey: .lastProbedAt)
        canonicalModelID = try c.decodeIfPresent(String.self, forKey: .canonicalModelID)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public var hasCompletePricing: Bool {
        inputPricePerMillion != nil && outputPricePerMillion != nil
    }

    public var blendedPricePerMillion: Double? {
        guard let input = inputPricePerMillion, let output = outputPricePerMillion else {
            return nil
        }
        // Standard 3:1 input-to-output blended benchmark heuristic
        return (input * 0.75) + (output * 0.25)
    }

    public func calculateCostUSD(promptTokens: Int, completionTokens: Int) -> Double? {
        guard let inputPrice = inputPricePerMillion, let outputPrice = outputPricePerMillion else {
            return nil
        }
        let inCost = (Double(max(0, promptTokens)) / 1_000_000.0) * inputPrice
        let outCost = (Double(max(0, completionTokens)) / 1_000_000.0) * outputPrice
        return inCost + outCost
    }

    public var effectiveCachedInputPricePerMillion: Double? {
        if let explicit = cachedInputPricePerMillion { return max(0, explicit) }
        guard let inputPrice = inputPricePerMillion else { return nil }
        let lower = modelID.lowercased()
        if lower.contains("claude") || lower.contains("deepseek") || lower.contains("gemini") {
            return inputPrice * 0.10
        }
        if lower.contains("gpt-5") || lower.contains("gpt-4.1") || lower.contains("o3") || lower.contains("o4") {
            return inputPrice * 0.25
        }
        if lower.contains("gpt-4o") || lower.contains("o1") {
            return inputPrice * 0.50
        }
        return inputPrice
    }

    public var effectiveCacheCreationPricePerMillion: Double? {
        if let explicit = cacheCreationPricePerMillion { return max(0, explicit) }
        guard let inputPrice = inputPricePerMillion else { return nil }
        let lower = modelID.lowercased()
        if lower.contains("claude") {
            return inputPrice * 1.25
        }
        return inputPrice
    }

    public func calculateCostUSD(usage: TokenUsage) -> Double? {
        guard let inputPrice = inputPricePerMillion, let outputPrice = outputPricePerMillion else {
            return nil
        }
        let cachedRead = max(0, usage.cachedInputTokens ?? 0)
        let cacheCreate = max(0, usage.cacheCreationTokens ?? 0)
        if cachedRead == 0 && cacheCreate == 0 {
            return calculateCostUSD(promptTokens: usage.promptTokens, completionTokens: usage.completionTokens)
        }
        let totalPrompt = max(0, usage.promptTokens)
        let clampedRead = min(totalPrompt, cachedRead)
        let clampedCreate = min(max(0, totalPrompt - clampedRead), cacheCreate)
        let uncachedPrompt = max(0, totalPrompt - clampedRead - clampedCreate)

        let readPrice = effectiveCachedInputPricePerMillion ?? inputPrice
        let createPrice = effectiveCacheCreationPricePerMillion ?? inputPrice

        let uncachedCost = (Double(uncachedPrompt) / 1_000_000.0) * inputPrice
        let readCost = (Double(clampedRead) / 1_000_000.0) * readPrice
        let createCost = (Double(clampedCreate) / 1_000_000.0) * createPrice
        let outCost = (Double(max(0, usage.completionTokens)) / 1_000_000.0) * outputPrice
        return uncachedCost + readCost + createCost + outCost
    }
}

// MARK: - Model Tiers & Routing Policy & Settings

public enum ModelTier: String, Codable, CaseIterable, Identifiable, CodingKeyRepresentable, Sendable {
    case low = "low"
    case medium = "medium"
    case high = "high"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: return "低档 · 轻量极速"
        case .medium: return "中档 · 均衡主力"
        case .high: return "高档 · 旗舰推理"
        }
    }

    public var shortName: String {
        switch self {
        case .low: return "低档"
        case .medium: return "中档"
        case .high: return "高档"
        }
    }

    public var virtualModelID: String {
        switch self {
        case .low: return "auto/low"
        case .medium: return "auto/medium"
        case .high: return "auto/high"
        }
    }

    public var subtitle: String {
        switch self {
        case .low: return "简单问答、摘要改写、高频轻量辅助（优先低价与极速响应）"
        case .medium: return "日常编码、常规对话、工具调用（兼顾质量、速度与成本）"
        case .high: return "复杂推理、架构设计、深度重构（优先顶级能力与准确率）"
        }
    }

    public static func matchExplicitTier(requestedModel: String) -> ModelTier? {
        let lower = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "auto/low", "low", "automodel/auto/low", "tier/low", "anthropic/haiku":
            return .low
        case "auto/medium", "medium", "automodel/auto/medium", "tier/medium", "anthropic/sonnet":
            return .medium
        case "auto/high", "high", "automodel/auto/high", "tier/high", "anthropic/opus":
            return .high
        default:
            return nil
        }
    }
}

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex = "codex"
    case opencode = "opencode"
    case hermes = "hermes"
    case claudeCode = "claude_code"
    case deepseekHarness = "deepseek_harness"
    case shellAndContinue = "shell_and_continue"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex CLI / App"
        case .opencode: return "OpenCode"
        case .hermes: return "Hermes Agent"
        case .claudeCode: return "Claude Code"
        case .deepseekHarness: return "DeepSeek Harness"
        case .shellAndContinue: return "Shell / Continue 通用配置"
        }
    }

    public static func isHermesSystemPrompt(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("you are hermes agent, built by nous research.")
    }

    public var subtitle: String {
        switch self {
        case .codex:
            return "在 ~/.codex/config.toml 中写入本地网关与默认模型，保留全部项目信任配置（类似 Magpie）"
        case .opencode:
            return "在 ~/.config/opencode/opencode.json 注册 automodel 供应商及 auto / 低中高三档模型"
        case .hermes:
            return "在 ~/.hermes/config.yaml 写入 automodel 供应商、默认模型与三档映射"
        case .claudeCode:
            return "在 ~/.claude/settings.json 的 env 中写入本地 /v1/messages 网关地址与 Haiku(低)/Sonnet(中)/Opus(高) 三档映射"
        case .deepseekHarness:
            return "在 ~/.dsh/profiles/desktop/cordis.patch.yml 注册 automodel 供应商与默认模型，并将 API Key 写入 ~/.dsh/.credentials.yaml"
        case .shellAndContinue:
            return "生成 ~/.automodel/agent-env.sh 环境变量脚本（兼容 Cursor/CLI），并同步更新 ~/.continue/config.json（若存在）"
        }
    }
}

public struct AgentModelBinding: Codable, Equatable, Sendable {
    public var defaultModelOption: String
    public var lowModelOption: String
    public var mediumModelOption: String
    public var highModelOption: String

    public init(
        defaultModelOption: String = "auto",
        lowModelOption: String = "auto/low",
        mediumModelOption: String = "auto/medium",
        highModelOption: String = "auto/high"
    ) {
        self.defaultModelOption = defaultModelOption
        self.lowModelOption = lowModelOption
        self.mediumModelOption = mediumModelOption
        self.highModelOption = highModelOption
    }
}

public enum RoutingStrategyPreset: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    case costFirst = "cost_first"
    case balanced = "balanced"
    case qualityFirst = "quality_first"

    public var displayName: String {
        switch self {
        case .costFirst: return "省钱优先"
        case .balanced: return "均衡模式"
        case .qualityFirst: return "质量优先"
        }
    }

    public var subtitle: String {
        switch self {
        case .costFirst:
            return "满足硬约束前提下优先选择单价最低的模型，未配置价格时倾向轻量角色"
        case .balanced:
            return "结合任务类型、质量、速度与成本加权选择，兼顾性价比与稳定性"
        case .qualityFirst:
            return "优先选择能力与质量评分最高的模型，适合复杂代码、推理与多步骤任务"
        }
    }
}

public struct TierModelAssignment: Codable, Equatable, Sendable {
    public var primaryModelID: UUID?
    public var backupModelIDs: [UUID]

    public init(primaryModelID: UUID? = nil, backupModelIDs: [UUID] = []) {
        self.primaryModelID = primaryModelID
        self.backupModelIDs = backupModelIDs
    }
}

public struct RoutingPolicyConfig: Codable, Equatable, Sendable {
    public var policyVersion: Int
    public var activeStrategy: RoutingStrategyPreset
    public var pinnedModelID: UUID?
    public var fallbackModelID: UUID?
    public var maxInputPricePerMillion: Double?
    public var maxOutputPricePerMillion: Double?
    public var enableSessionStickiness: Bool
    public var enableRetryOnUpstreamFailure: Bool
    public var maxUpstreamAttempts: Int
    public var maxRequestDurationSeconds: Double
    public var activeDeciderPluginID: String

    // Three-tier (Low / Medium / High) model configuration (primary + ordered failover backups)
    public var lowTierModelID: UUID?
    public var mediumTierModelID: UUID?
    public var highTierModelID: UUID?
    public var lowTierBackupModelIDs: [UUID]
    public var mediumTierBackupModelIDs: [UUID]
    public var highTierBackupModelIDs: [UUID]
    public var autoConfigureTiers: Bool
    public var preferTierMappingInAuto: Bool
    public var enablePhaseDowngradeHysteresis: Bool
    public var strictThreeTierPoolOnly: Bool
    public var lowTierIsManual: Bool
    public var mediumTierIsManual: Bool
    public var highTierIsManual: Bool
    /// Automatically group identical logical models across enabled providers for availability failover.
    public var enableAutoSameModelGrouping: Bool
    /// Per-strategy memory of primary & backup model assignments (falls back to global tier fields when absent).
    public var perStrategyTiers: [RoutingStrategyPreset: [ModelTier: TierModelAssignment]]

    public init(
        policyVersion: Int = 1,
        activeStrategy: RoutingStrategyPreset = .balanced,
        pinnedModelID: UUID? = nil,
        fallbackModelID: UUID? = nil,
        maxInputPricePerMillion: Double? = nil,
        maxOutputPricePerMillion: Double? = nil,
        enableSessionStickiness: Bool = true,
        enableRetryOnUpstreamFailure: Bool = true,
        maxUpstreamAttempts: Int = 3,
        maxRequestDurationSeconds: Double = 120,
        activeDeciderPluginID: String = "builtin.deterministic.v1",
        lowTierModelID: UUID? = nil,
        mediumTierModelID: UUID? = nil,
        highTierModelID: UUID? = nil,
        lowTierBackupModelIDs: [UUID] = [],
        mediumTierBackupModelIDs: [UUID] = [],
        highTierBackupModelIDs: [UUID] = [],
        autoConfigureTiers: Bool = true,
        preferTierMappingInAuto: Bool = true,
        enablePhaseDowngradeHysteresis: Bool = true,
        strictThreeTierPoolOnly: Bool = true,
        lowTierIsManual: Bool = false,
        mediumTierIsManual: Bool = false,
        highTierIsManual: Bool = false,
        enableAutoSameModelGrouping: Bool = true,
        perStrategyTiers: [RoutingStrategyPreset: [ModelTier: TierModelAssignment]] = [:]
    ) {
        self.policyVersion = policyVersion
        self.activeStrategy = activeStrategy
        self.pinnedModelID = pinnedModelID
        self.fallbackModelID = fallbackModelID
        self.maxInputPricePerMillion = maxInputPricePerMillion
        self.maxOutputPricePerMillion = maxOutputPricePerMillion
        self.enableSessionStickiness = enableSessionStickiness
        self.enableRetryOnUpstreamFailure = enableRetryOnUpstreamFailure
        self.maxUpstreamAttempts = max(1, maxUpstreamAttempts)
        self.maxRequestDurationSeconds = max(1, maxRequestDurationSeconds)
        self.activeDeciderPluginID = activeDeciderPluginID
        self.lowTierModelID = lowTierModelID
        self.mediumTierModelID = mediumTierModelID
        self.highTierModelID = highTierModelID
        self.lowTierBackupModelIDs = lowTierBackupModelIDs
        self.mediumTierBackupModelIDs = mediumTierBackupModelIDs
        self.highTierBackupModelIDs = highTierBackupModelIDs
        self.autoConfigureTiers = autoConfigureTiers
        self.preferTierMappingInAuto = preferTierMappingInAuto
        self.enablePhaseDowngradeHysteresis = enablePhaseDowngradeHysteresis
        self.strictThreeTierPoolOnly = strictThreeTierPoolOnly
        self.lowTierIsManual = lowTierIsManual
        self.mediumTierIsManual = mediumTierIsManual
        self.highTierIsManual = highTierIsManual
        self.enableAutoSameModelGrouping = enableAutoSameModelGrouping
        self.perStrategyTiers = perStrategyTiers
    }

    enum CodingKeys: String, CodingKey {
        case policyVersion, activeStrategy, pinnedModelID, fallbackModelID
        case maxInputPricePerMillion, maxOutputPricePerMillion
        case enableSessionStickiness, enableRetryOnUpstreamFailure
        case maxUpstreamAttempts, maxRequestDurationSeconds, activeDeciderPluginID
        case lowTierModelID, mediumTierModelID, highTierModelID
        case lowTierBackupModelIDs, mediumTierBackupModelIDs, highTierBackupModelIDs
        case autoConfigureTiers, preferTierMappingInAuto
        case enablePhaseDowngradeHysteresis, strictThreeTierPoolOnly
        case lowTierIsManual, mediumTierIsManual, highTierIsManual
        case enableAutoSameModelGrouping, perStrategyTiers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policyVersion = try c.decodeIfPresent(Int.self, forKey: .policyVersion) ?? 1
        activeStrategy = try c.decodeIfPresent(RoutingStrategyPreset.self, forKey: .activeStrategy) ?? .balanced
        pinnedModelID = try c.decodeIfPresent(UUID.self, forKey: .pinnedModelID)
        fallbackModelID = try c.decodeIfPresent(UUID.self, forKey: .fallbackModelID)
        maxInputPricePerMillion = try c.decodeIfPresent(Double.self, forKey: .maxInputPricePerMillion)
        maxOutputPricePerMillion = try c.decodeIfPresent(Double.self, forKey: .maxOutputPricePerMillion)
        enableSessionStickiness = try c.decodeIfPresent(Bool.self, forKey: .enableSessionStickiness) ?? true
        enableRetryOnUpstreamFailure = try c.decodeIfPresent(Bool.self, forKey: .enableRetryOnUpstreamFailure) ?? true
        maxUpstreamAttempts = max(1, try c.decodeIfPresent(Int.self, forKey: .maxUpstreamAttempts) ?? 3)
        maxRequestDurationSeconds = max(1, try c.decodeIfPresent(Double.self, forKey: .maxRequestDurationSeconds) ?? 120)
        activeDeciderPluginID = try c.decodeIfPresent(String.self, forKey: .activeDeciderPluginID) ?? "builtin.deterministic.v1"
        lowTierModelID = try c.decodeIfPresent(UUID.self, forKey: .lowTierModelID)
        mediumTierModelID = try c.decodeIfPresent(UUID.self, forKey: .mediumTierModelID)
        highTierModelID = try c.decodeIfPresent(UUID.self, forKey: .highTierModelID)
        lowTierBackupModelIDs = try c.decodeIfPresent([UUID].self, forKey: .lowTierBackupModelIDs) ?? []
        mediumTierBackupModelIDs = try c.decodeIfPresent([UUID].self, forKey: .mediumTierBackupModelIDs) ?? []
        highTierBackupModelIDs = try c.decodeIfPresent([UUID].self, forKey: .highTierBackupModelIDs) ?? []
        autoConfigureTiers = try c.decodeIfPresent(Bool.self, forKey: .autoConfigureTiers) ?? true
        preferTierMappingInAuto = try c.decodeIfPresent(Bool.self, forKey: .preferTierMappingInAuto) ?? true
        enablePhaseDowngradeHysteresis = try c.decodeIfPresent(Bool.self, forKey: .enablePhaseDowngradeHysteresis) ?? true
        strictThreeTierPoolOnly = try c.decodeIfPresent(Bool.self, forKey: .strictThreeTierPoolOnly) ?? true
        lowTierIsManual = try c.decodeIfPresent(Bool.self, forKey: .lowTierIsManual) ?? false
        mediumTierIsManual = try c.decodeIfPresent(Bool.self, forKey: .mediumTierIsManual) ?? false
        highTierIsManual = try c.decodeIfPresent(Bool.self, forKey: .highTierIsManual) ?? false
        enableAutoSameModelGrouping = try c.decodeIfPresent(Bool.self, forKey: .enableAutoSameModelGrouping) ?? true
        perStrategyTiers = try c.decodeIfPresent([RoutingStrategyPreset: [ModelTier: TierModelAssignment]].self, forKey: .perStrategyTiers) ?? [:]
    }

    public func modelID(for tier: ModelTier) -> UUID? {
        switch tier {
        case .low: return lowTierModelID
        case .medium: return mediumTierModelID
        case .high: return highTierModelID
        }
    }

    public func backupModelIDs(for tier: ModelTier) -> [UUID] {
        switch tier {
        case .low: return lowTierBackupModelIDs
        case .medium: return mediumTierBackupModelIDs
        case .high: return highTierBackupModelIDs
        }
    }

    /// Ordered pool of primary + backup model IDs for a tier (deduplicated).
    public func modelIDs(for tier: ModelTier) -> [UUID] {
        var result: [UUID] = []
        if let primary = modelID(for: tier) {
            result.append(primary)
        }
        for bid in backupModelIDs(for: tier) where !result.contains(bid) {
            result.append(bid)
        }
        return result
    }

    public func isManual(for tier: ModelTier) -> Bool {
        switch tier {
        case .low: return lowTierIsManual
        case .medium: return mediumTierIsManual
        case .high: return highTierIsManual
        }
    }

    public mutating func setBackupModelIDs(_ ids: [UUID], for tier: ModelTier) {
        let primary = modelID(for: tier)
        var deduped: [UUID] = []
        for id in ids where id != primary && !deduped.contains(id) {
            deduped.append(id)
        }
        switch tier {
        case .low: lowTierBackupModelIDs = deduped
        case .medium: mediumTierBackupModelIDs = deduped
        case .high: highTierBackupModelIDs = deduped
        }
        var strategyMap = perStrategyTiers[activeStrategy] ?? [:]
        strategyMap[tier] = TierModelAssignment(primaryModelID: primary, backupModelIDs: deduped)
        perStrategyTiers[activeStrategy] = strategyMap
    }

    public func tierAssignment(for tier: ModelTier, strategy: RoutingStrategyPreset? = nil) -> TierModelAssignment {
        let targetStrategy = strategy ?? activeStrategy
        if let assignment = perStrategyTiers[targetStrategy]?[tier],
           assignment.primaryModelID != nil || !assignment.backupModelIDs.isEmpty {
            return assignment
        }
        return TierModelAssignment(
            primaryModelID: modelID(for: tier),
            backupModelIDs: backupModelIDs(for: tier)
        )
    }

    public mutating func setTierAssignment(
        _ assignment: TierModelAssignment,
        for tier: ModelTier,
        strategy: RoutingStrategyPreset? = nil
    ) {
        let targetStrategy = strategy ?? activeStrategy
        var dedupedBackups: [UUID] = []
        for bid in assignment.backupModelIDs where bid != assignment.primaryModelID && !dedupedBackups.contains(bid) {
            dedupedBackups.append(bid)
        }
        let normalized = TierModelAssignment(primaryModelID: assignment.primaryModelID, backupModelIDs: dedupedBackups)
        var strategyMap = perStrategyTiers[targetStrategy] ?? [:]
        strategyMap[tier] = normalized
        perStrategyTiers[targetStrategy] = strategyMap

        if targetStrategy == activeStrategy {
            switch tier {
            case .low:
                lowTierModelID = normalized.primaryModelID
                lowTierBackupModelIDs = normalized.backupModelIDs
                lowTierIsManual = true
            case .medium:
                mediumTierModelID = normalized.primaryModelID
                mediumTierBackupModelIDs = normalized.backupModelIDs
                mediumTierIsManual = true
            case .high:
                highTierModelID = normalized.primaryModelID
                highTierBackupModelIDs = normalized.backupModelIDs
                highTierIsManual = true
            }
        }
    }

    public mutating func applyStrategyTierSnapshot(_ strategy: RoutingStrategyPreset) {
        activeStrategy = strategy
        guard let snapshot = perStrategyTiers[strategy] else { return }
        if let low = snapshot[.low] {
            lowTierModelID = low.primaryModelID
            lowTierBackupModelIDs = low.backupModelIDs
        }
        if let med = snapshot[.medium] {
            mediumTierModelID = med.primaryModelID
            mediumTierBackupModelIDs = med.backupModelIDs
        }
        if let high = snapshot[.high] {
            highTierModelID = high.primaryModelID
            highTierBackupModelIDs = high.backupModelIDs
        }
    }

    public mutating func addBackupModel(_ modelID: UUID, to tier: ModelTier, isManual: Bool = true) {
        if self.modelID(for: tier) == nil {
            setTier(tier, modelID: modelID, isManual: isManual)
            return
        }
        guard self.modelID(for: tier) != modelID else { return }
        var backups = backupModelIDs(for: tier)
        if !backups.contains(modelID) {
            backups.append(modelID)
            setBackupModelIDs(backups, for: tier)
        }
    }

    public mutating func removeBackupModel(_ modelID: UUID, from tier: ModelTier) {
        let filtered = backupModelIDs(for: tier).filter { $0 != modelID }
        setBackupModelIDs(filtered, for: tier)
    }

    public mutating func setTier(_ tier: ModelTier, modelID: UUID?, isManual: Bool) {
        switch tier {
        case .low:
            lowTierModelID = modelID
            lowTierIsManual = isManual
            if let modelID { lowTierBackupModelIDs.removeAll { $0 == modelID } }
        case .medium:
            mediumTierModelID = modelID
            mediumTierIsManual = isManual
            if let modelID { mediumTierBackupModelIDs.removeAll { $0 == modelID } }
        case .high:
            highTierModelID = modelID
            highTierIsManual = isManual
            if let modelID { highTierBackupModelIDs.removeAll { $0 == modelID } }
        }
    }
}

public struct ProxySettings: Codable, Equatable, Sendable {
    public var port: Int
    public var autoStartProxy: Bool
    public var autoDiscoverAndProbeOnLaunch: Bool
    public var periodicHealthCheckMinutes: Int

    public init(
        port: Int = 8765,
        autoStartProxy: Bool = true,
        autoDiscoverAndProbeOnLaunch: Bool = true,
        periodicHealthCheckMinutes: Int = 5
    ) {
        self.port = port
        self.autoStartProxy = autoStartProxy
        self.autoDiscoverAndProbeOnLaunch = autoDiscoverAndProbeOnLaunch
        self.periodicHealthCheckMinutes = max(0, periodicHealthCheckMinutes)
    }

    enum CodingKeys: String, CodingKey {
        case port, autoStartProxy, autoDiscoverAndProbeOnLaunch, periodicHealthCheckMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8765
        autoStartProxy = try c.decodeIfPresent(Bool.self, forKey: .autoStartProxy) ?? true
        autoDiscoverAndProbeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoDiscoverAndProbeOnLaunch) ?? true
        periodicHealthCheckMinutes = try c.decodeIfPresent(Int.self, forKey: .periodicHealthCheckMinutes) ?? 5
    }

    public var baseURLString: String {
        "http://127.0.0.1:\(port)/v1"
    }

    public var rootURLString: String {
        "http://127.0.0.1:\(port)"
    }
}

public struct DiscoveryAndProbeSummary: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var discoveredProvidersCount: Int
    public var discoveredModelsCount: Int
    public var probedModelsCount: Int
    public var healthyModelsCount: Int
    public var evictedModelsCount: Int
    public var sourcesScanned: [String]

    public init(
        timestamp: Date = Date(),
        discoveredProvidersCount: Int,
        discoveredModelsCount: Int,
        probedModelsCount: Int,
        healthyModelsCount: Int,
        evictedModelsCount: Int,
        sourcesScanned: [String]
    ) {
        self.timestamp = timestamp
        self.discoveredProvidersCount = discoveredProvidersCount
        self.discoveredModelsCount = discoveredModelsCount
        self.probedModelsCount = probedModelsCount
        self.healthyModelsCount = healthyModelsCount
        self.evictedModelsCount = evictedModelsCount
        self.sourcesScanned = sourcesScanned
    }
}

public struct PrivacySettings: Codable, Equatable, Sendable {
    public var recordRequestBody: Bool
    public var hasCompletedOnboarding: Bool
    /// Days to retain records in SQLite history store (0 = keep forever).
    public var historyRetentionDays: Int
    /// Send macOS notifications for budget alerts, auth errors, and tier degradation.
    public var enableSystemNotifications: Bool
    /// Check GitHub Releases for newer versions on launch (manual check always available).
    public var autoCheckUpdates: Bool

    public init(
        recordRequestBody: Bool = false,
        hasCompletedOnboarding: Bool = false,
        historyRetentionDays: Int = 90,
        enableSystemNotifications: Bool = true,
        autoCheckUpdates: Bool = false
    ) {
        self.recordRequestBody = recordRequestBody
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.historyRetentionDays = max(0, historyRetentionDays)
        self.enableSystemNotifications = enableSystemNotifications
        self.autoCheckUpdates = autoCheckUpdates
    }

    enum CodingKeys: String, CodingKey {
        case recordRequestBody, hasCompletedOnboarding, historyRetentionDays, enableSystemNotifications, autoCheckUpdates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordRequestBody = try container.decodeIfPresent(Bool.self, forKey: .recordRequestBody) ?? false
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        historyRetentionDays = max(0, try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? 90)
        enableSystemNotifications = try container.decodeIfPresent(Bool.self, forKey: .enableSystemNotifications) ?? true
        autoCheckUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? false
    }
}

public struct AppConfigBundle: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var providers: [ProviderConfig]
    public var models: [ModelConfig]
    public var policy: RoutingPolicyConfig
    public var proxySettings: ProxySettings
    public var privacySettings: PrivacySettings
    public var agentBindings: [String: AgentModelBinding]
    public var agentPolicyProfiles: [String: AgentPolicyProfile]
    public var budgetSettings: MonthlyBudgetSettings

    public init(
        schemaVersion: Int = 1,
        providers: [ProviderConfig] = [],
        models: [ModelConfig] = [],
        policy: RoutingPolicyConfig = RoutingPolicyConfig(),
        proxySettings: ProxySettings = ProxySettings(),
        privacySettings: PrivacySettings = PrivacySettings(),
        agentBindings: [String: AgentModelBinding] = [:],
        agentPolicyProfiles: [String: AgentPolicyProfile] = [:],
        budgetSettings: MonthlyBudgetSettings = MonthlyBudgetSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.providers = providers
        self.models = models
        self.policy = policy
        self.proxySettings = proxySettings
        self.privacySettings = privacySettings
        self.agentBindings = agentBindings
        self.agentPolicyProfiles = agentPolicyProfiles
        self.budgetSettings = budgetSettings
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, providers, models, policy, proxySettings, privacySettings, agentBindings, agentPolicyProfiles, budgetSettings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        providers = try c.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? []
        models = try c.decodeIfPresent([ModelConfig].self, forKey: .models) ?? []
        policy = try c.decodeIfPresent(RoutingPolicyConfig.self, forKey: .policy) ?? RoutingPolicyConfig()
        proxySettings = try c.decodeIfPresent(ProxySettings.self, forKey: .proxySettings) ?? ProxySettings()
        privacySettings = try c.decodeIfPresent(PrivacySettings.self, forKey: .privacySettings) ?? PrivacySettings()
        agentBindings = try c.decodeIfPresent([String: AgentModelBinding].self, forKey: .agentBindings) ?? [:]
        agentPolicyProfiles = try c.decodeIfPresent([String: AgentPolicyProfile].self, forKey: .agentPolicyProfiles) ?? [:]
        budgetSettings = try c.decodeIfPresent(MonthlyBudgetSettings.self, forKey: .budgetSettings) ?? MonthlyBudgetSettings()
    }

    public func binding(for kind: AgentKind) -> AgentModelBinding {
        agentBindings[kind.rawValue] ?? .stableIdentity(for: kind)
    }
}

// MARK: - Routing Decision, Receipts & Telemetry

public enum TaskIntentType: String, Codable, CaseIterable, Sendable {
    case simpleQA = "simple_qa"
    case generalChat = "general_chat"
    case coding = "coding"
    case complexReasoning = "complex_reasoning"
    case toolCalling = "tool_calling"
    case visionMultimodal = "vision_multimodal"
    case longContext = "long_context"

    public var displayName: String {
        switch self {
        case .simpleQA: return "简单问答/摘要"
        case .generalChat: return "通用对话"
        case .coding: return "代码编写与调试"
        case .complexReasoning: return "复杂推理与架构"
        case .toolCalling: return "工具/函数调用"
        case .visionMultimodal: return "图像理解"
        case .longContext: return "长上下文处理"
        }
    }

    public var defaultSubtaskCategory: AgentSubtaskCategory {
        switch self {
        case .simpleQA: return .summarizationCompaction
        case .generalChat: return .explorationSearch
        case .coding: return .routineCoding
        case .toolCalling: return .toolOrchestration
        case .visionMultimodal: return .routineCoding
        case .complexReasoning, .longContext: return .architecturePlanning
        }
    }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case max = "max"

    public var displayName: String {
        switch self {
        case .low: return "Low (极速)"
        case .medium: return "Medium (均衡)"
        case .high: return "High (深度)"
        case .max: return "Max (极限)"
        }
    }

    public var shortBadge: String {
        rawValue
    }

    public var requiresDeepReasoning: Bool {
        self == .high || self == .max
    }

    /// Standard OpenAI / Responses reasoning effort string ("low", "medium", "high").
    public var upstreamEffortValue: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high, .max: return "high"
        }
    }
}

public enum AgentSubtaskCategory: String, Codable, CaseIterable, Sendable {
    case explorationSearch = "exploration_search"
    case summarizationCompaction = "summarization_compaction"
    case routineCoding = "routine_coding"
    case generalEngineering = "general_engineering"
    case toolOrchestration = "tool_orchestration"
    case architecturePlanning = "architecture_planning"
    case deepDebugging = "deep_debugging"

    public var displayName: String {
        switch self {
        case .explorationSearch: return "检索与代码探索"
        case .summarizationCompaction: return "摘要与上下文整理"
        case .routineCoding: return "范围明确的实现与文档"
        case .generalEngineering: return "开放式工程与分析"
        case .toolOrchestration: return "工具编排与执行"
        case .architecturePlanning: return "架构设计与规划"
        case .deepDebugging: return "疑难调试与根因"
        }
    }

    public var recommendedTier: ModelTier {
        switch self {
        case .explorationSearch, .summarizationCompaction: return .low
        case .routineCoding, .generalEngineering, .toolOrchestration: return .medium
        case .architecturePlanning, .deepDebugging: return .high
        }
    }

    public var recommendedEffort: ReasoningEffort {
        switch self {
        case .explorationSearch, .summarizationCompaction: return .low
        case .routineCoding, .generalEngineering, .toolOrchestration: return .medium
        case .architecturePlanning, .deepDebugging: return .high
        }
    }

    public var defaultRationale: String {
        switch self {
        case .explorationSearch:
            return "文件检索、目录搜索或读取工具结果，无需深度推理，优先低延迟与低成本"
        case .summarizationCompaction:
            return "上下文压缩、标题提取或简单问答，结构明确，采用轻量模型 + Low Effort 直出"
        case .routineCoding:
            return "范围明确的代码修改、单测和文档，优先使用中档与中等思考强度"
        case .generalEngineering:
            return "常规问答、开放式工程或意图不明的请求，从中档与中等思考强度起步"
        case .toolOrchestration:
            return "多步工具调用与终端指令编排，需稳定遵循工具 Schema 并保持会话状态一致"
        case .architecturePlanning:
            return "跨模块架构设计、方案权衡与复杂长文分析，筛选深度推理模型 + High Effort 避免设计返工"
        case .deepDebugging:
            return "疑难报错排查、堆栈根因分析或高复杂度推理，采用旗舰推理模型与高思考强度"
        }
    }
}

public enum TokenEstimateConfidence: String, Codable, Sendable {
    case medium
    case low
}

public struct RequestFeatures: Codable, Equatable, Sendable {
    public var messageCount: Int
    public var estimatedInputTokens: Int
    public var tokenEstimateConfidence: TokenEstimateConfidence
    public var requiresTools: Bool
    public var requiresVision: Bool
    public var requiresJSONMode: Bool
    public var isStreaming: Bool
    public var detectedTaskType: TaskIntentType
    public var conversationFingerprint: String?
    public var isMultiTurn: Bool
    public var subtaskCategory: AgentSubtaskCategory
    public var recommendedEffort: ReasoningEffort
    public var subtaskSummary: String?
    public var clientProvidedEffort: ReasoningEffort?
    public var hasClientProvidedEffort: Bool
    public var isUserTurnBoundary: Bool?

    enum CodingKeys: String, CodingKey {
        case messageCount, estimatedInputTokens, tokenEstimateConfidence, requiresTools, requiresVision, requiresJSONMode
        case isStreaming, detectedTaskType, conversationFingerprint, isMultiTurn
        case subtaskCategory, recommendedEffort, subtaskSummary, clientProvidedEffort, hasClientProvidedEffort, isUserTurnBoundary
    }

    public init(
        messageCount: Int,
        estimatedInputTokens: Int,
        tokenEstimateConfidence: TokenEstimateConfidence = .medium,
        requiresTools: Bool,
        requiresVision: Bool,
        requiresJSONMode: Bool,
        isStreaming: Bool,
        detectedTaskType: TaskIntentType,
        conversationFingerprint: String?,
        isMultiTurn: Bool,
        subtaskCategory: AgentSubtaskCategory? = nil,
        recommendedEffort: ReasoningEffort? = nil,
        subtaskSummary: String? = nil,
        clientProvidedEffort: ReasoningEffort? = nil,
        hasClientProvidedEffort: Bool? = nil,
        isUserTurnBoundary: Bool? = nil
    ) {
        let resolvedSubtask = subtaskCategory ?? detectedTaskType.defaultSubtaskCategory
        self.messageCount = messageCount
        self.estimatedInputTokens = estimatedInputTokens
        self.tokenEstimateConfidence = tokenEstimateConfidence
        self.requiresTools = requiresTools
        self.requiresVision = requiresVision
        self.requiresJSONMode = requiresJSONMode
        self.isStreaming = isStreaming
        self.detectedTaskType = detectedTaskType
        self.conversationFingerprint = conversationFingerprint
        self.isMultiTurn = isMultiTurn
        self.subtaskCategory = resolvedSubtask
        self.recommendedEffort = recommendedEffort ?? resolvedSubtask.recommendedEffort
        self.subtaskSummary = subtaskSummary
        self.clientProvidedEffort = clientProvidedEffort
        self.hasClientProvidedEffort = hasClientProvidedEffort ?? (clientProvidedEffort != nil)
        self.isUserTurnBoundary = isUserTurnBoundary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? 1
        estimatedInputTokens = try c.decodeIfPresent(Int.self, forKey: .estimatedInputTokens) ?? 0
        tokenEstimateConfidence = try c.decodeIfPresent(TokenEstimateConfidence.self, forKey: .tokenEstimateConfidence) ?? .medium
        requiresTools = try c.decodeIfPresent(Bool.self, forKey: .requiresTools) ?? false
        requiresVision = try c.decodeIfPresent(Bool.self, forKey: .requiresVision) ?? false
        requiresJSONMode = try c.decodeIfPresent(Bool.self, forKey: .requiresJSONMode) ?? false
        isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        let task = try c.decodeIfPresent(TaskIntentType.self, forKey: .detectedTaskType) ?? .generalChat
        detectedTaskType = task
        conversationFingerprint = try c.decodeIfPresent(String.self, forKey: .conversationFingerprint)
        isMultiTurn = try c.decodeIfPresent(Bool.self, forKey: .isMultiTurn) ?? false
        let decodedSubtask = try c.decodeIfPresent(AgentSubtaskCategory.self, forKey: .subtaskCategory) ?? task.defaultSubtaskCategory
        subtaskCategory = decodedSubtask
        recommendedEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .recommendedEffort) ?? decodedSubtask.recommendedEffort
        subtaskSummary = try c.decodeIfPresent(String.self, forKey: .subtaskSummary)
        clientProvidedEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .clientProvidedEffort)
        hasClientProvidedEffort = try c.decodeIfPresent(Bool.self, forKey: .hasClientProvidedEffort) ?? (clientProvidedEffort != nil)
        isUserTurnBoundary = try c.decodeIfPresent(Bool.self, forKey: .isUserTurnBoundary)
    }
}

public struct CandidateEvaluation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { modelUUID }
    public var modelUUID: UUID
    public var modelID: String
    public var displayName: String
    public var providerID: UUID
    public var providerName: String
    public var passedHardConstraints: Bool
    public var exclusionReasons: [String]
    public var score: Double?
    public var scoreBreakdown: [String]

    public init(
        modelUUID: UUID,
        modelID: String,
        displayName: String,
        providerID: UUID,
        providerName: String,
        passedHardConstraints: Bool,
        exclusionReasons: [String] = [],
        score: Double? = nil,
        scoreBreakdown: [String] = []
    ) {
        self.modelUUID = modelUUID
        self.modelID = modelID
        self.displayName = displayName
        self.providerID = providerID
        self.providerName = providerName
        self.passedHardConstraints = passedHardConstraints
        self.exclusionReasons = exclusionReasons
        self.score = score
        self.scoreBreakdown = scoreBreakdown
    }
}

public struct RoutingDecision: Codable, Equatable, Sendable {
    public var requestedModel: String
    public var isAutoRouted: Bool
    public var selectedModelUUID: UUID?
    public var selectedModelID: String?
    public var selectedDisplayName: String?
    public var selectedProviderID: UUID?
    public var selectedProviderName: String?
    public var orderedFallbackCandidateIDs: [UUID]
    public var candidateEvaluations: [CandidateEvaluation]
    public var matchedRules: [String]
    public var strategyName: String
    public var policyVersion: Int
    public var deciderPluginID: String
    public var decisionDurationMs: Double
    public var errorSummary: String?
    public var selectedEffort: ReasoningEffort
    public var subtaskCategory: AgentSubtaskCategory?
    public var routingReasonNote: String?
    public var agentID: String?
    public var agentIdentitySource: AgentIdentitySource?
    public var agentPolicyOverrideReason: String?
    public var canonicalGroupID: String?
    public var groupChannelSwitchTrace: [String]

    enum CodingKeys: String, CodingKey {
        case requestedModel, isAutoRouted, selectedModelUUID, selectedModelID, selectedDisplayName
        case selectedProviderID, selectedProviderName, orderedFallbackCandidateIDs, candidateEvaluations
        case matchedRules, strategyName, policyVersion, deciderPluginID, decisionDurationMs, errorSummary
        case selectedEffort, subtaskCategory, routingReasonNote
        case agentID, agentIdentitySource, agentPolicyOverrideReason
        case canonicalGroupID, groupChannelSwitchTrace
    }

    public init(
        requestedModel: String,
        isAutoRouted: Bool,
        selectedModelUUID: UUID? = nil,
        selectedModelID: String? = nil,
        selectedDisplayName: String? = nil,
        selectedProviderID: UUID? = nil,
        selectedProviderName: String? = nil,
        orderedFallbackCandidateIDs: [UUID] = [],
        candidateEvaluations: [CandidateEvaluation] = [],
        matchedRules: [String] = [],
        strategyName: String,
        policyVersion: Int,
        deciderPluginID: String,
        decisionDurationMs: Double,
        errorSummary: String? = nil,
        selectedEffort: ReasoningEffort = .medium,
        subtaskCategory: AgentSubtaskCategory? = nil,
        routingReasonNote: String? = nil,
        agentID: String? = nil,
        agentIdentitySource: AgentIdentitySource? = nil,
        agentPolicyOverrideReason: String? = nil,
        canonicalGroupID: String? = nil,
        groupChannelSwitchTrace: [String] = []
    ) {
        self.requestedModel = requestedModel
        self.isAutoRouted = isAutoRouted
        self.selectedModelUUID = selectedModelUUID
        self.selectedModelID = selectedModelID
        self.selectedDisplayName = selectedDisplayName
        self.selectedProviderID = selectedProviderID
        self.selectedProviderName = selectedProviderName
        self.orderedFallbackCandidateIDs = orderedFallbackCandidateIDs
        self.candidateEvaluations = candidateEvaluations
        self.matchedRules = matchedRules
        self.strategyName = strategyName
        self.policyVersion = policyVersion
        self.deciderPluginID = deciderPluginID
        self.decisionDurationMs = decisionDurationMs
        self.errorSummary = errorSummary
        self.selectedEffort = selectedEffort
        self.subtaskCategory = subtaskCategory
        self.routingReasonNote = routingReasonNote
        self.agentID = agentID
        self.agentIdentitySource = agentIdentitySource
        self.agentPolicyOverrideReason = agentPolicyOverrideReason
        self.canonicalGroupID = canonicalGroupID
        self.groupChannelSwitchTrace = groupChannelSwitchTrace
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestedModel = try c.decode(String.self, forKey: .requestedModel)
        isAutoRouted = try c.decodeIfPresent(Bool.self, forKey: .isAutoRouted) ?? false
        selectedModelUUID = try c.decodeIfPresent(UUID.self, forKey: .selectedModelUUID)
        selectedModelID = try c.decodeIfPresent(String.self, forKey: .selectedModelID)
        selectedDisplayName = try c.decodeIfPresent(String.self, forKey: .selectedDisplayName)
        selectedProviderID = try c.decodeIfPresent(UUID.self, forKey: .selectedProviderID)
        selectedProviderName = try c.decodeIfPresent(String.self, forKey: .selectedProviderName)
        orderedFallbackCandidateIDs = try c.decodeIfPresent([UUID].self, forKey: .orderedFallbackCandidateIDs) ?? []
        candidateEvaluations = try c.decodeIfPresent([CandidateEvaluation].self, forKey: .candidateEvaluations) ?? []
        matchedRules = try c.decodeIfPresent([String].self, forKey: .matchedRules) ?? []
        strategyName = try c.decodeIfPresent(String.self, forKey: .strategyName) ?? "均衡模式"
        policyVersion = try c.decodeIfPresent(Int.self, forKey: .policyVersion) ?? 1
        deciderPluginID = try c.decodeIfPresent(String.self, forKey: .deciderPluginID) ?? "builtin.deterministic.v1"
        decisionDurationMs = try c.decodeIfPresent(Double.self, forKey: .decisionDurationMs) ?? 0
        errorSummary = try c.decodeIfPresent(String.self, forKey: .errorSummary)
        selectedEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .selectedEffort) ?? .medium
        subtaskCategory = try c.decodeIfPresent(AgentSubtaskCategory.self, forKey: .subtaskCategory)
        routingReasonNote = try c.decodeIfPresent(String.self, forKey: .routingReasonNote)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
        agentIdentitySource = try c.decodeIfPresent(AgentIdentitySource.self, forKey: .agentIdentitySource)
        agentPolicyOverrideReason = try c.decodeIfPresent(String.self, forKey: .agentPolicyOverrideReason)
        canonicalGroupID = try c.decodeIfPresent(String.self, forKey: .canonicalGroupID)
        groupChannelSwitchTrace = try c.decodeIfPresent([String].self, forKey: .groupChannelSwitchTrace) ?? []
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    /// Prompt tokens served from provider prompt cache (included inside `promptTokens`).
    public var cachedInputTokens: Int?
    /// Prompt tokens written into provider prompt cache (included inside `promptTokens`).
    public var cacheCreationTokens: Int?

    public init(
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheCreationTokens: Int? = nil
    ) {
        self.promptTokens = max(0, promptTokens)
        self.completionTokens = max(0, completionTokens)
        self.totalTokens = totalTokens ?? (max(0, promptTokens) + max(0, completionTokens))
        self.cachedInputTokens = cachedInputTokens.map { max(0, $0) }
        self.cacheCreationTokens = cacheCreationTokens.map { max(0, $0) }
    }

    public var cacheHitRate: Double? {
        guard let cached = cachedInputTokens, promptTokens > 0 else { return nil }
        return min(1.0, Double(cached) / Double(promptTokens))
    }

    /// Parses OpenAI Chat, OpenAI Responses, DeepSeek, and Anthropic usage objects,
    /// normalizing prompt-cache read/write tokens into a consistent `TokenUsage`.
    public static func parse(from rawUsage: [String: Any]) -> TokenUsage? {
        let rawPrompt = rawUsage["prompt_tokens"] as? Int
        let rawInput = rawUsage["input_tokens"] as? Int
        let rawCompletion = (rawUsage["completion_tokens"] as? Int) ?? (rawUsage["output_tokens"] as? Int)
        let cacheReadAnthropic = rawUsage["cache_read_input_tokens"] as? Int
        let cacheCreateAnthropic = rawUsage["cache_creation_input_tokens"] as? Int

        if rawPrompt == nil && rawInput == nil && rawCompletion == nil && cacheReadAnthropic == nil && cacheCreateAnthropic == nil {
            return nil
        }

        let isAnthropicStyle = (cacheReadAnthropic != nil || cacheCreateAnthropic != nil) && rawPrompt == nil
        if isAnthropicStyle {
            let uncachedIn = max(0, rawInput ?? 0)
            let readIn = max(0, cacheReadAnthropic ?? 0)
            let createIn = max(0, cacheCreateAnthropic ?? 0)
            let totalPrompt = uncachedIn + readIn + createIn
            let out = max(0, rawCompletion ?? 0)
            return TokenUsage(
                promptTokens: totalPrompt,
                completionTokens: out,
                totalTokens: totalPrompt + out,
                cachedInputTokens: cacheReadAnthropic == nil ? nil : readIn,
                cacheCreationTokens: cacheCreateAnthropic == nil ? nil : createIn
            )
        }

        let promptDetails = rawUsage["prompt_tokens_details"] as? [String: Any]
        let inputDetails = rawUsage["input_tokens_details"] as? [String: Any]
        let cached = (promptDetails?["cached_tokens"] as? Int)
            ?? (inputDetails?["cached_tokens"] as? Int)
            ?? (rawUsage["prompt_cache_hit_tokens"] as? Int)

        let prompt = max(0, rawPrompt ?? rawInput ?? 0)
        let completion = max(0, rawCompletion ?? 0)
        let total = rawUsage["total_tokens"] as? Int
        return TokenUsage(
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: total,
            cachedInputTokens: cached,
            cacheCreationTokens: nil
        )
    }
}

public enum UsageDataSource: String, Codable, Sendable {
    case upstreamReported = "upstream_reported"
    case estimatedWhenMissing = "estimated_when_missing"
    case unavailable = "unavailable"

    public var displayName: String {
        switch self {
        case .upstreamReported: return "上游实测返回"
        case .estimatedWhenMissing: return "本地估算（上游未返回）"
        case .unavailable: return "无可用用量"
        }
    }
}

public enum CostCalculationStatus: String, Codable, Sendable {
    case calculated = "calculated"
    case missingPriceConfig = "missing_price_config"
    case noUsage = "no_usage"

    public var displayName: String {
        switch self {
        case .calculated: return "已按单价计算"
        case .missingPriceConfig: return "无法计算费用（未配置单价）"
        case .noUsage: return "无法计算费用（无用量数据）"
        }
    }
}

public enum WireEffortSource: String, Codable, Sendable {
    case client, automatic, absent
}

/// Only protocol metadata is retained; request bodies and cache-key values are never recorded here.
public struct WireRequestMetadata: Codable, Equatable, Sendable {
    public var effortValue: String?
    public var effortSource: WireEffortSource
    public var omittedCacheHints: [String]

    public init(effortValue: String?, effortSource: WireEffortSource, omittedCacheHints: [String] = []) {
        self.effortValue = effortValue
        self.effortSource = effortSource
        self.omittedCacheHints = omittedCacheHints
    }
}

public struct UpstreamAttemptRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var attemptIndex: Int
    public var modelUUID: UUID?
    public var modelID: String
    public var providerID: UUID?
    public var providerName: String
    public var httpStatusCode: Int?
    public var succeeded: Bool
    public var firstTokenMs: Double?
    public var totalLatencyMs: Double
    public var usage: TokenUsage?
    public var usageSource: UsageDataSource
    public var usageEstimationMethod: String?
    public var costUSD: Double?
    public var costStatus: CostCalculationStatus
    public var errorMessage: String?
    public var retryAfterSeconds: Double?
    public var accountLabel: String?
    public var wireMetadata: WireRequestMetadata?

    public init(
        id: UUID = UUID(),
        attemptIndex: Int,
        modelUUID: UUID?,
        modelID: String,
        providerID: UUID?,
        providerName: String,
        httpStatusCode: Int?,
        succeeded: Bool,
        firstTokenMs: Double?,
        totalLatencyMs: Double,
        usage: TokenUsage?,
        usageSource: UsageDataSource,
        usageEstimationMethod: String?,
        costUSD: Double?,
        costStatus: CostCalculationStatus,
        errorMessage: String?,
        accountLabel: String? = nil,
        wireMetadata: WireRequestMetadata? = nil
    ) {
        self.id = id
        self.attemptIndex = attemptIndex
        self.modelUUID = modelUUID
        self.modelID = modelID
        self.providerID = providerID
        self.providerName = providerName
        self.httpStatusCode = httpStatusCode
        self.succeeded = succeeded
        self.firstTokenMs = firstTokenMs
        self.totalLatencyMs = totalLatencyMs
        self.usage = usage
        self.usageSource = usageSource
        self.usageEstimationMethod = usageEstimationMethod
        self.costUSD = costUSD
        self.costStatus = costStatus
        self.errorMessage = errorMessage
        self.accountLabel = accountLabel
        self.wireMetadata = wireMetadata
    }
}

public enum ComparisonBasis: String, Codable, Sendable {
    /// Derived from an actual A/B execution of the baseline model on the same prompt
    case realABTest = "real_ab_test"
    /// Derived from historical recorded runs of the baseline model + current request token count
    case historicalEstimate = "historical_estimate"

    public var badgeLabel: String {
        switch self {
        case .realABTest: return "实测对照"
        case .historicalEstimate: return "历史估算"
        }
    }
}

public struct ComparisonAnalysis: Codable, Equatable, Sendable {
    public var basis: ComparisonBasis
    public var baselineModelID: String
    public var baselineModelDisplayName: String
    public var costDifferenceUSD: Double?
    public var costSavingsPercent: Double?
    /// Latency difference is ONLY populated for realABTest or when historical samples exist.
    public var latencyDifferenceMs: Double?
    public var sampleCount: Int
    public var note: String
    /// True only when both A/B sides produced upstream-reported measured costs without estimated retries.
    public var isMeasuredPair: Bool?

    public init(
        basis: ComparisonBasis,
        baselineModelID: String,
        baselineModelDisplayName: String,
        costDifferenceUSD: Double?,
        costSavingsPercent: Double?,
        latencyDifferenceMs: Double?,
        sampleCount: Int,
        note: String,
        isMeasuredPair: Bool? = nil
    ) {
        self.basis = basis
        self.baselineModelID = baselineModelID
        self.baselineModelDisplayName = baselineModelDisplayName
        self.costDifferenceUSD = costDifferenceUSD
        self.costSavingsPercent = costSavingsPercent
        self.latencyDifferenceMs = latencyDifferenceMs
        self.sampleCount = sampleCount
        self.note = note
        self.isMeasuredPair = isMeasuredPair
    }
}

public struct LiveRoutingState: Equatable, Sendable {
    public var inFlightCount: Int
    public var activeAgentName: String?
    public var targetModelDisplayName: String?
    public var targetTier: ModelTier?
    public var lastCompletedSummary: String?
    public var updatedAt: Date

    public init(
        inFlightCount: Int = 0,
        activeAgentName: String? = nil,
        targetModelDisplayName: String? = nil,
        targetTier: ModelTier? = nil,
        lastCompletedSummary: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.inFlightCount = inFlightCount
        self.activeAgentName = activeAgentName
        self.targetModelDisplayName = targetModelDisplayName
        self.targetTier = targetTier
        self.lastCompletedSummary = lastCompletedSummary
        self.updatedAt = updatedAt
    }
}

public struct RoutingImpactSummary: Equatable, Sendable {
    public var baselineModelDisplayName: String
    public var evaluatedTurnCount: Int
    public var actualCostUSD: Double
    public var baselineCostUSD: Double
    public var costSavedUSD: Double
    public var costSavingsPercent: Double?
    public var actualAvgLatencyMs: Double
    public var baselineAvgLatencyMs: Double?
    public var speedGainPercent: Double?
    public var speedSavedMsPerTurn: Double?
    public var totalTimeSavedSeconds: Double?
    public var actualTotalLatencyMs: Double
    public var baselineTotalLatencyMs: Double?
    public var speedSampleCount: Int
    public var speedComparedTurnCount: Int
    public var successRatePercent: Int
    public var retryCount: Int
    public var top10PercentCostSharePercent: Double?
    public var speedBasisLabel: String

    /// Positive when routing saved time, negative when it increased latency.
    public var timeDifferenceSeconds: Double? {
        guard speedSampleCount > 0, speedComparedTurnCount > 0, let baselineTotalLatencyMs else { return nil }
        return (baselineTotalLatencyMs - actualTotalLatencyMs) / 1_000
    }

    public init(
        baselineModelDisplayName: String,
        evaluatedTurnCount: Int,
        actualCostUSD: Double,
        baselineCostUSD: Double,
        costSavedUSD: Double,
        costSavingsPercent: Double?,
        actualAvgLatencyMs: Double,
        baselineAvgLatencyMs: Double?,
        speedGainPercent: Double?,
        speedSavedMsPerTurn: Double?,
        totalTimeSavedSeconds: Double? = nil,
        actualTotalLatencyMs: Double = 0,
        baselineTotalLatencyMs: Double? = nil,
        speedSampleCount: Int,
        successRatePercent: Int,
        retryCount: Int,
        top10PercentCostSharePercent: Double?,
        speedBasisLabel: String,
        speedComparedTurnCount: Int = 0
    ) {
        self.baselineModelDisplayName = baselineModelDisplayName
        self.evaluatedTurnCount = evaluatedTurnCount
        self.actualCostUSD = actualCostUSD
        self.baselineCostUSD = baselineCostUSD
        self.costSavedUSD = costSavedUSD
        self.costSavingsPercent = costSavingsPercent
        self.actualAvgLatencyMs = actualAvgLatencyMs
        self.baselineAvgLatencyMs = baselineAvgLatencyMs
        self.speedGainPercent = speedGainPercent
        self.speedSavedMsPerTurn = speedSavedMsPerTurn
        self.totalTimeSavedSeconds = totalTimeSavedSeconds
        self.actualTotalLatencyMs = actualTotalLatencyMs
        self.baselineTotalLatencyMs = baselineTotalLatencyMs
        self.speedSampleCount = speedSampleCount
        self.speedComparedTurnCount = speedComparedTurnCount
        self.successRatePercent = successRatePercent
        self.retryCount = retryCount
        self.top10PercentCostSharePercent = top10PercentCostSharePercent
        self.speedBasisLabel = speedBasisLabel
    }
}

public enum CallStatus: String, Codable, Sendable {
    case success
    case failed
    case rejected

    public var displayName: String {
        switch self {
        case .success: return "成功"
        case .failed: return "上游失败"
        case .rejected: return "本地拒绝"
        }
    }
}

public enum CallExecutionOrigin: String, Codable, Sendable {
    case real
    case demo
}

public enum CallSource: String, Codable, Sendable {
    case testBench = "test_bench"
    case externalProxy = "external_proxy"

    public var displayName: String {
        switch self {
        case .testBench: return "测试台"
        case .externalProxy: return "外部应用代理"
        }
    }
}

public struct CallRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var source: CallSource
    public var status: CallStatus
    public var requestedModel: String
    public var executedModelID: String?
    public var executedModelDisplayName: String?
    public var executedProviderName: String?
    public var httpStatusCode: Int
    public var requestFeatures: RequestFeatures
    public var decision: RoutingDecision
    public var attempts: [UpstreamAttemptRecord]
    public var routingDecisionMs: Double
    public var upstreamFirstTokenMs: Double?
    public var totalCompletionMs: Double
    public var finalUsage: TokenUsage?
    public var usageSource: UsageDataSource
    public var usageEstimationMethod: String?
    public var costStatus: CostCalculationStatus
    public var primaryAttemptCostUSD: Double?
    public var retryAttemptsCostUSD: Double
    public var totalCostUSD: Double?
    public var comparison: ComparisonAnalysis?
    public var requestPreview: String?
    public var responsePreview: String?
    public var reasoningPreview: String?
    public var errorMessage: String?
    public var clientName: String?
    public var endpointPath: String?
    /// Nil means a legacy receipt whose real/demo provenance cannot be established safely.
    public var executionOrigin: CallExecutionOrigin?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: CallSource,
        status: CallStatus,
        requestedModel: String,
        executedModelID: String?,
        executedModelDisplayName: String?,
        executedProviderName: String?,
        httpStatusCode: Int,
        requestFeatures: RequestFeatures,
        decision: RoutingDecision,
        attempts: [UpstreamAttemptRecord],
        routingDecisionMs: Double,
        upstreamFirstTokenMs: Double?,
        totalCompletionMs: Double,
        finalUsage: TokenUsage?,
        usageSource: UsageDataSource,
        usageEstimationMethod: String?,
        costStatus: CostCalculationStatus,
        primaryAttemptCostUSD: Double?,
        retryAttemptsCostUSD: Double,
        totalCostUSD: Double?,
        comparison: ComparisonAnalysis? = nil,
        requestPreview: String? = nil,
        responsePreview: String? = nil,
        reasoningPreview: String? = nil,
        errorMessage: String? = nil,
        clientName: String? = nil,
        endpointPath: String? = nil,
        executionOrigin: CallExecutionOrigin? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.status = status
        self.requestedModel = requestedModel
        self.executedModelID = executedModelID
        self.executedModelDisplayName = executedModelDisplayName
        self.executedProviderName = executedProviderName
        self.httpStatusCode = httpStatusCode
        self.requestFeatures = requestFeatures
        self.decision = decision
        self.attempts = attempts
        self.routingDecisionMs = routingDecisionMs
        self.upstreamFirstTokenMs = upstreamFirstTokenMs
        self.totalCompletionMs = totalCompletionMs
        self.finalUsage = finalUsage
        self.usageSource = usageSource
        self.usageEstimationMethod = usageEstimationMethod
        self.costStatus = costStatus
        self.primaryAttemptCostUSD = primaryAttemptCostUSD
        self.retryAttemptsCostUSD = retryAttemptsCostUSD
        self.totalCostUSD = totalCostUSD
        self.comparison = comparison
        self.requestPreview = requestPreview
        self.responsePreview = responsePreview
        self.reasoningPreview = reasoningPreview
        self.errorMessage = errorMessage
        self.clientName = clientName
        self.endpointPath = endpointPath
        self.executionOrigin = executionOrigin
    }
}

// MARK: - Formatting & Cost Helpers

public enum AutoModelFormatter {
    public static func formatUSD(_ value: Double?) -> String {
        guard let value else { return "无法计算费用" }
        if value == 0 { return "$0.000000" }
        if value < 0.0001 {
            return String(format: "$%.6f", value)
        }
        return String(format: "$%.5f", value)
    }

    public static func formatMs(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1 {
            return String(format: "%.2f ms", value)
        }
        if value < 1000 {
            return String(format: "%.0f ms", value)
        }
        return String(format: "%.2f s", value / 1000.0)
    }

    public static func formatPricePair(input: Double?, output: Double?) -> String {
        guard let input, let output else {
            return "未配置价格（无法计算费用）"
        }
        return String(format: "$%.2f / $%.2f (每百万 tokens)", input, output)
    }
}

public enum RoutingComplexityLevel: String, CaseIterable, Identifiable, Sendable {
    case high = "high"
    case medium = "medium"
    case low = "low"
    case direct = "direct"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .high: return "高复杂度 (高档)"
        case .medium: return "中复杂度 (中档)"
        case .low: return "低复杂度 (低档)"
        case .direct: return "指定模型直连"
        }
    }

    public var shortBadge: String {
        switch self {
        case .high: return "高复杂"
        case .medium: return "中复杂"
        case .low: return "低复杂"
        case .direct: return "直连"
        }
    }
}

public extension CallRecord {
    /// Complexity tier derived from the routing decision rules, explicit tier, or task intent.
    var routingComplexityLevel: RoutingComplexityLevel {
        if !decision.isAutoRouted {
            return .direct
        }
        let reqLower = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if reqLower == "auto/high" { return .high }
        if reqLower == "auto/medium" { return .medium }
        if reqLower == "auto/low" { return .low }

        let joinedRules = decision.matchedRules.joined(separator: "\n")
        if joinedRules.contains(ModelTier.high.displayName) { return .high }
        if joinedRules.contains(ModelTier.medium.displayName) { return .medium }
        if joinedRules.contains(ModelTier.low.displayName) { return .low }

        switch requestFeatures.detectedTaskType {
        case .complexReasoning, .longContext:
            return .high
        case .coding, .toolCalling, .visionMultimodal:
            return .medium
        case .simpleQA:
            return .low
        case .generalChat:
            if requestFeatures.requiresTools || requestFeatures.requiresVision || requestFeatures.estimatedInputTokens >= 1800 {
                return .medium
            }
            return .low
        }
    }

    /// Stable session grouping key; falls back to single-call ID when no fingerprint is present.
    var sessionGroupKey: String {
        if let fp = requestFeatures.conversationFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fp.isEmpty {
            return fp
        }
        return "single-\(id.uuidString)"
    }

    var hasConversationFingerprint: Bool {
        guard let fp = requestFeatures.conversationFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !fp.isEmpty
    }

    var executedModelShortLabel: String {
        executedModelDisplayName ?? executedModelID ?? requestedModel
    }

    var displayClientAgent: String {
        if let name = clientName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if source == .testBench {
            return "测试台"
        }
        if endpointPath == "/v1/messages" {
            return "Claude Code"
        }
        if endpointPath == "/v1/responses" {
            return "Codex"
        }
        return "外部客户端"
    }

    var shortSessionLabel: String {
        if let fp = requestFeatures.conversationFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fp.isEmpty {
            return "#\(String(fp.prefix(6)))"
        }
        return "单次"
    }

    /// Concise, factual natural-language summary of why this model was chosen and what happened.
    var humanReadableSummary: String {
        if status != .success {
            let reason = errorMessage ?? decision.errorSummary ?? "上游请求失败"
            if let model = executedModelDisplayName ?? executedModelID {
                return "本次尝试路由至「\(model)」（\(routingComplexityLevel.shortBadge)），但执行未成功：\(reason)"
            }
            return "本次请求（\(requestedModel)）未能完成路由或执行：\(reason)"
        }

        let modelName = executedModelShortLabel
        let complexityLabel = routingComplexityLevel.displayName

        var reasons: [String] = []
        if !decision.isAutoRouted {
            reasons.append("按你指定的模型「\(requestedModel)」直连转发")
        } else {
            let reqLower = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if reqLower == "auto/low" || reqLower == "auto/medium" || reqLower == "auto/high" {
                reasons.append("按显式档位「\(requestedModel)」直达")
            } else {
                var taskDesc = "识别为「\(requestFeatures.detectedTaskType.displayName)」"
                var caps: [String] = []
                if requestFeatures.requiresTools { caps.append("Tools") }
                if requestFeatures.requiresVision { caps.append("Vision") }
                if !caps.isEmpty {
                    taskDesc += "（需 \(caps.joined(separator: "+"))）"
                }
                reasons.append(taskDesc)
            }

            let joinedRules = decision.matchedRules.joined(separator: "\n")
            if joinedRules.contains("粘性") {
                reasons.append("沿用本会话上一轮模型以保留缓存")
            } else {
                reasons.append("依「\(decision.strategyName)」策略选中")
            }
        }

        if attempts.count > 1 {
            reasons.append("经 \(attempts.count) 次尝试后成功")
        }

        var metrics: [String] = []
        if let ttft = upstreamFirstTokenMs {
            metrics.append("首字 \(AutoModelFormatter.formatMs(ttft))")
        }
        metrics.append("总耗时 \(AutoModelFormatter.formatMs(totalCompletionMs))")
        if costStatus == .calculated, let cost = totalCostUSD {
            metrics.append("估算花费 \(AutoModelFormatter.formatUSD(cost))")
        } else {
            metrics.append("未配置单价（无法计算费用）")
        }

        return "本次由「\(modelName)」（\(complexityLabel)）执行 — \(reasons.joined(separator: "，"))；\(metrics.joined(separator: "，"))。"
    }

    var effectiveSubtaskCategory: AgentSubtaskCategory {
        if let cat = decision.subtaskCategory {
            return cat
        }
        if !decision.isAutoRouted {
            // Re-infer from preview if historical record didn't populate subtaskCategory
            return requestFeatures.subtaskCategory
        }
        return requestFeatures.subtaskCategory
    }

    var effectiveEffort: ReasoningEffort {
        if decision.isAutoRouted || decision.subtaskCategory != nil {
            return decision.selectedEffort
        }
        // Fallback heuristic for older records decoded with default .medium
        switch routingComplexityLevel {
        case .low: return .low
        case .high: return .high
        case .medium, .direct: return requestFeatures.recommendedEffort
        }
    }

    var conciseSubtaskDescription: String {
        if let summary = requestFeatures.subtaskSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary.count > 36 ? String(summary.prefix(35)) + "…" : summary
        }
        if let preview = requestPreview {
            let lines = preview
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("[system]") && !$0.hasPrefix("<system-reminder>") }
            if let lastToolOrUser = lines.reversed().first(where: { $0.hasPrefix("[user]") || $0.hasPrefix("[tool]") }) ?? lines.first {
                let cleaned = lastToolOrUser
                    .replacingOccurrences(of: "[user]", with: "")
                    .replacingOccurrences(of: "[tool]", with: "工具返回:")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned.count > 36 ? String(cleaned.prefix(35)) + "…" : cleaned
                }
            }
        }
        return effectiveSubtaskCategory.displayName
    }

    var conciseRoutingReason: String {
        if let note = decision.routingReasonNote?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            return note
        }
        let joined = decision.matchedRules.joined(separator: "；")
        if !decision.isAutoRouted {
            return "显式指定「\(requestedModel)」直连执行"
        }
        if joined.contains("粘性") {
            return "沿用同会话上一轮模型保留缓存 · \(effectiveSubtaskCategory.displayName)"
        }
        return effectiveSubtaskCategory.defaultRationale
    }
}
