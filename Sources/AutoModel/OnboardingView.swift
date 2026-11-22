import AppKit
import AutoModelCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var engine: AutoModelEngine
    var onNavigate: (SidebarTab) -> Void
    var onOpenTestBench: () -> Void = {}
    var onOpenReceipt: (UUID) -> Void = { _ in }

    @State private var statusBanner: String?
    @State private var isTestingLocalMock = false
    @State private var isValidating = false
    @State private var showValidationConfirmation = false
    @State private var validationResult: OnboardingValidationResult?
    @State private var selectedAgent: AgentKind?
    @State private var showProviderEditor = false
    @State private var selectedProviderID: UUID?
    @State private var showProbeConfirmation = false

    private var agentStatus: AgentIntegrationStatus? {
        engine.agentStatuses.first { $0.kind == selectedAgent }
    }

    private var agentPickerStatuses: [AgentIntegrationStatus] {
        engine.agentStatuses.filter { $0.isInstalled || $0.isConnectedToAutoModel || $0.kind == .codex }
    }

    private var hasUsableModel: Bool { !engine.healthyAvailableModels().isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("欢迎使用 AutoRoute").font(.title.bold())
                Text("连接提供商、接入一个 Agent，然后从 Agent 发出第一条请求。默认使用均衡策略，模型档位自动分配。")
                    .foregroundStyle(.secondary)
                if let statusBanner {
                    Text(statusBanner).font(.callout).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if !engine.isLocalAPITokenPersistent { credentialBlockingSection }
                providerStep
                if hasUsableModel && engine.proxyReadiness != .running {
                    ConnectionStatusView(engine: engine, onNavigate: onNavigate, onOpenReceipt: onOpenReceipt)
                }
                agentStep
                firstRequestStep
                DisclosureGroup("高级选项：发现、档位、模拟和手动接入") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("本机发现会读取受支持的 Agent 配置，并测活已启用的上游，可能产生费用；新发现的提供商默认关闭，需手动启用。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("发现本机配置") {
                                Task {
                                    _ = await engine.discoverAndProbeLocalModels()
                                    selectedProviderID = engine.config.providers.first(where: \.isEnabled)?.id
                                    statusBanner = "发现完成。新发现的供应商默认关闭，请到管理页启用后检测。"
                                }
                            }.disabled(engine.isDiscoveringAndProbing)
                            Button("修改策略与档位") { onNavigate(.modelsAndPolicy) }
                            Button("使用本地模拟上游") { activateLocalMockPreset() }.disabled(isTestingLocalMock)
                            Button("打开测试台") { onOpenTestBench() }
                        }
                        Text("模拟请求只用于演示，不会验证 Agent 的真实接入。")
                            .font(.caption).foregroundStyle(.secondary)
                        validationSection
                        clientIntegrationSection
                        Button("跳过引导") {
                            engine.skipOnboarding()
                            onNavigate(.history)
                        }
                    }.padding(.top, 8)
                }
            }.padding(24)
        }
        .navigationTitle("首次使用引导")
        .onAppear {
            engine.recordOnboardingStarted()
            engine.refreshAgentStatuses()
            if selectedAgent == nil {
                selectedAgent = AgentReadiness.preferredOnboardingAgent(from: engine.agentStatuses)
            }
            selectedProviderID = selectedProviderID ?? engine.config.providers.first(where: \.isEnabled)?.id
        }
        .sheet(isPresented: $showProviderEditor) {
            ProviderEditorSheet(existingProvider: nil, existingKeyStatus: .missing) { provider, keys, preset, seed in
                do {
                    statusBanner = try applyProviderEditorSave(engine: engine, provider: provider, apiKeys: keys, selectedPreset: preset, seedRecommendedModels: seed)
                    selectedProviderID = provider.id
                } catch { statusBanner = "保存失败：\(error.localizedDescription)" }
            }
        }
        .confirmationDialog("检测会向供应商发送请求，可能产生费用。继续？", isPresented: $showProbeConfirmation, titleVisibility: .visible) {
            Button("检测供应商") {
                if let id = selectedProviderID { Task { await engine.probeProviderModels(providerID: id) } }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("将通过本地 HTTP 代理调用实际上游，可能产生供应商费用。继续？", isPresented: $showValidationConfirmation, titleVisibility: .visible) {
            Button("发送真实验收请求") { Task { await validate() } }
            Button("取消", role: .cancel) {}
        }
    }

    private var providerStep: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("1. 连接一个提供商", systemImage: hasUsableModel ? "checkmark.circle.fill" : "1.circle")
                    .font(.headline)
                switch engine.providerReadiness {
                case .ready: Text("已检测到可用模型。")
                case .needsTesting: Text("已配置模型，尚未完成测活；可继续接入 Agent，或主动检测。")
                case .missing: Text("添加提供商并选择推荐模型，或主动检测以发现模型。")
                }
                HStack {
                    if engine.config.providers.isEmpty {
                        Button("添加提供商") { showProviderEditor = true }.buttonStyle(.borderedProminent)
                    } else {
                        if let id = selectedProviderID, engine.config.providers.contains(where: { $0.id == id && $0.isEnabled }) {
                            if hasUsableModel {
                                Button("检测提供商") { showProbeConfirmation = true }
                                    .buttonStyle(.bordered).disabled(engine.isDiscoveringAndProbing)
                            } else {
                                Button(engine.isDiscoveringAndProbing ? "正在检测…" : "检测提供商") { showProbeConfirmation = true }
                                    .buttonStyle(.borderedProminent).disabled(engine.isDiscoveringAndProbing)
                            }
                        }
                        Button("添加其他提供商") { showProviderEditor = true }.buttonStyle(.bordered)
                        if engine.config.providers.contains(where: \.isEnabled) {
                            Button("管理提供商") { onNavigate(.modelsAndPolicy) }.buttonStyle(.bordered)
                        } else {
                            Button("管理并启用提供商") { onNavigate(.modelsAndPolicy) }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            }.padding(6)
        }
    }

    private var agentStep: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(selectedAgent == .codex ? "2. 接入 Codex" : "2. 预览并接入一个 Agent", systemImage: "2.circle")
                    .font(.headline)
                if !hasUsableModel {
                    Text("连接提供商后可预览 Agent 配置。")
                        .foregroundStyle(.secondary)
                } else if !agentPickerStatuses.isEmpty {
                    Picker("Agent", selection: $selectedAgent) {
                        ForEach(agentPickerStatuses) { status in
                            Text(status.kind == .codex && !status.isInstalled ? "Codex（尚未检测到）" : status.kind.displayName)
                                .tag(AgentKind?.some(status.kind))
                        }
                    }
                    .frame(maxWidth: 300)
                    if let status = agentStatus {
                        if status.kind == .codex && !status.isInstalled && !status.isConnectedToAutoModel {
                            Text("尚未找到 Codex 配置。你可以先预览，确认后会创建 ~/.codex/config.toml。打开 Codex 并发送一条请求，即可验证接入。")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        AgentConnectionCard(engine: engine, status: status, onOpenReceipt: onOpenReceipt)
                    }
                } else {
                    Text("未检测到受支持的 Agent；可继续完成提供商设置，之后再接入 Codex。")
                        .foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }

    private var firstRequestStep: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("3. 从 Agent 发出第一条请求", systemImage: "3.circle").font(.headline)
                if let status = agentStatus {
                    let progress = AgentReadiness.requestProgress(
                        status: status,
                        updatedAt: engine.agentConfigService.configurationUpdatedAt(for: status.kind),
                        records: engine.callHistory
                    )
                    switch progress.readiness {
                    case .notConfigured:
                        Text("先预览并写入 \(status.kind.displayName) 的配置。")
                    case .waiting:
                        Text("配置已写入。重启 \(status.kind.displayName) 并发送一条请求。供应商可能收取费用。")
                    case .verified:
                        Text("已收到该 Agent 的真实成功请求。")
                        Button("完成引导") {
                            engine.setOnboardingCompleted(true)
                            onNavigate(.history)
                        }.buttonStyle(.borderedProminent)
                    }
                    if let id = progress.latestFailureID {
                        Label("最近一次请求失败", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("查看失败收据") { onOpenReceipt(id) }
                            .buttonStyle(.bordered)
                    }
                }
            }.padding(6)
        }
    }

    private var credentialBlockingSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("本地凭据未持久化，暂时无法启动代理或接入 Agent", systemImage: "exclamationmark.lock.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text(engine.localAPITokenPersistenceError ?? "无法确认本地 token 已保存到 Keychain。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("检查并重试保存凭据") {
                    do {
                        try engine.retryPersistingLocalAPIToken()
                        if !engine.proxyState.isRunning {
                            engine.startProxy()
                        }
                        statusBanner = engine.proxyState.isRunning
                            ? "本地 API token 已持久化，本地代理已启动，可以继续验收和接入 Agent。"
                            : "本地 API token 已持久化，可以继续验收和接入 Agent。"
                    } catch {
                        statusBanner = "仍无法持久化本地凭据：\(error.localizedDescription)"
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(6)
        }
    }

    private var validationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("验收通过真实 URLSession → 127.0.0.1 socket → 本地认证与路由器 → 上游执行，不直接调用内部路由方法来代替端到端验证。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button {
                        showValidationConfirmation = true
                    } label: {
                        if isValidating { ProgressView().controlSize(.small) } else { Label("发送真实 HTTP 验收", systemImage: "network") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isValidating)
                    Button("明确跳过引导") {
                        engine.skipOnboarding()
                        statusBanner = "已跳过引导，现有配置未删除。之后可从设置重新打开并完成真实验收。"
                    }
                    .buttonStyle(.bordered)
                }
                if let validationResult {
                    Label(validationResult.isDemo ? "演示链路成功（不计入真实成功或节省）" : "真实外部代理请求成功", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    RoutingReceiptView(record: validationResult.record)
                        .frame(minHeight: 360)
                }
            }
            .padding(6)
        } label: {
            Label("独立 HTTP 验收与路由收据", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
        }
    }

    private var clientIntegrationSection: some View {
        let baseURL = engine.config.proxySettings.baseURLString
        let curlCmd = """
        export AUTOROUTE_API_TOKEN='在设置中复制的本机 token'
        curl -N \(baseURL)/chat/completions \\
          -H "Authorization: Bearer $AUTOROUTE_API_TOKEN" \\
          -H "Content-Type: application/json" \\
          -d '{"model":"auto","stream":true,"messages":[{"role":"user","content":"用三句话解释 Raft 共识算法"}]}'
        """
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(baseURL).font(.callout.monospaced()).textSelection(.enabled)
                    Button("复制 Base URL") { copy(baseURL, message: "已复制 Base URL") }
                    Button("复制 token") { copy(engine.localAPIToken, message: "已复制本地 API token，请勿提交到 Git 或公开日志。") }
                    Spacer()
                    Text(engine.proxyState.statusText).font(.caption).foregroundStyle(engine.proxyState.isRunning ? .green : .orange)
                }
                Text("支持 OpenAI Chat Completions、OpenAI Responses 与 Anthropic Messages 的普通和 SSE 请求。除最小健康检查外均需 token；默认不授予浏览器 CORS。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CodeBlockCard(title: "手动客户端等价路径（curl）", code: curlCmd) {
                    statusBanner = "已复制 curl 命令；请先设置 AUTOROUTE_API_TOKEN 环境变量。"
                }
            }
            .padding(6)
        } label: {
            Label("手动客户端配置", systemImage: "terminal")
                .font(.headline)
        }
    }

    private func validate() async {
        isValidating = true
        defer { isValidating = false }
        do {
            let result = try await engine.validateOnboardingEndToEnd()
            validationResult = result
            statusBanner = result.isDemo
                ? "演示链路已通过真实本地 HTTP socket 验证；它不会被计为真实路由成功。接入真实供应商后可再次验收。"
                : "真实外部代理验收成功，已生成可核对的模型、路由原因、TTFT、用量、费用和回退收据。"
        } catch {
            statusBanner = error.localizedDescription
        }
    }

    private func activateLocalMockPreset() {
        isTestingLocalMock = true
        defer { isTestingLocalMock = false }
        do {
            try engine.installLocalTestPreset()
            statusBanner = "本地模拟上游已启动并配置 3 个演示模型。可继续验证 socket 与收据，但不会标记真实完成。"
        } catch {
            statusBanner = "启用模拟上游失败：\(error.localizedDescription)。请检查本地端口或改用手动供应商。"
        }
    }

    private func copy(_ value: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        statusBanner = message
    }
}

private struct CodeBlockCard: View {
    let title: String
    let code: String
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    onCopy()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Text(code)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
