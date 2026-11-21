import Foundation

public enum ProviderPresetCategory: String, CaseIterable, Identifiable, Sendable {
    case international = "international"
    case domestic = "domestic"
    case local = "local"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .international: return "国际官方与聚合"
        case .domestic: return "国内主流模型"
        case .local: return "本地服务"
        case .custom: return "自定义"
        }
    }
}

public struct ProviderPresetModelSeed: Equatable, Hashable, Sendable {
    public var modelID: String
    public var displayName: String
    public var contextWindow: Int
    public var capabilities: Set<ModelCapability>
    public var defaultRole: ModelDefaultUsage
    public var qualityScore: Int
    public var speedScore: Int
    public var inputPricePerMillion: Double?
    public var outputPricePerMillion: Double?
    public var cachedInputPricePerMillion: Double?
    public var cacheCreationPricePerMillion: Double?

    public init(
        modelID: String,
        displayName: String? = nil,
        contextWindow: Int = 128_000,
        capabilities: Set<ModelCapability> = [.chat, .tools],
        defaultRole: ModelDefaultUsage = .general,
        qualityScore: Int = 78,
        speedScore: Int = 78,
        inputPricePerMillion: Double? = nil,
        outputPricePerMillion: Double? = nil,
        cachedInputPricePerMillion: Double? = nil,
        cacheCreationPricePerMillion: Double? = nil
    ) {
        self.modelID = modelID
        self.displayName = displayName ?? modelID
        self.contextWindow = contextWindow
        self.capabilities = capabilities
        self.defaultRole = defaultRole
        self.qualityScore = qualityScore
        self.speedScore = speedScore
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cachedInputPricePerMillion = cachedInputPricePerMillion
        self.cacheCreationPricePerMillion = cacheCreationPricePerMillion
    }

    public func toModelConfig(providerID: UUID, source: String) -> ModelConfig {
        ModelConfig(
            providerID: providerID,
            modelID: modelID,
            displayName: displayName,
            isEnabled: true,
            inputPricePerMillion: inputPricePerMillion,
            outputPricePerMillion: outputPricePerMillion,
            cachedInputPricePerMillion: cachedInputPricePerMillion,
            cacheCreationPricePerMillion: cacheCreationPricePerMillion,
            contextWindow: contextWindow,
            capabilities: capabilities,
            defaultRole: defaultRole,
            qualityScore: qualityScore,
            speedScore: speedScore,
            availabilityStatus: .available,
            discoveredSource: source
        )
    }
}

public struct ProviderPreset: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var category: ProviderPresetCategory
    public var tagline: String
    public var baseURL: String
    public var apiProtocol: ProviderProtocol
    public var requiresAPIKey: Bool
    public var apiKeyPlaceholder: String
    public var defaultHeaders: [String: String]
    public var recommendedModels: [ProviderPresetModelSeed]
    public var docsURL: String

    public init(
        id: String,
        name: String,
        category: ProviderPresetCategory,
        tagline: String,
        baseURL: String,
        apiProtocol: ProviderProtocol = .openAIChatCompletions,
        requiresAPIKey: Bool = true,
        apiKeyPlaceholder: String = "sk-...",
        defaultHeaders: [String: String] = [:],
        recommendedModels: [ProviderPresetModelSeed] = [],
        docsURL: String = ""
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.tagline = tagline
        self.baseURL = baseURL
        self.apiProtocol = apiProtocol
        self.requiresAPIKey = requiresAPIKey
        self.apiKeyPlaceholder = apiKeyPlaceholder
        self.defaultHeaders = defaultHeaders
        self.recommendedModels = recommendedModels
        self.docsURL = docsURL
    }

    public func makeProviderConfig(
        customName: String? = nil,
        customBaseURL: String? = nil,
        proxyURL: String? = nil,
        customHeaders: [String: String]? = nil,
        passThroughHeaderNames: [String] = [],
        keyRotationStrategy: ProviderKeyRotationStrategy = .roundRobin
    ) -> ProviderConfig {
        let resolvedName = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedURL = customBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderConfig(
            name: (resolvedName?.isEmpty == false) ? resolvedName! : name,
            baseURL: (resolvedURL?.isEmpty == false) ? resolvedURL! : baseURL,
            isEnabled: true,
            discoveredSource: "preset:\(id)",
            apiProtocol: apiProtocol,
            presetID: id,
            customHeaders: customHeaders ?? defaultHeaders,
            passThroughHeaderNames: passThroughHeaderNames,
            proxyURL: proxyURL,
            keyRotationStrategy: keyRotationStrategy
        )
    }

    public func makeModelConfigs(providerID: UUID) -> [ModelConfig] {
        recommendedModels.map { $0.toModelConfig(providerID: providerID, source: "preset:\(id)") }
    }
}

