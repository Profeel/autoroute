import AppKit
import AutoModelCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: AutoModelEngine
    var onShowOnboarding: (() -> Void)? = nil

    @State private var portInput: String = ""
    @State private var feedbackMessage: String?
    @State private var launchAtLoginEnabled: Bool = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if engine.portSyncNeededForConnectedAgents {
                    portSyncBanner
                }
                proxyConfigCard
                localSimulatorCard
                probeAuditLogsCard
                privacyAndDataCard
                openSourceAboutCard
            }
            .padding(20)
        }
        .navigationTitle("设置")
        .onAppear {
            portInput = String(engine.config.proxySettings.port)
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    private var portSyncBanner: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("代理端口已变更，已接入的外部 Agent 需要同步")
                        .font(.callout.weight(.semibold))
                    Text("检测到部分已接入的 Agent 仍指向旧端口。点击右侧按钮可一键刷新它们的配置文件至当前端口 \(engine.config.proxySettings.port)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("一键同步 Agent 端口") {
                    let result = engine.syncConnectedAgentsToCurrentPort()
                    if result.errors.isEmpty {
                        feedbackMessage = "已成功将 \(result.succeeded) 个已接入 Agent 同步到端口 \(engine.config.proxySettings.port)。"
                    } else {
                        feedbackMessage = "同步完成（成功 \(result.succeeded) 个），失败: \(result.errors.joined(separator: "; "))"
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(6)
        }
    }

    private var proxyConfigCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("监听地址固定为 127.0.0.1（仅本机可访问）", systemImage: "lock.shield")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(engine.proxyState.statusText)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(engine.proxyState.isRunning ? .green : .red)
                }

                if case .portConflict(let occupiedPort, let suggested) = engine.proxyState {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("端口 \(occupiedPort) 已被其他进程占用。")
                            .font(.callout)
                        Spacer()
                        if let suggested {
                            Button("一键切换到可用端口 \(suggested)") {
                                portInput = String(suggested)
                                engine.updateProxyPort(suggested)
                                feedbackMessage = "已切换到端口 \(suggested) 并重新启动本地代理。"
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 12) {
                    Text("代理端口:")
                    TextField("8765", text: $portInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Button("应用端口并重启代理") {
                        applyPort()
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    if engine.proxyState.isRunning {
                        Button("停止代理") {
                            engine.stopProxy()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("启动代理") {
                            engine.startProxy()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Toggle("打开 App 时自动启动本地代理", isOn: Binding(
                    get: { engine.config.proxySettings.autoStartProxy },
                    set: { engine.updateAutoStartProxy($0) }
                ))

                Toggle("启动时自动发掘本机已配置模型并定期巡检剔除不可用模型", isOn: Binding(
                    get: { engine.config.proxySettings.autoDiscoverAndProbeOnLaunch },
                    set: { engine.updateAutoDiscoverAndProbe($0) }
                ))

                HStack(spacing: 10) {
                    Button {
                        Task {
                            let summary = await engine.discoverAndProbeLocalModels()
                            feedbackMessage = "巡检完成：实测可用 \(summary.healthyModelsCount) 个，已自动剔除 \(summary.evictedModelsCount) 个不可用模型。"
                        }
                    } label: {
                        Label("立即扫描本机模型并测活剔除", systemImage: "radar")
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.isDiscoveringAndProbing)

                    if let progress = engine.probeProgressText {
                        Text(progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let feedbackMessage {
                    Text(feedbackMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Toggle(isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                                launchAtLoginEnabled = true
                                feedbackMessage = "已开启登录时自动启动 Auto Model。"
                            } else {
                                try SMAppService.mainApp.unregister()
                                launchAtLoginEnabled = false
                                feedbackMessage = "已取消登录时自动启动。"
                            }
                        } catch {
                            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
                            feedbackMessage = "设置开机自启失败（可将 AutoModel.app 拖入「应用程序」目录后重试）: \(error.localizedDescription)"
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录 macOS 时自动启动 Auto Model")
                            .font(.callout.weight(.medium))
                        Text("开启后将在后台自动拉起本地 127.0.0.1 代理与菜单栏入口。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        } label: {
            Label("本地 HTTP API 代理", systemImage: "network")
                .font(.headline)
        }
    }

    private var localSimulatorCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("内置本地模拟测试上游 (Loopback Mock)")
                            .font(.callout.weight(.medium))
                        Text("当您暂无外部模型 API Key 时，可启动此本地模拟服务（127.0.0.1:18765）来验证多模型路由、SSE 流式转发与费用统计。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if engine.isLocalTestUpstreamRunning {
                        Button("停止模拟上游") {
                            engine.stopLocalTestUpstream()
                            feedbackMessage = "已停止本地模拟测试上游。"
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("启动并添加模拟模型") {
                            do {
                                try engine.installLocalTestPreset()
                                feedbackMessage = "本地模拟测试上游已在 127.0.0.1:\(engine.localTestUpstreamPort ?? 18765) 运行。"
                            } catch {
                                feedbackMessage = "启动失败: \(error.localizedDescription)"
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(6)
        } label: {
            Label("离线验证工具", systemImage: "cpu")
                .font(.headline)
        }
    }

    private var privacyAndDataCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { engine.config.privacySettings.recordRequestBody },
                    set: { engine.setRecordRequestBody($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("在调用记录中保存请求与响应正文摘要")
                            .font(.callout.weight(.medium))
                        Text("关闭后，调用历史仅保留路由决策、模型选择、耗时、用量与费用元数据，不保存对话内容。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Button("导出已脱敏收据 JSON") {
                        exportSanitizedReceipts()
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.callHistory.isEmpty)

                    Button("清空所有调用历史", role: .destructive) {
                        engine.clearCallHistory()
                        feedbackMessage = "已清空本机调用历史与会话粘性缓存。"
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.callHistory.isEmpty)

                    Button("清除 Keychain 中的全部密钥", role: .destructive) {
                        do {
                            try engine.clearAllKeychainKeys()
                            feedbackMessage = "已从 macOS Keychain 清除全部供应商 API Key。"
                        } catch {
                            feedbackMessage = "清除失败: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("配置文件路径（不含任何 API Key）: \(engine.persistence.configFileURL.path)")
                    Text("调用历史路径: \(engine.persistence.historyFileURL.path)")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .padding(6)
        } label: {
            Label("隐私与本地存储", systemImage: "hand.raised")
                .font(.headline)
        }
    }

    private var probeAuditLogsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if engine.probeAuditLogs.isEmpty {
                    Text("尚无探测或自动剔除记录。点击「发现并健康探测」或在运行中触发故障降级时，这里将记录时间戳与原因。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(engine.probeAuditLogs.prefix(20).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("本地发现与健康探测日志（含自动剔除审计）", systemImage: "stethoscope")
                .font(.headline)
        }
    }

    private var openSourceAboutCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Auto Model · 开源 macOS 本地多模型路由器 (MIT License)")
                    .font(.callout.weight(.semibold))
                Text("• 开源版无需注册账号、不依赖托管中转服务、不发送遥测数据。")
                Text("• 本机兼容接口：`POST /v1/chat/completions`（OpenAI Chat Completions 普通与流式）、`POST /v1/messages`（Anthropic Messages 普通与流式）、`POST /v1/responses`（OpenAI Responses 普通与流式）及 `GET /v1/models`。")
                Text("• 思考模型兼容：自动分离并透传 `reasoning_content` / `reasoning`，避免冷启动误判。")
                Text("• 已知限制：暂未实现 `/v1/embeddings` 与图片生成接口；跨协议转换以文本与 Tool Calls 为主。")
                if let onShowOnboarding {
                    Button("查看首次使用引导") {
                        onShowOnboarding()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(6)
        } label: {
            Label("开源说明与兼容范围", systemImage: "info.circle")
                .font(.headline)
        }
    }

    private func applyPort() {
        guard let parsed = Int(portInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed >= 1024 && parsed <= 65535 else {
            feedbackMessage = "端口号必须是 1024 到 65535 之间的整数。"
            return
        }
        engine.updateProxyPort(parsed)
        feedbackMessage = "端口已更新为 \(parsed)。"
    }

    private func exportSanitizedReceipts() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "automodel-receipts.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try engine.persistence.exportReceiptsJSON(
                    records: engine.callHistory,
                    secretsToRedact: engine.keychain.allKnownSecretValues()
                )
                try data.write(to: url, options: .atomic)
                feedbackMessage = "已导出 \(engine.callHistory.count) 条脱敏路由收据到 \(url.lastPathComponent)。"
            } catch {
                feedbackMessage = "导出失败: \(error.localizedDescription)"
            }
        }
    }
}
