import AppKit
import AutoModelCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var engine: AutoModelEngine
    var onNavigate: (SidebarTab) -> Void
    var onOpenTestBench: () -> Void = {}

    @State private var statusBanner: String?
    @State private var isTestingLocalMock = false
    @State private var isValidating = false
    @State private var showValidationConfirmation = false
    @State private var validationResult: OnboardingValidationResult?
    @State private var selectedAgent: AgentKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroSection
                if !engine.isLocalAPITokenPersistent {
                    credentialBlockingSection
                }
                checklistSection
                discoverySection
                policyAndAgentSection
                validationSection
                clientIntegrationSection
            }
            .padding(24)
        }
        .navigationTitle("首次使用引导")
        .onAppear {
            engine.recordOnboardingStarted()
            engine.refreshAgentStatuses()
            selectedAgent = selectedAgent ?? engine.agentStatuses.first(where: \.isInstalled)?.kind
        }
        .confirmationDialog(
            "将通过 127.0.0.1 本地 HTTP 代理调用实际上游，可能产生供应商费用。继续？",
            isPresented: $showValidationConfirmation,
            titleVisibility: .visible
        ) {
            Button("发送真实验收请求") {
                Task { await validate() }
            }
            Button("取消", role: .cancel) {}
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
                        statusBanner = "本地 API token 已持久化，可以继续验收和接入 Agent。"
                    } catch {
                        statusBanner = "仍无法持久化本地凭据：\(error.localizedDescription)"
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(6)
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("欢迎使用 AutoRoute")
                        .font(.title.bold())
                    Text("本机多模型路由 API 代理 · 仅监听 127.0.0.1 · 请求正文默认不记录 · 密钥仅存 macOS Keychain")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let statusBanner {
                Text(statusBanner)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var checklistSection: some View {
        let healthyModels = engine.config.models.filter {
            $0.isEnabled && !$0.isAutoEvicted && $0.availabilityStatus == .available
        }
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                StepRow(number: 1, title: "主动发现或手动添加供应商", subtitle: "发现会读取本机 Agent 配置并向上游发送轻量测活请求", done: !engine.config.providers.isEmpty, actionTitle: "手动配置") {
                    onNavigate(.modelsAndPolicy)
                }
                StepRow(number: 2, title: "确认健康模型与低/中/高档", subtitle: "当前 \(healthyModels.count) 个健康模型；可返回修改，不会清空已有选择", done: !healthyModels.isEmpty, actionTitle: "修改档位") {
                    onNavigate(.modelsAndPolicy)
                }
                StepRow(number: 3, title: "选择省钱、均衡或质量策略", subtitle: "当前：\(engine.config.policy.activeStrategy.displayName)", done: true, actionTitle: "高级策略") {
                    onNavigate(.modelsAndPolicy)
                }
                StepRow(number: 4, title: "备份并接入 Agent（可选）", subtitle: "未安装 Agent 时可复制下方 Base URL、token 和 curl 手动接入", done: engine.agentStatuses.contains(where: \.isConnectedToAutoModel), actionTitle: "高级接入") {
                    onNavigate(.agents)
                }
                StepRow(number: 5, title: "通过真实 HTTP socket 验收", subtitle: validationResult == nil ? "携带本地 token 请求 127.0.0.1，并展示真实路由收据" : (validationResult?.isDemo == true ? "演示链路已验证，不计为真实路由成功" : "真实外部代理请求已成功"), done: validationResult != nil, actionTitle: "高级测试台") {
                    onOpenTestBench()
                }
            }
            .padding(6)
        } label: {
            Label("首次成功链路", systemImage: "checklist")
                .font(.headline)
        }
    }

    private var discoverySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("点击后才会扫描 ~/.codex、~/.config/opencode、~/.hermes、~/.claude 等本机配置和已知本地 OpenAI 端口；随后向候选上游发送轻量测活请求，并剔除不可用模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        Task {
                            let summary = await engine.discoverAndProbeLocalModels()
                            statusBanner = "发现与测活完成：新增 \(summary.discoveredProvidersCount) 个供应商、\(summary.discoveredModelsCount) 个模型；\(summary.healthyModelsCount) 个实测可用，剔除 \(summary.evictedModelsCount) 个不可用模型。"
                        }
                    } label: {
                        if engine.isDiscoveringAndProbing {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在发现与测活...") }
                        } else {
                            Label("发现本机模型并测活", systemImage: "radar")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isDiscoveringAndProbing)

                    Button("手动添加供应商") { onNavigate(.modelsAndPolicy) }
                        .buttonStyle(.bordered)
                    Button("使用本地模拟上游") { activateLocalMockPreset() }
                        .buttonStyle(.bordered)
                        .disabled(isTestingLocalMock)
                }
                Text("模拟上游只用于演示路由与回退，不产生外部费用，也不会把引导标记为真实完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("1. 发现与测活", systemImage: "bolt.fill")
                .font(.headline)
        }
    }

    private var policyAndAgentSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("路由策略", selection: Binding(
                        get: { engine.config.policy.activeStrategy },
                        set: { engine.setStrategy($0) }
                    )) {
                        ForEach(RoutingStrategyPreset.allCases, id: \.self) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    .pickerStyle(.segmented)
                    Button("修改三档模型") { onNavigate(.modelsAndPolicy) }
                        .buttonStyle(.bordered)
                }

                ForEach(ModelTier.allCases) { tier in
                    Text("\(tier.displayName)：\(engine.model(for: tier)?.displayName ?? "未分配，请前往供应商页面处理") · \(engine.model(for: tier)?.modelID ?? "—")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Divider()
                if engine.agentStatuses.contains(where: \.isInstalled) {
                    Picker("要接入的 Agent", selection: $selectedAgent) {
                        ForEach(engine.agentStatuses.filter(\.isInstalled)) { status in
                            Text(status.kind.displayName).tag(AgentKind?.some(status.kind))
                        }
                    }
                    Button("备份原配置并接入所选 Agent") {
                        guard let selectedAgent else { return }
                        do {
                            let status = try engine.applyAgentIntegration(kind: selectedAgent)
                            statusBanner = "已备份并接入 \(selectedAgent.displayName)，使用稳定模型身份 \(status.kind.stableAlias)。"
                        } catch {
                            statusBanner = "接入失败：\(error.localizedDescription)。可到「Agent 接入」预览变更或恢复备份。"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("未检测到受支持 Agent。可跳过此步，使用下方手动客户端配置。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        } label: {
            Label("2–4. 档位、策略与 Agent", systemImage: "slider.horizontal.3")
                .font(.headline)
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
            Label("5. 真实验收与路由收据", systemImage: "doc.text.magnifyingglass")
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

private extension AgentKind {
    var stableAlias: String { "auto/agent/\(rawValue)" }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let subtitle: String
    let done: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
