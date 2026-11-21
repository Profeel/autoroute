import AutoModelCore
import SwiftUI

struct ConnectionStatusView: View {
    @ObservedObject var engine: AutoModelEngine
    let onNavigate: (SidebarTab) -> Void
    let onOpenReceipt: (UUID) -> Void

    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch engine.proxyReadiness {
                case .running:
                    Label("本地代理运行中", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("停止") { engine.stopProxy() }
                case .stopped:
                    Label("本地代理已停止", systemImage: "pause.circle").foregroundStyle(.orange)
                    Spacer()
                    Button("启动") { engine.startProxy() }
                case .portConflict(let port, let suggested):
                    Label("端口 \(port) 被占用", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    if let suggested {
                        Button("切换 \(suggested)") { engine.updateProxyPort(suggested) }
                    } else {
                        Button("设置端口") { onNavigate(.settings) }
                    }
                case .keychainError:
                    Label("本地凭据未保存", systemImage: "exclamationmark.lock.fill").foregroundStyle(.red)
                    Spacer()
                    Button("重试保存") {
                        do {
                            try engine.retryPersistingLocalAPIToken()
                            engine.startProxy()
                            message = nil
                        } catch { message = error.localizedDescription }
                    }
                case .error:
                    Label("本地代理启动失败", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Spacer()
                    Button("检查设置") { onNavigate(.settings) }
                }
            }
            if case .error(let detail) = engine.proxyReadiness {
                Text(detail).foregroundStyle(.secondary)
            } else if case .keychainError(let detail) = engine.proxyReadiness {
                Text(message ?? detail).foregroundStyle(.secondary)
            }
            HStack {
                switch engine.providerReadiness {
                case .ready: Label("提供商模型已测活", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .needsTesting: Label("提供商模型待测活", systemImage: "clock").foregroundStyle(.orange)
                case .missing: Label("尚无可用提供商模型", systemImage: "circle").foregroundStyle(.orange)
                }
                Spacer()
                if engine.providerReadiness != .ready {
                    Button("管理提供商") { onNavigate(.modelsAndPolicy) }
                }
            }
            HStack {
                if let (status, readiness) = configuredAgent {
                    switch readiness {
                    case .verified(let id):
                        Label("\(status.kind.displayName) 最近成功 \(receiptTime(id))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("收据") { onOpenReceipt(id) }
                    case .waiting:
                        Label("\(status.kind.displayName) 已写入，等待真实请求", systemImage: "clock").foregroundStyle(.secondary)
                        Spacer()
                        Button("Agent") { onNavigate(.agents) }
                    case .notConfigured:
                        agentMissing
                    }
                } else {
                    agentMissing
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { engine.refreshAgentStatuses() }
    }

    private var configuredAgent: (AgentIntegrationStatus, AgentReadiness)? {
        let connected = engine.agentStatuses.filter { $0.isInstalled || $0.hasBackup || $0.isConnectedToAutoModel }
            .map { ($0, engine.agentReadiness(for: $0.kind)) }
            .filter { $0.1 != .notConfigured }
        return connected.first { if case .verified = $0.1 { return true }; return false } ?? connected.first
    }

    private func receiptTime(_ id: UUID) -> String {
        engine.callHistory.first { $0.id == id }?.timestamp.formatted(date: .abbreviated, time: .shortened) ?? ""
    }

    private var agentMissing: some View {
        Group {
            Label("尚未接入 Agent", systemImage: "circle").foregroundStyle(.secondary)
            Spacer()
            Button("接入 Agent") { onNavigate(.agents) }
        }
    }
}

struct ActivitySummaryView: View {
    @ObservedObject var engine: AutoModelEngine
    let onOpenReceipt: (UUID) -> Void

    var body: some View {
        let today = engine.callHistory.filter { $0.executionOrigin == .real && Calendar.current.isDateInToday($0.timestamp) }
        let priced = today.compactMap(\.totalCostUSD)
        let issue = engine.callHistory.filter {
            ($0.executionOrigin == .real && ($0.status != .success || $0.attempts.count > 1))
                || ($0.source == .externalProxy && $0.executionOrigin == nil && $0.status != .success)
        }.max { $0.timestamp < $1.timestamp }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("今日真实调用 \(today.count) 次")
                Spacer()
                Text(priced.isEmpty ? "费用未知" : "已记录费用 \(AutoModelFormatter.formatUSD(priced.reduce(0, +)))")
            }
            Text("基于当前保留的记录\(today.count > priced.count ? "；\(today.count - priced.count) 次缺费用" : "")")
                .foregroundStyle(.secondary)
            if let issue {
                HStack {
                    Text(issue.status == .success ? "最近回退后成功" : "最近代理请求失败")
                    Text(issue.timestamp.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    Spacer()
                    Button("查看收据") { onOpenReceipt(issue.id) }
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SavingsDetailsView: View {
    @ObservedObject var engine: AutoModelEngine

    var body: some View {
        let records = engine.callHistory.filter { $0.executionOrigin == .real }
        let successful = records.filter { $0.status == .success }.count
        let impact = engine.routingImpactSummary()
        return VStack(alignment: .leading, spacing: 5) {
            Text("保留记录的估算对比").font(.caption.weight(.semibold))
            if let oldest = records.map(\.timestamp).min(), let newest = records.map(\.timestamp).max() {
                Text("\(records.count) 条真实记录 · \(oldest.formatted(date: .abbreviated, time: .omitted))–\(newest.formatted(date: .abbreviated, time: .omitted))")
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无可对比的真实记录").foregroundStyle(.secondary)
            }
            if let impact {
                Text("当前基准：\(impact.baselineModelDisplayName)；按当前单价估算，并非供应商账单。")
                    .foregroundStyle(.secondary)
                if impact.evaluatedTurnCount > 0 {
                    Text("费用覆盖 \(impact.evaluatedTurnCount)/\(successful) 条成功请求；\(impact.costSavedUSD >= 0 ? "估算节省" : "估算多支出") \(AutoModelFormatter.formatUSD(abs(impact.costSavedUSD)))。")
                } else {
                    Text("缺少用量或单价，无法估算费用差额。")
                }
                if let baselineTotal = impact.baselineTotalLatencyMs, impact.speedSampleCount > 0 {
                    let delta = (baselineTotal - impact.actualTotalLatencyMs) / 1000
                    Text("耗时覆盖 \(impact.speedComparedTurnCount)/\(successful) 条成功请求；估算\(delta >= 0 ? "节省" : "增加") \(String(format: "%.1f", abs(delta))) 秒；\(impact.speedBasisLabel)。")
                } else {
                    Text("缺少基准耗时样本，无法估算时间差额。")
                }
            } else if !records.isEmpty {
                Text("缺少可用的基准模型。")
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
}
