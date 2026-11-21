import Foundation

/// Stable display identity only; routing continues to use CanonicalModelNormalizer.
public enum ModelPresentationIdentity {
    private static let prefixes: Set<String> = [
        "auto", "codex", "paiyun", "opendesign", "antigravity", "openrouter", "openai", "anthropic",
        "deepseek", "deepseek-ai", "google", "zhipu", "qwen", "moonshot"
    ]

    public static func id(for rawID: String) -> String {
        var value = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let slash = value.firstIndex(of: "/"), prefixes.contains(String(value[..<slash])) {
            value = String(value[value.index(after: slash)...])
        }
        value = value.replacingOccurrences(
            of: #"^claude-(opus|sonnet|haiku|fable)-(\d+)-(\d+)$"#,
            with: "claude-$1-$2.$3",
            options: .regularExpression
        )
        return value == "deepseek-v4.1-flash-1017" ? "deepseek-v4.1-flash" : value
    }

    public static func id(for model: ModelConfig) -> String {
        if let explicit = model.canonicalModelID?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return id(for: explicit)
        }
        return id(for: model.modelID)
    }

    public static func id(for record: CallRecord, models: [ModelConfig]) -> String {
        guard let rawID = record.executedModelID, !rawID.isEmpty else { return id(for: record.requestedModel) }
        let attempt = record.attempts.last { $0.modelID == rawID }
        let modelID = attempt?.modelUUID ?? record.decision.selectedModelUUID
        guard let modelID, let model = models.first(where: { $0.id == modelID && $0.modelID == rawID }),
              attempt?.providerID == nil || attempt?.providerID == model.providerID else {
            return id(for: rawID)
        }
        return id(for: model)
    }
}

public struct PublicBenchmarkEntry: Identifiable, Equatable, Sendable {
    public var id: String { canonicalModelID }
    public let canonicalModelID: String
    public let displayName: String
    /// Artificial Analysis Coding Agent Index points, not a percentage.
    public let benchmarkScore: Double
    /// Reference average API cost per task for the same evaluation row.
    public let avgCostPerTaskUSD: Double
    public let harness: String
    public let configuration: String
    public let sourceURL: URL
    public let versionNote: String?

    public init(
        canonicalModelID: String,
        displayName: String,
        benchmarkScore: Double,
        avgCostPerTaskUSD: Double,
        harness: String,
        configuration: String,
        sourceURL: URL,
        versionNote: String? = nil
    ) {
        self.canonicalModelID = canonicalModelID
        self.displayName = displayName
        self.benchmarkScore = benchmarkScore
        self.avgCostPerTaskUSD = avgCostPerTaskUSD
        self.harness = harness
        self.configuration = configuration
        self.sourceURL = sourceURL
        self.versionNote = versionNote
    }
}

public struct MatchedBenchmarkPoint: Identifiable, Equatable, Sendable {
    public var id: String { entry.canonicalModelID }
    public let entry: PublicBenchmarkEntry
    public let connectedChannels: [AutoModelGroupChannel]

    public var isLit: Bool { !connectedChannels.isEmpty }

    public var channelSummaryLabel: String? {
        guard !connectedChannels.isEmpty else { return nil }
        let names = Array(Set(connectedChannels.map(\.providerName))).sorted()
        let label = names.joined(separator: " + ")
        return connectedChannels.count == 1 ? label : "\(label)（\(connectedChannels.count) 个通道）"
    }
}

public struct UnmatchedBenchmarkModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let channelCount: Int
}

public struct PublicBenchmarkCoverage: Equatable, Sendable {
    public let points: [MatchedBenchmarkPoint]
    public let unmatchedModels: [UnmatchedBenchmarkModel]
}

/// Offline snapshot of published evaluation rows; no network access is needed at runtime.
public enum PublicBenchmarkCatalog {
    public static let catalogVersion = "v2.1"
    public static let benchmarkName = "Artificial Analysis Coding Agent Index"
    public static let updatedAt = "2026-11-21"
    public static let methodologyURL = URL(string: "https://artificialanalysis.ai/methodology/coding-agents-benchmarking")!
    private static let codexSource = URL(string: "https://artificialanalysis.ai/agents/coding-agents/comparisons/codex-vs-opencode")!
    private static let claudeSource = URL(string: "https://artificialanalysis.ai/agents/coding-agents/comparisons/claude-code-vs-opencode")!
    private static let deepSeekSource = URL(string: "https://artificialanalysis.ai/agents/coding-agents/comparisons/codex-vs-deepseek-harness")!
    private static let geminiSource = URL(string: "https://artificialanalysis.ai/agents/coding-agents/comparisons/antigravity-cli-vs-deepseek-harness")!
    private static let kimiSource = URL(string: "https://artificialanalysis.ai/agents/coding-agents/comparisons/deepseek-harness-vs-kimi-code-cli")!

