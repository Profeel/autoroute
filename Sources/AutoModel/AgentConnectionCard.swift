import AutoModelCore
import SwiftUI

struct AgentConnectionCard: View {
    @ObservedObject var engine: AutoModelEngine
    let status: AgentIntegrationStatus
    var onOpenReceipt: ((UUID) -> Void)? = nil

    @State private var preview: Preview?
    @State private var message: String?
    @State private var showRestore = false
    @State private var inlineKeyInput = ""
    @State private var showInlineKeyPlaintext = false

    private struct Preview: Identifiable {
        let id = UUID()
        let binding: AgentModelBinding
        let port: Int
        let updatedAt: Date?
        let pendingCustomKey: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch engine.agentReadiness(for: status.kind) {
            case .notConfigured:
                Label("尚未写入当前代理配置", systemImage: "circle")
            case .waiting:
                Label("配置已写入，等待 Agent 的真实请求", systemImage: "clock")
                if !engine.binding(for: status.kind).defaultModelOption.hasPrefix("auto/agent/\(status.kind.rawValue)") {
                    Text("当前默认模型不是稳定 Agent 别名，不能自动验证身份；可在高级映射中改回推荐别名。")
                        .foregroundStyle(.secondary)
                }
            case .verified(let id):
                HStack {
                    Label("最近真实请求成功 \(receiptTime(id))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let onOpenReceipt { Button("查看收据") { onOpenReceipt(id) } }
                }
            }

            if status.kind == .deepseekHarness {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Key 设置（写入 ~/.dsh/.credentials.yaml 的 AUTOROUTE_API_KEY）")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(engine.localModelAPIKey == nil ? "当前将使用：默认管理 token" : "当前将使用：自定义模型密钥")
                            .font(.caption2)
                            .foregroundStyle(engine.localModelAPIKey == nil ? Color.secondary : Color.green)
                    }
                    HStack(spacing: 8) {
                        Group {
                            if showInlineKeyPlaintext {
                                TextField("可选：直接输入自定义 Key（留空沿用当前密钥）", text: $inlineKeyInput)
                            } else {
                                SecureField("可选：直接输入自定义 Key（留空沿用当前密钥）", text: $inlineKeyInput)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())

                        Button {
                            showInlineKeyPlaintext.toggle()
                        } label: {
                            Image(systemName: showInlineKeyPlaintext ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(showInlineKeyPlaintext ? "隐藏输入" : "显示输入")

                        Button("随机生成") {
                            do {
                                inlineKeyInput = try LocalAPITokenManager.generateModelAPIKey()
                                showInlineKeyPlaintext = true
                                message = "已生成随机 Key，点击「一键设置到 DeepSeek Harness」即可保存并写入。"
                            } catch {
                                message = "生成随机 Key 失败：\(error.localizedDescription)"
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(Color(.controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                if status.kind == .deepseekHarness {
                    Button(status.isConnectedToAutoModel ? "一键更新到 DeepSeek Harness" : "一键设置到 DeepSeek Harness") {
                        applyOneClickDeepSeekHarness()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!engine.isLocalAPITokenPersistent)

                    Button("预览配置") { preparePreview() }
                        .buttonStyle(.bordered)
                        .disabled(!engine.isLocalAPITokenPersistent)
                } else if status.isConnectedToAutoModel {
                    Button("预览并更新配置") { preparePreview() }
                        .buttonStyle(.bordered).disabled(!engine.isLocalAPITokenPersistent)
                } else {
                    Button("预览并接入") { preparePreview() }
                        .buttonStyle(.borderedProminent).disabled(!engine.isLocalAPITokenPersistent)
                }
                if status.hasBackup {
                    Button("恢复原配置") { showRestore = true }
                        .buttonStyle(.bordered)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .sheet(item: $preview) { item in
            VStack(alignment: .leading, spacing: 12) {
                Text("\(status.kind.displayName) 接入预览").font(.headline)
                Text("确认后先备份原配置，再写入本地网关与模型映射。已有配置中的其他字段会保留；为保护密钥，这里不展示原文件内容。")
                    .foregroundStyle(.secondary)
                Text("配置文件：\(status.configFilePath)").textSelection(.enabled)
                if status.kind == .deepseekHarness {
                    Text("凭据文件：\(engine.agentConfigService.dshCredentialsURL().path) (refs.AUTOROUTE_API_KEY)")
                        .textSelection(.enabled)
                }
                Text("本地网关：http://127.0.0.1:\(item.port)/v1")
                Text("默认模型：\(item.binding.defaultModelOption)")
                if status.kind != .codex {
                    Text("低 / 中 / 高：\(item.binding.lowModelOption) / \(item.binding.mediumModelOption) / \(item.binding.highModelOption)")
                }
                if item.pendingCustomKey != nil {
                    Text("将保存新输入的自定义模型密钥并写入 Agent 配置，预览中不显示。")
                        .foregroundStyle(.secondary)
                } else {
                    Text(engine.localModelAPIKey == nil
                         ? "本地管理 token 将写入 Agent 配置，预览中不显示。"
                         : "自定义模型密钥将写入 Agent 配置，预览中不显示。")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("取消") { preview = nil }
                    Button("备份并写入") {
                        guard engine.config.proxySettings.port == item.port,
                              engine.binding(for: status.kind) == item.binding,
                              engine.agentConfigService.configurationUpdatedAt(for: status.kind) == item.updatedAt else {
                            preview = nil
                            message = "配置或端口已变化，请重新预览。"
                            return
                        }
                        do {
                            if let pendingKey = item.pendingCustomKey {
                                try engine.setLocalModelAPIKey(pendingKey)
                                inlineKeyInput = ""
                            }
                            _ = try engine.applyAgentIntegration(kind: status.kind)
                            message = "配置已写入。请重启 \(status.kind.displayName) 并发送请求。"
                        } catch {
                            message = "接入失败：\(error.localizedDescription)"
                        }
                        preview = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 600)
        }
        .confirmationDialog("恢复 \(status.kind.displayName) 的原配置？", isPresented: $showRestore, titleVisibility: .visible) {
            Button("恢复原配置", role: .destructive) {
                do {
                    _ = try engine.restoreAgentIntegration(kind: status.kind)
                    message = "已恢复原配置。"
                } catch {
                    message = "恢复失败：\(error.localizedDescription)"
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func applyOneClickDeepSeekHarness() {
        let trimmedKey = inlineKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !trimmedKey.isEmpty {
                try engine.setLocalModelAPIKey(trimmedKey)
                inlineKeyInput = ""
            }
            _ = try engine.applyAgentIntegration(kind: .deepseekHarness)
            message = "已一键备份并设置到 DeepSeek Harness（已同步写入 cordis.patch.yml 与 .credentials.yaml）。请重启 DeepSeek Harness 并发送请求。"
        } catch {
            message = "一键设置失败：\(error.localizedDescription)"
        }
    }

    private func preparePreview() {
        let binding = engine.binding(for: status.kind)
        let port = engine.config.proxySettings.port
        let updatedAt = engine.agentConfigService.configurationUpdatedAt(for: status.kind)
        let trimmedKey = inlineKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingKey: String? = (status.kind == .deepseekHarness && !trimmedKey.isEmpty) ? trimmedKey : nil
        do {
            if let pendingKey {
                try LocalModelAPIKeyError.validate(pendingKey, managementToken: engine.localAPIToken)
            }
            let previewToken = pendingKey ?? engine.manualAgentAPIKey ?? engine.localAPIToken
            _ = try engine.agentConfigService.previewAgentConfig(
                kind: status.kind, binding: binding, proxyPort: port,
                localAPIToken: previewToken, resolvedTierDisplayNames: engine.resolvedTierDisplayNames()
            )
            preview = Preview(binding: binding, port: port, updatedAt: updatedAt, pendingCustomKey: pendingKey)
        } catch {
            message = "生成预览失败：\(error.localizedDescription)"
        }
    }

    private func receiptTime(_ id: UUID) -> String {
        engine.callHistory.first { $0.id == id }?.timestamp.formatted(date: .abbreviated, time: .shortened) ?? ""
    }
}
