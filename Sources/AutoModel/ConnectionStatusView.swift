import AppKit
import AutoModelCore
import SwiftUI

struct ConnectionStatusView: View {
    @ObservedObject var engine: AutoModelEngine
    let onNavigate: (SidebarTab) -> Void
    let onOpenReceipt: (UUID) -> Void
    var compact = false

    @State private var message: String?
    @State private var showConnectionDetails = false
    @State private var copiedAddress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if compact {
                proxyStatus
                proxyAddress
                if allConnectionsReady {
                    DisclosureGroup("连接详情", isExpanded: $showConnectionDetails) {
                        VStack(alignment: .leading, spacing: 6) {
                            providerStatus
                            agentStatus
                        }
                        .padding(.top, 6)
                    }
                } else {
                    providerStatus
                    if let (_, readiness) = configuredAgent, case .verified = readiness {
                        DisclosureGroup("连接详情", isExpanded: $showConnectionDetails) {
                            agentStatus.padding(.top, 6)
                        }
                    } else {
                        agentStatus
                    }
                }
            } else if allConnectionsReady {
                DisclosureGroup(isExpanded: $showConnectionDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        proxyStatus
                        providerStatus
                        agentStatus
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 8) {
                        Label("连接正常", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("连接详情").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("连接正常，连接详情")
                }
            } else {
                proxyStatus
                providerStatus
                if let (_, readiness) = configuredAgent, case .verified = readiness {
                    DisclosureGroup("连接详情", isExpanded: $showConnectionDetails) {
                        agentStatus.padding(.top, 6)
                    }
                } else {
                    agentStatus
                }
            }
        }
        .font(.caption)
        .controlSize(compact ? .mini : .small)
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { engine.refreshAgentStatuses() }
    }

    private var allConnectionsReady: Bool {
        guard case .running = engine.proxyReadiness,
              engine.providerReadiness == .ready,
              let (_, readiness) = configuredAgent,
              case .verified = readiness else { return false }
        return true
    }

    private var proxyAddress: some View {
        HStack(spacing: 4) {
            Text(engine.config.proxySettings.baseURLString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(engine.config.proxySettings.baseURLString)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(engine.config.proxySettings.baseURLString, forType: .string)
                copiedAddress = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedAddress = false }
            } label: {
                Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制本地代理地址")
            .accessibilityLabel("复制本地代理地址")
        }
    }

    private var proxyStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                Text(detail).foregroundStyle(.secondary).lineLimit(2).help(detail)
            } else if case .keychainError(let detail) = engine.proxyReadiness {
                Text(message ?? detail).foregroundStyle(.secondary).lineLimit(2).help(message ?? detail)
            }
        }
    }

    private var providerStatus: some View {
        HStack(alignment: .top, spacing: 4) {
            switch engine.providerReadiness {
            case .ready: Label("提供商模型已测活", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .needsTesting: Label("提供商模型待测活", systemImage: "clock").foregroundStyle(.orange)
            case .missing: Label("尚无可用提供商模型", systemImage: "circle").foregroundStyle(.orange)
            }
            Spacer()
            if engine.providerReadiness != .ready {
                Button(compact ? "管理" : "管理提供商") { onNavigate(.modelsAndPolicy) }
            }
        }
    }

    private var agentStatus: some View {
        HStack(alignment: .top, spacing: 4) {
            if let (status, readiness) = configuredAgent {
                switch readiness {
                case .verified(let id):
                    Label("\(status.kind.displayName) 最近成功 \(receiptTime(id))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("收据") { onOpenReceipt(id) }
                        .accessibilityLabel("查看 Agent 最近成功收据")
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
            Button(compact ? "接入" : "接入 Agent") { onNavigate(.agents) }
        }
    }
}

struct ActivitySummaryView: View {
    @ObservedObject var engine: AutoModelEngine
    let onOpenReceipt: (UUID) -> Void
    var compact = false

    var body: some View {
        let today = engine.callHistory.filter { $0.executionOrigin == .real && Calendar.current.isDateInToday($0.timestamp) }
        let priced = today.compactMap(\.totalCostUSD)
        let issue = engine.callHistory.filter {
            ($0.executionOrigin == .real && ($0.status != .success || $0.attempts.count > 1))
                || ($0.source == .externalProxy && $0.executionOrigin == nil && $0.status != .success)
        }.max { $0.timestamp < $1.timestamp }
        let latestProxyRequest = engine.callHistory.filter {
            $0.source == .externalProxy && $0.executionOrigin == .real
        }.max { $0.timestamp < $1.timestamp }
        return VStack(alignment: .leading, spacing: 6) {
            if compact {
                Text("今日真实调用 \(today.count) 次")
                Text(priced.isEmpty ? "费用未知" : "已记录费用 \(AutoModelFormatter.formatUSD(priced.reduce(0, +)))")
            } else {
                HStack {
                    Text("今日真实调用 \(today.count) 次")
                    Spacer()
                    Text(priced.isEmpty ? "费用未知" : "已记录费用 \(AutoModelFormatter.formatUSD(priced.reduce(0, +)))")
                }
            }
            Text("基于当前保留的记录\(today.count > priced.count ? "；\(today.count - priced.count) 次缺费用" : "")")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if compact {
                Divider()
                Text("最近代理请求").font(.caption.weight(.semibold))
                if let latestProxyRequest {
                    HStack(spacing: 4) {
                        Text(latestProxyRequest.status == .success && latestProxyRequest.attempts.count > 1
                             ? "回退后成功" : latestProxyRequest.status.displayName)
                        Spacer(minLength: 0)
                        Button("收据") { onOpenReceipt(latestProxyRequest.id) }
                            .accessibilityLabel("查看最近代理请求收据")
                    }
                    Text(latestProxyRequest.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                    let modelName: String = {
                        if latestProxyRequest.status != .success, let attempt = latestProxyRequest.attempts.last {
                            return engine.config.models.first {
                                $0.modelID == attempt.modelID && (attempt.providerID == nil || $0.providerID == attempt.providerID)
                            }?.displayName ?? attempt.modelID
                        }
                        return latestProxyRequest.executedModelDisplayName ?? latestProxyRequest.executedModelID ?? "未记录"
                    }()
                    Text("模型：\(modelName)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("模型：\(modelName)")
                        .accessibilityLabel("模型：\(modelName)")
                } else {
                    Text("暂无真实代理请求").foregroundStyle(.secondary)
                }
                if let issue, issue.id != latestProxyRequest?.id {
                    Divider()
                    Text(issue.status == .success ? "最近回退后成功" : "最近请求异常")
                    HStack(spacing: 4) {
                        Text(issue.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("收据") { onOpenReceipt(issue.id) }
                            .accessibilityLabel("查看最近请求异常收据")
                    }
                }
            } else if let issue {
                HStack {
                    Text(issue.status == .success ? "最近回退后成功" : "最近代理请求失败")
                    Text(issue.timestamp.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    Spacer()
                    Button("查看收据") { onOpenReceipt(issue.id) }
                }
            }
        }
        .font(.caption)
        .controlSize(compact ? .mini : .small)
        .padding(compact ? 8 : 10)
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
                    let comparison = impact.costSavedUSD == 0
                        ? "估算费用相同"
                        : "\(impact.costSavedUSD > 0 ? "估算节省" : "估算多支出") \(AutoModelFormatter.formatUSD(abs(impact.costSavedUSD)))"
                    Text("费用覆盖 \(impact.evaluatedTurnCount)/\(successful) 条成功请求；\(comparison)。")
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
