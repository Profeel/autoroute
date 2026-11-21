import Foundation

public struct AgentPolicyProfile: Codable, Equatable, Sendable {
    public var kind: AgentKind
    public var strategy: RoutingStrategyPreset?
    public var defaultTier: ModelTier?
    public var lowTierModelID: UUID?
    public var mediumTierModelID: UUID?
    public var highTierModelID: UUID?

    public init(
        kind: AgentKind,
        strategy: RoutingStrategyPreset? = nil,
        defaultTier: ModelTier? = nil,
        lowTierModelID: UUID? = nil,
        mediumTierModelID: UUID? = nil,
        highTierModelID: UUID? = nil
    ) {
        self.kind = kind
        self.strategy = strategy
        self.defaultTier = defaultTier
        self.lowTierModelID = lowTierModelID
        self.mediumTierModelID = mediumTierModelID
        self.highTierModelID = highTierModelID
    }

    fileprivate func applying(to global: RoutingPolicyConfig, includeStrategy: Bool) -> RoutingPolicyConfig {
        var policy = global
        if includeStrategy, let strategy {
            policy.activeStrategy = strategy
        }
        if let lowTierModelID {
            policy.setTier(.low, modelID: lowTierModelID, isManual: true)
        }
        if let mediumTierModelID {
            policy.setTier(.medium, modelID: mediumTierModelID, isManual: true)
        }
        if let highTierModelID {
            policy.setTier(.high, modelID: highTierModelID, isManual: true)
        }
        return policy
    }
}

public extension AgentModelBinding {
    static func stableIdentity(for kind: AgentKind) -> AgentModelBinding {
        let alias = "auto/agent/\(kind.rawValue)"
        return AgentModelBinding(
            defaultModelOption: alias,
            lowModelOption: "\(alias)/low",
            mediumModelOption: "\(alias)/medium",
            highModelOption: "\(alias)/high"
        )
    }
}

public enum AgentIdentitySource: String, Codable, Equatable, Sendable {
    case modelAlias = "model_alias"
    case explicitHeader = "explicit_header"
}

public struct AgentRequestResolutionError: Error, Equatable, Sendable {
    public let statusCode: Int
    public let code: String
    public let message: String

    public init(statusCode: Int = 400, code: String = "unknown_agent_alias", message: String) {
        self.statusCode = statusCode
        self.code = code
        self.message = message
    }
}

public struct ResolvedAgentRequest: Equatable, Sendable {
    public let originalRequestedModel: String
    public let effectiveRequestedModel: String
    public let agentKind: AgentKind?
    public let identitySource: AgentIdentitySource?
    public let policy: RoutingPolicyConfig
    public let appliesAgentPolicy: Bool
    public let overrideReason: String?
}

public enum AgentRequestResolver {
    public static func resolve(
        requestedModel: String,
        agentHeader: String?,
        globalPolicy: RoutingPolicyConfig,
        profiles: [String: AgentPolicyProfile]
    ) throws -> ResolvedAgentRequest {
        let requested = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveLegacyRequest = requested.isEmpty ? "auto" : requested

        if requested == "auto/agent" || requested.hasPrefix("auto/agent/") {
            let components = requested.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.count >= 3, components.count <= 4,
                  let kind = AgentKind(rawValue: components[2]) else {
                throw AgentRequestResolutionError(
                    message: "未知 Agent 模型别名「\(requested)」。请使用 auto/agent/<agent>，支持的 Agent: \(AgentKind.allCases.map(\.rawValue).joined(separator: ", "))。"
                )
            }

            var explicitTier: ModelTier?
            if components.count == 4 {
                guard let tier = ModelTier(rawValue: components[3]) else {
                    throw AgentRequestResolutionError(message: "Agent 别名「\(requested)」的档位无效，只允许 low、medium 或 high。")
                }
                explicitTier = tier
            }

            let profile = profiles[kind.rawValue] ?? AgentPolicyProfile(kind: kind)
            let targetTier = explicitTier ?? profile.defaultTier
            let effectiveModel = targetTier.map { "auto/\($0.rawValue)" } ?? "auto"
            let reason = explicitTier == nil
                ? "命中 \(kind.displayName) profile，应用 Agent 策略与档位覆盖"
                : "命中 \(kind.displayName) profile，显式档位优先于 Agent 默认策略"
            return ResolvedAgentRequest(
                originalRequestedModel: effectiveLegacyRequest,
                effectiveRequestedModel: effectiveModel,
                agentKind: kind,
                identitySource: .modelAlias,
                policy: profile.applying(to: globalPolicy, includeStrategy: explicitTier == nil),
                appliesAgentPolicy: true,
                overrideReason: reason
            )
        }

        var kind: AgentKind?
        if let rawHeader = agentHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHeader.isEmpty {
            guard let parsed = AgentKind(rawValue: rawHeader) else {
                throw AgentRequestResolutionError(message: "X-AutoModel-Agent 包含未知身份「\(rawHeader)」。")
            }
            kind = parsed
        }

        let lower = effectiveLegacyRequest.lowercased()
        let isLegacyAuto = lower == "auto" || lower == "automodel/auto"
        let appliesPolicy = kind != nil && isLegacyAuto
        let policy: RoutingPolicyConfig
        let reason: String?
        if appliesPolicy, let kind {
            let profile = profiles[kind.rawValue] ?? AgentPolicyProfile(kind: kind)
            policy = profile.applying(to: globalPolicy, includeStrategy: true)
            reason = "X-AutoModel-Agent 命中 \(kind.displayName) profile"
        } else {
            policy = globalPolicy
            reason = kind == nil ? nil : "显式档位或具体模型优先，Agent 仅用于收据身份与预算归属"
        }

        return ResolvedAgentRequest(
            originalRequestedModel: effectiveLegacyRequest,
            effectiveRequestedModel: effectiveLegacyRequest,
            agentKind: kind,
            identitySource: kind == nil ? nil : .explicitHeader,
            policy: policy,
            appliesAgentPolicy: appliesPolicy,
            overrideReason: reason
        )
    }
}
