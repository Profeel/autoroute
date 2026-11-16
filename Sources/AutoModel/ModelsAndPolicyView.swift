import AutoModelCore
import SwiftUI

struct ModelsAndPolicyView: View {
    @ObservedObject var engine: AutoModelEngine

    @State private var selectedProviderID: UUID?
    @State private var showAddProvider = false
    @State private var editingProvider: ProviderConfig?
    @State private var showAddModel = false
    @State private var editingModel: ModelConfig?

    @State private var showCandidatePool = true
    @State private var showDisabledModels = false
    @State private var showAdvancedPolicy = false

    @State private var maxInInput: String = ""
    @State private var maxOutInput: String = ""
    @State private var feedbackMessage: String?

    private var healthyModels: [ModelConfig] {
        engine.healthyAvailableModels()
    }

    private var selectedProvider: ProviderConfig? {
        if let id = selectedProviderID, let found = engine.config.providers.first(where: { $0.id == id }) {
            return found
        }
        return engine.config.providers.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let feedbackMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(feedbackMessage)
                            .font(.callout)
                        Spacer()
                        Button("关闭") { self.feedbackMessage = nil }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                threeTierSlotsSection
                routingStrategySection
                providersAndModelsSection
            }
            .padding(20)
        }
        .navigationTitle("模型与策略")
        .onAppear {
            if selectedProviderID == nil {
                selectedProviderID = engine.config.providers.first?.id
            }
            syncPriceCapInputs()
        }
        .sheet(isPresented: $showAddProvider) {
            ProviderEditorSheet(existingProvider: nil, existingHasKey: false) { newProvider, apiKey in
                do {
                    try engine.upsertProvider(newProvider, apiKey: apiKey)
                    selectedProviderID = newProvider.id
                    feedbackMessage = "已添加供应商「\(newProvider.name)」。"
                } catch {
                    feedbackMessage = "保存供应商失败: \(error.localizedDescription)"
                }
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditorSheet(
                existingProvider: provider,
                existingHasKey: engine.hasAPIKey(for: provider.id)
            ) { updated, apiKey in
                do {
                    try engine.upsertProvider(updated, apiKey: apiKey)
                    selectedProviderID = updated.id
                    feedbackMessage = "已更新供应商「\(updated.name)」。"
                } catch {
                    feedbackMessage = "更新供应商失败: \(error.localizedDescription)"
                }
            }
        }
        .sheet(isPresented: $showAddModel) {
            if let provider = selectedProvider {
                ModelEditorSheet(providerID: provider.id, existingModel: nil) { created in
                    engine.upsertModel(created)
                    feedbackMessage = "已添加模型「\(created.displayName)」。"
                }
            }
        }
        .sheet(item: $editingModel) { model in
            ModelEditorSheet(providerID: model.providerID, existingModel: model) { updated in
                engine.upsertModel(updated)
                feedbackMessage = "已更新模型「\(updated.displayName)」。"
            }
        }
    }

    // MARK: - 1. Active Three-Tier Slots

    private var threeTierSlotsSection: some View {
        let healthyIDs = Set(healthyModels.map(\.id))
        let providersByID = Dictionary(uniqueKeysWithValues: engine.config.providers.map { ($0.id, $0) })

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前上岗模型（低 / 中 / 高三档）")
                    .font(.headline)
                Spacer()
                Button("填充参考单价") {
                    let count = engine.fillReferencePricingForUnpricedModels()
                    feedbackMessage = count > 0
                        ? "已为 \(count) 个未配置单价的模型补全公开参考价格。"
                        : "当前模型均已配置单价，或暂无匹配的公开参考价格。"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("自动重配") {
                    engine.autoConfigureModelTiers(forceResetManual: true)
                    feedbackMessage = "已从可用模型中重新自动分配低 / 中 / 高三档。"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(healthyModels.isEmpty)
            }

            HStack(spacing: 12) {
                ForEach(ModelTier.allCases) { tier in
                    let assigned = engine.model(for: tier)
                    let isHealthy = assigned.map { healthyIDs.contains($0.id) } ?? false
                    let tierColor: Color = (tier == .low ? .green : (tier == .medium ? .blue : .purple))
                    let providerName = assigned.flatMap { providersByID[$0.providerID]?.name }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(assigned == nil ? Color.gray.opacity(0.4) : (isHealthy ? Color.green : Color.orange))
                                    .frame(width: 7, height: 7)
                                Text(tier.displayName)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(tierColor)
                                Spacer()
                                if engine.config.policy.isManual(for: tier) {
                                    Text("手动")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Picker(tier.shortName, selection: Binding(
                                get: { engine.config.policy.modelID(for: tier) },
                                set: { newID in
                                    engine.setTierModel(tier: tier, modelUUID: newID, isManual: newID != nil)
                                }
                            )) {
                                Text("未分配").tag(UUID?.none)
                                ForEach(healthyModels) { m in
                                    Text(m.displayName).tag(UUID?.some(m.id))
                                }
                                if let assigned, !healthyModels.contains(where: { $0.id == assigned.id }) {
                                    Text("\(assigned.displayName) [不可用]").tag(UUID?.some(assigned.id))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)

                            HStack {
                                Text(providerName ?? "未指定供应商")
                                    .lineLimit(1)
                                Spacer()
                                if let assigned,
                                   let inp = assigned.inputPricePerMillion,
                                   let out = assigned.outputPricePerMillion {
                                    Text("$\(String(format: "%.2f", inp))/$\(String(format: "%.2f", out))")
                                        .monospacedDigit()
                                } else if assigned != nil {
                                    Text("未填单价")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(4)
                    }
                }
            }
        }
    }

    // MARK: - 2. Strategy & Protections

    private var routingStrategySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(RoutingStrategyPreset.allCases, id: \.self) { preset in
                        let selected = engine.config.policy.activeStrategy == preset
                        Button {
                            engine.setStrategy(preset)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(preset.displayName)
                                        .font(.callout.weight(.semibold))
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text(preset.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected ? Color.accentColor.opacity(0.12) : Color(.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                HStack(spacing: 18) {
                    Toggle("保持多轮会话稳定", isOn: Binding(
                        get: { engine.config.policy.enableSessionStickiness },
                        set: { val in engine.updatePolicy { $0.enableSessionStickiness = val } }
                    ))
                    Toggle("失败自动切换备选", isOn: Binding(
                        get: { engine.config.policy.enableRetryOnUpstreamFailure },
                        set: { val in engine.updatePolicy { $0.enableRetryOnUpstreamFailure = val } }
                    ))
                    Spacer()
                }
                .font(.callout)

                DisclosureGroup("高级设置（固定模型 / 回退模型 / 价格上限）", isExpanded: $showAdvancedPolicy) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("固定使用模型")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("固定模型", selection: Binding(
                                    get: { engine.config.policy.pinnedModelID },
                                    set: { val in engine.updatePolicy { $0.pinnedModelID = val } }
                                )) {
                                    Text("不固定（按策略路由）").tag(UUID?.none)
                                    ForEach(engine.config.models) { model in
                                        Text(model.displayName).tag(UUID?.some(model.id))
                                    }
                                }
                                .labelsHidden()
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("默认回退模型")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("回退模型", selection: Binding(
                                    get: { engine.config.policy.fallbackModelID },
                                    set: { val in engine.updatePolicy { $0.fallbackModelID = val } }
                                )) {
                                    Text("无").tag(UUID?.none)
                                    ForEach(engine.config.models) { model in
                                        Text(model.displayName).tag(UUID?.some(model.id))
                                    }
                                }
                                .labelsHidden()
                            }
                        }

                        HStack(spacing: 10) {
                            Text("单次价格上限 ($/1M):")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("输入上限", text: $maxInInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            TextField("输出上限", text: $maxOutInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Button("应用") { applyPriceCaps() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("清除") {
                                maxInInput = ""
                                maxOutInput = ""
                                engine.updatePolicy {
                                    $0.maxInputPricePerMillion = nil
                                    $0.maxOutputPricePerMillion = nil
                                }
                                feedbackMessage = "已清除单次价格上限。"
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Toggle("自动用三档模型覆盖 model=auto（推荐）", isOn: Binding(
                            get: { engine.config.policy.preferTierMappingInAuto },
                            set: { val in engine.updatePolicy { $0.preferTierMappingInAuto = val } }
                        ))
                        .font(.caption)
                    }
                    .padding(.top, 8)
                }
                .font(.caption.weight(.medium))
            }
            .padding(4)
        } label: {
            Label("路由策略与保护", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - 3. Providers & Candidate Pool

    private var providersAndModelsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button {
                        Task {
                            let summary = await engine.discoverAndProbeLocalModels()
                            feedbackMessage = "已扫描并测活完成：\(summary.healthyModelsCount) 个可用，\(summary.evictedModelsCount) 个不可用已自动剔除。"
                        }
                    } label: {
                        if engine.isDiscoveringAndProbing {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text("探测中...")
                            }
                        } else {
                            Label("发现与测活", systemImage: "radar")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(engine.isDiscoveringAndProbing)

                    Button {
                        showAddProvider = true
                    } label: {
                        Label("添加供应商", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Spacer()

                    if let current = selectedProvider {
                        Button("拉取模型") {
                            Task {
                                let result = await engine.testProviderConnection(providerID: current.id)
                                switch result {
                                case .success(let ids):
                                    feedbackMessage = "「\(current.name)」连通正常，发现 \(ids.count) 个上游模型。"
                                case .failure(let err):
                                    feedbackMessage = "拉取失败: \(err.localizedDescription)"
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("添加模型") { showAddModel = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                        Button("编辑供应商") { editingProvider = current }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                if engine.config.providers.isEmpty {
                    Text("尚未配置供应商，点击右上角「添加供应商」或「发现与测活」。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(engine.config.providers) { provider in
                                let isSelected = selectedProvider?.id == provider.id
                                let dotColor: Color = {
                                    switch provider.healthStatus {
                                    case .healthy: return .green
                                    case .checking: return .blue
                                    case .authError, .networkError, .serverError: return .red
                                    case .unknown: return .gray
                                    }
                                }()

                                Button {
                                    selectedProviderID = provider.id
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle().fill(dotColor).frame(width: 7, height: 7)
                                        Text(provider.name)
                                            .font(.callout.weight(isSelected ? .semibold : .regular))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? Color.accentColor.opacity(0.16) : Color(.controlBackgroundColor))
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let provider = selectedProvider {
                        let providerModels = engine.config.models.filter { $0.providerID == provider.id }
                        let activeList = providerModels.filter { $0.isEnabled && !$0.isAutoEvicted && $0.availabilityStatus != .unavailable }
                        let inactiveList = providerModels.filter { !$0.isEnabled || $0.isAutoEvicted || $0.availabilityStatus == .unavailable }

                        DisclosureGroup("可用模型 (\(activeList.count))", isExpanded: $showCandidatePool) {
                            if activeList.isEmpty {
                                Text("该供应商下暂无可用模型，可点击「拉取模型」或「添加模型」。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                            } else {
                                VStack(spacing: 6) {
                                    ForEach(activeList) { model in
                                        compactModelRow(model)
                                    }
                                }
                                .padding(.top, 6)
                            }
                        }
                        .font(.callout.weight(.medium))

                        if !inactiveList.isEmpty {
                            DisclosureGroup("已停用或异常模型 (\(inactiveList.count))", isExpanded: $showDisabledModels) {
                                VStack(spacing: 6) {
                                    ForEach(inactiveList) { model in
                                        compactModelRow(model)
                                    }
                                }
                                .padding(.top, 6)
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(4)
        } label: {
            Label("供应商与候选模型池 (\(engine.config.providers.count) 家 / \(healthyModels.count) 个可用)", systemImage: "server.rack")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func compactModelRow(_ model: ModelConfig) -> some View {
        let dotColor: Color = {
            if !model.isEnabled || model.isAutoEvicted || model.availabilityStatus == .unavailable {
                return .orange
            }
            return .green
        }()

        return HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.callout.weight(.medium))
                Text(model.modelID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let inp = model.inputPricePerMillion, let out = model.outputPricePerMillion {
                Text("$\(String(format: "%.2f", inp))/$\(String(format: "%.2f", out))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("未填单价")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if model.isAutoEvicted {
                Button("恢复") {
                    engine.restoreEvictedModel(id: model.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Toggle("", isOn: Binding(
                get: { model.isEnabled },
                set: { enabled in
                    var updated = model
                    updated.isEnabled = enabled
                    engine.upsertModel(updated)
                }
            ))
            .labelsHidden()
            .controlSize(.small)

            Button("编辑") {
                editingModel = model
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func syncPriceCapInputs() {
        maxInInput = engine.config.policy.maxInputPricePerMillion.map { String(format: "%.2f", $0) } ?? ""
        maxOutInput = engine.config.policy.maxOutputPricePerMillion.map { String(format: "%.2f", $0) } ?? ""
    }

    private func applyPriceCaps() {
        let inTrim = maxInInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let outTrim = maxOutInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxIn = inTrim.isEmpty ? nil : Double(inTrim)
        let maxOut = outTrim.isEmpty ? nil : Double(outTrim)
        if !inTrim.isEmpty && maxIn == nil || !outTrim.isEmpty && maxOut == nil {
            feedbackMessage = "价格上限请输入有效数字。"
            return
        }
        engine.updatePolicy {
            $0.maxInputPricePerMillion = maxIn
            $0.maxOutputPricePerMillion = maxOut
        }
        feedbackMessage = "已更新单次价格上限。"
    }
}
