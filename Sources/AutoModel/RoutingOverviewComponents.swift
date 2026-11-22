import AutoModelCore
import Charts
import SwiftUI

enum ModelChartPalette {
    private static let hues: [CGFloat] = [0.59, 0.08, 0.34, 0.76, 0.48, 0.94, 0.15, 0.66, 0.01, 0.26]
    private static let preferredSlots = [
        "gpt-6.2-sol": 0,
        "gpt-6-luna": 1,
        "gpt-6.2-astra": 2,
        "gpt-5.6-luna": 3,
    ]

    static func sessionColors(for modelIDs: [String]) -> [String: Color] {
        let reservedSlots = Set(modelIDs.compactMap { preferredSlots[$0] })
        var availableSlots = hues.indices.filter { !reservedSlots.contains($0) }.makeIterator()
        var colors: [String: Color] = [:]
        for modelID in modelIDs where colors[modelID] == nil {
            if let slot = preferredSlots[modelID] ?? availableSlots.next() {
                colors[modelID] = color(hue: hues[slot])
            } else {
                colors[modelID] = color(for: modelID)
            }
        }
        return colors
    }

    static func color(for modelID: String) -> Color {
        let id = ModelPresentationIdentity.id(for: modelID)
        if let slot = preferredSlots[id] {
            return color(hue: hues[slot])
        }
        let hash = id.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return color(hue: CGFloat(Double(hash & 0xFFFF) / 65_536))
    }

    private static func color(hue: CGFloat) -> Color {
        Color(NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(calibratedHue: hue, saturation: dark ? 0.76 : 0.84,
                           brightness: dark ? 0.90 : 0.68, alpha: 1)
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
                Text("正在使用")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(state.targetModelDisplayName ?? "路由中…")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(state.targetModelDisplayName ?? "路由中…")
                    .accessibilityLabel("当前实际尝试的模型：\(state.targetModelDisplayName ?? "路由中")；并发请求或重试可能使用其他模型")

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
    let agentKind: AgentKind?
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
        let turnModelIDs = turnPoints.filter { $0.tokens > 0 }.map(\.modelID)
        let chartModelIDs = Set(turnModelIDs).sorted()
        let chartColors = ModelChartPalette.sessionColors(for: turnModelIDs + modelBreakdown.map(\.modelID))
        let costSaved = sessionImpact.flatMap { $0.evaluatedTurnCount > 0 ? $0.costSavedUSD : nil }
        let timeSaved = sessionImpact.flatMap(\.timeDifferenceSeconds)
        let visibleTurns = min(10, turnPoints.count)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) {
                    Image(systemName: AgentPresentation.symbol(for: agentKind))
                        .foregroundStyle(AgentPresentation.color(for: agentKind))
                    Text(agentName)
                        .font(.caption.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("调用 Agent：\(agentName)")

                // Session title and model path
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("session-task-title")

                    HStack(spacing: 8) {
                        Image(systemName: switchCount > 0 ? "arrow.triangle.swap" : "checkmark.circle")
                        Text(recordsChronological.map { $0.executedModelDisplayName ?? $0.executedModelID ?? $0.requestedModel }.joined(separator: " → "))
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(recordsChronological.contains { $0.status != .success } ? "失败" : "已结束")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(recordsChronological.contains { $0.status != .success } ? .orange : .secondary)
                    }
                    .foregroundStyle(switchCount > 0 ? Color.blue : Color.secondary)

                }

                if let impact = sessionImpact {
                    Text("对比旗舰模型 · \(impact.baselineModelDisplayName)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .help("费用按本轮实际 Token 用量估算。耗时依据可比样本。\(impact.speedBasisLabel)")
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    sessionMetricTile(icon: "number", label: "总 Token", value: formatTokens(totalTokens), tint: .primary)
                    sessionMetricTile(icon: "dollarsign.circle.fill", label: "实际费用", value: totalCostUSD.map(AutoModelFormatter.formatUSD) ?? "未定价", tint: .secondary)
                    sessionMetricTile(
                        icon: "dollarsign.circle",
                        label: costSaved.map { $0 < 0 ? "估算多支出" : "估算省钱" } ?? "估算省钱",
                        value: costSaved.map { AutoModelFormatter.formatUSD(abs($0)) } ?? "—",
                        tint: costSaved.map { $0 < 0 ? Color.orange : Color.green } ?? .secondary
                    )
                    sessionMetricTile(
                        icon: "clock",
                        label: timeSaved.map { $0 < 0 ? "估算多耗时" : "估算省时" } ?? "估算省时",
                        value: timeSaved.map { formatSavedTime(abs($0)) } ?? "—",
                        tint: timeSaved.map { $0 < 0 ? Color.orange : Color.blue } ?? .secondary
                    )
                }

                if let latestRecord = recordsChronological.last, let latestModelID = turnPoints.last?.modelID {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: ModelChartPalette.symbol(for: latestModelID))
                                .foregroundStyle(chartColors[latestModelID] ?? ModelChartPalette.color(for: latestModelID))
                            Text("当前实际模型")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(latestRecord.executedModelDisplayName ?? latestRecord.executedModelID ?? latestRecord.requestedModel)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Label(latestRecord.decision.subtaskCategory?.displayName ?? "通用任务", systemImage: "square.stack.3d.up.fill")
                                .font(.caption)
                            Text(latestRecord.decision.routingReasonNote ?? latestRecord.decision.matchedRules.first ?? "\(latestRecord.decision.strategyName) 策略")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .help("路由原因")
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                }

                // The KPI grid above is the primary session summary; detailed timing and switches remain in the turn list.
                // Per-turn Token Bar Chart
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("逐轮 Token 消耗")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(turnPoints.count > 10 ? "最近 10 轮 · 左右滑动看更早" : "共 \(turnPoints.count) 轮")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if turnPoints.allSatisfy({ $0.tokens == 0 }) {
                        Text("本会话暂无 Token 统计")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(height: 110)
                            .frame(maxWidth: .infinity)
                    } else {
                        Chart(turnPoints) { point in
                            BarMark(
                                x: .value("轮次", Double(point.turnNumber)),
                                y: .value("Tokens", point.tokens)
                            )
                            .foregroundStyle(chartColors[point.modelID] ?? .secondary)
                            .cornerRadius(3)
                            .accessibilityLabel("T\(point.turnNumber) · \(point.modelID)")
                            .accessibilityValue("\(point.tokens.formatted()) Token")
                        }
                        .chartXScale(domain: 0.5...(Double(turnPoints.count) + 0.5))
                        .chartScrollableAxes(.horizontal)
                        .chartXVisibleDomain(length: Double(visibleTurns))
                        .chartScrollPosition(initialX: Double(turnPoints.count - visibleTurns) + 0.5)
                        .chartXAxis {
                            AxisMarks(values: turnPoints.map { Double($0.turnNumber) }) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let turn = value.as(Double.self) {
                                        Text("T\(Int(turn))")
                                            .font(.caption2.monospacedDigit())
                                    }
                                }
                            }
                        }
                        .frame(height: 142)
                    }

