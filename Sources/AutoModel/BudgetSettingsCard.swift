import AutoModelCore
import SwiftUI

struct BudgetSettingsCard: View {
    @ObservedObject var engine: AutoModelEngine
    @State private var globalLimit = ""
    @State private var warningThreshold = "0.8"
    @State private var selectedAgent: AgentKind = .codex
    @State private var agentLimits: [String: String] = [:]
    @State private var feedback: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                budgetUsageRow(
                    title: "全局本月",
                    usage: engine.monthlyBudgetUsage(),
                    warning: engine.monthlyBudgetWarning()
                )
                HStack {
                    TextField("全局上限 USD（留空不限）", text: $globalLimit)
                        .textFieldStyle(.roundedBorder)
                    TextField("预警阈值 0–1", text: $warningThreshold)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    Button("保存全局预算") { saveGlobal() }
                        .buttonStyle(.borderedProminent)
                    Button("不限") {
                        globalLimit = ""
                        engine.updateGlobalBudget(nil)
                    }
                    .buttonStyle(.bordered)
                }

                Divider()
                Picker("Agent", selection: $selectedAgent) {
                    ForEach(AgentKind.allCases) { kind in Text(kind.displayName).tag(kind) }
                }
                .frame(maxWidth: 360)
                budgetUsageRow(
                    title: "\(selectedAgent.displayName) 本月",
                    usage: engine.monthlyBudgetUsage(agentID: selectedAgent.rawValue),
                    warning: engine.monthlyBudgetWarning(agentID: selectedAgent.rawValue)
                )
                HStack {
                    TextField("该 Agent 上限 USD（留空不限）", text: Binding(
                        get: { agentLimits[selectedAgent.rawValue] ?? "" },
                        set: { agentLimits[selectedAgent.rawValue] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button("保存 Agent 预算") { saveAgent() }
                        .buttonStyle(.borderedProminent)
                    Button("不限") {
                        agentLimits[selectedAgent.rawValue] = ""
                        engine.updateAgentBudget(nil, for: selectedAgent)
                    }
                    .buttonStyle(.bordered)
                }

                Picker("Agent 策略覆盖", selection: Binding(
                    get: { engine.config.agentPolicyProfiles[selectedAgent.rawValue]?.strategy },
                    set: { strategy in
                        var profile = engine.config.agentPolicyProfiles[selectedAgent.rawValue]
                            ?? AgentPolicyProfile(kind: selectedAgent)
                        profile.strategy = strategy
                        engine.updateAgentPolicyProfile(profile)
                    }
                )) {
                    Text("继承全局策略").tag(RoutingStrategyPreset?.none)
                    ForEach(RoutingStrategyPreset.allCases, id: \.self) { strategy in
                        Text(strategy.displayName).tag(RoutingStrategyPreset?.some(strategy))
                    }
                }
                .frame(maxWidth: 360)

                if let feedback {
                    Text(feedback).font(.caption).foregroundStyle(.secondary)
                }
                Text("按本机时区自然月计量。实测与本地估算分开累计，未定价调用不会按 0 元计入。达到硬上限的新请求在上游前返回 429 budget_exceeded；在途并发、上游延迟 usage 和价格变化仍可能造成超支，请同时核对供应商账单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("月度预算与 Agent 策略", systemImage: "chart.bar.doc.horizontal")
                .font(.headline)
        }
        .onAppear {
            globalLimit = engine.config.budgetSettings.global.map { String($0.limitUSD) } ?? ""
            warningThreshold = String(engine.config.budgetSettings.warningThreshold)
            for kind in AgentKind.allCases {
                agentLimits[kind.rawValue] = engine.config.budgetSettings.agentLimits[kind.rawValue].map { String($0.limitUSD) } ?? ""
            }
        }
    }

    private func budgetUsageRow(
        title: String,
        usage: MonthlyBudgetUsage,
        warning: MonthlyBudgetWarningState
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(usage.period)")
                .font(.callout.weight(.medium))
            Text("上游实测 \(AutoModelFormatter.formatUSD(usage.measuredCostUSD)) · 本地估算 \(AutoModelFormatter.formatUSD(usage.estimatedCostUSD)) · 未定价 \(usage.unpricedCallCount) 轮 · 已计量 \(AutoModelFormatter.formatUSD(warning.accountedCostUSD))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if warning.level == .warning {
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if warning.level == .hardLimit {
                Label(warning.message, systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func saveGlobal() {
        do {
            let threshold = try parseThreshold(warningThreshold)
            let limit = try parseLimit(globalLimit, threshold: threshold)
            engine.updateBudgetWarningThreshold(threshold)
            engine.updateGlobalBudget(limit)
            feedback = limit == nil ? "已取消全局预算上限。" : "已保存全局月度预算。"
        } catch {
            feedback = error.localizedDescription
        }
    }

    private func saveAgent() {
        do {
            let threshold = try parseThreshold(warningThreshold)
            let limit = try parseLimit(agentLimits[selectedAgent.rawValue] ?? "", threshold: threshold)
            engine.updateBudgetWarningThreshold(threshold)
            engine.updateAgentBudget(limit, for: selectedAgent)
            feedback = limit == nil ? "已取消该 Agent 预算上限。" : "已保存 \(selectedAgent.displayName) 月度预算。"
        } catch {
            feedback = error.localizedDescription
        }
    }

    private func parseThreshold(_ text: String) throws -> Double {
        guard let value = Double(text), (0...1).contains(value) else {
            throw BudgetInputError.invalid("预警阈值必须是 0 到 1 之间的数字。")
        }
        return value
    }

    private func parseLimit(_ text: String, threshold: Double) throws -> MonthlyBudgetLimit? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value >= 0 else {
            throw BudgetInputError.invalid("预算上限必须是大于或等于 0 的 USD 数字，或留空表示不限。")
        }
        return MonthlyBudgetLimit(limitUSD: value, warningThreshold: threshold)
    }
}

private enum BudgetInputError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
