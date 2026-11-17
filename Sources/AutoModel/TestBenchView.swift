import AppKit
import AutoModelCore
import SwiftUI

struct TestBenchView: View {
    @ObservedObject var engine: AutoModelEngine

    @State private var promptText: String = "请用 3 句话总结为什么本地多模型路由器需要区分实测延迟与估算费用。"
    @State private var requestedModelMode: String = "auto"
    @State private var useStreaming: Bool = true
    @State private var includeToolsSample: Bool = false
    @State private var includeVisionSample: Bool = false
        @State private var baselineModelID: UUID?
    @State private var abRepetitions: Int = 3
    @State private var abAgentKind: AgentKind?
    @State private var abQualityMethod: ABQualityAssessmentMethod = .notAssessed
    @State private var latestABReport: ABExperimentReport?
    @State private var isRunningAB: Bool = false
    @State private var showABConfirmation: Bool = false
    @State private var abFeedback: String?

    @State private var isRunning: Bool = false
    @State private var streamedResponseText: String = ""
    @State private var latestRecord: CallRecord?

    var body: some View {
        VStack(spacing: 0) {
            composerSection
            Divider()
            outputAndReceiptSection
        }
        .navigationTitle("测试台")
        .onAppear {
            if baselineModelID == nil {
                baselineModelID = engine.config.models.first?.id
            }
        }
        .confirmationDialog(
            "重复 A/B 将发送 \(abRepetitions * 2) 个真实上游请求，可能产生供应商费用。继续？",
            isPresented: $showABConfirmation,
            titleVisibility: .visible
        ) {
            Button("运行交错 A/B") {
                Task { await runRepeatedAB() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var composerSection: some View {
        let enabledModels = engine.config.models.filter(\.isEnabled)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("快速场景模板:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("简单问答") {
                    promptText = "把下面这句话翻译成英文：今天天气很好。"
                    includeToolsSample = false
                    includeVisionSample = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("代码编写") {
                    promptText = "请用 Swift 编写一个线程安全的 LRU Cache 实现，包含单元测试思路。"
                    includeToolsSample = false
                    includeVisionSample = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("工具调用 (Tools)") {
                    promptText = "查询旧金山当前天气并输出结构化工具参数。"
                    includeToolsSample = true
                    includeVisionSample = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("视觉理解 (Vision)") {
                    promptText = "请描述这张图片里的主要元素。"
                    includeToolsSample = false
                    includeVisionSample = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text("策略: \(engine.config.policy.activeStrategy.displayName) (v\(engine.config.policy.policyVersion))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $promptText)
                .font(.body)
                .frame(minHeight: 78, maxHeight: 110)
                .padding(6)
                .background(Color(.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))

            HStack(spacing: 14) {
                Picker("目标模型", selection: $requestedModelMode) {
                    Text("auto（智能三档路由）").tag("auto")
                    Text("auto/low（低档轻量）").tag("auto/low")
                    Text("auto/medium（中档均衡）").tag("auto/medium")
                    Text("auto/high（高档旗舰）").tag("auto/high")
                    ForEach(enabledModels) { m in
                        Text("固定调用: \(m.displayName)").tag(m.modelID)
                    }
                }
                .frame(width: 245)

                Toggle("流式 SSE", isOn: $useStreaming)
                Toggle("附带 Tools", isOn: $includeToolsSample)
                Toggle("附带 Vision 图片", isOn: $includeVisionSample)

                Spacer()

                Button {
                    Task { await runTestRequest() }
                } label: {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("发送真实请求", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || isRunningAB || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()
            abExperimentControls(enabledModels: enabledModels)
        }
        .padding(16)
    }

    private func abExperimentControls(enabledModels: [ModelConfig]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("固定基线", selection: $baselineModelID) {
                    ForEach(enabledModels) { model in
                        Text(model.displayName).tag(UUID?.some(model.id))
                    }
                }
                .frame(width: 220)

                Stepper("每侧重复 \(abRepetitions) 次", value: $abRepetitions, in: 1...10)
                    .frame(width: 170)

                Picker("质量评估", selection: $abQualityMethod) {
                    Text("未评估").tag(ABQualityAssessmentMethod.notAssessed)
                    Text("人工复核").tag(ABQualityAssessmentMethod.humanReview)
                    Text("确定性精确匹配").tag(ABQualityAssessmentMethod.deterministicExactMatch)
                }
                .frame(width: 190)

                Button {
                    showABConfirmation = true
                } label: {
                    if isRunningAB {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("运行交错 A/B", systemImage: "arrow.triangle.swap")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || isRunningAB || baselineModelID == nil || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 10) {
                Picker("A/B Agent 身份", selection: $abAgentKind) {
                    Text("不指定（仅测试台）").tag(AgentKind?.none)
                    ForEach(AgentKind.allCases) { kind in
                        Text(kind.displayName).tag(AgentKind?.some(kind))
                    }
                }
                .frame(width: 260)
                Text("报告记录 Agent、策略版本与非敏感请求参数；真实请求仍按当前全局策略执行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("每轮交替 auto 与固定基线的先后顺序，并为每次调用使用独立会话。两边除模型与会话标识外参数一致；报告不导出提示词或响应正文。普通单次请求不会隐式调用基线模型。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let abFeedback {
                Text(abFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var outputAndReceiptSection: some View {
        VStack(spacing: 0) {
            if let latestABReport {
                abReportSummary(latestABReport)
                Divider()
            }
            HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("上游响应正文")
                        .font(.headline)
                    Spacer()
                    if let record = latestRecord {
                        StatusPill(status: record.status)
                    }
                }
                .padding([.top, .horizontal], 14)

                ScrollView {
                    if streamedResponseText.isEmpty && latestRecord == nil {
                        ContentUnavailableView {
                            Label("等待发送测试请求", systemImage: "waveform.path.ecg")
                        } description: {
                            Text("测试台与本地 HTTP 代理共用同一路由与上游执行引擎；发送后即可查看实时输出与完整路由收据。")
                        }
                        .padding(.top, 40)
                    } else if let record = latestRecord, record.status != .success {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("调用失败（真实错误透传，未伪造成功）", systemImage: "xmark.octagon.fill")
                                .font(.headline)
                                .foregroundStyle(.red)
                            Text(record.errorMessage ?? "未知错误")
                                .font(.body.monospaced())
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(streamedResponseText)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 420)

            VStack(alignment: .leading, spacing: 0) {
                if let latestRecord {
                    RoutingReceiptView(record: latestRecord)
                } else {
                    ContentUnavailableView {
                        Label("路由收据", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("发送一次请求后，这里会展示候选模型淘汰原因、命中的规则、耗时拆解与估算费用。")
                    }
                }
            }
            .frame(minWidth: 420, idealWidth: 540)
            }
        }
    }

    private func abReportSummary(_ report: ABExperimentReport) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("A/B 报告 · \(report.sampleVersion) · \(report.samples.count) 次调用 · \(report.summary.comparablePricedPairs) 个有价配对")
                    .font(.callout.weight(.semibold))
                Text("实测成本差（基线 − auto）：\(formatOptionalUSD(report.summary.measuredCostDifferenceUSD)) · 本地估算差：\(formatOptionalUSD(report.summary.estimatedCostDifferenceUSD))")
                    .font(.caption.monospacedDigit())
                Text("平均总耗时差（基线 − auto）：\(report.summary.meanLatencyDifferenceMs.map { String(format: "%.1f ms", $0) } ?? "缺失")")
                    .font(.caption.monospacedDigit())
                Text("\(report.summary.costNote) \(report.summary.qualityNote)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("导出脱敏 JSON") { exportABReport() }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06))
    }

    private func runRepeatedAB() async {
        guard let baselineModelID,
              let baseline = engine.config.models.first(where: { $0.id == baselineModelID }) else {
            abFeedback = "请选择一个仍然存在的固定基线模型。"
            return
        }
        isRunningAB = true
        abFeedback = nil
        defer { isRunningAB = false }
        let report = await engine.runABExperiment(
            baselineModel: baseline,
            prompt: promptText,
            repetitions: abRepetitions,
            agentID: abAgentKind,
            qualityAssessmentMethod: abQualityMethod
        )
        latestABReport = report
        abFeedback = "实验完成：auto 成功 \(report.summary.autoSuccessCount)/\(abRepetitions)，基线成功 \(report.summary.baselineSuccessCount)/\(abRepetitions)。样本量较小时请勿外推笼统百分比结论。"
    }

    private func exportABReport() {
        guard let latestABReport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "autoroute-ab-report.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try latestABReport.jsonData().write(to: url, options: .atomic)
            abFeedback = "已导出不含提示词、响应正文和凭据的 A/B 报告到 \(url.lastPathComponent)。"
        } catch {
            abFeedback = "A/B 报告导出失败：\(error.localizedDescription)"
        }
    }

    private func formatOptionalUSD(_ value: Double?) -> String {
        value.map(AutoModelFormatter.formatUSD) ?? "缺失（不按 0 元处理）"
    }

    private func runTestRequest() async {
        isRunning = true
        streamedResponseText = ""
        latestRecord = nil
        defer { isRunning = false }

        var payload: [String: Any] = [
            "model": requestedModelMode,
            "stream": useStreaming
        ]

        if includeVisionSample {
            // Tiny 1x1 transparent PNG data URI for multimodal capability routing & testing
            let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
            payload["messages"] = [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": promptText],
                        ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(tinyPNGBase64)"]]
                    ]
                ]
            ]
        } else {
            payload["messages"] = [
                ["role": "user", "content": promptText]
            ]
        }

        if includeToolsSample {
            payload["tools"] = [
                [
                    "type": "function",
                    "function": [
                        "name": "get_weather",
                        "description": "Get weather for a city",
                        "parameters": [
                            "type": "object",
                            "properties": ["city": ["type": "string"]],
                            "required": ["city"]
                        ]
                    ]
                ]
            ]
        }

        let chunkHandler: (@Sendable (Data) async throws -> Void)? = useStreaming ? { @Sendable chunkData in
            guard let line = String(data: chunkData, encoding: .utf8) else { return }
            for rawLine in line.components(separatedBy: "\n") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { continue }
                let body = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard body != "[DONE]",
                      let jsonData = body.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let content = delta["content"] as? String else {
                    continue
                }
                await MainActor.run {
                    self.streamedResponseText += content
                }
            }
        } : nil

        let outcome = await engine.executeChatCompletion(
            payload: payload,
            source: .testBench,
            onStreamChunk: chunkHandler
        )

        latestRecord = outcome.callRecord
        if !useStreaming && outcome.callRecord.status == .success {
            if let obj = try? JSONSerialization.jsonObject(with: outcome.responseBody) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String {
                streamedResponseText = content
            } else {
                streamedResponseText = outcome.callRecord.responsePreview ?? ""
            }
        }
    }
}
