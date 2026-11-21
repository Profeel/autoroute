import AppKit
import AutoModelCore
import SwiftUI

struct AgentIntegrationView: View {
    @ObservedObject var engine: AutoModelEngine

    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false
    @State private var showBulkConfirmation = false
    @State private var agentKeyInput = ""
    @State private var showAgentKeyPlaintext = false
    @State private var keyFeedbackMessage: String?
    @State private var keyFeedbackIsError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !engine.isLocalAPITokenPersistent {
                    localCredentialBlockingBanner
                }
                headerBannerCard

                if let feedbackMessage {
                    HStack(spacing: 8) {
                        Image(systemName: feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(feedbackIsError ? .red : .green)
                        Text(feedbackMessage)
                            .font(.callout)
                        Spacer()
                        Button("关闭") {
                            self.feedbackMessage = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(12)
                    .background((feedbackIsError ? Color.red : Color.green).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                agentKeySettingsCard
                manualAgentCard
                ForEach(engine.agentStatuses) { status in
                    agentCard(for: status)
                }
            }
            .padding(20)
        }
        .navigationTitle("Agent 自动配置")
        .onAppear {
            engine.refreshAgentStatuses()
        }
        .confirmationDialog("将备份并配置全部已检测到的 Agent？", isPresented: $showBulkConfirmation, titleVisibility: .visible) {
            Button("备份并配置全部") {
                let result = engine.applyAllInstalledAgents()
                feedbackIsError = !result.errors.isEmpty
                feedbackMessage = result.errors.isEmpty
                    ? "已写入 \(result.succeeded) 个 Agent。请重启并分别发送真实请求。"
                    : "完成 \(result.succeeded) 个，失败：\(result.errors.joined(separator: "；"))"
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var agentKeySettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Agent 接入密钥（API Key）")
                    .font(.headline)
                if engine.localModelAPIKey != nil {
                    pillBadge("已设置自定义模型密钥", color: .green)
                } else {
                    pillBadge("默认管理 token", color: .secondary)
                }
                Spacer()
                if engine.agentStatuses.contains(where: \.isConnectedToAutoModel) {
                    Button("同步密钥到已接入 Agent") {
                        let result = engine.syncConnectedAgentsToCurrentPort()
                        keyFeedbackIsError = !result.errors.isEmpty
                        keyFeedbackMessage = result.errors.isEmpty
                            ? "已将当前密钥与端口同步到 \(result.succeeded) 个已接入 Agent。"
                            : "同步完成 \(result.succeeded) 个，失败：\(result.errors.joined(separator: "；"))"
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!engine.isLocalAPITokenPersistent)
                }
            }

            Text("设置后，一键接入各 Agent（含 DeepSeek Harness）及手动接入均优先使用此模型专用密钥（仅可调用 /v1/* 模型接口，无法调用管理接口）。允许 4–128 位字母、数字及 - . _ ~。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Group {
                    if showAgentKeyPlaintext {
                        TextField("输入新密钥，或点击右侧随机生成", text: $agentKeyInput)
                    } else {
                        SecureField("输入新密钥，或点击右侧随机生成", text: $agentKeyInput)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())

                Button {
                    showAgentKeyPlaintext.toggle()
                } label: {
                    Image(systemName: showAgentKeyPlaintext ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(showAgentKeyPlaintext ? "隐藏输入" : "显示输入")

                Button("保存密钥") {
                    do {
                        let trimmed = agentKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        try engine.setLocalModelAPIKey(trimmed)
                        agentKeyInput = ""
                        keyFeedbackIsError = false
                        keyFeedbackMessage = "模型密钥已保存并立即生效；如需写入已接入 Agent，可点击「同步密钥到已接入 Agent」或对应 Agent 的一键设置。"
                    } catch {
                        keyFeedbackIsError = true
                        keyFeedbackMessage = "保存密钥失败：\(error.localizedDescription)"
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!engine.isLocalAPITokenPersistent || agentKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("生成随机密钥") {
                    do {
                        let generated = try LocalAPITokenManager.generateModelAPIKey()
                        try engine.setLocalModelAPIKey(generated)
                        agentKeyInput = ""
                        keyFeedbackIsError = false
                        keyFeedbackMessage = "已生成并保存新的模型专用密钥。"
                    } catch {
                        keyFeedbackIsError = true
                        keyFeedbackMessage = "生成密钥失败：\(error.localizedDescription)"
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!engine.isLocalAPITokenPersistent)

                Button("复制当前密钥") {
                    guard let key = engine.manualAgentAPIKey else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    keyFeedbackIsError = false
                    keyFeedbackMessage = "已复制当前 Agent 密钥，请仅粘贴到受信任的本机客户端。"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(engine.manualAgentAPIKey == nil)

                Button("恢复默认 token", role: .destructive) {
                    do {
                        try engine.clearLocalModelAPIKey()
                        agentKeyInput = ""
                        keyFeedbackIsError = false
                        keyFeedbackMessage = "已清除自定义模型密钥，恢复使用本地管理 token。"
                    } catch {
                        keyFeedbackIsError = true
                        keyFeedbackMessage = "清除失败：\(error.localizedDescription)"
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(engine.localModelAPIKey == nil && engine.localModelAPIKeyError == nil)
            }

            if let error = engine.localModelAPIKeyError {
                Text("\(error) 请重新保存或清除后重试。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let keyFeedbackMessage {
                Text(keyFeedbackMessage)
                    .font(.caption)
                    .foregroundStyle(keyFeedbackIsError ? Color.red : Color.secondary)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private var manualAgentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("其他 Agent")
                .font(.headline)
            Text("在客户端中手动填写以下地址、密钥和模型；不会修改客户端配置文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !engine.proxyState.isRunning {
                Text("代理当前未运行；启动后可使用以下地址。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            manualValueRow("OpenAI 兼容 Base URL", value: engine.manualAgentRootURL + "/v1")
            manualValueRow("Anthropic Base URL", value: engine.manualAgentRootURL)
            Text("Anthropic 客户端通常会自动追加 /v1/messages；请按客户端的地址约定填写。")
                .font(.caption)
                .foregroundStyle(.secondary)
            manualValueRow("模型", value: "auto")
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("API 密钥").font(.caption.weight(.medium))
                    Text(engine.localModelAPIKeyError != nil
                         ? "当前密钥状态暂不可确认。"
                         : (engine.localModelAPIKey == nil
                            ? "未设置自定义模型密钥时使用管理 token，可访问本地管理接口。"
                            : "当前使用自定义模型密钥，仅可调用模型接口。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("复制密钥") {
                    guard let key = engine.manualAgentAPIKey else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    feedbackIsError = false
                    feedbackMessage = "已复制本地密钥，请仅粘贴到受信任的本机客户端。"
                }
                .disabled(engine.manualAgentAPIKey == nil)
            }
            if let error = engine.localModelAPIKeyError {
                Text("\(error) 请在「设置 → 通用与代理」中重试。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("可在上方「Agent 接入密钥」或「设置 → 通用与代理」中设置、生成或更换模型专用密钥。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func manualValueRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption.weight(.medium))
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
            Spacer()
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .controlSize(.small)
            .accessibilityLabel("复制\(label)")
        }
    }

    private var localCredentialBlockingBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
                Label("本地 API token 未持久化，Agent 接入已阻断", systemImage: "exclamationmark.lock.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text(engine.localAPITokenPersistenceError ?? "无法确认本地 token 已保存到 Keychain。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("修复前不会写入任何 Agent 配置，也不会自动启动代理；请先重试持久化，避免 Agent 使用重启后失效的临时 token。")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("检查并重试保存凭据") {
                    do {
                        try engine.retryPersistingLocalAPIToken()
                        if !engine.proxyState.isRunning {
                            engine.startProxy()
                        }
                        feedbackIsError = false
                        feedbackMessage = engine.proxyState.isRunning
                            ? "本地 token 已持久化，本地代理已启动，现在可以接入 Agent。"
                            : "本地 token 已持久化，现在可以接入 Agent。"
                    } catch {
                        feedbackIsError = true
                        feedbackMessage = "仍无法持久化本地凭据：\(error.localizedDescription)"
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.25), lineWidth: 1))
    }

    private var headerBannerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("一键将 AutoRoute 本地网关与低 / 中 / 高三档模型配置到各 AI Agent")
                            .font(.headline)
                        Text("类似 Magpie 的接管方式：首次注入前自动备份原配置文件（保留现有供应商、MCP 与项目信任列表），支持随时一键断开并还原。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        engine.refreshAgentStatuses()
                        feedbackIsError = false
                        feedbackMessage = "已重新扫描本机 Agent 配置文件状态。"
                    } label: {
                        Label("刷新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button("批量配置（高级）") { showBulkConfirmation = true }
                        .buttonStyle(.bordered)
                        .disabled(!engine.isLocalAPITokenPersistent)
                }

                Divider()

                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Text("本地网关:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(engine.config.proxySettings.baseURLString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(engine.config.proxySettings.baseURLString, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        ForEach(ModelTier.allCases) { tier in
                            let modelName = engine.model(for: tier)?.displayName ?? "未分配"
                            let tint: Color = (tier == .low ? .green : (tier == .medium ? .blue : .purple))
                            HStack(spacing: 4) {
                                Text(tier.shortName)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(tint)
                                Text(modelName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(tint.opacity(0.1))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(.controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func agentCard(for status: AgentIntegrationStatus) -> some View {
        let binding = engine.binding(for: status.kind)
        let modelOptions = buildModelOptions(currentBinding: binding)

        return VStack(alignment: .leading, spacing: 12) {
                // Header row
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(status.kind.displayName)
                                .font(.headline)

                            if status.isConnectedToAutoModel {
                                pillBadge("配置已写入", color: .blue)
                            } else if status.isInstalled {
                                pillBadge("已检测到本地配置", color: .blue)
                            } else {
                                pillBadge("未检测到安装", color: .secondary)
                            }

                            if status.hasBackup {
                                pillBadge("已保存原始备份", color: .orange)
                            }
                        }

                        Text(status.kind.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        let url = URL(fileURLWithPath: status.configFilePath)
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            let parent = url.deletingLastPathComponent()
                            if FileManager.default.fileExists(atPath: parent.path) {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: parent.path)
                            }
                        }
                    } label: {
                        Label("定位配置文件", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Current status metadata
                HStack(spacing: 18) {
                    Label {
                        Text("配置文件: \(status.configFilePath)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                    .foregroundStyle(.secondary)

                    if let base = status.currentBaseURL, !base.isEmpty {
                        Label {
                            Text("当前地址: \(base)")
                                .font(.caption.monospaced())
                        } icon: {
                            Image(systemName: "network")
                        }
                        .foregroundStyle(.secondary)
                    }

                    if let currentModel = status.currentModelSummary, !currentModel.isEmpty {
                        Label {
                            Text("当前模型: \(currentModel)")
                                .font(.caption.monospaced())
                        } icon: {
                            Image(systemName: "cpu")
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                if let note = status.statusNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(status.kind == .claudeCode ? .orange : .secondary)
                }

                Divider()

                // Editable Model & Tier Mapping section (collapsed by default for clarity)
                DisclosureGroup("自定义模型映射（默认: \(binding.defaultModelOption)）") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("接入模型与三档映射设置（可修改）：")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Button("重置为推荐 Agent 别名") {
                                engine.updateAgentBinding(.stableIdentity(for: status.kind), for: status.kind)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("默认主模型 (Default)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Picker("主模型", selection: bindingPicker(for: status.kind, keyPath: \.defaultModelOption)) {
                                    ForEach(modelOptions, id: \.id) { opt in
                                        Text(opt.label).tag(opt.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                            }

                            if status.kind != .codex {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("低档 (Low / Haiku)")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                    Picker("低档", selection: bindingPicker(for: status.kind, keyPath: \.lowModelOption)) {
                                        ForEach(modelOptions, id: \.id) { opt in
                                            Text(opt.label).tag(opt.id)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("中档 (Medium / Sonnet)")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                    Picker("中档", selection: bindingPicker(for: status.kind, keyPath: \.mediumModelOption)) {
                                        ForEach(modelOptions, id: \.id) { opt in
                                            Text(opt.label).tag(opt.id)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("高档 (High / Opus)")
                                        .font(.caption2)
                                        .foregroundStyle(.purple)
                                    Picker("高档", selection: bindingPicker(for: status.kind, keyPath: \.highModelOption)) {
                                        ForEach(modelOptions, id: \.id) { opt in
                                            Text(opt.label).tag(opt.id)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 6)
                }
                .font(.caption.weight(.medium))

                AgentConnectionCard(engine: engine, status: status)
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private struct ModelPickerOption: Identifiable {
        let id: String
        let label: String
    }

    private func buildModelOptions(currentBinding: AgentModelBinding) -> [ModelPickerOption] {
        let lowName = engine.model(for: .low)?.displayName ?? "未分配"
        let medName = engine.model(for: .medium)?.displayName ?? "未分配"
        let highName = engine.model(for: .high)?.displayName ?? "未分配"

        var options: [ModelPickerOption] = [
            ModelPickerOption(id: "auto", label: "auto · 智能三档自适应路由（推荐）"),
            ModelPickerOption(id: "auto/low", label: "auto/low · 低档 (\(lowName))"),
            ModelPickerOption(id: "auto/medium", label: "auto/medium · 中档 (\(medName))"),
            ModelPickerOption(id: "auto/high", label: "auto/high · 高档 (\(highName))")
        ]

        var seen = Set(options.map(\.id))
        let codexProviderIDs = Set(engine.config.providers.filter { $0.apiProtocol == .codexChatGPT }.map(\.id))
        for model in engine.healthyAvailableModels() where !seen.contains(model.modelID) {
            let tag = codexProviderIDs.contains(model.providerID) ? " [Codex 订阅]" : ""
            options.append(ModelPickerOption(id: model.modelID, label: "\(model.displayName)\(tag) (\(model.modelID))"))
            seen.insert(model.modelID)
        }

        // Preserve any previously saved custom option so Picker tag is always valid
        for existing in [
            currentBinding.defaultModelOption,
            currentBinding.lowModelOption,
            currentBinding.mediumModelOption,
            currentBinding.highModelOption
        ] where !existing.isEmpty && !seen.contains(existing) {
            options.append(ModelPickerOption(id: existing, label: existing))
            seen.insert(existing)
        }

        return options
    }

    private func bindingPicker(
        for kind: AgentKind,
        keyPath: WritableKeyPath<AgentModelBinding, String>
    ) -> Binding<String> {
        Binding(
            get: { engine.binding(for: kind)[keyPath: keyPath] },
            set: { newValue in
                var current = engine.binding(for: kind)
                current[keyPath: keyPath] = newValue
                engine.updateAgentBinding(current, for: kind)
            }
        )
    }

    private func pillBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
