import AppKit
import AutoModelCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: AutoModelEngine
    var onShowOnboarding: (() -> Void)? = nil

    @State private var selectedSection: SettingsSection = .generalAndProxy
    @State private var portInput: String = ""
    @State private var modelKeyInput: String = ""
    @State private var modelKeyFeedback: String?
    @State private var modelKeyFeedbackIsError = false
    @State private var feedbackMessage: String?
    @State private var launchAtLoginEnabled: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var showClearHistoryConfirmation = false
    @State private var isCheckingUpdate = false
    @State private var updateCheckResult: UpdateCheckResult?

    enum SettingsSection: String, CaseIterable {
        case generalAndProxy = "通用与代理"
        case budgetAndPrivacy = "预算与隐私"
        case diagnosticsAndAbout = "诊断与关于"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("设置分组", selection: $selectedSection) {
                    ForEach(SettingsSection.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !engine.isLocalAPITokenPersistent {
                        localTokenBlockingBanner
                    }
                    if engine.portSyncNeededForConnectedAgents {
                        portSyncBanner
                    }

                    switch selectedSection {
                    case .generalAndProxy:
                        proxyConfigCard
                        localSimulatorCard
                    case .budgetAndPrivacy:
                        BudgetSettingsCard(engine: engine)
                        LocalMetricsSettingsCard(engine: engine)
                        privacyAndDataCard
                    case .diagnosticsAndAbout:
                        probeAuditLogsCard
                        openSourceAboutCard
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("设置")
        .onAppear {
            portInput = String(engine.config.proxySettings.port)
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        }
        .confirmationDialog(
            "将永久删除本机调用历史、会话粘性和本地指标，且无法撤销。供应商配置与 Keychain 密钥保留。继续？",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空历史与指标", role: .destructive) {
                do {
                    try engine.clearCallHistory()
                    feedbackMessage = "已清空本机调用历史、会话粘性缓存与本地指标。"
                } catch {
                    feedbackMessage = "清空失败，历史仍保留：\(error.localizedDescription)"
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var localTokenBlockingBanner: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                    Text("本地凭据未持久化，代理与 Agent 接入已阻断")
                        .font(.callout.weight(.semibold))
                }
                Text(engine.localAPITokenPersistenceError ?? "本地 API token 未能写入 Keychain。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("在修复 Keychain 访问并成功持久化前，AutoRoute 不会自动启动代理，也不会写入任何 Agent 配置；请勿把当前临时 token 配置到外部客户端。")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("检查并重试保存凭据") {
                    do {
                        try engine.retryPersistingLocalAPIToken()
                        if !engine.proxyState.isRunning {
                            engine.startProxy()
                        }
                        feedbackMessage = engine.proxyState.isRunning
                            ? "本地 API token 已持久化，本地代理已启动。"
                            : "本地 API token 已持久化，现在可以启动代理并接入 Agent。"
                    } catch {
                        feedbackMessage = "仍无法持久化本地凭据：\(error.localizedDescription)"
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(6)
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
                        .disabled(!engine.isLocalAPITokenPersistent)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("本地 API 凭据")
                        .font(.callout.weight(.medium))
                    Text("管理 token 可访问模型和本地管理接口，现有自动配置的 Agent 继续使用它。自定义模型密钥仅可访问模型接口；供应商密钥使用独立 Keychain 条目。不要把密钥提交到 Git 或写入公开日志。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("复制 API token") {
                            copyToPasteboard(engine.localAPIToken)
                            feedbackMessage = "已复制本地 API token，请仅粘贴到受信任的本机客户端。"
                        }
                        .disabled(!engine.isLocalAPITokenPersistent)
                        Button("复制 Base URL") {
                            copyToPasteboard(engine.config.proxySettings.baseURLString)
                            feedbackMessage = "已复制本地 Base URL。"
                        }
                        Button("复制 curl 模板") {
                            let command = "curl $AUTOROUTE_BASE_URL/chat/completions -H \"Authorization: Bearer $AUTOROUTE_API_TOKEN\" -H \"Content-Type: application/json\" -d '{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}]}'"
                            copyToPasteboard(command)
                            feedbackMessage = "已复制不含真实 token 的 curl 模板；请先设置 AUTOROUTE_BASE_URL 与 AUTOROUTE_API_TOKEN。"
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("自定义默认模型密钥")
                        .font(.callout.weight(.medium))
                    Text("可选；供手动接入的 Agent 使用。只允许 4–128 个英文字母、数字及 - . _ ~；较短密钥容易被本机其他程序猜中。清除后使用管理 token。更换或清除后，请更新使用旧密钥的客户端。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        SecureField("输入新模型密钥", text: $modelKeyInput)
                            .textFieldStyle(.roundedBorder)
                        Button(engine.localModelAPIKey == nil ? "保存密钥" : "更换密钥") {
                            do {
                                try engine.setLocalModelAPIKey(modelKeyInput)
                                modelKeyInput = ""
                                modelKeyFeedbackIsError = false
                                modelKeyFeedback = "模型密钥已保存并立即生效。"
                            } catch {
                                modelKeyFeedbackIsError = true
                                modelKeyFeedback = "模型密钥保存失败：\(error.localizedDescription)"
                            }
                        }
                        .disabled(!engine.isLocalAPITokenPersistent || modelKeyInput.isEmpty)
                        Button("复制当前密钥") {
                            guard let key = engine.manualAgentAPIKey else { return }
                            copyToPasteboard(key)
                            modelKeyFeedbackIsError = false
                            modelKeyFeedback = "已复制当前密钥，请仅粘贴到受信任的本机客户端。"
                        }
                        .disabled(engine.manualAgentAPIKey == nil)
                        Button("清除自定义密钥", role: .destructive) {
                            do {
                                try engine.clearLocalModelAPIKey()
                                modelKeyInput = ""
                                modelKeyFeedbackIsError = false
                                modelKeyFeedback = "自定义模型密钥已清除。"
                            } catch {
                                modelKeyFeedbackIsError = true
                                modelKeyFeedback = "模型密钥清除失败：\(error.localizedDescription)"
                            }
                        }
                        .disabled(engine.localModelAPIKey == nil && engine.localModelAPIKeyError == nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if let error = engine.localModelAPIKeyError {
                        HStack {
                            Text(error).foregroundStyle(.red)
                            Button("重试读取") {
                                do {
                                    try engine.reloadLocalModelAPIKey()
                                    modelKeyFeedbackIsError = false
                                    modelKeyFeedback = "已重新读取模型密钥。"
                                } catch {
                                    modelKeyFeedbackIsError = true
                                    modelKeyFeedback = "模型密钥读取失败：\(error.localizedDescription)"
                                }
                            }
                            .disabled(!engine.isLocalAPITokenPersistent)
                        }
                        .font(.caption)
                    } else {
                        Text(engine.localModelAPIKey == nil ? "当前：管理 token（可访问本地管理接口）" : "当前：自定义模型密钥（仅模型接口）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let modelKeyFeedback {
                        Text(modelKeyFeedback)
                            .font(.caption)
                            .foregroundStyle(modelKeyFeedbackIsError ? Color.red : Color.secondary)
                    }
                }

                Toggle("打开 App 时自动启动本地代理", isOn: Binding(
                    get: { engine.config.proxySettings.autoStartProxy },
                    set: { engine.updateAutoStartProxy($0) }
                ))
                .disabled(!engine.isLocalAPITokenPersistent)

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
                                feedbackMessage = "已开启登录时自动启动 AutoRoute。"
                            } else {
                                try SMAppService.mainApp.unregister()
                                launchAtLoginEnabled = false
                                feedbackMessage = "已取消登录时自动启动。"
                            }
                        } catch {
                            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
                            feedbackMessage = "设置开机自启失败（可将 AutoRoute.app 拖入「应用程序」目录后重试）: \(error.localizedDescription)"
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录 macOS 时自动启动 AutoRoute")
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
                    get: { engine.config.privacySettings.enableSystemNotifications },
                    set: { engine.setSystemNotificationsEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("异常与预算预警发送 macOS 系统通知")
                            .font(.callout.weight(.medium))
                        Text("预算达到预警/硬上限、供应商密钥鉴权失败、档位全部冷却或端口冲突时主动提醒（同类事件 15 分钟内防刷屏）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SQLite 历史保留周期")
                            .font(.callout.weight(.medium))
                        Text("当前已持久化 \(engine.totalStoredRecordCount()) 条调用明细（WAL 模式按单条增量追加，首页默认展示最近 500 条）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { engine.config.privacySettings.historyRetentionDays },
                        set: { engine.setHistoryRetentionDays($0) }
                    )) {
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                        Text("365 天").tag(365)
                        Text("永久保留").tag(0)
                    }
                    .frame(width: 120)
                }

                Divider()

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
                        showClearHistoryConfirmation = true
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
                    Text("SQLite 历史库路径 (WAL): \(engine.persistence.historyDBFileURL.path)")
                    Text("调用历史镜像路径: \(engine.persistence.historyFileURL.path)")
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("AutoRoute v\(UpdateCheckService.currentAppVersion()) · 开源 macOS 本地多模型路由器 (MIT License)")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button(isCheckingUpdate ? "检查中…" : "检查更新") {
                        Task {
                            isCheckingUpdate = true
                            updateCheckResult = await UpdateCheckService.checkForUpdates()
                            isCheckingUpdate = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCheckingUpdate)
                }

                if let result = updateCheckResult {
                    switch result {
                    case .upToDate(let current):
                        Text("当前已是最新版本 (v\(current))。")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .updateAvailable(let current, let release):
                        HStack(spacing: 8) {
                            Text("发现新版本 v\(release.version)（当前 v\(current)）")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Button("前往 GitHub Release 下载") {
                                NSWorkspace.shared.open(release.releaseURL)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                    case .noPublishedRelease(let current):
                        Text("当前版本 v\(current)；GitHub 仓库尚未创建正式公开 Release。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .failed(let msg):
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Text("• 开源版无需注册账号、不依赖托管中转服务、不发送遥测数据。")
                Text("• 本机兼容接口：`POST /v1/chat/completions`（OpenAI Chat Completions 普通与流式）、`POST /v1/messages`（Anthropic Messages 原生透传与兼容转换）、`POST /v1/responses`（OpenAI Responses 原生透传与兼容转换）及 `GET /v1/models`。")
                Text("• 思考模型与 Prompt 缓存兼容：自动分离透传 `reasoning_content` / `thinking`，精准解析并计费缓存读写 Token。")
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
            Label("开源说明与版本更新", systemImage: "info.circle")
                .font(.headline)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
