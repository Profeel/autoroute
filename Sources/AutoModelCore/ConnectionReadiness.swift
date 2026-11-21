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

    public static func evaluate(status: AgentIntegrationStatus, updatedAt: Date?, records: [CallRecord]) -> AgentReadiness {
        guard status.isConnectedToAutoModel else { return .notConfigured }
        guard let updatedAt else { return .waiting }
        guard let record = records.first(where: {
            $0.totalCompletionMs.isFinite && $0.totalCompletionMs >= 0
                && $0.timestamp.addingTimeInterval(-$0.totalCompletionMs / 1000) >= updatedAt
                && $0.source == .externalProxy && $0.status == .success
                && $0.executionOrigin == .real && $0.decision.agentID == status.kind.rawValue
                && $0.decision.agentIdentitySource == .modelAlias
        }) else { return .waiting }
        return .verified(record.id)
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
