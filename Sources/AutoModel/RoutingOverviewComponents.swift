import AutoModelCore
import Charts
import SwiftUI

enum ModelChartPalette {
    static func color(for modelID: String) -> Color {
        let id = ModelPresentationIdentity.id(for: modelID)
        let hue: CGFloat
        if id.hasPrefix("gpt-") || id.hasPrefix("o3") || id.hasPrefix("o4") { hue = 0.60 }
        else if id.hasPrefix("claude-") { hue = 0.07 }
        else if id.hasPrefix("deepseek-") { hue = 0.50 }
        else if id.hasPrefix("glm-") { hue = 0.76 }
        else if id.hasPrefix("gemini-") { hue = 0.35 }
        else if id.hasPrefix("qwen") { hue = 0.91 }
        else if id.hasPrefix("kimi-") { hue = 0.14 }
        else {
            let hash = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
            hue = [0.15, 0.29, 0.45, 0.67, 0.84][hash % 5]
        }
        let shade: CGFloat
        if id.contains("astra") || id.contains("opus") { shade = -0.10 }
        else if id.contains("terra") || id.contains("sonnet") { shade = 0.05 }
        else if id.contains("luna") || id.contains("haiku") { shade = 0.14 }
        else { shade = 0 }
        let revision: CGFloat
        if id.contains("-6.2-") || id.contains("-5.2") { revision = -0.04 }
        else if id.contains("-6.1-") || id.contains("-5.1") { revision = 0.03 }
        else if id.contains("-6-") { revision = 0.07 }
        else { revision = 0 }
        return Color(NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(calibratedHue: hue, saturation: dark ? 0.67 : 0.78,
                           brightness: min(0.98, (dark ? 0.83 : 0.63) + shade + revision), alpha: 1)
        })
    }

    static func symbol(for modelID: String) -> String {
        let id = ModelPresentationIdentity.id(for: modelID)
        if id.hasPrefix("gpt-") { return "sparkles" }
        if id.hasPrefix("claude-") { return "sun.max.fill" }
        if id.hasPrefix("deepseek-") { return "wave.3.right" }
        if id.hasPrefix("glm-") { return "hexagon.fill" }
        if id.hasPrefix("gemini-") { return "diamond.fill" }
        if id.hasPrefix("qwen") { return "circle.hexagongrid.fill" }
        if id.hasPrefix("kimi-") { return "moon.fill" }
        return "cpu"
    }
}

struct ModelFamilyIcon: View {
    let modelID: String

    var body: some View {
        Image(systemName: ModelChartPalette.symbol(for: modelID))
            .foregroundStyle(ModelChartPalette.color(for: modelID))
            .accessibilityHidden(true)
    }
}

struct LiveRoutingBannerView: View {
    @ObservedObject var engine: AutoModelEngine

