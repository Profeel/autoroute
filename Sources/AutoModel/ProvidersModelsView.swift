import AutoModelCore
import SwiftUI

struct ProvidersModelsView: View {
    @ObservedObject var engine: AutoModelEngine

    @State private var selectedProviderID: UUID?
    @State private var showingProviderSheet = false
    @State private var editingProvider: ProviderConfig?
    @State private var showingModelSheet = false
    @State private var editingModel: ModelConfig?
    @State private var discoveredModelIDs: [String] = []
    @State private var discoveryProviderID: UUID?
    @State private var feedbackMessage: String?
    @State private var isTestingConnection = false
    @State private var modelFilter: ModelHealthFilter = .all

    enum ModelHealthFilter: String, CaseIterable {
        case all = "全部"
        case availableOnly = "实测可用"
        case evictedOnly = "已自动剔除"
    }

    var body: some View {
        VStack(spacing: 0) {
            discoveryToolbar
            Divider()
            HStack(spacing: 0) {
                providerListColumn
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                Divider()
                providerDetailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("供应商")
        .sheet(isPresented: $showingProviderSheet) {
            ProviderEditorSheet(
                existingProvider: editingProvider,
                existingHasKey: editingProvider.map { engine.hasAPIKey(for: $0.id) } ?? false
            ) { provider, apiKey in
                do {
                    try engine.upsertProvider(provider, apiKey: apiKey)
                    selectedProviderID = provider.id
                    feedbackMessage = "已保存供应商「\(provider.name)」，API Key 已加密存入 macOS Keychain。"
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
        .onAppear {
            if selectedProviderID == nil {
                selectedProviderID = engine.config.providers.first?.id
            }
        }
    }

    private var discoveryToolbar: some View {
        let healthyCount = engine.config.models.filter { $0.isEnabled && !$0.isAutoEvicted && $0.availabilityStatus == .available }.count
        let evictedCount = engine.config.models.filter { $0.isAutoEvicted || $0.availabilityStatus != .available }.count
        return HStack(spacing: 12) {
            Button {
                Task {
                    let summary = await engine.discoverAndProbeLocalModels()
                    feedbackMessage = "本机扫面完成：新增 \(summary.discoveredProvidersCount) 个供应商、\(summary.discoveredModelsCount) 个模型；实测 \(summary.probedModelsCount) 个模型后，\(summary.healthyModelsCount) 个可用，\(summary.evictedModelsCount) 个不可用已自动剔除。"
                }
            } label: {
                if engine.isDiscoveringAndProbing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在发掘与测活...")
                    }
                } else {
                    Label("自动发掘本机模型并测活剔除", systemImage: "radar")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine.isDiscoveringAndProbing)

            Button {
                let count = engine.fillReferencePricingForUnpricedModels()
                feedbackMessage = count > 0
                    ? "已为 \(count) 个未配置单价的模型补全公开参考价格。"
                    : "当前模型均已配置单价，或暂无匹配的公开参考价格。"
            } label: {
                Label("填充参考单价", systemImage: "dollarsign.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let progress = engine.probeProgressText {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let summary = engine.lastDiscoverySummary {
                Text("最近巡检: \(summary.timestamp.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Text("可用 \(healthyCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())

                Text("已剔除 \(evictedCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(evictedCount > 0 ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12))
                    .foregroundStyle(evictedCount > 0 ? .red : .secondary)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.controlBackgroundColor).opacity(0.5))
    }

    private var tierQuickStrip: some View {
        let healthy = engine.healthyAvailableModels()
        return HStack(spacing: 12) {
            Label("三档配置:", systemImage: "square.stack.3d.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(ModelTier.allCases) { tier in
                let assigned = engine.model(for: tier)
                let color: Color = (tier == .low ? .green : (tier == .medium ? .blue : .purple))
                HStack(spacing: 6) {
                    Text(tier.shortName)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.15))
                        .foregroundStyle(color)
                        .clipShape(Capsule())

                    Picker(tier.shortName, selection: Binding(
                        get: { engine.config.policy.modelID(for: tier) },
                        set: { newID in
                            engine.setTierModel(tier: tier, modelUUID: newID, isManual: newID != nil)
                        }
                    )) {
                        Text("未分配").tag(UUID?.none)
                        ForEach(healthy) { m in
                            Text(m.displayName).tag(UUID?.some(m.id))
                        }
                        if let assigned, !healthy.contains(where: { $0.id == assigned.id }) {
                            Text("\(assigned.displayName) [不可用]").tag(UUID?.some(assigned.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 190)
                }
            }

            Spacer()

            Button("自动重配三档") {
                engine.autoConfigureModelTiers(forceResetManual: true)
                feedbackMessage = "已从当前可用模型中重新自动分配低 / 中 / 高三档。"
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(healthy.isEmpty)

            Button("填充参考单价") {
                let updatedCount = engine.fillReferencePricingForUnpricedModels()
                if updatedCount > 0 {
                    feedbackMessage = "已为 \(updatedCount) 个未配置价格的模型填充公开参考单价（可在右侧表格修改）。"
                } else {
                    feedbackMessage = "所有已配置模型已有单价，或暂无匹配的公开参考单价。"
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("仅对未填写单价的模型匹配公开参考价格，不会覆盖你手动设置的价格")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(.controlBackgroundColor).opacity(0.28))
    }

    private var selectedProvider: ProviderConfig? {
        if let id = selectedProviderID, let found = engine.config.providers.first(where: { $0.id == id }) {
            return found
        }
        return engine.config.providers.first
    }

    private var providerListColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("供应商 (\(engine.config.providers.count))")
                    .font(.headline)
                Spacer()
                Button {
                    editingProvider = nil
                    showingProviderSheet = true
                } label: {
                    Label("添加供应商", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)

            Divider()

            if engine.config.providers.isEmpty {
                ContentUnavailableView {
                    Label("尚未添加供应商", systemImage: "server.rack")
                } description: {
                    Text("点击右上角“添加供应商”，填写您的 OpenAI 兼容厂商、中转站或本地服务地址。")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(engine.config.providers, selection: $selectedProviderID) { provider in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(provider.name)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            ProviderStatusBadge(status: provider.healthStatus)
                        }
                        Text(provider.baseURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            let providerModels = engine.config.models.filter { $0.providerID == provider.id }
                            let okCount = providerModels.filter { !$0.isAutoEvicted && $0.availabilityStatus == .available }.count
                            let evictedCount = providerModels.count - okCount
                            Text("\(okCount) 可用" + (evictedCount > 0 ? " / \(evictedCount) 剔除" : ""))
                            if provider.apiProtocol != .openAIChatCompletions {
                                Text(provider.apiProtocol.displayName)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                            if let src = provider.discoveredSource {
                                Text("· \(src)")
                                    .lineLimit(1)
                            } else if engine.hasAPIKey(for: provider.id) {
                                Label("Keychain", systemImage: "key.fill")
                                    .foregroundStyle(.green)
                            }
                            if !provider.isEnabled {
                                Text("已禁用")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(provider.id)
                }
            }
        }
    }

    private var providerDetailColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let feedbackMessage {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(feedbackMessage)
                        .font(.callout)
                    Spacer()
                    Button("关闭") { self.feedbackMessage = nil }
                        .buttonStyle(.plain)
                        .font(.caption)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.1))
            }

            if let provider = selectedProvider {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        providerHeaderCard(provider)

                        if discoveryProviderID == provider.id && !discoveredModelIDs.isEmpty {
                            discoveredModelsCard(provider)
                        }

                        modelsSection(provider)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView {
                    Label("请选择或添加供应商", systemImage: "network")
                } description: {
                    Text("添加供应商后，即可在此配置多个模型及其单价、能力标签和默认用途。")
                }
            }
        }
    }

    private func providerHeaderCard(_ provider: ProviderConfig) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(provider.name)
                                .font(.title3.bold())
                            ProviderStatusBadge(status: provider.healthStatus)
                            if !provider.isEnabled {
                                Text("已禁用")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.18))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            }
                        }
                        Text("Base URL: \(provider.normalizedBaseURL)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("API Key 存储: \(engine.hasAPIKey(for: provider.id) ? "已保存在 macOS Keychain（不写入明文配置）" : "未设置（仅适用于免密本地服务）")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            Task {
                                await runConnectionTest(provider: provider)
                            }
                        } label: {
                            if isTestingConnection {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("测试连接 & 拉取模型", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isTestingConnection)

                        Button("编辑") {
                            editingProvider = provider
                            showingProviderSheet = true
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            engine.deleteProvider(id: provider.id)
                            selectedProviderID = engine.config.providers.first?.id
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let err = provider.lastErrorMessage, !err.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("最近一次连接检查异常")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(4)
        } label: {
            Label("供应商信息", systemImage: "building.2")
                .font(.headline)
        }
    }

    private func discoveredModelsCard(_ provider: ProviderConfig) -> some View {
        let existingIDs = Set(engine.config.models.filter { $0.providerID == provider.id }.map(\.modelID))
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("上游 /v1/models 返回了 \(discoveredModelIDs.count) 个模型，点击即可添加到路由池：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 8) {
                    ForEach(discoveredModelIDs, id: \.self) { modelID in
                        let added = existingIDs.contains(modelID)
                        Button {
                            if !added {
                                let newModel = ModelConfig(providerID: provider.id, modelID: modelID)
                                editingModel = newModel
                                showingModelSheet = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                                Text(modelID)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(added)
                    }
                }
            }
            .padding(4)
        } label: {
            Label("发现的上游模型", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func modelsSection(_ provider: ProviderConfig) -> some View {
        let allModels = engine.config.models.filter { $0.providerID == provider.id }
        let filteredModels = allModels.filter { model in
            switch modelFilter {
            case .all: return true
            case .availableOnly: return !model.isAutoEvicted && model.availabilityStatus == .available
            case .evictedOnly: return model.isAutoEvicted || model.availabilityStatus != .available
            }
        }
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("已配置模型 (\(allModels.count))")
                        .font(.subheadline.weight(.semibold))

                    Picker("筛选", selection: $modelFilter) {
                        ForEach(ModelHealthFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)

                    Spacer()

                    Button {
                        Task {
                            await engine.probeProviderModels(providerID: provider.id)
                            feedbackMessage = "已完成对「\(provider.name)」全部模型的测活与不可用剔除。"
                        }
                    } label: {
                        Label("测活该供应商模型", systemImage: "stethoscope")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(engine.isDiscoveringAndProbing || allModels.isEmpty)

                    Button {
                        editingModel = nil
                        showingModelSheet = true
                    } label: {
                        Label("手动添加模型", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if filteredModels.isEmpty {
                    Text(allModels.isEmpty
                         ? "该供应商下还没有模型。请至少添加两个可用模型（可从上方自动拉取或手动添加），以便路由器进行对比和切换。"
                         : "当前筛选条件下没有模型。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(filteredModels) { model in
                        modelRowCard(model)
                    }
                }
            }
            .padding(4)
        } label: {
            Label("模型目录与定价", systemImage: "square.stack.3d.up")
                .font(.headline)
        }
    }

    private func modelRowCard(_ model: ModelConfig) -> some View {
        let evicted = model.isAutoEvicted || model.availabilityStatus != .available
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { model.isEnabled },
                    set: { next in
                        var updated = model
                        updated.isEnabled = next
                        engine.upsertModel(updated)
                    }
                ))
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.callout.weight(.semibold))
                            .strikethrough(evicted, color: .red)
                        if model.displayName != model.modelID {
                            Text("(\(model.modelID))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if model.isAutoEvicted {
                            Text("已自动剔除 · \(model.availabilityStatus.displayName)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.16))
                                .foregroundStyle(.red)
                                .clipShape(Capsule())
                        } else if model.availabilityStatus != .available {
                            Text(model.availabilityStatus.displayName)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.15))
                                .foregroundStyle(.red)
                                .clipShape(Capsule())
                        } else if let probeMs = model.lastProbeLatencyMs {
                            Text("实测 \(Int(probeMs.rounded())) ms")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                        if let src = model.discoveredSource {
                            Text(src)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 10) {
                        Text("用途: \(model.defaultRole.displayName)")
                        Text("上下文: \(model.contextWindow / 1000)k")
                        Text("质量 \(model.qualityScore) · 速度 \(model.speedScore)")
                        Text(AutoModelFormatter.formatPricePair(input: model.inputPricePerMillion, output: model.outputPricePerMillion))
                            .foregroundStyle(model.hasCompletePricing ? Color.secondary : Color.orange)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    ForEach(Array(model.capabilities).sorted { $0.rawValue < $1.rawValue }, id: \.self) { cap in
                        Text(cap.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Button("重测") {
                    Task {
                        await engine.probeSingleModel(modelID: model.id)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if evicted {
                    Button("恢复") {
                        engine.restoreEvictedModel(id: model.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button("编辑") {
                    editingModel = model
                    showingModelSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    engine.deleteModel(id: model.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let note = model.lastAvailabilityNote, !note.isEmpty {
                Text(evicted ? note : "健康检测: \(note)")
                    .font(.caption)
                    .foregroundStyle(evicted ? .red : .secondary)
                    .padding(.leading, 28)
            }
        }
        .padding(10)
        .background(evicted ? Color.red.opacity(0.05) : Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func runConnectionTest(provider: ProviderConfig) async {
        isTestingConnection = true
        defer { isTestingConnection = false }

        let result = await engine.testProviderConnection(providerID: provider.id)
        switch result {
        case .success(let models):
            discoveredModelIDs = models
            discoveryProviderID = provider.id
            feedbackMessage = "连接「\(provider.name)」成功，拉取到 \(models.count) 个可用模型。"
        case .failure(let err):
            feedbackMessage = "连接「\(provider.name)」失败：\(err.localizedDescription)"
        }
    }
}

struct ProviderStatusBadge: View {
    let status: ProviderHealthStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .healthy: return .green
        case .checking: return .blue
        case .unknown: return .secondary
        case .authError, .networkError, .serverError: return .red
        }
    }
}

// MARK: - Provider Editor Sheet

struct ProviderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingProvider: ProviderConfig?
    let existingHasKey: Bool
    let onSave: (ProviderConfig, String?) -> Void

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKeyInput: String = ""
    @State private var clearKey: Bool = false
    @State private var timeoutSeconds: Double = 60
    @State private var isEnabled: Bool = true
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingProvider == nil ? "添加 OpenAI 兼容供应商" : "编辑供应商")
                .font(.title3.bold())

            Form {
                TextField("名称（如：中转站 A / OpenAI / 本机 Ollama）", text: $name)
                TextField("Base URL（如：https://api.example.com/v1）", text: $baseURL)
                SecureField(
                    existingHasKey ? "API Key（留空表示保留 Keychain 中已有密钥）" : "API Key（将保存在 macOS Keychain）",
                    text: $apiKeyInput
                )
                if existingHasKey {
                    Toggle("清除已保存的 API Key", isOn: $clearKey)
                }
                Toggle("启用该供应商", isOn: $isEnabled)
                Stepper("请求超时: \(Int(timeoutSeconds)) 秒", value: $timeoutSeconds, in: 10...300, step: 10)
            }
            .formStyle(.grouped)

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("安全承诺：API Key 仅保存在 macOS Keychain，绝不写入 config.json 或调用历史。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    save()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let existing = existingProvider {
                name = existing.name
                baseURL = existing.baseURL
                timeoutSeconds = existing.timeoutSeconds
                isEnabled = existing.isEnabled
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationError = "请输入供应商名称。"
            return
        }
        guard let parsed = URL(string: trimmedURL),
              let scheme = parsed.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              parsed.host != nil else {
            validationError = "请输入有效的 http:// 或 https:// Base URL。"
            return
        }

        var updated = existingProvider ?? ProviderConfig(name: trimmedName, baseURL: trimmedURL)
        updated.name = trimmedName
        updated.baseURL = trimmedURL
        updated.timeoutSeconds = timeoutSeconds
        updated.isEnabled = isEnabled
        if existingProvider?.baseURL != trimmedURL {
            updated.healthStatus = .unknown
            updated.lastErrorMessage = nil
        }

        let keyToApply: String?
        if clearKey {
            keyToApply = ""
        } else if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keyToApply = apiKeyInput
        } else {
            keyToApply = nil
        }

        onSave(updated, keyToApply)
        dismiss()
    }
}

// MARK: - Model Editor Sheet

struct ModelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let providerID: UUID
    let existingModel: ModelConfig?
    let onSave: (ModelConfig) -> Void

    @State private var modelID: String = ""
    @State private var displayName: String = ""
    @State private var hasPricing: Bool = true
    @State private var inputPriceText: String = ""
    @State private var outputPriceText: String = ""
    @State private var contextWindow: Int = 128_000
    @State private var capabilities: Set<ModelCapability> = [.chat]
    @State private var defaultRole: ModelDefaultUsage = .general
    @State private var qualityScore: Double = 75
    @State private var speedScore: Double = 75
    @State private var isEnabled: Bool = true
    @State private var availability: ModelAvailabilityStatus = .available
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existingModel == nil ? "添加模型" : "编辑模型")
                .font(.title3.bold())

            Form {
                Section("基础信息") {
                    TextField("上游 Model ID（如 gpt-4o-mini / claude-sonnet-4）", text: $modelID)
                    TextField("展示名称（可选，默认同 Model ID）", text: $displayName)
                    Picker("默认用途", selection: $defaultRole) {
                        ForEach(ModelDefaultUsage.allCases, id: \.self) { role in
                            Text(role.displayName).tag(role)
                        }
                    }
                    Picker("可用状态", selection: $availability) {
                        ForEach(ModelAvailabilityStatus.allCases, id: \.self) { st in
                            Text(st.displayName).tag(st)
                        }
                    }
                    Toggle("启用该模型参与路由", isOn: $isEnabled)
                }

                Section("价格设置（USD / 每百万 tokens）") {
                    Toggle("配置模型单价（关闭后收据将显示“无法计算费用”）", isOn: $hasPricing)
                    if hasPricing {
                        TextField("输入单价 ($ / 1M tokens)", text: $inputPriceText)
                        TextField("输出单价 ($ / 1M tokens)", text: $outputPriceText)
                    }
                }

                Section("约束与能力标签") {
                    Stepper("上下文上限: \(contextWindow) tokens", value: $contextWindow, in: 2048...2_000_000, step: 8192)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("能力标签")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 8) {
                            ForEach(ModelCapability.allCases, id: \.self) { cap in
                                Toggle(cap.displayName, isOn: Binding(
                                    get: { capabilities.contains(cap) },
                                    set: { enabled in
                                        if enabled { capabilities.insert(cap) } else { capabilities.remove(cap) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    HStack {
                        Text("质量评分 (\(Int(qualityScore)))")
                        Slider(value: $qualityScore, in: 10...100, step: 1)
                    }
                    HStack {
                        Text("速度评分 (\(Int(speedScore)))")
                        Slider(value: $speedScore, in: 10...100, step: 1)
                    }
                }
            }
            .formStyle(.grouped)

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存模型") {
                    save()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
        .onAppear {
            if let existing = existingModel {
                modelID = existing.modelID
                displayName = existing.displayName
                hasPricing = existing.hasCompletePricing
                if let inp = existing.inputPricePerMillion {
                    inputPriceText = String(inp)
                }
                if let out = existing.outputPricePerMillion {
                    outputPriceText = String(out)
                }
                contextWindow = existing.contextWindow
                capabilities = existing.capabilities
                defaultRole = existing.defaultRole
                qualityScore = Double(existing.qualityScore)
                speedScore = Double(existing.speedScore)
                isEnabled = existing.isEnabled
                availability = existing.availabilityStatus
            }
        }
    }

    private func save() {
        let trimmedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            validationError = "请输入上游 Model ID。"
            return
        }

        var inPrice: Double? = nil
        var outPrice: Double? = nil
        if hasPricing {
            let trimmedIn = inputPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedOut = outputPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedIn.isEmpty && trimmedOut.isEmpty {
                hasPricing = false
            } else {
                guard let parsedIn = Double(trimmedIn), parsedIn >= 0,
                      let parsedOut = Double(trimmedOut), parsedOut >= 0 else {
                    validationError = "请输入有效的非负输入/输出单价，或关闭“配置模型单价”。"
                    return
                }
                inPrice = parsedIn
                outPrice = parsedOut
            }
        }

        var updated = existingModel ?? ModelConfig(providerID: providerID, modelID: trimmedID)
        updated.providerID = existingModel?.providerID ?? providerID
        updated.modelID = trimmedID
        updated.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmedID : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.inputPricePerMillion = inPrice
        updated.outputPricePerMillion = outPrice
        updated.contextWindow = contextWindow
        updated.capabilities = capabilities
        updated.defaultRole = defaultRole
        updated.qualityScore = Int(qualityScore)
        updated.speedScore = Int(speedScore)
        updated.isEnabled = isEnabled
        updated.availabilityStatus = availability
        if availability == .available {
            updated.lastAvailabilityNote = nil
        }

        onSave(updated)
        dismiss()
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }
    }
}
