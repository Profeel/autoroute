import AppKit
import AutoModelCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Provider Editor Sheet

@MainActor
func applyProviderEditorSave(
    engine: AutoModelEngine,
    provider: ProviderConfig,
    apiKeys: [String]?,
    selectedPreset: ProviderPreset?,
    seedRecommendedModels: Bool
) throws -> String {
    try engine.upsertProvider(provider, apiKeys: apiKeys)
    var seededCount = 0
    if seedRecommendedModels,
       let selectedPreset,
       !selectedPreset.recommendedModels.isEmpty {
        for model in selectedPreset.makeModelConfigs(providerID: provider.id) {
            engine.upsertModel(model)
            seededCount += 1
        }
    }
    let keySummary: String
    if let apiKeys {
        keySummary = apiKeys.isEmpty ? "未配置 Key" : "已加密保存 \(apiKeys.count) 把 Key 到 Keychain"
    } else {
        keySummary = "保留现有 Keychain 密钥"
    }
    if seededCount > 0 {
        return "已保存供应商「\(provider.name)」（\(keySummary)），并自动导入 \(seededCount) 个推荐模型与参考单价。"
    }
    return "已保存供应商「\(provider.name)」（\(keySummary)）。"
}

private struct EditableHeaderRow: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}

struct ProviderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingProvider: ProviderConfig?
    let existingKeyStatus: CachedAPIKey
    let onSave: (ProviderConfig, [String]?, ProviderPreset?, Bool) -> Void

    @State private var selectedPresetCategory: ProviderPresetCategory? = nil
    @State private var selectedPreset: ProviderPreset? = nil
    @State private var seedRecommendedModels: Bool = true

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKeysText: String = ""
    @State private var clearKeys: Bool = false
    @State private var keyRotationStrategy: ProviderKeyRotationStrategy = .roundRobin
    @State private var timeoutSeconds: Double = 60
    @State private var maxConcurrentText: String = ""
    @State private var apiProtocol: ProviderProtocol = .openAIChatCompletions
    @State private var isEnabled: Bool = true

    @State private var proxyURLText: String = ""
    @State private var headerRows: [EditableHeaderRow] = []
    @State private var passThroughHeadersText: String = ""
    @State private var validationError: String?

    private var filteredPresets: [ProviderPreset] {
        guard let category = selectedPresetCategory else {
            return ProviderPresetCatalog.allPresets
        }
        return ProviderPresetCatalog.allPresets.filter { $0.category == category }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existingProvider == nil ? "添加供应商（兼容 Magpie 预设与密钥池）" : "编辑供应商")
                .font(.title3.bold())

            ScrollView {
                Form {
                    if existingProvider == nil {
                        presetSection
                    }
                    basicConfigSection
                    keyPoolSection
                    advancedNetworkSection
                }
                .formStyle(.grouped)
            }

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            footerButtons
        }
        .padding(20)
        .frame(width: 600, height: 640)
        .onAppear(perform: populateInitialValues)
    }

    @ViewBuilder
    private var presetSection: some View {
        Section("Magpie 供应商预设") {
            Picker("分类筛选", selection: $selectedPresetCategory) {
                Text("全部").tag(ProviderPresetCategory?.none)
                Text("国际").tag(ProviderPresetCategory?.some(.international))
                Text("国内").tag(ProviderPresetCategory?.some(.domestic))
                Text("本地服务").tag(ProviderPresetCategory?.some(.local))
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(filteredPresets) { preset in
                    presetTile(for: preset)
                }
            }
            .padding(.vertical, 4)

            if let preset = selectedPreset, !preset.recommendedModels.isEmpty {
                Toggle(
                    "保存后自动导入推荐模型与参考单价（\(preset.recommendedModels.count) 个）",
                    isOn: $seedRecommendedModels
                )
            }
        }
    }

    @ViewBuilder
    private func presetTile(for preset: ProviderPreset) -> some View {
        let isSelected = (selectedPreset?.id == preset.id)
        let bgColor: Color = isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08)
        let borderColor: Color = isSelected ? Color.accentColor : Color.clear
        Button {
            applyPreset(preset)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(preset.apiProtocol.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(bgColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var basicConfigSection: some View {
        Section("基础配置") {
            TextField("名称（如：中转站 A / OpenAI / 本机 Ollama）", text: $name)
            TextField("Base URL（如：https://api.example.com/v1）", text: $baseURL)
            Toggle("启用该供应商", isOn: $isEnabled)
            Picker("上游协议", selection: $apiProtocol) {
                ForEach(ProviderProtocol.allCases, id: \.self) { proto in
                    Text(proto.displayName).tag(proto)
                }
            }
            Stepper("请求超时: \(Int(timeoutSeconds)) 秒", value: $timeoutSeconds, in: 10...300, step: 10)
            TextField("最大并发请求数（可选，留空不限制）", text: $maxConcurrentText)
        }
    }

    @ViewBuilder
    private var keyPoolSection: some View {
        Section("API Key 池与调度（保存于 macOS Keychain）") {
            if apiProtocol == .workBuddy,
               let preset = selectedPreset ?? existingProvider?.presetID.flatMap(ProviderPresetCatalog.preset(id:)),
               let url = URL(string: preset.docsURL) {
                Link("创建 \(preset.name) API Key", destination: url)
                Text("保存后可测试连通性并导入该账号可用的模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let existing = existingProvider {
                HStack {
                    keyStatusHint(for: existing)
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API Keys（每行一个，支持多 Key 自动轮询与 429/401 故障切换）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $apiKeysText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 68, maxHeight: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }

            Picker("多 Key 调度策略", selection: $keyRotationStrategy) {
                ForEach(ProviderKeyRotationStrategy.allCases, id: \.self) { strategy in
                    Text(strategyLabel(strategy)).tag(strategy)
                }
            }

            if existingProvider != nil {
                Toggle("清除已保存的全部 API Key", isOn: $clearKeys)
            }
        }
    }

    @ViewBuilder
    private func keyStatusHint(for existing: ProviderConfig) -> some View {
        if existing.configuredKeyCount > 0 {
            Text("当前已保存 \(existing.configuredKeyCount) 个 API Key；留空则保持不变。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if case .unknown = existingKeyStatus {
            Text("密钥状态未知；留空不会读取或更改密钥。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("当前尚未配置 API Key（如本地 Ollama 可留空）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var advancedNetworkSection: some View {
        Section("高级网络与请求头") {
            TextField("专属代理 URL（可选，如 http://127.0.0.1:7890 或 socks5://127.0.0.1:1080）", text: $proxyURLText)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("自定义上游请求头（Custom Headers）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        headerRows.append(EditableHeaderRow(key: "", value: ""))
                    } label: {
                        Label("添加请求头", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }

                ForEach($headerRows) { $row in
                    HStack(spacing: 6) {
                        TextField("Header 名称", text: $row.key)
                        TextField("Header 值", text: $row.value)
                        Button(role: .destructive) {
                            headerRows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            TextField("透传客户端请求头白名单（逗号分隔，如 X-Trace-Id, Anthropic-Beta）", text: $passThroughHeadersText)
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
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

    private func populateInitialValues() {
        guard let existing = existingProvider else { return }
        name = existing.name
        baseURL = existing.baseURL
        timeoutSeconds = existing.timeoutSeconds
        apiProtocol = existing.apiProtocol
        if let maxConc = existing.maxConcurrentRequests {
            maxConcurrentText = String(maxConc)
        }
        isEnabled = existing.isEnabled
        keyRotationStrategy = existing.keyRotationStrategy
        proxyURLText = existing.proxyURL ?? ""
        headerRows = existing.customHeaders
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { EditableHeaderRow(key: $0.key, value: $0.value) }
        passThroughHeadersText = existing.passThroughHeaderNames.joined(separator: ", ")
        if let presetID = existing.presetID {
            selectedPreset = ProviderPresetCatalog.preset(id: presetID)
        }
    }

    private func applyPreset(_ preset: ProviderPreset) {
        selectedPreset = preset
        name = preset.name
        baseURL = preset.baseURL
        apiProtocol = preset.apiProtocol
        headerRows = preset.defaultHeaders
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { EditableHeaderRow(key: $0.key, value: $0.value) }
        seedRecommendedModels = !preset.recommendedModels.isEmpty
    }

    private func strategyLabel(_ strategy: ProviderKeyRotationStrategy) -> String {
        switch strategy {
        case .roundRobin:
            return "轮询负载均衡（Round Robin）"
        case .priorityFailover:
            return "主备优先顺延（Priority Failover）"
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

        let trimmedMaxConc = maxConcurrentText.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedMaxConc: Int? = nil
        if !trimmedMaxConc.isEmpty {
            guard let v = Int(trimmedMaxConc), v > 0 else {
                validationError = "最大并发请求数请填写正整数，或留空表示不限制。"
                return
            }
            parsedMaxConc = v
        }

        let trimmedProxy = proxyURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedProxy: String? = nil
        if !trimmedProxy.isEmpty {
            guard let proxyParsed = URL(string: trimmedProxy),
                  let proxyScheme = proxyParsed.scheme?.lowercased(),
                  ["http", "https", "socks5", "socks"].contains(proxyScheme),
                  proxyParsed.host != nil else {
                validationError = "代理地址请使用有效的 http://、https:// 或 socks5:// URL，或留空。"
                return
            }
            parsedProxy = trimmedProxy
        }

        var parsedHeaders: [String: String] = [:]
        for row in headerRows {
            let k = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty {
                parsedHeaders[k] = v
            }
        }

        var parsedPassThrough: [String] = []
        var seenPassThrough: Set<String> = []
        for rawPart in passThroughHeadersText.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
            let trimmed = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            if !trimmed.isEmpty, seenPassThrough.insert(lowered).inserted {
                parsedPassThrough.append(trimmed)
            }
        }

        let parsedKeys = APIKeyPoolCodec.normalize(
            apiKeysText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )

        var updated = existingProvider ?? ProviderConfig(name: trimmedName, baseURL: trimmedURL)
        updated.name = trimmedName
        updated.baseURL = trimmedURL
        updated.timeoutSeconds = timeoutSeconds
        updated.apiProtocol = apiProtocol
        updated.maxConcurrentRequests = parsedMaxConc
        updated.isEnabled = isEnabled
        updated.keyRotationStrategy = keyRotationStrategy
        updated.proxyURL = parsedProxy
        updated.customHeaders = parsedHeaders
        updated.passThroughHeaderNames = parsedPassThrough
        updated.presetID = selectedPreset?.id ?? existingProvider?.presetID
        if existingProvider?.baseURL != trimmedURL {
            updated.healthStatus = .unknown
            updated.lastErrorMessage = nil
        }

        let keysToApply: [String]?
        if clearKeys {
            keysToApply = []
            updated.configuredKeyCount = 0
        } else if !parsedKeys.isEmpty {
            keysToApply = parsedKeys
            updated.configuredKeyCount = parsedKeys.count
        } else {
            keysToApply = nil
        }

        onSave(updated, keysToApply, existingProvider == nil ? selectedPreset : nil, seedRecommendedModels)
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
    @State private var cachedInputPriceText: String = ""
    @State private var cacheCreationPriceText: String = ""
    @State private var maxRPMText: String = ""
    @State private var contextWindow: Int = 128_000
    @State private var verifiedContextWindowText = ""
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
                        TextField("缓存命中读取单价（可选，留空按模型族折扣估算）", text: $cachedInputPriceText)
                        TextField("缓存写入单价（可选，留空按模型族默认估算）", text: $cacheCreationPriceText)
                    }
                }

                Section("约束与能力标签") {
                    Stepper("上下文上限: \(contextWindow) tokens", value: $contextWindow, in: 2048...2_000_000, step: 8192)
                    TextField("已验证上下文（tokens，未知留空）", text: $verifiedContextWindowText)
                    TextField("软 RPM 上限（可选，超限优先分流到同档备用）", text: $maxRPMText)
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
                if let cached = existing.cachedInputPricePerMillion {
                    cachedInputPriceText = String(cached)
                }
                if let created = existing.cacheCreationPricePerMillion {
                    cacheCreationPriceText = String(created)
                }
                if let rpm = existing.maxRequestsPerMinute {
                    maxRPMText = String(rpm)
                }
                contextWindow = existing.contextWindow
                verifiedContextWindowText = existing.verifiedContextWindow.map(String.init) ?? ""
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

        var cachedPrice: Double? = nil
        var cacheCreatePrice: Double? = nil
        if hasPricing {
            let trimmedCached = cachedInputPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCached.isEmpty {
                guard let v = Double(trimmedCached), v >= 0 else {
                    validationError = "缓存读取单价请填写非负数字，或留空。"
                    return
                }
                cachedPrice = v
            }
            let trimmedCreate = cacheCreationPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCreate.isEmpty {
                guard let v = Double(trimmedCreate), v >= 0 else {
                    validationError = "缓存写入单价请填写非负数字，或留空。"
                    return
                }
                cacheCreatePrice = v
            }
        }
        var maxRPM: Int? = nil
        let trimmedRPM = maxRPMText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRPM.isEmpty {
            guard let v = Int(trimmedRPM), v > 0 else {
                validationError = "软 RPM 上限请填写正整数，或留空。"
                return
            }
            maxRPM = v
        }

        let verifiedText = verifiedContextWindowText.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifiedWindow = Int(verifiedText)
        if !verifiedText.isEmpty && (verifiedWindow ?? 0) <= 0 {
            validationError = "已验证上下文请填正整数，或留空。"
            return
        }
        if let existing = existingModel, trimmedID != existing.modelID,
           verifiedWindow != nil, verifiedWindow == existing.verifiedContextWindow {
            verifiedContextWindowText = ""
            validationError = "模型 ID 已更改，请重新填写已验证上下文，或留空。"
            return
        }

        var updated = existingModel ?? ModelConfig(providerID: providerID, modelID: trimmedID)
        updated.providerID = existingModel?.providerID ?? providerID
        updated.modelID = trimmedID
        updated.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmedID : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.inputPricePerMillion = inPrice
        updated.outputPricePerMillion = outPrice
        updated.cachedInputPricePerMillion = cachedPrice
        updated.cacheCreationPricePerMillion = cacheCreatePrice
        updated.maxRequestsPerMinute = maxRPM
        updated.contextWindow = contextWindow
        updated.verifiedContextWindow = verifiedWindow
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

struct CodexSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var engine: AutoModelEngine
    let onConnected: (UUID, String) -> Void

    @State private var activeSession: CodexOAuthLoginSession?
    @State private var isAwaitingBrowserLogin = false
    @State private var manualCallbackURL: String = ""
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        let codexProvider = engine.codexSubscriptionProvider
        let accounts = codexProvider?.subscriptionAccounts ?? []

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Codex 订阅直连与多账号池", systemImage: "person.badge.key.fill")
                    .font(.title3.bold())
                Spacer()
                Button("关闭") {
                    activeSession?.cancel()
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            Text("无需启动 Magpie，直接在 AutoRoute 中使用你的 ChatGPT Plus / Pro 订阅额度，并在模型列表中一键设为低 / 中 / 高档或固定基础模型，供 Claude Code、OpenCode、Codex 等全部 Agent 共用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    startBrowserOAuth()
                } label: {
                    if isAwaitingBrowserLogin {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("等待浏览器完成 ChatGPT 登录…")
                        }
                    } else {
                        Label("浏览器登录 ChatGPT 添加账号", systemImage: "safari")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAwaitingBrowserLogin)

                Button {
                    do {
                        let res = try engine.importCodexCLIAuthAccount()
                        isError = false
                        statusMessage = "已导入本机 ~/.codex/auth.json（\(res.account.displayTitle)），可用模型 \(res.addedModelsCount) 个新增。"
                        onConnected(res.provider.id, statusMessage!)
                    } catch {
                        isError = true
                        statusMessage = error.localizedDescription
                    }
                } label: {
                    Label("从本机 ~/.codex 导入", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                if isAwaitingBrowserLogin {
                    Button("取消等待") {
                        activeSession?.cancel()
                        activeSession = nil
                        isAwaitingBrowserLogin = false
                    }
                    .buttonStyle(.bordered)
                }
            }

            if isAwaitingBrowserLogin, let session = activeSession {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.loopbackPortOccupied
                             ? "检测到本地 1455 端口已被占用（可能是 Codex CLI 正在运行）。完成浏览器授权后，请把浏览器跳转后的完整地址粘贴到下方："
                             : "已在默认浏览器打开 ChatGPT 登录页；登录完成将自动回调并存入 Keychain。若浏览器未自动跳回，也可手动粘贴回调 URL：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("粘贴 http://localhost:1455/auth/callback?code=...&state=...", text: $manualCallbackURL)
                                .textFieldStyle(.roundedBorder)
                            Button("完成导入") {
                                Task {
                                    await session.completeWithCallbackURL(manualCallbackURL)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(manualCallbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(4)
                }
            }

            if let statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? .red : .green)
                    Text(statusMessage)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((isError ? Color.red : Color.green).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            HStack {
                Text("已绑定订阅账号 (\(accounts.count))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let codexProvider {
                    Picker("多账号调度策略", selection: Binding(
                        get: { codexProvider.keyRotationStrategy },
                        set: { nextStrategy in
                            var updated = codexProvider
                            updated.keyRotationStrategy = nextStrategy
                            try? engine.upsertProvider(updated, apiKeys: nil)
                        }
                    )) {
                        Text("主备顺延（配额见底自动切换）").tag(ProviderKeyRotationStrategy.priorityFailover)
                        Text("轮询均衡（多账号分摊额度）").tag(ProviderKeyRotationStrategy.roundRobin)
                    }
                    .frame(width: 240)
                }
            }

            if accounts.isEmpty {
                ContentUnavailableView {
                    Label("暂无已连接的 Codex 订阅账号", systemImage: "key.radiowaves.forward")
                } description: {
                    Text("点击上方「浏览器登录 ChatGPT 添加账号」或「从本机 ~/.codex 导入」，即可直接把 gpt-5.4、gpt-5.3-codex 等订阅模型作为 AutoRoute 基础模型。")
                }
                .frame(maxHeight: .infinity)
            } else if let codexProvider {
                List {
                    ForEach(accounts) { acct in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(acct.displayTitle)
                                    .font(.callout.weight(.medium))
                                HStack(spacing: 8) {
                                    Text(acct.source == "oauth_login" ? "AutoRoute OAuth" : "~/.codex/auth.json")
                                    if let acctID = acct.accountID {
                                        Text("Account: \(acctID.prefix(12))…")
                                    }
                                    if let exp = acct.expiresAt {
                                        Text(acct.isExpiredOrExpiringSoon(leeway: 0) ? "待刷新" : "有效至 \(exp.formatted(date: .abbreviated, time: .shortened))")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("移除", role: .destructive) {
                                try? engine.removeCodexSubscriptionAccount(accountID: acct.id, from: codexProvider.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .frame(minHeight: 160)
            }
        }
        .padding(20)
        .frame(width: 660, height: 520)
        .onDisappear {
            activeSession?.cancel()
            activeSession = nil
        }
    }

    private func startBrowserOAuth() {
        let session = CodexOAuthLoginSession()
        activeSession = session
        isAwaitingBrowserLogin = true
        statusMessage = nil
        isError = false
        manualCallbackURL = ""

        NSWorkspace.shared.open(session.authorizeURL)

        Task {
            do {
                let account = try await session.startAndAwaitAccount()
                let res = try engine.addCodexSubscriptionAccount(account)
                await MainActor.run {
                    isAwaitingBrowserLogin = false
                    activeSession = nil
                    isError = false
                    let msg = "已连接 ChatGPT 订阅账号「\(res.account.displayTitle)」，现在可以直接将 Codex 模型设为基础模型或供 Agent 使用。"
                    statusMessage = msg
                    onConnected(res.provider.id, msg)
                }
            } catch {
                await MainActor.run {
                    isAwaitingBrowserLogin = false
                    activeSession = nil
                    isError = true
                    statusMessage = error.localizedDescription
                }
            }
        }
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
