import Foundation

/// Normalizes provider-specific model IDs into a canonical logical model identifier
/// so equivalent models from different providers can be grouped for availability routing.
public enum CanonicalModelNormalizer {
    private static let knownVendorPrefixes = [
        "anthropic/",
        "openai/",
        "deepseek/",
        "deepseek-ai/",
        "google/",
        "x-ai/",
        "xai/",
        "qwen/",
        "meta-llama/",
        "openrouter/",
        "mistralai/",
        "cohere/",
        "moonshot/",
        "zhipu/",
        "minimax/",
        "volcengine/",
        "dashscope/",
        "azure/",
        "bedrock/"
    ]

    public static func normalize(_ rawModelID: String) -> String {
        var value = rawModelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else { return "" }

        // Strip known vendor/gateway prefixes (may be nested like openrouter/anthropic/...)
        var stripped = true
        while stripped {
            stripped = false
            for prefix in knownVendorPrefixes where value.hasPrefix(prefix) {
                value.removeFirst(prefix.count)
                stripped = true
                break
            }
        }
        // If another slash remains (e.g. org/model), take the last path segment
        if let slashIndex = value.lastIndex(of: "/") {
            let tail = String(value[value.index(after: slashIndex)...])
            if !tail.isEmpty {
                value = tail
            }
        }

        // Strip channel/tag suffixes like :free, :beta, @latest, -v1:0
        if let colonIndex = value.firstIndex(of: ":") {
            value = String(value[..<colonIndex])
        }
        if let atIndex = value.firstIndex(of: "@") {
            value = String(value[..<atIndex])
        }

        // Strip trailing date stamps: -YYYYMMDD, -YYYY-MM-DD, -MMDD
        value = value.replacingOccurrences(
            of: #"-(20\d{2}-?\d{2}-?\d{2}|\d{8}|\d{4})$"#,
            with: "",
            options: .regularExpression
        )
        // Strip trailing -latest or -preview-YYYY-MM
        value = value.replacingOccurrences(
            of: #"-(latest|preview)$"#,
            with: "",
            options: .regularExpression
        )

        // Normalize Claude major-minor hyphenated versions (e.g. claude-3-7-sonnet -> claude-3.7-sonnet)
        value = value.replacingOccurrences(
            of: #"claude-(\d+)-(\d+)-"#,
            with: "claude-$1.$2-",
            options: .regularExpression
        )
        // Normalize Claude 4.x family ordering if written as claude-4-5-sonnet -> claude-4.5-sonnet
        value = value.replacingOccurrences(
            of: #"claude-(sonnet|opus|haiku)-(\d+)-(\d+)$"#,
            with: "claude-$1-$2.$3",
            options: .regularExpression
        )

        return value
    }

    public static func canonicalID(for model: ModelConfig) -> String {
        if let explicit = model.canonicalModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return normalize(explicit)
        }
        return normalize(model.modelID)
    }
}

public struct AutoModelGroupChannel: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let providerID: UUID
    public let providerName: String
    public let modelConfig: ModelConfig
    public let isConnected: Bool
    public let isCoolingDown: Bool
    public let cooldownRemainingSec: Double?
    public let avgLatencyMs: Double?

    public init(
        id: UUID,
        providerID: UUID,
        providerName: String,
        modelConfig: ModelConfig,
        isConnected: Bool,
        isCoolingDown: Bool,
        cooldownRemainingSec: Double?,
        avgLatencyMs: Double?
    ) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName
        self.modelConfig = modelConfig
        self.isConnected = isConnected
        self.isCoolingDown = isCoolingDown
        self.cooldownRemainingSec = cooldownRemainingSec
        self.avgLatencyMs = avgLatencyMs
    }

    public var isHealthy: Bool {
        isConnected && !isCoolingDown && !modelConfig.isAutoEvicted && modelConfig.availabilityStatus == .available
    }
}

public struct AutoModelGroup: Identifiable, Equatable, Sendable {
    public var id: String { canonicalID }
    public let canonicalID: String
    public var displayName: String
    public var channels: [AutoModelGroupChannel]

    public init(
        canonicalID: String,
        displayName: String,
        channels: [AutoModelGroupChannel]
    ) {
        self.canonicalID = canonicalID
        self.displayName = displayName
        self.channels = channels
    }

    /// Preferred healthy connected channel sorted by health -> availability -> latency.
    public var activeChannel: AutoModelGroupChannel? {
        channels.first(where: { $0.isHealthy })
    }

    public var connectedChannels: [AutoModelGroupChannel] {
        channels.filter(\.isConnected)
    }
}

public enum CanonicalModelGroupingBuilder {
    public static func buildGroups(
        providers: [ProviderConfig],
        models: [ModelConfig],
        cooldownUntilByModelID: [UUID: Date] = [:],
        avgLatencyByModelID: [UUID: Double] = [:],
        now: Date = Date(),
        connectedOnly: Bool = false
    ) -> [AutoModelGroup] {
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        var grouped: [String: [AutoModelGroupChannel]] = [:]

        for model in models {
            guard let provider = providersByID[model.providerID] else { continue }
            let isConnected = provider.isEnabled && model.isEnabled
            if connectedOnly && !isConnected { continue }

            let canonicalID = CanonicalModelNormalizer.canonicalID(for: model)
            guard !canonicalID.isEmpty else { continue }

            let cooldownUntil = cooldownUntilByModelID[model.id]
            let isCoolingDown = cooldownUntil.map { $0 > now } ?? false
            let remainingSec = isCoolingDown ? cooldownUntil?.timeIntervalSince(now) : nil
            let latency = avgLatencyByModelID[model.id] ?? model.lastProbeLatencyMs

            let channel = AutoModelGroupChannel(
                id: model.id,
                providerID: provider.id,
                providerName: provider.name,
                modelConfig: model,
                isConnected: isConnected,
                isCoolingDown: isCoolingDown,
                cooldownRemainingSec: remainingSec,
                avgLatencyMs: latency
            )
            grouped[canonicalID, default: []].append(channel)
        }

        return grouped.map { canonicalID, rawChannels in
            let sortedChannels = sortChannels(rawChannels)
            let displayName = sortedChannels.first(where: { $0.isConnected })?.modelConfig.displayName
                ?? sortedChannels.first?.modelConfig.displayName
                ?? canonicalID
            return AutoModelGroup(
                canonicalID: canonicalID,
                displayName: displayName,
                channels: sortedChannels
            )
        }
        .sorted { lhs, rhs in
            let lhsConnected = lhs.connectedChannels.count
            let rhsConnected = rhs.connectedChannels.count
            if lhsConnected != rhsConnected {
                return lhsConnected > rhsConnected
            }
            if lhs.channels.count != rhs.channels.count {
                return lhs.channels.count > rhs.channels.count
            }
            return lhs.canonicalID < rhs.canonicalID
        }
    }

    public static func sortChannels(_ channels: [AutoModelGroupChannel]) -> [AutoModelGroupChannel] {
        channels.sorted { lhs, rhs in
            if lhs.isHealthy != rhs.isHealthy {
                return lhs.isHealthy
            }
            if lhs.isConnected != rhs.isConnected {
                return lhs.isConnected
            }
            if lhs.isCoolingDown != rhs.isCoolingDown {
                return !lhs.isCoolingDown
            }
            let lhsLat = lhs.avgLatencyMs ?? .greatestFiniteMagnitude
            let rhsLat = rhs.avgLatencyMs ?? .greatestFiniteMagnitude
            if lhsLat != rhsLat {
                return lhsLat < rhsLat
            }
            return lhs.providerName < rhs.providerName
        }
    }
}