    var body: some View {
        let state = engine.liveRoutingState
        HStack(spacing: 10) {
            if state.inFlightCount > 0 {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("路由目标")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(state.targetModelDisplayName ?? "路由中…")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(state.targetModelDisplayName ?? "路由中…")
                    .accessibilityLabel("最近开始请求的初始路由目标：\(state.targetModelDisplayName ?? "路由中")；并发请求或重试可能使用其他模型")

                Spacer(minLength: 0)

                Text("\(state.inFlightCount) 个进行中")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                Circle()
                    .fill(engine.proxyState.isRunning ? Color.green.opacity(0.7) : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(engine.proxyState.isRunning ? "本地网关就绪 · 等待 Agent 请求" : "本地网关未启动")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .help(state.inFlightCount > 0 ? "显示最近开始请求的初始路由目标；并发请求或上游重试可能使用其他模型。" : "")
    }
}

struct StrategyTierStripView: View {
    @ObservedObject var engine: AutoModelEngine
    var compact = false
    var overview = false
    @State private var activePopoverTier: ModelTier?

    var body: some View {
        let groups = engine.autoModelGroups(connectedOnly: true)
        let groupCountByCanonical = Dictionary(
            uniqueKeysWithValues: groups.map { ($0.canonicalID, $0.connectedChannels.count) }
        )
        let modelsByID = Dictionary(uniqueKeysWithValues: engine.config.models.map { ($0.id, $0) })
        let providersByID = Dictionary(uniqueKeysWithValues: engine.config.providers.map { ($0.id, $0) })

        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            ForEach(ModelTier.allCases) { tier in
                let assignment = TierModelAssignment(
                    primaryModelID: engine.config.policy.modelID(for: tier),
                    backupModelIDs: engine.config.policy.backupModelIDs(for: tier)
                )
                let primaryModel = assignment.primaryModelID.flatMap { modelsByID[$0] }
                let primaryProvider = primaryModel.flatMap { providersByID[$0.providerID] }
                let channelCount: Int = {
                    guard let m = primaryModel, engine.config.policy.enableAutoSameModelGrouping else { return 0 }
                    return groupCountByCanonical[CanonicalModelNormalizer.canonicalID(for: m)] ?? 0
                }()
                let backupNames = assignment.backupModelIDs.compactMap { modelsByID[$0]?.displayName }

                Button {
                    activePopoverTier = tier
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if overview {
                            HStack(spacing: 6) {
                                Text(tier.shortName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                Text(primaryModel?.displayName ?? "未配置模型")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(primaryModel != nil ? .primary : .secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Image(systemName: "slider.horizontal.3")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(tier.shortName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                if channelCount > 1 {
                                    Text("\(channelCount)通道")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.blue.opacity(0.12), in: Capsule())
                                }
                                Spacer()
                                Image(systemName: "slider.horizontal.3")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            HStack(spacing: 5) {
                                if let primaryModel {
                                    ModelFamilyIcon(modelID: ModelPresentationIdentity.id(for: primaryModel))
                                        .font(.caption2)
                                }
                                Text(primaryModel?.displayName ?? "未配置模型")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(primaryModel != nil ? .primary : .secondary)
                                    .lineLimit(1)
                                if let providerName = primaryProvider?.name {
                                    Text("· \(providerName)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            if backupNames.isEmpty {
                                Text("备用：自动同组/同档回退")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            } else {
                                Text("备用：\(backupNames.joined(separator: " → "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: overview ? 36 : nil, alignment: .leading)
                    .padding(overview ? 8 : 10)
                    .background(Color(.controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("\(tier.shortName)主模型：\(primaryModel?.displayName ?? "未配置模型")；点击编辑")
                .accessibilityLabel("\(tier.shortName)主模型：\(primaryModel?.displayName ?? "未配置模型")，点击编辑")
                .popover(
                    isPresented: Binding(
                        get: { activePopoverTier == tier },
                        set: { if !$0 { activePopoverTier = nil } }
                    ),
                    arrowEdge: .bottom
                ) {
                    TierAssignmentPopover(engine: engine, tier: tier)
                }
            }
        }
    }
}

struct TodayOverviewChartsView: View {
    @ObservedObject var engine: AutoModelEngine
    var compact = false

    var body: some View {
        let impact = engine.routingImpactSummary(todayOnly: true)
        let hourly = engine.todayHourlyTokenBuckets()
        let breakdown = engine.todayModelTokenBreakdown()

        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            // 1. Today vs Flagship Baseline
            todayImpactCard(impact: impact)
                .frame(maxWidth: .infinity)

            // 2. Today Hourly Token Bar Chart
            todayHourlyChartCard(buckets: hourly)
                .frame(maxWidth: .infinity)

            // 3. Today Per-Model Token Breakdown
            todayModelBreakdownCard(items: breakdown)
                .frame(maxWidth: .infinity)
        }
    }

    private func todayImpactCard(impact: RoutingImpactSummary?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日估算对比").font(.caption.weight(.semibold))
            if let impact {
                Text("基准：\(impact.baselineModelDisplayName)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if impact.evaluatedTurnCount > 0 {
                    Text(impact.costSavedUSD == 0 ? "估算费用相同" : "\(impact.costSavedUSD > 0 ? "估算节省" : "估算多支出") \(AutoModelFormatter.formatUSD(abs(impact.costSavedUSD)))")
                        .font(.caption.weight(.semibold))
                    Text("费用可对比 \(impact.evaluatedTurnCount) 条")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("缺少用量或单价").font(.caption).foregroundStyle(.secondary)
                }
                Text(impact.speedSampleCount > 0 ? impact.speedBasisLabel : "缺少基准耗时样本")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("暂无可对比的真实记录").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
        .background(Color(.controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func todayHourlyChartCard(buckets: [HourlyTokenBucket]) -> some View {
        let totalToday = buckets.reduce(0) { $0 + $1.totalTokens }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("今日时段 Token")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatCompactTokens(totalToday))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }

            if totalToday == 0 {
                Spacer()
                Text("今日暂无 Token 消耗")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("时段", bucket.hour),
                        y: .value("Tokens", bucket.totalTokens)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.8))
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisValueLabel {
                            if let h = value.as(Int.self) {
                                Text(String(format: "%02d", h))
                                    .font(.system(size: 9).monospacedDigit())
                            }
                        }
                    }
                }
                .chartYAxis(.hidden)
            }
        }
        .padding(10)
        .frame(height: 122)
        .background(Color(.controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func todayModelBreakdownCard(items: [ModelTokenBreakdownItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("今日各模型分布")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count) 个模型")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if items.isEmpty {
                Spacer()
                Text("暂无模型消耗数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(items) { item in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(ModelChartPalette.color(for: item.modelID))
                                .frame(width: max(4, (geo.size.width - CGFloat(max(0, items.count - 1) * 2)) * CGFloat(item.sharePercent / 100.0)))
                        }
                    }
                }
                .frame(height: 10)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items.prefix(3)) { item in
                        HStack(spacing: 6) {
                            ModelFamilyIcon(modelID: item.modelID)
                                .font(.system(size: 9))
                            Text(item.modelLabel)
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer()
                            Text("\(formatCompactTokens(item.totalTokens)) · \(Int(item.sharePercent.rounded()))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(height: 122)
        .background(Color(.controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func formatCompactTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }
}

struct SessionTaskDetailView: View {
    @ObservedObject var engine: AutoModelEngine
    let agentName: String
    let title: String
    let recordsChronological: [CallRecord]
    let switchCount: Int
    let totalDurationMs: Double
    let totalTokens: Int
    let totalCostUSD: Double?
    let onSelectTurn: (CallRecord) -> Void

    private struct TurnBarPoint: Identifiable {
        let id: UUID
        let turnNumber: Int
        let tokens: Int
        let modelID: String
    }

    var body: some View {
        let sessionImpact = engine.sessionImpactSummary(for: recordsChronological)
        let turnPoints: [TurnBarPoint] = recordsChronological.enumerated().map { idx, rec in
            TurnBarPoint(
                id: rec.id,
                turnNumber: idx + 1,
                tokens: max(0, rec.finalUsage?.totalTokens ?? 0),
                modelID: ModelPresentationIdentity.id(for: rec, models: engine.config.models)
            )
        }
        let modelBreakdown = ModelTokenBreakdownItem.summarize(recordsChronological, models: engine.config.models)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Title & baseline savings summary
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)

                    if let impact = sessionImpact {
                        VStack(alignment: .leading, spacing: 4) {
                            if impact.evaluatedTurnCount > 0 {
                                let costDescription = impact.costSavedUSD == 0
                                    ? "费用相同"
                                    : "\(impact.costSavedUSD > 0 ? "节省" : "多支出") \(AutoModelFormatter.formatUSD(abs(impact.costSavedUSD)))"
                                Label("对比 \(impact.baselineModelDisplayName) \(costDescription)", systemImage: "dollarsign.circle.fill")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(impact.costSavedUSD > 0 ? Color.green : (impact.costSavedUSD < 0 ? Color.orange : Color.secondary))
                            } else {
                                Text("暂无可比费用")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let baselineTotal = impact.baselineTotalLatencyMs,
                               impact.speedSampleCount > 0, impact.speedComparedTurnCount > 0 {
                                let sec = (baselineTotal - impact.actualTotalLatencyMs) / 1000
                                Label(
                                    sec == 0 ? "耗时相同" : String(format: "%@ %.1f 秒", sec > 0 ? "节省" : "增加", abs(sec)),
                                    systemImage: "bolt.circle.fill"
                                )
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(sec < 0 ? Color.orange : Color.blue)
                            }
                        }
                    } else {
                        Text("暂无可比费用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 4 Core Stat Cards
                HStack(spacing: 8) {
                    statCard(title: "识别 Agent", value: agentName)
                    statCard(title: "总共耗时", value: AutoModelFormatter.formatMs(totalDurationMs))
                    statCard(title: "模型切换", value: "\(switchCount) 次")
                    statCard(
                        title: "费用 / Token",
                        value: "\(totalCostUSD.map { AutoModelFormatter.formatUSD($0) } ?? "未定价") · \(formatTokens(totalTokens))"
                    )
                }

                // Per-turn Token Bar Chart
                VStack(alignment: .leading, spacing: 8) {
                    Text("逐轮 Token 消耗")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if turnPoints.allSatisfy({ $0.tokens == 0 }) {
                        Text("本会话暂无 Token 统计")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(height: 110)
                            .frame(maxWidth: .infinity)
                    } else {
                        Chart(turnPoints) { point in
                            BarMark(
                                x: .value("轮次", point.turnNumber),
                                y: .value("Tokens", point.tokens)
                            )
                            .foregroundStyle(ModelChartPalette.color(for: point.modelID))
                            .cornerRadius(3)
                        }
                        .chartXScale(domain: 0.5...(Double(turnPoints.count) + 0.5))
                        .chartXAxis {
                            AxisMarks(values: routingTurnAxisValues(turnPoints.count)) { value in
                                AxisGridLine()
                                AxisValueLabel(anchor: turnPoints.count == 1 ? .top : (value.as(Int.self) == 1 ? .topLeading : (value.as(Int.self) == turnPoints.count ? .topTrailing : .top))) {
                                    if let turn = value.as(Int.self) {
                                        Text("T\(turn)")
                                            .font(.caption2.monospacedDigit())
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                            }
                        }
                        .frame(height: 130)
                    }
                }
                .padding(12)
                .background(Color(.controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))

                // Per-model breakdown bar
                if !modelBreakdown.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本会话各模型 Token 占比")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        GeometryReader { geo in
                            HStack(spacing: 2) {
                                ForEach(modelBreakdown) { item in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(ModelChartPalette.color(for: item.modelID))
                                        .frame(width: max(4, (geo.size.width - CGFloat(max(0, modelBreakdown.count - 1) * 2)) * CGFloat(item.sharePercent / 100.0)))
                                }
                            }
                        }
                        .frame(height: 10)

                        ForEach(modelBreakdown) { item in
                            HStack {
                                ModelFamilyIcon(modelID: item.modelID)
                                    .font(.caption2)
                                Text(item.modelLabel)
                                    .font(.caption)
                                Spacer()
                                Text("\(formatTokens(item.totalTokens)) (\(Int(item.sharePercent.rounded()))%)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                }

                // Turn list
                VStack(alignment: .leading, spacing: 6) {
                    Text("会话轮次明细 (\(recordsChronological.count) 轮)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(recordsChronological.enumerated()), id: \.element.id) { idx, record in
                        Button {
                            onSelectTurn(record)
                        } label: {
                            HStack(spacing: 8) {
                                Text("T\(idx + 1)")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, alignment: .leading)
                                Circle()
                                    .fill(record.status == .success ? Color.green : Color.red)
                                    .frame(width: 6, height: 6)
                                Text(record.executedModelShortLabel)
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Text(AutoModelFormatter.formatMs(record.totalCompletionMs))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if let tokens = record.finalUsage?.totalTokens {
                                    Text("\(formatTokens(tokens)) tok")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color(.controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color(.controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }
}

// Keep first and last turns visible while limiting labels in long sessions.
func routingTurnAxisValues(_ count: Int) -> [Int] {
    guard count > 0 else { return [] }
    let labelCount = min(count, 6)
    guard labelCount > 1 else { return [1] }
    return (0..<labelCount).map { index in
        1 + Int((Double(index) * Double(count - 1) / Double(labelCount - 1)).rounded())
    }
}
