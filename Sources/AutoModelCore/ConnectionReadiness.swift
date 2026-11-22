import Foundation

public enum ProxyReadiness: Equatable {
    case running
    case stopped
    case portConflict(Int, Int?)
    case keychainError(String)
    case error(String)
}

public enum ProviderReadiness: Equatable {
    case missing
    case needsTesting
    case ready
}

public enum AgentReadiness: Equatable {
    case notConfigured
    case waiting
    case verified(UUID)

    public static func preferredOnboardingAgent(from statuses: [AgentIntegrationStatus]) -> AgentKind? {
        statuses.first(where: \.isConnectedToAutoModel)?.kind
            ?? statuses.first(where: { $0.isInstalled && $0.kind != .shellAndContinue })?.kind
            ?? statuses.first(where: { $0.kind == .codex })?.kind
            ?? statuses.first(where: \.isInstalled)?.kind
    }

    public static func evaluate(status: AgentIntegrationStatus, updatedAt: Date?, records: [CallRecord]) -> AgentReadiness {
        requestProgress(status: status, updatedAt: updatedAt, records: records).readiness
    }

    public static func requestProgress(status: AgentIntegrationStatus, updatedAt: Date?, records: [CallRecord])
        -> (readiness: AgentReadiness, latestFailureID: UUID?) {
        guard status.isConnectedToAutoModel else { return (.notConfigured, nil) }
        guard let updatedAt else { return (.waiting, nil) }
        var success: CallRecord?
        var failure: CallRecord?
        for record in records {
            guard record.source == .externalProxy, record.executionOrigin == .real,
                  record.decision.agentID == status.kind.rawValue, record.decision.agentIdentitySource == .modelAlias,
                  record.totalCompletionMs.isFinite, record.totalCompletionMs >= 0,
                  record.timestamp.addingTimeInterval(-record.totalCompletionMs / 1000) >= updatedAt else { continue }
            switch record.status {
            case .success where record.timestamp >= (success?.timestamp ?? .distantPast):
                success = record
            case .failed where record.timestamp >= (failure?.timestamp ?? .distantPast):
                failure = record
            default: break
            }
        }
        guard let success else { return (.waiting, failure?.id) }
        let latestFailureID = failure.flatMap { $0.timestamp > success.timestamp ? $0.id : nil }
        return (.verified(success.id), latestFailureID)
    }
}

@MainActor
public extension AutoModelEngine {
    var proxyReadiness: ProxyReadiness {
        guard isLocalAPITokenPersistent else {
            return .keychainError(localAPITokenPersistenceError ?? "本地凭据未保存到 Keychain")
        }
        switch proxyState {
        case .running: return .running
        case .stopped: return .stopped
        case .portConflict(let port, let suggested): return .portConflict(port, suggested)
        case .error(let message): return .error(message)
        }
    }

    var providerReadiness: ProviderReadiness {
        let models = healthyAvailableModels()
        guard !models.isEmpty else { return .missing }
        let healthyProviderIDs = Set(config.providers.filter { $0.isEnabled && $0.healthStatus == .healthy }.map(\.id))
        return models.contains { healthyProviderIDs.contains($0.providerID) && $0.lastProbedAt != nil }
            ? .ready : .needsTesting
    }

    func agentReadiness(for kind: AgentKind) -> AgentReadiness {
        let status = agentConfigService.inspectAgent(kind, proxyPort: config.proxySettings.port)
        return .evaluate(status: status, updatedAt: agentConfigService.configurationUpdatedAt(for: kind), records: callHistory)
    }
}
