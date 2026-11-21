import AppKit
import AutoModelCore
import SwiftUI

struct LocalMetricsSettingsCard: View {
    @ObservedObject var engine: AutoModelEngine
    @State private var feedback: String?
    @State private var showClearConfirmation = false

    var body: some View {
        let metrics = engine.localProductMetrics()
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                metricRow(
                    title: "首次真实路由",
                    value: rate(metrics.firstRealRouteSuccessRate) + " · \(metrics.funnel.firstRealSuccessCount)/\(metrics.funnel.startedCount) 次引导",
                    note: "仅统计明确标记为真实外部代理的首次成功；演示验收 \(metrics.funnel.demoValidationCount) 次，单列不转化。"
                )
                metricRow(
                    title: "最近 7 日本机活跃",
                    value: "\(metrics.activeDaysLast7) 天 · 真实路由样本 \(metrics.realRouteSampleCount)",
                    note: metrics.lastRealRouteAt.map { "最近真实路由：\($0.formatted(date: .abbreviated, time: .shortened))；单用户本地活跃不代表项目级留存。" } ?? "尚无来源明确的真实路由。"
                )
                metricRow(
                    title: "路由附加延迟",
                    value: "p50 \(milliseconds(metrics.routingP50Ms)) · p95 \(milliseconds(metrics.routingP95Ms)) · n=\(metrics.routingLatencySampleCount)",
                    note: "从收据的路由判断耗时计算，采用最近秩百分位；不包含上游生成时间。"
                )
                metricRow(
                    title: "跨模型故障恢复",
                    value: rate(metrics.fallbackRecoveryRate) + " · \(metrics.fallbackRecoveredSampleCount)/\(metrics.fallbackEligibleSampleCount)",
                    note: "统计失败后由不同模型成功完成的收据。引擎在 SSE 已开始后不换模型，因此不会把中途重复输出算作恢复。"
                )
                metricRow(
                    title: "成本对照（基线 − auto）",
                    value: "实测 \(usd(metrics.realABMeasuredCostDifferenceUSD))（n=\(metrics.realABPricedSampleCount)） · 历史估算 \(usd(metrics.historicalEstimatedCostDifferenceUSD))（n=\(metrics.historicalPricedSampleCount)）",
                    note: "只汇总有价格的对照；无 usage \(metrics.missingUsageSampleCount) 条、无价格 \(metrics.missingPriceSampleCount) 条，均不按 0 元或确定节省处理。"
                )

                if metrics.demoRouteSampleCount > 0 || metrics.unclassifiedRouteSampleCount > 0 {
                    Text("演示路由 \(metrics.demoRouteSampleCount) 条；旧版/来源无法判别 \(metrics.unclassifiedRouteSampleCount) 条。二者均不混入上述真实路由指标。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("导出聚合 JSON") { exportMetrics() }
                        .buttonStyle(.bordered)
                    Button("清空历史与本地指标", role: .destructive) {
                        showClearConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.callHistory.isEmpty && metrics.funnel.startedCount == 0)
                }
                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("仅在本机从收据与最小引导事件派生，不保存提示词、代码、响应、token 或广告式标识符；不上传、不发起额外网络请求。导出只在你主动点击后发生。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("本地优先产品指标", systemImage: "chart.xyaxis.line")
                .font(.headline)
        }
        .confirmationDialog(
            "将永久删除本机调用历史、会话粘性和本地指标，且无法撤销。供应商配置与 Keychain 密钥保留。继续？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空历史与指标", role: .destructive) {
                do {
                    try engine.clearCallHistory()
                    feedback = "已清空本机调用历史、会话粘性和本地指标。"
                } catch {
                    feedback = "清空失败，历史仍保留：\(error.localizedDescription)"
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func metricRow(title: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium))
            Text(value).font(.caption.monospacedDigit())
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func exportMetrics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "autoroute-local-metrics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try engine.localProductMetricsExport().jsonData().write(to: url, options: .atomic)
            feedback = "已导出匿名聚合指标到 \(url.lastPathComponent)；不包含请求或响应正文。"
        } catch {
            feedback = "导出失败：\(error.localizedDescription)"
        }
    }

    private func rate(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "暂无样本"
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f ms", $0) } ?? "—"
    }

    private func usd(_ value: Double?) -> String {
        value.map(AutoModelFormatter.formatUSD) ?? "缺失"
    }
}
