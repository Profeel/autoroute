import AppKit
import AutoModelCore
import SwiftUI

@MainActor
final class AppNavigationState: ObservableObject {
    @Published var requestedTab: SidebarTab?
    @Published var requestedRecordID: UUID?

    func openHistory(recordID: UUID? = nil) {
        requestedTab = .history
        if let recordID {
            requestedRecordID = recordID
        }
    }
}

struct MenuBarPopoverView: View {
    @ObservedObject var engine: AutoModelEngine
    let onOpenMainWindow: (SidebarTab?, UUID?) -> Void
    let onQuit: () -> Void

    @State private var copiedAddress = false

    private var recentRecords: [CallRecord] {
        Array(engine.callHistory.prefix(4))
    }

    private var todayCallsCount: Int {
        let cal = Calendar.current
        return engine.callHistory.filter { cal.isDateInToday($0.timestamp) }.count
    }

    private var todayCostUSD: Double {
        let cal = Calendar.current
        return engine.callHistory
            .filter { cal.isDateInToday($0.timestamp) }
            .compactMap(\.totalCostUSD)
            .reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            impactBannerSection
            Divider()
            strategySection
            tierStripSection
            Divider()
            recentCallsSection
            Divider()
            footerSection
        }
        .padding(14)
        .frame(width: 360)
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(engine.proxyState.isRunning ? Color.green : Color.orange)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Auto Model")
                        .font(.headline)
                    Text(engine.proxyState.isRunning ? "运行中" : "已停止")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background((engine.proxyState.isRunning ? Color.green : Color.orange).opacity(0.15))
                        .foregroundStyle(engine.proxyState.isRunning ? Color.green : Color.orange)
                        .clipShape(Capsule())
                }
                Text("\(engine.config.proxySettings.baseURLString) · 今日 \(todayCallsCount) 次 · \(AutoModelFormatter.formatUSD(todayCostUSD))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(engine.config.proxySettings.baseURLString, forType: .string)
                copiedAddress = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    copiedAddress = false
                }
            } label: {
                Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("复制本地代理 Base URL")

            Button(engine.proxyState.isRunning ? "停止" : "启动") {
                if engine.proxyState.isRunning {
                    engine.stopProxy()
                } else {
                    engine.startProxy()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var impactBannerSection: some View {
        if let impact = engine.routingImpactSummary(todayOnly: false) {
            let costSavedPositive = impact.costSavedUSD >= 0
            let costPctText: String = {
                if let pct = impact.costSavingsPercent {
                    return String(format: "%@%.1f%%", pct >= 0 ? "-" : "+", abs(pct))
                }
                return "—"
            }()
            let speedPctText: String = {
                if let pct = impact.speedGainPercent {
                    return String(format: "%@%.1f%%", pct >= 0 ? "+" : "-", abs(pct))
                }
                return "—"
            }()
            let speedSubText: String = {
                if let savedMs = impact.speedSavedMsPerTurn {
                    let sec = abs(savedMs) / 1000.0
                    return savedMs >= 0
                        ? String(format: "均快 %.1fs/轮", sec)
                        : String(format: "均慢 %.1fs/轮", sec)
                }
                return impact.speedBasisLabel
            }()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(costSavedPositive ? "较传统方案省费" : "较基准多花")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(costPctText)
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(costSavedPositive ? Color.green : Color.orange)
                        }
                        Text("\(costSavedPositive ? "已省" : "多花") \(AutoModelFormatter.formatUSD(abs(impact.costSavedUSD)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((costSavedPositive ? Color.green : Color.orange).opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("响应速度提升")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(speedPctText)
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Color.blue)
                        }
                        Text(speedSubText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }

                HStack(spacing: 6) {
                    Text("基准: \(impact.baselineModelDisplayName)")
                    Text("·")
                    Text("成功率 \(impact.successRatePercent)%")
                    if let top10 = impact.top10PercentCostSharePercent {
                        Text("·")
                        Text(String(format: "Top10%%难题占%.0f%%花费", top10))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    private var strategySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("路由策略")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(engine.config.policy.activeStrategy.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Picker("路由策略", selection: Binding(
                get: { engine.config.policy.activeStrategy },
                set: { engine.setStrategy($0) }
            )) {
                ForEach(RoutingStrategyPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var tierStripSection: some View {
        let healthyIDs = Set(engine.healthyAvailableModels().map(\.id))
        return HStack(spacing: 8) {
            ForEach(ModelTier.allCases) { tier in
                let assigned = engine.model(for: tier)
                let color: Color = (tier == .low ? .green : (tier == .medium ? .blue : .purple))
                let isHealthy = assigned.map { healthyIDs.contains($0.id) } ?? false

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(tier.shortName)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(color)
                        Spacer()
                        Circle()
                            .fill(assigned == nil ? Color.gray.opacity(0.4) : (isHealthy ? Color.green : Color.orange))
                            .frame(width: 6, height: 6)
                    }
                    Text(assigned?.displayName ?? "未分配")
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var recentCallsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("最近路由动态")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !engine.callHistory.isEmpty {
                    Button("查看全部") {
                        onOpenMainWindow(.history, nil)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
            }

            if recentRecords.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(.secondary)
                    Text("暂无调用记录，接入客户端或使用测试台即可在此实时查看。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 4) {
                    ForEach(recentRecords) { record in
                        Button {
                            onOpenMainWindow(.history, record.id)
                        } label: {
                            recentRecordRow(record)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func recentRecordRow(_ record: CallRecord) -> some View {
        let level = record.routingComplexityLevel
        let badgeColor: Color = {
            switch level {
            case .low: return .green
            case .medium: return .blue
            case .high: return .purple
            case .direct: return .gray
            }
        }()

        return HStack(spacing: 8) {
            Circle()
                .fill(record.status == .success ? Color.green : Color.red)
                .frame(width: 6, height: 6)

            Text(level.shortBadge)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(badgeColor.opacity(0.14))
                .foregroundStyle(badgeColor)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 1) {
                Text(record.executedModelShortLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(record.requestFeatures.detectedTaskType.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(AutoModelFormatter.formatMs(record.totalCompletionMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(record.costStatus == .calculated ? AutoModelFormatter.formatUSD(record.totalCostUSD) : "—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.controlBackgroundColor).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private var footerSection: some View {
        HStack {
            Button {
                onOpenMainWindow(nil, nil)
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Spacer()

            Button("退出") {
                onQuit()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
