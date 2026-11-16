import AppKit
import AutoModelCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var engine: AutoModelEngine
    var onNavigate: (SidebarTab) -> Void
    var onOpenTestBench: () -> Void = {}

    @State private var statusBanner: String?
    @State private var isTestingLocalMock = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroSection
                checklistSection
                quickSetupSection
                clientIntegrationSection
            }
            .padding(24)
        }
        .navigationTitle("首次使用引导")
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("欢迎使用 Auto Model")
                        .font(.title.bold())
                    Text("本机多模型路由 API 代理 · 仅监听 127.0.0.1 · 开源版无需账号，密钥仅存 macOS Keychain")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let statusBanner {
                Text(statusBanner)
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var checklistSection: some View {
        let hasProvider = !engine.config.providers.isEmpty
        let hasTwoModels = engine.config.models.filter(\.isEnabled).count >= 2
        let hasSuccessfulTest = engine.callHistory.contains { $0.source == .testBench && $0.status == .success }
        let hasExternalCall = engine.callHistory.contains { $0.source == .externalProxy }

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                StepRow(
                    number: 1,
                    title: "添加一个 OpenAI 兼容供应商或中转站",
                    subtitle: "填写名称、Base URL 与 API Key（保存在 macOS Keychain）",
                    done: hasProvider,
                    actionTitle: "前往配置"
                ) {
                    onNavigate(.modelsAndPolicy)
                }

                StepRow(
                    number: 2,
                    title: "添加至少两个可用模型",
                    subtitle: "配置模型 ID、输入/输出单价（可选，未填时显示无法计算费用）、能力标签与默认用途",
                    done: hasTwoModels,
                    actionTitle: "管理模型"
                ) {
                    onNavigate(.modelsAndPolicy)
                }

                StepRow(
                    number: 3,
                    title: "在「快速测试台」发送真实请求验证链路",
                    subtitle: "确认供应商连通、流式响应与路由收据解释正常",
                    done: hasSuccessfulTest,
                    actionTitle: "打开测试台"
                ) {
                    onOpenTestBench()
                }

                StepRow(
                    number: 4,
                    title: "在外部 AI 应用接入 127.0.0.1 并使用 model=auto",
                    subtitle: "将其他客户端的 Base URL 设为 \(engine.config.proxySettings.baseURLString)，模型填 auto",
                    done: hasExternalCall,
                    actionTitle: "查看调用记录"
                ) {
                    onNavigate(.history)
                }
            }
            .padding(6)
        } label: {
            Label("4 步上手进度", systemImage: "checklist")
                .font(.headline)
        }
    }

    private var quickSetupSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("快速开始选项")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 12) {
                    Button {
                        Task {
                            let summary = await engine.discoverAndProbeLocalModels()
                            statusBanner = "已自动发掘并实测完成：新增 \(summary.discoveredProvidersCount) 个供应商、\(summary.discoveredModelsCount) 个模型；其中 \(summary.healthyModelsCount) 个实测可用，\(summary.evictedModelsCount) 个不可用模型已自动剔除。"
                        }
                    } label: {
                        if engine.isDiscoveringAndProbing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在发掘与测活...")
                            }
                        } else {
                            Label("一键发掘本机已配置模型并测活剔除", systemImage: "radar")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isDiscoveringAndProbing)

                    Button {
                        onNavigate(.modelsAndPolicy)
                    } label: {
                        Label("手动添加中转站", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        activateLocalMockPreset()
                    } label: {
                        Label("启用本地模拟测试上游", systemImage: "cpu")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTestingLocalMock)
                }

                if let summary = engine.lastDiscoverySummary {
                    Text("最近自动巡检：共实测 \(summary.probedModelsCount) 个模型 · 可用 \(summary.healthyModelsCount) 个 · 自动剔除不可用 \(summary.evictedModelsCount) 个（扫描来源：\(summary.sourcesScanned.joined(separator: "、"))）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("注：「本地模拟测试上游」仅在 127.0.0.1:18765 提供确定性模拟响应，用于在没有外部 API Key 时验证路由规则、流式输出和错误回退；真实生产调用请添加您的模型厂商或中转站。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("快速接入", systemImage: "bolt.fill")
                .font(.headline)
        }
    }

    private var clientIntegrationSection: some View {
        let baseURL = engine.config.proxySettings.baseURLString
        let curlCmd = """
        curl -N \(baseURL)/chat/completions \\
          -H "Content-Type: application/json" \\
          -d '{"model":"auto","stream":true,"messages":[{"role":"user","content":"用三句话解释 Raft 共识算法"}]}'
        """

        let pythonSnippet = """
        from openai import OpenAI

        client = OpenAI(base_url="\(baseURL)", api_key="local-auto-model")
        resp = client.chat.completions.create(
            model="auto",
            messages=[{"role": "user", "content": "写一个 Swift 防抖函数"}],
        )
        print("实际执行模型:", resp.model)
        print(resp.choices[0].message.content)
        """

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("本地代理地址:")
                        .font(.callout.weight(.medium))
                    Text(baseURL)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(baseURL, forType: .string)
                        statusBanner = "已复制本地代理地址 \(baseURL)"
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                    Text(engine.proxyState.statusText)
                        .font(.caption)
                        .foregroundStyle(engine.proxyState.isRunning ? .green : .orange)
                }

                Text("第一版明确支持 OpenAI Chat Completions (`POST /v1/chat/completions`) 的普通与流式响应，以及 `GET /v1/models`。暂未实现 Responses API (`/v1/responses`) 或 Anthropic Messages (`/v1/messages`)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                CodeBlockCard(title: "curl 流式测试示例", code: curlCmd) {
                    statusBanner = "已复制 curl 测试命令"
                }

                CodeBlockCard(title: "Python OpenAI SDK 示例", code: pythonSnippet) {
                    statusBanner = "已复制 Python SDK 示例"
                }
            }
            .padding(6)
        } label: {
            Label("在其他 AI 应用中使用 model=auto", systemImage: "terminal")
                .font(.headline)
        }
    }

    private func activateLocalMockPreset() {
        isTestingLocalMock = true
        defer { isTestingLocalMock = false }
        do {
            try engine.installLocalTestPreset()
            statusBanner = "已启动本地模拟测试上游并添加了 3 个模拟模型，现在可以去「测试台」或使用外部客户端请求 model=auto。"
        } catch {
            statusBanner = "启用模拟上游失败: \(error.localizedDescription)"
        }
    }
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
