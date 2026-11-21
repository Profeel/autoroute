import AppKit
import AutoModelCore
import SwiftUI

struct ProvidersModelsView: View {
    @ObservedObject var engine: AutoModelEngine

    @State private var viewMode: ProvidersViewMode = .byProvider
    @State private var selectedProviderID: UUID?
    @State private var showingProviderSheet = false
    @State private var editingProvider: ProviderConfig?
    @State private var showingModelSheet = false
    @State private var editingModel: ModelConfig?
    @State private var showingCodexSubscriptionSheet = false
    @State private var feedbackMessage: String?
    @State private var isTestingConnection = false

    enum ProvidersViewMode: String, CaseIterable {
        case byProvider = "按提供商接入"
        case autoGroups = "同模型自动分组"
    }

    private var selectedProvider: ProviderConfig? {
        if let id = selectedProviderID, let found = engine.config.providers.first(where: { $0.id == id }) {
            return found
        }
        return engine.config.providers.first
    }

    var body: some View {
        VStack(spacing: 12) {
            // 1. Minimalist Top Bar
            topToolbar

            // 2. Public Benchmark Scatter Frontier Chart (lights up connected models)
            PublicBenchmarkChartView(engine: engine)

            if let feedbackMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(feedbackMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        self.feedbackMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }

            // 3. Main Content: Opt-in Providers OR Auto Same-Model Groups
            if viewMode == .byProvider {
                providerOptInWorkspace
            } else {
                autoModelGroupsWorkspace
            }
        }
        .padding(14)
        .sheet(isPresented: $showingProviderSheet) {
            ProviderEditorSheet(
                existingProvider: editingProvider,
                existingKeyStatus: editingProvider.map { engine.cachedAPIKey(for: $0.id) } ?? .missing
            ) { provider, apiKeys, selectedPreset, seedRecommendedModels in
                let wasNew = (editingProvider == nil)
                do {
                    feedbackMessage = try applyProviderEditorSave(
                        engine: engine,
                        provider: provider,
                        apiKeys: apiKeys,
                        selectedPreset: wasNew ? selectedPreset : nil,
                        seedRecommendedModels: seedRecommendedModels
                    )
                    selectedProviderID = provider.id
                } catch {
                    feedbackMessage = "保存失败: \(error.localizedDescription)"
                }
            }
        }
        .sheet(isPresented: $showingModelSheet) {
            if let providerID = selectedProvider?.id ?? engine.config.providers.first?.id {
                ModelEditorSheet(
                    providerID: providerID,
                    existingModel: editingModel
                ) { model in
                    engine.upsertModel(model)
                    feedbackMessage = "已保存模型「\(model.displayName)」。"
                }
            }
        }
        .sheet(isPresented: $showingCodexSubscriptionSheet) {
            CodexSubscriptionSheet(
                engine: engine,
                onConnected: { providerID, message in
                    selectedProviderID = providerID
                    feedbackMessage = message
                }
            )
        }
        .onAppear {
            if selectedProviderID == nil {
                selectedProviderID = engine.config.providers.first?.id
            }
        }
    }