public enum ProviderPresetCatalog {
    public static let allPresets: [ProviderPreset] = [
        // MARK: International
        ProviderPreset(
            id: "openai",
            name: "OpenAI",
            category: .international,
            tagline: "GPT-5 / GPT-4.1 / o4-mini 官方 Responses 接口",
            baseURL: "https://api.openai.com/v1",
            apiProtocol: .openAIResponses,
            apiKeyPlaceholder: "sk-proj-...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "gpt-5",
                    displayName: "GPT-5",
                    contextWindow: 400_000,
                    capabilities: [.chat, .tools, .vision, .reasoning],
                    defaultRole: .complexReasoning,
                    qualityScore: 95,
                    speedScore: 76,
                    inputPricePerMillion: 1.25,
                    outputPricePerMillion: 10.0,
                    cachedInputPricePerMillion: 0.125
                ),
                ProviderPresetModelSeed(
                    modelID: "gpt-4.1",
                    displayName: "GPT-4.1",
                    contextWindow: 1_000_000,
                    capabilities: [.chat, .tools, .vision],
                    defaultRole: .coding,
                    qualityScore: 88,
                    speedScore: 82,
                    inputPricePerMillion: 2.0,
                    outputPricePerMillion: 8.0,
                    cachedInputPricePerMillion: 0.5
                ),
                ProviderPresetModelSeed(
                    modelID: "gpt-4.1-mini",
                    displayName: "GPT-4.1 mini",
                    contextWindow: 1_000_000,
                    capabilities: [.chat, .tools, .vision],
                    defaultRole: .fastEconomy,
                    qualityScore: 74,
                    speedScore: 93,
                    inputPricePerMillion: 0.4,
                    outputPricePerMillion: 1.6,
                    cachedInputPricePerMillion: 0.1
                ),
                ProviderPresetModelSeed(
                    modelID: "o4-mini",
                    displayName: "o4-mini",
                    contextWindow: 200_000,
                    capabilities: [.chat, .tools, .vision, .reasoning],
                    defaultRole: .complexReasoning,
                    qualityScore: 86,
                    speedScore: 78,
                    inputPricePerMillion: 1.1,
                    outputPricePerMillion: 4.4,
                    cachedInputPricePerMillion: 0.275
                )
            ],
            docsURL: "https://platform.openai.com/docs"
        ),
        ProviderPreset(
            id: "anthropic",
            name: "Anthropic",
            category: .international,
            tagline: "Claude 原生 Messages 接口（支持 Prompt 缓存与 Extended Thinking）",
            baseURL: "https://api.anthropic.com",
            apiProtocol: .anthropicMessages,
            apiKeyPlaceholder: "sk-ant-...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "claude-opus-4-1",
                    displayName: "Claude Opus 4.1",
                    contextWindow: 200_000,
                    capabilities: [.chat, .tools, .vision, .reasoning],
                    defaultRole: .complexReasoning,
                    qualityScore: 96,
                    speedScore: 68,
                    inputPricePerMillion: 15.0,
                    outputPricePerMillion: 75.0,
                    cachedInputPricePerMillion: 1.5,
                    cacheCreationPricePerMillion: 18.75
                ),
                ProviderPresetModelSeed(
                    modelID: "claude-sonnet-4",
                    displayName: "Claude Sonnet 4",
                    contextWindow: 200_000,
                    capabilities: [.chat, .tools, .vision, .reasoning],
                    defaultRole: .coding,
                    qualityScore: 91,
                    speedScore: 82,
                    inputPricePerMillion: 3.0,
                    outputPricePerMillion: 15.0,
                    cachedInputPricePerMillion: 0.3,
                    cacheCreationPricePerMillion: 3.75
                ),
                ProviderPresetModelSeed(
                    modelID: "claude-3-5-haiku-latest",
                    displayName: "Claude 3.5 Haiku",
                    contextWindow: 200_000,
                    capabilities: [.chat, .tools, .vision],
                    defaultRole: .fastEconomy,
                    qualityScore: 75,
                    speedScore: 94,
                    inputPricePerMillion: 0.8,
                    outputPricePerMillion: 4.0,
                    cachedInputPricePerMillion: 0.08,
                    cacheCreationPricePerMillion: 1.0
                )
            ],
            docsURL: "https://docs.anthropic.com"
        ),
        ProviderPreset(
            id: "gemini",
            name: "Google Gemini",
            category: .international,
            tagline: "Gemini 2.5 Pro / Flash OpenAI 兼容端点（百万上下文）",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            apiProtocol: .openAIChatCompletions,
            apiKeyPlaceholder: "AIza...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "gemini-2.5-pro",
                    displayName: "Gemini 2.5 Pro",
                    contextWindow: 1_000_000,
                    capabilities: [.chat, .tools, .vision, .reasoning],
                    defaultRole: .complexReasoning,
                    qualityScore: 92,
                    speedScore: 78,
                    inputPricePerMillion: 1.25,
                    outputPricePerMillion: 10.0,
                    cachedInputPricePerMillion: 0.31
                ),
                ProviderPresetModelSeed(
                    modelID: "gemini-2.5-flash",
                    displayName: "Gemini 2.5 Flash",
                    contextWindow: 1_000_000,
                    capabilities: [.chat, .tools, .vision, .reasoning],
                    defaultRole: .fastEconomy,
                    qualityScore: 80,
                    speedScore: 94,
                    inputPricePerMillion: 0.15,
                    outputPricePerMillion: 0.6,
                    cachedInputPricePerMillion: 0.0375
                )
            ],
            docsURL: "https://ai.google.dev/gemini-api/docs/openai"
        ),
        ProviderPreset(
            id: "openrouter",
            name: "OpenRouter",
            category: .international,
            tagline: "聚合多厂商模型，内置 HTTP-Referer / X-Title 归因头",
            baseURL: "https://openrouter.ai/api/v1",
            apiProtocol: .openAIChatCompletions,
            apiKeyPlaceholder: "sk-or-v1-...",
            defaultHeaders: [
                "HTTP-Referer": "https://github.com/Profeel/autoroute",
                "X-Title": "AutoRoute"
            ],
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "anthropic/claude-sonnet-4",
                    displayName: "Claude Sonnet 4 (OR)",
                    contextWindow: 200_000,
                    capabilities: [.chat, .tools, .vision, .reasoning],
                    defaultRole: .coding,
                    qualityScore: 91,
                    speedScore: 80,
                    inputPricePerMillion: 3.0,
                    outputPricePerMillion: 15.0
                ),
                ProviderPresetModelSeed(
                    modelID: "openai/gpt-4.1",
                    displayName: "GPT-4.1 (OR)",
                    contextWindow: 1_000_000,
                    capabilities: [.chat, .tools, .vision],
                    defaultRole: .coding,
                    qualityScore: 88,
                    speedScore: 81,
                    inputPricePerMillion: 2.0,
                    outputPricePerMillion: 8.0
                ),
                ProviderPresetModelSeed(
                    modelID: "deepseek/deepseek-chat-v3-0324",
                    displayName: "DeepSeek V3 (OR)",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools],
                    defaultRole: .general,
                    qualityScore: 82,
                    speedScore: 85,
                    inputPricePerMillion: 0.27,
                    outputPricePerMillion: 1.1
                ),
                ProviderPresetModelSeed(
                    modelID: "google/gemini-2.5-flash",
                    displayName: "Gemini 2.5 Flash (OR)",
                    contextWindow: 1_000_000,
                    capabilities: [.chat, .tools, .vision, .reasoning],
                    defaultRole: .fastEconomy,
                    qualityScore: 80,
                    speedScore: 92,
                    inputPricePerMillion: 0.15,
                    outputPricePerMillion: 0.6
                )
            ],
            docsURL: "https://openrouter.ai/docs"
        ),
        ProviderPreset(
            id: "xai",
            name: "xAI (Grok)",
            category: .international,
            tagline: "Grok-3 / Grok-3-mini OpenAI 兼容接口",
            baseURL: "https://api.x.ai/v1",
            apiProtocol: .openAIChatCompletions,
            apiKeyPlaceholder: "xai-...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "grok-3",
                    displayName: "Grok 3",
                    contextWindow: 131_072,
                    capabilities: [.chat, .tools, .reasoning],
                    defaultRole: .complexReasoning,
                    qualityScore: 89,
                    speedScore: 80,
                    inputPricePerMillion: 3.0,
                    outputPricePerMillion: 15.0
                ),
                ProviderPresetModelSeed(
                    modelID: "grok-3-mini",
                    displayName: "Grok 3 Mini",
                    contextWindow: 131_072,
                    capabilities: [.chat, .tools, .reasoning],
                    defaultRole: .fastEconomy,
                    qualityScore: 76,
                    speedScore: 92,
                    inputPricePerMillion: 0.3,
                    outputPricePerMillion: 0.5
                )
            ],
            docsURL: "https://docs.x.ai"
        ),
        ProviderPreset(
            id: "groq",
            name: "Groq",
            category: .international,
            tagline: "超低延迟 LPU 推理（适合轻量快响应与工具预处理）",
            baseURL: "https://api.groq.com/openai/v1",
            apiProtocol: .openAIChatCompletions,
            apiKeyPlaceholder: "gsk_...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "llama-3.3-70b-versatile",
                    displayName: "Llama 3.3 70B",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools],
                    defaultRole: .general,
                    qualityScore: 78,
                    speedScore: 96,
                    inputPricePerMillion: 0.59,
                    outputPricePerMillion: 0.79
                ),
                ProviderPresetModelSeed(
                    modelID: "llama-3.1-8b-instant",
                    displayName: "Llama 3.1 8B Instant",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools],
                    defaultRole: .fastEconomy,
                    qualityScore: 66,
                    speedScore: 99,
                    inputPricePerMillion: 0.05,
                    outputPricePerMillion: 0.08
                )
            ],
            docsURL: "https://console.groq.com/docs"
        ),

        // MARK: Domestic (CN)
        ProviderPreset(
            id: "deepseek",
            name: "DeepSeek",
            category: .domestic,
            tagline: "DeepSeek-V3 / R1 官方接口（高性价比编码与推理）",
            baseURL: "https://api.deepseek.com/v1",
            apiProtocol: .openAIChatCompletions,
            apiKeyPlaceholder: "sk-...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "deepseek-chat",
                    displayName: "DeepSeek Chat (V3)",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools],
                    defaultRole: .coding,
                    qualityScore: 84,
                    speedScore: 88,
                    inputPricePerMillion: 0.27,
                    outputPricePerMillion: 1.1,
                    cachedInputPricePerMillion: 0.07
                ),
                ProviderPresetModelSeed(
                    modelID: "deepseek-reasoner",
                    displayName: "DeepSeek Reasoner (R1)",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools, .reasoning],
                    defaultRole: .complexReasoning,
                    qualityScore: 89,
                    speedScore: 72,
                    inputPricePerMillion: 0.55,
                    outputPricePerMillion: 2.19,
                    cachedInputPricePerMillion: 0.14
                )
            ],
            docsURL: "https://api-docs.deepseek.com"
        ),
        ProviderPreset(
            id: "kimi",
            name: "Kimi (Moonshot)",
            category: .domestic,
            tagline: "Kimi K2 / Moonshot 长上下文与 Agent 编码接口",
            baseURL: "https://api.moonshot.cn/v1",
            apiProtocol: .openAIChatCompletions,
            apiKeyPlaceholder: "sk-...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "kimi-k2-0711-preview",
                    displayName: "Kimi K2",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools],
                    defaultRole: .coding,
                    qualityScore: 86,
                    speedScore: 84,
                    inputPricePerMillion: 0.6,
                    outputPricePerMillion: 2.5
                ),
                ProviderPresetModelSeed(
                    modelID: "moonshot-v1-128k",
                    displayName: "Moonshot v1 128k",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools],
                    defaultRole: .general,
                    qualityScore: 74,
                    speedScore: 86
                )
            ],
            docsURL: "https://platform.moonshot.cn/docs"
        ),
        ProviderPreset(
            id: "glm",
            name: "智谱 GLM",
            category: .domestic,
            tagline: "GLM-4.5 / GLM-4.5-Air 开放平台接口",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            apiProtocol: .openAIChatCompletions,
            apiKeyPlaceholder: "...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "glm-4.5",
                    displayName: "GLM-4.5",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools, .reasoning],
                    defaultRole: .coding,
                    qualityScore: 84,
                    speedScore: 82
                ),
                ProviderPresetModelSeed(
                    modelID: "glm-4.5-air",
                    displayName: "GLM-4.5 Air",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools],
                    defaultRole: .fastEconomy,
                    qualityScore: 74,
                    speedScore: 92
                )
            ],
            docsURL: "https://open.bigmodel.cn/dev/api"
        ),
        ProviderPreset(
            id: "minimax",
            name: "MiniMax",
            category: .domestic,
            tagline: "MiniMax-M1 / Text-01 OpenAI 兼容接口",
            baseURL: "https://api.minimax.chat/v1",
            apiProtocol: .openAIChatCompletions,
            apiKeyPlaceholder: "eyJ...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "MiniMax-M1",
                    displayName: "MiniMax M1",
                    contextWindow: 1_000_000,
                    capabilities: [.chat, .tools, .reasoning],
                    defaultRole: .complexReasoning,
                    qualityScore: 84,
                    speedScore: 78
                ),
                ProviderPresetModelSeed(
                    modelID: "MiniMax-Text-01",
                    displayName: "MiniMax Text 01",
                    contextWindow: 1_000_000,
                    capabilities: [.chat, .tools],
                    defaultRole: .general,
                    qualityScore: 76,
                    speedScore: 86
                )
            ],
            docsURL: "https://platform.minimaxi.com"
        ),
        ProviderPreset(
            id: "qwen",
            name: "通义千问 Qwen (阿里云百炼)",
            category: .domestic,
            tagline: "Qwen3-Coder / Qwen-Plus / Turbo 兼容接口",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            apiProtocol: .openAIChatCompletions,
            apiKeyPlaceholder: "sk-...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "qwen3-coder-plus",
                    displayName: "Qwen3 Coder Plus",
                    contextWindow: 1_000_000,
                    capabilities: [.chat, .tools],
                    defaultRole: .coding,
                    qualityScore: 86,
                    speedScore: 84
                ),
                ProviderPresetModelSeed(
                    modelID: "qwen-plus",
                    displayName: "Qwen Plus",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools, .reasoning],
                    defaultRole: .general,
                    qualityScore: 80,
                    speedScore: 86
                ),
                ProviderPresetModelSeed(
                    modelID: "qwen-turbo",
                    displayName: "Qwen Turbo",
                    contextWindow: 1_000_000,
                    capabilities: [.chat, .tools],
                    defaultRole: .fastEconomy,
                    qualityScore: 70,
                    speedScore: 95
                )
            ],
            docsURL: "https://help.aliyun.com/zh/model-studio"
        ),
        ProviderPreset(
            id: "volcengine",
            name: "火山方舟 (豆包 / Ark)",
            category: .domestic,
            tagline: "Doubao / DeepSeek 火山引擎接入点（支持填写推理接入点 ID）",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            apiProtocol: .openAIChatCompletions,
            apiKeyPlaceholder: "ark-...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "doubao-seed-1-6",
                    displayName: "Doubao Seed 1.6",
                    contextWindow: 256_000,
                    capabilities: [.chat, .tools, .vision, .reasoning],
                    defaultRole: .general,
                    qualityScore: 83,
                    speedScore: 85
                )
            ],
            docsURL: "https://www.volcengine.com/docs/82379"
        ),
        ProviderPreset(
            id: "siliconflow",
            name: "硅基流动 (SiliconFlow)",
            category: .domestic,
            tagline: "聚合 DeepSeek / Qwen 开源主力模型",
            baseURL: "https://api.siliconflow.cn/v1",
            apiProtocol: .openAIChatCompletions,
            apiKeyPlaceholder: "sk-...",
            recommendedModels: [
                ProviderPresetModelSeed(
                    modelID: "deepseek-ai/DeepSeek-V3",
                    displayName: "DeepSeek-V3 (SF)",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools],
                    defaultRole: .coding,
                    qualityScore: 83,
                    speedScore: 85
                ),
                ProviderPresetModelSeed(
                    modelID: "deepseek-ai/DeepSeek-R1",
                    displayName: "DeepSeek-R1 (SF)",
                    contextWindow: 128_000,
                    capabilities: [.chat, .tools, .reasoning],
                    defaultRole: .complexReasoning,
                    qualityScore: 88,
                    speedScore: 72
                ),
                ProviderPresetModelSeed(
                    modelID: "Qwen/Qwen3-Coder-480B-A35B-Instruct",
                    displayName: "Qwen3 Coder 480B (SF)",
                    contextWindow: 262_144,
                    capabilities: [.chat, .tools],
                    defaultRole: .coding,
                    qualityScore: 86,
                    speedScore: 78
                )
            ],
            docsURL: "https://docs.siliconflow.cn"
        ),

        ProviderPreset(
            id: "workbuddy",
            name: "WorkBuddy（国内版）",
            category: .domestic,
            tagline: "使用 WorkBuddy API Key 获取并调用模型",
            baseURL: "https://copilot.tencent.com",
            apiProtocol: .workBuddy,
            apiKeyPlaceholder: "ck_... / pt_...",
            docsURL: "https://www.workbuddy.cn/profile/keys"
        ),
        ProviderPreset(
            id: "workbuddy-ai",
            name: "WorkBuddy AI（国际版）",
            category: .international,
            tagline: "使用 WorkBuddy AI API Key 获取并调用模型",
            baseURL: "https://www.workbuddy.ai",
            apiProtocol: .workBuddy,
            apiKeyPlaceholder: "ck_... / pt_...",
            docsURL: "https://www.workbuddy.ai/profile/keys"
        ),

        // MARK: Local
        ProviderPreset(
            id: "ollama",
            name: "Ollama (本机)",
            category: .local,
            tagline: "本机 Ollama OpenAI 兼容服务（免 API Key）",
            baseURL: "http://127.0.0.1:11434/v1",
            apiProtocol: .openAIChatCompletions,
            requiresAPIKey: false,
            apiKeyPlaceholder: "本机免密（可留空）",
            recommendedModels: [],
            docsURL: "https://ollama.com"
        ),
        ProviderPreset(
            id: "lmstudio",
            name: "LM Studio (本机)",
            category: .local,
            tagline: "本机 LM Studio 推理服务（免 API Key）",
            baseURL: "http://127.0.0.1:1234/v1",
            apiProtocol: .openAIChatCompletions,
            requiresAPIKey: false,
            apiKeyPlaceholder: "本机免密（可留空）",
            recommendedModels: [],
            docsURL: "https://lmstudio.ai"
        )
    ]

    public static func preset(id: String) -> ProviderPreset? {
        let target = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allPresets.first { $0.id.lowercased() == target }
    }

    public static func presets(in category: ProviderPresetCategory?) -> [ProviderPreset] {
        guard let category else { return allPresets }
        return allPresets.filter { $0.category == category }
    }

    public static func matchPreset(baseURL: String?, name: String? = nil) -> ProviderPreset? {
        let cleanURL = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !cleanURL.isEmpty {
            let normalizedIncoming = normalizeForMatch(cleanURL)
            if let exact = allPresets.first(where: { normalizeForMatch($0.baseURL.lowercased()) == normalizedIncoming }) {
                return exact
            }
            if let hostMatch = URL(string: cleanURL)?.host?.lowercased(), !hostMatch.isEmpty {
                if let matched = allPresets.first(where: { URL(string: $0.baseURL)?.host?.lowercased() == hostMatch }) {
                    return matched
                }
            }
        }
        let cleanName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !cleanName.isEmpty {
            return allPresets.first {
                $0.id.lowercased() == cleanName || $0.name.lowercased() == cleanName
            }
        }
        return nil
    }

    private static func normalizeForMatch(_ url: String) -> String {
        var u = url
        while u.hasSuffix("/") { u.removeLast() }
        if u.hasSuffix("/v1") { u = String(u.dropLast(3)) }
        return u
    }
}
