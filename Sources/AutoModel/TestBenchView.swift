import AutoModelCore
import SwiftUI

struct TestBenchView: View {
    @ObservedObject var engine: AutoModelEngine

    @State private var promptText: String = "请用 3 句话总结为什么本地多模型路由器需要区分实测延迟与估算费用。"
    @State private var requestedModelMode: String = "auto"
    @State private var useStreaming: Bool = true
    @State private var includeToolsSample: Bool = false
    @State private var includeVisionSample: Bool = false
    @State private var enableABBaseline: Bool = false
    @State private var baselineModelID: UUID?

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

                Toggle("实测对照 (A/B)", isOn: $enableABBaseline)
                    .help("同时向指定基准模型发送同一请求，获取真实的耗时与费用对比")

                if enableABBaseline {
                    Picker("对照模型", selection: $baselineModelID) {
                        ForEach(enabledModels) { m in
                            Text(m.displayName).tag(UUID?.some(m.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }

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
                .disabled(isRunning || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    private var outputAndReceiptSection: some View {
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
            abBaselineModelUUID: enableABBaseline ? baselineModelID : nil,
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