                    if chartModelIDs.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(chartModelIDs, id: \.self) { modelID in
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(chartColors[modelID] ?? .secondary)
                                            .frame(width: 7, height: 7)
                                        Text(modelID)
                                            .font(.caption2)
                                            .fixedSize()
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color(.controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))

                if !modelBreakdown.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本会话各模型 Token 占比")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(alignment: .center, spacing: 12) {
                            Chart(modelBreakdown) { item in
                                SectorMark(angle: .value("Token", item.totalTokens))
                                    .foregroundStyle(chartColors[item.modelID] ?? .secondary)
                            }
                            .chartLegend(.hidden)
                            .frame(width: 142, height: 142)
                            .accessibilityLabel("本会话各模型 Token 占比饼图")
                            .accessibilityValue(modelBreakdown.map { "\($0.modelLabel) \(Int($0.sharePercent.rounded()))%" }.joined(separator: "、"))

                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(modelBreakdown) { item in
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 5) {
                                            Circle()
                                                .fill(chartColors[item.modelID] ?? .secondary)
                                                .frame(width: 8, height: 8)
                                            Text(item.modelLabel)
                                                .font(.caption2.weight(.medium))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer(minLength: 2)
                                            Text("\(Int(item.sharePercent.rounded()))%")
                                                .font(.caption2.monospacedDigit().weight(.semibold))
                                        }
                                        Text(formatTokens(item.totalTokens) + " tokens")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .padding(.leading, 13)
                                    }
                                    .help("\(item.modelLabel)：\(formatTokens(item.totalTokens)) Token（\(Int(item.sharePercent.rounded()))%）")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .contain)
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

    private func sessionMetricTile(icon: String, label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .padding(10)
        .background(Color(.controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
    }

    private func formatSavedTime(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f 秒", seconds) }
        if seconds < 3600 { return String(format: "%.1f 分", seconds / 60) }
        return String(format: "%.1f 小时", seconds / 3600)
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
