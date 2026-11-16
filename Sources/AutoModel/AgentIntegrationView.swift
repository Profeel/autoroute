import AppKit
import AutoModelCore
import SwiftUI

struct AgentIntegrationView: View {
    @ObservedObject var engine: AutoModelEngine

    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false
    @State private var previewPayload: ConfigPreviewPayload?

    private struct ConfigPreviewPayload: Identifiable {
        let id = UUID()
        let kind: AgentKind
        let before: String
        let after: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
        .sheet(item: $previewPayload) { payload in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(payload.kind.displayName) 配置变更预览")
                        .font(.headline)
                    Spacer()
                    Button("关闭") {
                        previewPayload = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("以下为写入前（当前磁盘内容）与写入后（将注入 Auto Model 网关与三档配置）的对比：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("写入前（Before）")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(payload.before.isEmpty ? "(空文件或尚不存在)" : payload.before)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("写入后（After）")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                        ScrollView {
                            Text(payload.after)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 760, minHeight: 460)
        }
    }

    private var headerBannerCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("一键将 Auto Model 本地网关与低 / 中 / 高三档模型配置到各 AI Agent")
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

                    Button {
                        let res = engine.applyAllInstalledAgents()
                        if res.errors.isEmpty {
                            feedbackIsError = false
                            feedbackMessage = "已成功将 Auto Model 配置写入 \(res.succeeded) 个已检测到的 Agent。"
                        } else {
                            feedbackIsError = true
                            feedbackMessage = "完成 \(res.succeeded) 个，失败：\(res.errors.joined(separator: "；"))"
                        }
                    } label: {
                        Label("一键配置全部已安装 Agent", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent)
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
            .padding(6)
        }
    }

    private func agentCard(for status: AgentIntegrationStatus) -> some View {
        let binding = engine.binding(for: status.kind)
        let modelOptions = buildModelOptions(currentBinding: binding)

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Header row
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(status.kind.displayName)
                                .font(.headline)

                            if status.isConnectedToAutoModel {
                                pillBadge("已接入 Auto Model", color: .green)
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
                            Button("重置为推荐 auto / 三档") {
                                engine.updateAgentBinding(AgentModelBinding(), for: status.kind)
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

                // Action buttons
                HStack(spacing: 10) {
                    Button {
                        do {
                            let updated = try engine.applyAgentIntegration(kind: status.kind)
                            feedbackIsError = false
                            feedbackMessage = "已成功将 Auto Model 写入「\(updated.kind.displayName)」(\(updated.configFilePath))。"
                        } catch {
                            feedbackIsError = true
                            feedbackMessage = "配置 \(status.kind.displayName) 失败: \(error.localizedDescription)"
                        }
                    } label: {
                        Label(
                            status.isConnectedToAutoModel ? "更新并重新写入配置" : "一键接入 Auto Model",
                            systemImage: "arrow.right.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        do {
                            let preview = try engine.agentConfigService.previewAgentConfig(
                                kind: status.kind,
                                binding: engine.binding(for: status.kind),
                                proxyPort: engine.config.proxySettings.port,
                                resolvedTierDisplayNames: engine.resolvedTierDisplayNames()
                            )
                            previewPayload = ConfigPreviewPayload(kind: status.kind, before: preview.before, after: preview.after)
                        } catch {
                            feedbackIsError = true
                            feedbackMessage = "生成预览失败: \(error.localizedDescription)"
                        }
                    } label: {
                        Label("预览变更", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        do {
                            let restored = try engine.restoreAgentIntegration(kind: status.kind)
                            feedbackIsError = false
                            feedbackMessage = "已断开「\(restored.kind.displayName)」并从备份还原原配置。"
                        } catch {
                            feedbackIsError = true
                            feedbackMessage = "恢复 \(status.kind.displayName) 失败: \(error.localizedDescription)"
                        }
                    } label: {
                        Label("断开并恢复原配置", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!status.hasBackup)

                    Spacer()

                    if !engine.proxyState.isRunning {
                        Text("⚠️ 本地代理未运行，建议先启动代理")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(6)
        }
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
        for model in engine.healthyAvailableModels() where !seen.contains(model.modelID) {
            options.append(ModelPickerOption(id: model.modelID, label: "\(model.displayName) (\(model.modelID))"))
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