    public static let entries: [PublicBenchmarkEntry] = [
        PublicBenchmarkEntry(canonicalModelID: "gpt-6.2-astra", displayName: "GPT-6.2 Astra", benchmarkScore: 53, avgCostPerTaskUSD: 5.12, harness: "Codex", configuration: "Max", sourceURL: codexSource),
        PublicBenchmarkEntry(canonicalModelID: "gpt-6.2-sol", displayName: "GPT-6.2 Sol", benchmarkScore: 50, avgCostPerTaskUSD: 0.90, harness: "Codex", configuration: "Xhigh", sourceURL: codexSource),
        PublicBenchmarkEntry(canonicalModelID: "gpt-6-astra", displayName: "GPT-6 Astra", benchmarkScore: 53, avgCostPerTaskUSD: 7.63, harness: "Codex", configuration: "Max", sourceURL: codexSource),
        PublicBenchmarkEntry(canonicalModelID: "gpt-6.1-sol", displayName: "GPT-6.1 Sol", benchmarkScore: 52, avgCostPerTaskUSD: 1.51, harness: "Codex", configuration: "Max", sourceURL: codexSource),
        PublicBenchmarkEntry(canonicalModelID: "gpt-6.1-terra", displayName: "GPT-6.1 Terra", benchmarkScore: 49, avgCostPerTaskUSD: 1.53, harness: "Codex", configuration: "Max", sourceURL: codexSource),
        PublicBenchmarkEntry(canonicalModelID: "gpt-6-luna", displayName: "GPT-6 Luna", benchmarkScore: 26, avgCostPerTaskUSD: 0.19, harness: "Codex", configuration: "Max", sourceURL: codexSource),
        PublicBenchmarkEntry(canonicalModelID: "glm-5.3", displayName: "GLM-5.3", benchmarkScore: 40, avgCostPerTaskUSD: 5.41, harness: "OpenCode", configuration: "Max", sourceURL: codexSource),
        PublicBenchmarkEntry(canonicalModelID: "claude-opus-5.5", displayName: "Claude Opus 5.5", benchmarkScore: 58, avgCostPerTaskUSD: 12.61, harness: "Claude Code", configuration: "Max · Default Fallback", sourceURL: claudeSource),
        PublicBenchmarkEntry(canonicalModelID: "claude-sonnet-5.5", displayName: "Claude Sonnet 5.5", benchmarkScore: 56, avgCostPerTaskUSD: 11.40, harness: "Claude Code", configuration: "Max · Default Fallback", sourceURL: claudeSource),
        PublicBenchmarkEntry(canonicalModelID: "claude-haiku-5.5", displayName: "Claude Haiku 5.5", benchmarkScore: 30, avgCostPerTaskUSD: 2.25, harness: "Claude Code", configuration: "Max", sourceURL: claudeSource),
        PublicBenchmarkEntry(canonicalModelID: "deepseek-v4.1-flash", displayName: "DeepSeek V4.1 Flash 1017", benchmarkScore: 37, avgCostPerTaskUSD: 0.32, harness: "DeepSeek Harness", configuration: "Max", sourceURL: deepSeekSource, versionNote: "1017 版本参考；已启用的未固定版本通道可能不同"),
        PublicBenchmarkEntry(canonicalModelID: "claude-fable-5.2", displayName: "Claude Fable 5.2", benchmarkScore: 58, avgCostPerTaskUSD: 15.47, harness: "Claude Code", configuration: "Xhigh · Default Fallback", sourceURL: claudeSource),
        PublicBenchmarkEntry(canonicalModelID: "claude-fable-5.1", displayName: "Claude Fable 5.1", benchmarkScore: 52, avgCostPerTaskUSD: 11.70, harness: "Claude Code", configuration: "Max · Default Fallback", sourceURL: claudeSource),
        PublicBenchmarkEntry(canonicalModelID: "step-5-preview", displayName: "Step 5 Preview", benchmarkScore: 36, avgCostPerTaskUSD: 3.55, harness: "Claude Code", configuration: "Reasoning", sourceURL: claudeSource),
        PublicBenchmarkEntry(canonicalModelID: "qwen3.8-max", displayName: "Qwen3.8 Max", benchmarkScore: 33, avgCostPerTaskUSD: 4.03, harness: "Claude Code", configuration: "Reasoning", sourceURL: claudeSource),
        PublicBenchmarkEntry(canonicalModelID: "gemini-4-neon", displayName: "Gemini 4 Neon", benchmarkScore: 59, avgCostPerTaskUSD: 6.86, harness: "Antigravity CLI", configuration: "Xhigh", sourceURL: geminiSource),
        PublicBenchmarkEntry(canonicalModelID: "kimi-k3.1-pro", displayName: "Kimi K3.1 Pro", benchmarkScore: 49, avgCostPerTaskUSD: 2.94, harness: "Kimi Code CLI", configuration: "Max", sourceURL: kimiSource)
    ]

    public static func coverage(
        providers: [ProviderConfig],
        models: [ModelConfig],
        cooldownUntilByModelID: [UUID: Date] = [:],
        now: Date = Date()
    ) -> PublicBenchmarkCoverage {
        let groups = CanonicalModelGroupingBuilder.buildGroups(
            providers: providers,
            models: models,
            cooldownUntilByModelID: cooldownUntilByModelID,
            now: now,
            connectedOnly: true
        )
        let knownIDs = Set(entries.map(\.canonicalModelID))
        var byID: [String: [AutoModelGroupChannel]] = [:]
        for channel in groups.flatMap(\.connectedChannels) {
            let id = ModelPresentationIdentity.id(for: channel.modelConfig)
            guard !id.isEmpty else { continue }
            byID[id, default: []].append(channel)
        }
        let points = entries.map { entry in
            MatchedBenchmarkPoint(
                entry: entry,
                connectedChannels: CanonicalModelGroupingBuilder.sortChannels(byID[entry.canonicalModelID] ?? [])
            )
        }
        let unmatched = byID.compactMap { id, channels -> UnmatchedBenchmarkModel? in
            guard !knownIDs.contains(id), let channel = channels.first else { return nil }
            return UnmatchedBenchmarkModel(id: id, displayName: channel.modelConfig.displayName, channelCount: channels.count)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return PublicBenchmarkCoverage(points: points, unmatchedModels: unmatched)
    }

    public static func matchPoints(
        providers: [ProviderConfig],
        models: [ModelConfig],
        cooldownUntilByModelID: [UUID: Date] = [:],
        now: Date = Date()
    ) -> [MatchedBenchmarkPoint] {
        coverage(providers: providers, models: models, cooldownUntilByModelID: cooldownUntilByModelID, now: now).points
    }
}
