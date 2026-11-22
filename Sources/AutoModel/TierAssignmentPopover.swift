import AutoModelCore
import SwiftUI

/// Lightweight popover for configuring a tier's primary model and ordered backup chain
/// for the currently active routing strategy.
struct TierAssignmentPopover: View {
    @ObservedObject var engine: AutoModelEngine
    let tier: ModelTier

    private var strategy: RoutingStrategyPreset {
        engine.config.policy.activeStrategy
    }

    private var assignment: TierModelAssignment {
        TierModelAssignment(
            primaryModelID: engine.config.policy.modelID(for: tier),
            backupModelIDs: engine.config.policy.backupModelIDs(for: tier)
        )
    }

    private var connectedModels: [(model: ModelConfig, provider: ProviderConfig)] {
        let providersByID = Dictionary(uniqueKeysWithValues: engine.config.providers.map { ($0.id, $0) })
        return engine.config.models.compactMap { model in
            guard model.isEnabled,
                  let provider = providersByID[model.providerID],
                  provider.isEnabled else {
                return nil
            }
            return (model, provider)
        }
        .sorted { lhs, rhs in
            if lhs.model.qualityScore != rhs.model.qualityScore {
                return lhs.model.qualityScore > rhs.model.qualityScore
            }
            return lhs.model.displayName < rhs.model.displayName
        }
    }

    private var backupCandidates: [(model: ModelConfig, provider: ProviderConfig)] {
        connectedModels.filter { item in
            item.model.id != assignment.primaryModelID && !assignment.backupModelIDs.contains(item.model.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(tier.displayName)配置")
                    .font(.headline)
                Spacer()
                Text(strategy.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("主用模型")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if connectedModels.isEmpty {
                    Text("暂无已接入的可用模型，请先在「提供商」页开启接入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("主用模型", selection: Binding(
                        get: { assignment.primaryModelID },
                        set: { newPrimary in
                            let filteredBackups = assignment.backupModelIDs.filter { $0 != newPrimary }
                            engine.setTierAssignment(
                                strategy: strategy,
                                tier: tier,
                                primaryModelID: newPrimary,
                                backupModelIDs: filteredBackups
                            )
                        }
                    )) {
                        Text("自动选择").tag(UUID?.none)
                        ForEach(connectedModels, id: \.model.id) { item in
                            Text("\(item.model.displayName) (\(item.provider.name))")
                                .tag(Optional(item.model.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("候选备用链（按顺序回退）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !backupCandidates.isEmpty {
                        Menu("+ 添加备用") {
                            ForEach(backupCandidates, id: \.model.id) { item in
                                Button("\(item.model.displayName) (\(item.provider.name))") {
                                    var next = assignment.backupModelIDs
                                    next.append(item.model.id)
                                    engine.setTierAssignment(
                                        strategy: strategy,
                                        tier: tier,
                                        primaryModelID: assignment.primaryModelID,
                                        backupModelIDs: next
                                    )
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .font(.caption)
                    }
                }

                if assignment.backupModelIDs.isEmpty {
                    Text("未配置候选备用；主通道冷却时优先切至同模型其他健康通道。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let modelsByID = Dictionary(uniqueKeysWithValues: engine.config.models.map { ($0.id, $0) })
                    let providersByID = Dictionary(uniqueKeysWithValues: engine.config.providers.map { ($0.id, $0) })
                    VStack(spacing: 4) {
                        ForEach(Array(assignment.backupModelIDs.enumerated()), id: \.element) { idx, bid in
                            let model = modelsByID[bid]
                            let providerName = model.flatMap { providersByID[$0.providerID]?.name } ?? "未知"
                            HStack(spacing: 6) {
                                Text("\(idx + 1).")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(model?.displayName ?? "已移除模型")
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(providerName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if idx > 0 {
                                    Button {
                                        var next = assignment.backupModelIDs
                                        next.swapAt(idx, idx - 1)
                                        engine.setTierAssignment(
                                            strategy: strategy,
                                            tier: tier,
                                            primaryModelID: assignment.primaryModelID,
                                            backupModelIDs: next
                                        )
                                    } label: {
                                        Image(systemName: "arrow.up")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                Button {
                                    let next = assignment.backupModelIDs.filter { $0 != bid }
                                    engine.setTierAssignment(
                                        strategy: strategy,
                                        tier: tier,
                                        primaryModelID: assignment.primaryModelID,
                                        backupModelIDs: next
                                    )
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