    private var topToolbar: some View {
        HStack(spacing: 12) {
            Picker("视图", selection: $viewMode) {
                ForEach(ProvidersViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            let enabledCount = engine.config.providers.filter(\.isEnabled).count
            Text("已接入 \(enabledCount)/\(engine.config.providers.count) 个提供商")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                Task {
                    let summary = await engine.discoverAndProbeLocalModels()
                    feedbackMessage = "本机扫描完成：发现 \(summary.discoveredProvidersCount) 个来源、\(summary.discoveredModelsCount) 个模型；请通过开关选择要接入路由池的提供商。"
                }
            } label: {
                if engine.isDiscoveringAndProbing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("扫描中…")
                    }
                } else {
                    Label("重新扫描本机", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(engine.isDiscoveringAndProbing)

            Menu {
                Button("添加 API 提供商") {
                    editingProvider = nil
                    showingProviderSheet = true
                }
                Button("接入 Codex 订阅账号") {
                    showingCodexSubscriptionSheet = true
                }
            } label: {
                Label("添加", systemImage: "plus")
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
        }
    }

    private var providerOptInWorkspace: some View {
        HSplitView {
            // Left: Providers list with Opt-in Toggle
            List(engine.config.providers, selection: $selectedProviderID) { provider in
                providerOptInRow(provider)
                    .tag(provider.id)
            }
            .listStyle(.inset)
            .frame(minWidth: 270, idealWidth: 310, maxWidth: 360)

            // Right: Selected Provider Detail & Models
            if let provider = selectedProvider {
                providerDetailView(provider)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("暂无提供商配置")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("扫描本机配置") {
                            Task { _ = await engine.discoverAndProbeLocalModels() }
                        }
                        .buttonStyle(.bordered)
                        Button("+ 添加提供商") {
                            editingProvider = nil
                            showingProviderSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func providerOptInRow(_ provider: ProviderConfig) -> some View {
        let models = engine.config.models.filter { $0.providerID == provider.id }
        let enabledModels = models.filter(\.isEnabled).count
        let sourceText = provider.discoverySourceLabel ?? provider.discoveredSource

        return HStack(spacing: 10) {
            Circle()
                .fill(statusColor(for: provider))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(provider.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if provider.isAutoDiscovered && !provider.isEnabled {
                        Text("未接入")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    if let sourceText {
                        Text(sourceText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text("\(enabledModels)/\(models.count) 模型")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { provider.isEnabled },
                set: { newValue in
                    var updated = provider
                    updated.isEnabled = newValue
                    do {
                        try engine.upsertProvider(updated, apiKey: nil)
                        feedbackMessage = newValue
                            ? "已接入「\(provider.name)」，其健康模型已加入可用路由池与 Bench 榜单。"
                            : "已停用「\(provider.name)」，其模型已从路由池移除。"
                    } catch {
                        feedbackMessage = "切换失败: \(error.localizedDescription)"
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func providerDetailView(_ provider: ProviderConfig) -> some View {
        let models = engine.config.models.filter { $0.providerID == provider.id }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(provider.name)
                                .font(.title3.weight(.semibold))
                            Text(provider.isEnabled ? "已接入路由池" : "仅本机发现（未接入）")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(provider.isEnabled ? .green : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background((provider.isEnabled ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
                        }
                        Text(provider.baseURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let source = provider.discoverySourceLabel ?? provider.discoveredSource {
                            Text("来源：\(source)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            Task {
                                isTestingConnection = true
                                let result = await engine.testProviderConnection(providerID: provider.id)
                                isTestingConnection = false
                                switch result {
                                case .success(let models):
                                    feedbackMessage = "连通性测试成功，发现 \(models.count) 个模型。"
                                case .failure(let err):
                                    feedbackMessage = "连通性测试失败：\(err.localizedDescription)"
                                }
                            }
                        } label: {
                            if isTestingConnection {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("测试连通性")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isTestingConnection)

                        Button("编辑") {
                            editingProvider = provider
                            showingProviderSheet = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(role: .destructive) {
                            engine.deleteProvider(id: provider.id)
                            selectedProviderID = engine.config.providers.first?.id
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Divider()

                HStack {
                    Text("模型列表 (\(models.count))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("+ 添加模型") {
                        editingModel = nil
                        showingModelSheet = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if models.isEmpty {
                    Text("该提供商暂无模型，可点击「测试连通性」或「+ 添加模型」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 6) {
                        ForEach(models) { model in
                            modelRow(model, providerEnabled: provider.isEnabled)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func modelRow(_ model: ModelConfig, providerEnabled: Bool) -> some View {
        let canonical = CanonicalModelNormalizer.canonicalID(for: model)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.isEnabled },
                set: { newValue in
                    var updated = model
                    updated.isEnabled = newValue
                    engine.upsertModel(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!providerEnabled)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.callout.weight(.medium))
                    if !canonical.isEmpty {
                        Text(canonical)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 10) {
                    if let inp = model.inputPricePerMillion, let out = model.outputPricePerMillion {
                        Text(String(format: "$%.2f / $%.2f per 1M", inp, out))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未配置价格")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let lat = model.lastProbeLatencyMs {
                        Text(AutoModelFormatter.formatMs(lat))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let cooldownSec = engine.cooldownRemainingSeconds(for: model.id) {
                Text("冷却 \(cooldownSec)s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14), in: Capsule())
            }

            Button("编辑") {
                editingModel = model
                showingModelSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private var autoModelGroupsWorkspace: some View {
        let groups = engine.autoModelGroups(connectedOnly: false)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("开启同模型自动分组与组内可用性故障转移", isOn: Binding(
                    get: { engine.config.policy.enableAutoSameModelGrouping },
                    set: { newVal in
                        engine.updatePolicy { $0.enableAutoSameModelGrouping = newVal }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                Text("共 \(groups.count) 个逻辑模型组")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if groups.isEmpty {
                Text("暂无模型，请先扫描或添加提供商。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(groups) { group in
                            autoGroupCard(group)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func autoGroupCard(_ group: AutoModelGroup) -> some View {
        let connectedCount = group.connectedChannels.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.displayName)
                    .font(.callout.weight(.semibold))
                Text(group.canonicalID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(connectedCount > 1 ? "\(connectedCount)通道自动分组" : "\(connectedCount) 个已接入通道")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(connectedCount > 1 ? .blue : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((connectedCount > 1 ? Color.blue : Color.secondary).opacity(0.12), in: Capsule())
            }

            VStack(spacing: 4) {
                ForEach(group.channels) { ch in
                    let isPreferred = group.activeChannel?.id == ch.id
                    HStack(spacing: 8) {
                        Circle()
                            .fill(ch.isHealthy ? Color.green : (ch.isCoolingDown ? Color.orange : Color.secondary.opacity(0.4)))
                            .frame(width: 6, height: 6)
                        Text(ch.providerName)
                            .font(.caption.weight(isPreferred ? .semibold : .regular))
                        Text(ch.modelConfig.modelID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer()
                        if let lat = ch.avgLatencyMs {
                            Text(AutoModelFormatter.formatMs(lat))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if isPreferred {
                            Text("首选健康")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.14), in: Capsule())
                        } else if ch.isCoolingDown, let rem = ch.cooldownRemainingSec {
                            Text("冷却 \(Int(rem.rounded()))s")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                        } else if !ch.isConnected {
                            Text("未接入")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("可用备选")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(.windowBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func statusColor(for provider: ProviderConfig) -> Color {
        if !provider.isEnabled { return .gray.opacity(0.5) }
        switch provider.healthStatus {
        case .healthy: return .green
        case .checking: return .blue
        case .unknown: return .orange
        case .authError, .networkError, .serverError: return .red
        }
    }
}
