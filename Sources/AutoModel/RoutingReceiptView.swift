import AutoModelCore
import Charts
import SwiftUI

struct RoutingReceiptView: View {
    let record: CallRecord
    var sessionRecords: [CallRecord] = []
    var sessionImpact: RoutingImpactSummary? = nil
    var onSelectRecord: ((UUID) -> Void)? = nil

    @State private var showSubtaskTable = false
    @State private var showRawAudit = false
    @State private var showPayloads = false
    @State private var hoveredTurn: Int? = nil

    private struct MergedPathSegment: Identifiable {
        let id: String
        let startTurn: Int
        let endTurn: Int
        let records: [CallRecord]
        let shortModel: String
        let complexityLevel: RoutingComplexityLevel
        let subtaskCategory: AgentSubtaskCategory
        let effort: ReasoningEffort
        let subtaskSummary: String
        let reasonNote: String
        let totalDurationMs: Double
        let totalTokens: Int
        let hasFailure: Bool

        var turnRangeLabel: String {
            startTurn == endTurn ? "T\(startTurn)" : "T\(startTurn)–T\(endTurn)"
        }

        var containsRecord: (UUID) -> Bool {
            let ids = Set(records.map(\.id))
            return { ids.contains($0) }
        }
    }

    private struct ModelAggregateStat: Identifiable {
        let id: String
        let shortModel: String
        let turnCount: Int
        let totalDurationMs: Double
        let totalTokens: Int
        let totalCostUSD: Double
        let hasCostData: Bool
        let color: Color
    }

    private var effectiveTimeline: [CallRecord] {
        if sessionRecords.isEmpty {
            return [record]
        }
        return sessionRecords.sorted { $0.timestamp < $1.timestamp }
    }

    private var selectedTurnIndex: Int {
        if let idx = effectiveTimeline.firstIndex(where: { $0.id == record.id }) {
            return idx + 1
        }
        return effectiveTimeline.count
    }

    /// Extract a crisp short model alias (strips provider suffixes like " · PAIYUN", " · Codex", "group/", etc.).
    private func shortModelName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dotRange = s.range(of: " · ") {
            s = String(s[..<dotRange.lowerBound])
        }
        if let slashIdx = s.lastIndex(of: "/") {
            let tail = String(s[s.index(after: slashIdx)...])
            if !tail.isEmpty { s = tail }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var distinctShortModelsInOrder: [String] {
        var seenKeys = Set<String>()
        var ordered: [String] = []
        for item in effectiveTimeline {
            let name = shortModelName(item.executedModelShortLabel)
            let key = name.lowercased()
            if seenKeys.insert(key).inserted {
                ordered.append(key)
            }
        }
        return ordered
    }

    private func colorForModel(_ shortName: String) -> Color {
        let palette: [Color] = [.blue, .purple, .green, .orange, .teal, .pink, .indigo]
        if let idx = distinctShortModelsInOrder.firstIndex(of: shortName.lowercased()) {
            return palette[idx % palette.count]
        }
        return .blue
    }

    private var mergedPathSegments: [MergedPathSegment] {
        let timeline = effectiveTimeline
        var result: [MergedPathSegment] = []
        var currentGroup: [CallRecord] = []
        var groupStart = 1

        func flush(endTurn: Int) {
            guard !currentGroup.isEmpty, let last = currentGroup.last else { return }
            let shortName = shortModelName(last.executedModelShortLabel)
            let totalMs = currentGroup.map(\.totalCompletionMs).reduce(0, +)
            let totalTok = currentGroup.compactMap { $0.finalUsage?.totalTokens }.reduce(0, +)
            let hasFailure = currentGroup.contains { $0.status != .success }
            let focusRecord = currentGroup.first(where: { $0.id == record.id }) ?? last
            result.append(MergedPathSegment(
                id: "\(groupStart)-\(endTurn)-\(shortName.lowercased())",
                startTurn: groupStart,
                endTurn: endTurn,
                records: currentGroup,
                shortModel: shortName,
                complexityLevel: focusRecord.routingComplexityLevel,
                subtaskCategory: focusRecord.effectiveSubtaskCategory,
                effort: focusRecord.effectiveEffort,
                subtaskSummary: focusRecord.conciseSubtaskDescription,
                reasonNote: focusRecord.conciseRoutingReason,
                totalDurationMs: totalMs,
                totalTokens: totalTok,
                hasFailure: hasFailure
            ))
        }

        for (idx, item) in timeline.enumerated() {
            let turn = idx + 1
            let itemShortKey = shortModelName(item.executedModelShortLabel).lowercased()
            if let last = currentGroup.last,
               shortModelName(last.executedModelShortLabel).lowercased() == itemShortKey {
                currentGroup.append(item)
            } else {
                if !currentGroup.isEmpty {
                    flush(endTurn: turn - 1)
                }
                currentGroup = [item]
                groupStart = turn
            }
        }
        if !currentGroup.isEmpty {
            flush(endTurn: timeline.count)
        }
        return result
    }

    private var modelAggregateStats: [ModelAggregateStat] {
        var order: [String] = []
        var displayByKey: [String: String] = [:]
        var counts: [String: Int] = [:]
        var durations: [String: Double] = [:]
        var tokens: [String: Int] = [:]
        var costs: [String: Double] = [:]
        var pricedFlags: [String: Bool] = [:]

        for item in effectiveTimeline {
            let name = shortModelName(item.executedModelShortLabel)
            let key = name.lowercased()
            if counts[key] == nil {
                order.append(key)
                displayByKey[key] = name
            }
            counts[key, default: 0] += 1
            durations[key, default: 0] += item.totalCompletionMs
            tokens[key, default: 0] += (item.finalUsage?.totalTokens ?? 0)
            if let cost = item.totalCostUSD {
                costs[key, default: 0] += cost
                pricedFlags[key] = true
            }
        }

        return order.map { key in
            let display = displayByKey[key] ?? key
            return ModelAggregateStat(
                id: key,
                shortModel: display,
                turnCount: counts[key] ?? 0,
                totalDurationMs: durations[key] ?? 0,
                totalTokens: tokens[key] ?? 0,
                totalCostUSD: costs[key] ?? 0,
                hasCostData: pricedFlags[key] ?? false,
                color: colorForModel(display)
            )
        }
    }

    private var totalSessionTokens: Int {
        effectiveTimeline.compactMap { $0.finalUsage?.totalTokens }.reduce(0, +)
    }

    private var totalSessionDurationMs: Double {
        effectiveTimeline.map(\.totalCompletionMs).reduce(0, +)
    }

    private var totalSessionCostUSD: Double? {
        let costs = effectiveTimeline.compactMap(\.totalCostUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                compactHeaderStrip
                unifiedSessionChartCard
                modelSharePieChartsCard
                rawDetailsDisclosure
            }
            .padding(14)
        }
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - 1. Compact Header & 4 KPIs

    private var compactHeaderStrip: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusPill(status: record.status)

                    Label(record.displayClientAgent, systemImage: agentSymbol(record.displayClientAgent))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())

                    Text(record.hasConversationFingerprint ? "会话 \(record.shortSessionLabel) · \(effectiveTimeline.count) 轮 (T\(selectedTurnIndex))" : "单次调用")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())

                    Spacer()

                    Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let error = record.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    kpiTile(
                        title: "T\(selectedTurnIndex) 模型",
                        value: shortModelName(record.executedModelShortLabel),
                        sub: record.routingComplexityLevel.shortBadge,
                        tint: colorForModel(shortModelName(record.executedModelShortLabel))
                    )
                    Divider().frame(height: 26)
                    kpiTile(
                        title: "本轮耗时",
                        value: AutoModelFormatter.formatMs(record.totalCompletionMs),
                        sub: "TTFT \(AutoModelFormatter.formatMs(record.upstreamFirstTokenMs))"
                    )
                    Divider().frame(height: 26)
                    kpiTile(
                        title: "本轮 Tokens",
                        value: record.finalUsage.map { formatTokens($0.totalTokens) } ?? "—",
                        sub: record.finalUsage.map { "\($0.promptTokens)入 / \($0.completionTokens)出" } ?? "无用量"
                    )
                    Divider().frame(height: 26)
                    kpiTile(
                        title: effectiveTimeline.count > 1 ? "会话累计" : "估算费用",
                        value: (effectiveTimeline.count > 1 ? totalSessionCostUSD : record.totalCostUSD).map { AutoModelFormatter.formatUSD($0) } ?? "—",
                        sub: effectiveTimeline.count > 1 ? "\(formatTokens(totalSessionTokens)) · \(AutoModelFormatter.formatMs(totalSessionDurationMs))" : record.decision.strategyName
                    )
                }

                if let impact = sessionImpact, impact.evaluatedTurnCount > 0 {
                    sessionBaselineComparisonStrip(impact)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private func sessionBaselineComparisonStrip(_ impact: RoutingImpactSummary) -> some View {
        let turnCount = max(1, effectiveTimeline.filter { $0.status == .success }.count)
        let baselineTotalMs = impact.baselineAvgLatencyMs.map { $0 * Double(turnCount) }
        let actualTotalMs = impact.actualAvgLatencyMs * Double(turnCount)
        let savedTotalMs = baselineTotalMs.map { $0 - actualTotalMs }

        let savedCost = impact.costSavedUSD
        let extraRatioPct = impact.actualCostUSD > 0
            ? ((impact.baselineCostUSD - impact.actualCostUSD) / impact.actualCostUSD) * 100.0
            : nil

        return VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.6)
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.right.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(savedCost > 0.00001 ? Color.green : Color.secondary)
                    if savedCost > 0.00001, let savePct = impact.costSavingsPercent {
                        let extraText = extraRatioPct.map { String(format: " · 全用最高级贵 +%.0f%%", $0) } ?? ""
                        Text("对比全用「\(shortModelName(impact.baselineModelDisplayName))」(\(AutoModelFormatter.formatUSD(impact.baselineCostUSD)))：AutoRoute 省 \(AutoModelFormatter.formatUSD(savedCost)) (-\(String(format: "%.1f", savePct))%)\(extraText)")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(Color.green)
                    } else if savedCost < -0.00001 {
                        Text("对比「\(shortModelName(impact.baselineModelDisplayName))」(\(AutoModelFormatter.formatUSD(impact.baselineCostUSD)))：本次多花 \(AutoModelFormatter.formatUSD(-savedCost))")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(Color.orange)
                    } else {
                        Text("本会话与最高级「\(shortModelName(impact.baselineModelDisplayName))」同档执行，费用一致")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)

                Spacer(minLength: 6)

                HStack(spacing: 5) {
                    Image(systemName: "bolt.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.blue)
                    if let savedMs = savedTotalMs, let speedPct = impact.speedGainPercent {
                        if savedMs >= 0 {
                            Text(String(format: "快 %.1fs (+%.1f%%)", savedMs / 1000.0, speedPct))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Color.blue)
                        } else {
                            Text(String(format: "慢 %.1fs (-%.1f%%)", (-savedMs) / 1000.0, abs(speedPct)))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Color.orange)
                        }
                    } else {
                        Text(impact.speedBasisLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
        }
    }

    private func kpiTile(title: String, value: String, sub: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(sub)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 2. Subtask & Effort Routing Table (Expanded on demand)

    private var subtaskEffortTableCard: some View {
        let segments = mergedPathSegments
        return GroupBox {
            VStack(spacing: 0) {
                // Table header
                HStack(spacing: 8) {
                    Text("任务 / 执行简述")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("任务类型 (Anthropic)")
                        .frame(width: 126, alignment: .leading)
                    Text("模型")
                        .frame(width: 118, alignment: .leading)
                    Text("Effort")
                        .frame(width: 68, alignment: .center)
                    Text("备注（原因）")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(.controlBackgroundColor).opacity(0.8))

                Divider()

                ForEach(Array(segments.enumerated()), id: \.element.id) { index, seg in
                    let isSelected = seg.containsRecord(record.id)
                    let segColor = colorForModel(seg.shortModel)
                    Button {
                        if let target = seg.records.last {
                            onSelectRecord?(target.id)
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(seg.turnRangeLabel)
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .foregroundStyle(isSelected ? segColor : .secondary)
                                Text(seg.subtaskSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(seg.subtaskCategory.displayName)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                                .frame(width: 126, alignment: .leading)

                            HStack(spacing: 5) {
                                Circle().fill(segColor).frame(width: 6, height: 6)
                                Text(seg.shortModel)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .frame(width: 118, alignment: .leading)

                            effortPill(seg.effort)
                                .frame(width: 68, alignment: .center)

                            Text(seg.reasonNote)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(isSelected ? segColor.opacity(0.10) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < segments.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            HStack {
                Label("子任务与 Effort 路由明细表", systemImage: "tablecells")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("当前子任务：\(record.effectiveSubtaskCategory.displayName) · effort=\(record.effectiveEffort.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func effortPill(_ effort: ReasoningEffort) -> some View {
        let color: Color = {
            switch effort {
            case .low: return .green
            case .medium: return .blue
            case .high: return .orange
            case .max: return .purple
            }
        }()
        return Text(effort.rawValue)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - 3. Single Unified Chart (Model Bands + Switch Markers + Tokens + Latency + Per-Model Totals)

    private var unifiedSessionChartCard: some View {
        let timeline = effectiveTimeline
        let segments = mergedPathSegments
        let stats = modelAggregateStats

        let maxTokensK = max(1.0, timeline.map { Double($0.finalUsage?.totalTokens ?? 0) / 1000.0 }.max() ?? 1.0)
        let maxLatencySec = max(0.5, timeline.map { $0.totalCompletionMs / 1000.0 }.max() ?? 1.0)
        let activeTurn = hoveredTurn ?? selectedTurnIndex
        let activeItem = (activeTurn >= 1 && activeTurn <= timeline.count) ? timeline[activeTurn - 1] : record

        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                activeTurnReadoutBar(activeItem: activeItem, activeTurn: activeTurn)

                if !segments.isEmpty {
                    stagePathBar(segments: segments, activeTurn: activeTurn)
                }

                if timeline.count >= 2 {
                    sessionTimelineChart(
                        timeline: timeline,
                        segments: segments,
                        maxTokensK: maxTokensK,
                        maxLatencySec: maxLatencySec,
                        activeTurn: activeTurn
                    )
                } else {
                    singleTurnBar
                }

                Divider()

                modelSummaryStrip(stats: stats)
            }
            .padding(4)
        } label: {
            HStack {
                Label("模型切换、Token 与耗时总览图", systemImage: "chart.xyaxis.line")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("悬停或点击图表查看任意轮次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activeTurnReadoutBar(activeItem: CallRecord, activeTurn: Int) -> some View {
        let activeShort = shortModelName(activeItem.executedModelShortLabel)
        let activeColor = colorForModel(activeShort)
        return HStack(spacing: 10) {
            Circle().fill(activeColor).frame(width: 8, height: 8)
            Text("T\(activeTurn)")
                .font(.caption.weight(.bold).monospacedDigit())
            Text(activeShort)
                .font(.caption.weight(.semibold))
                .foregroundStyle(activeColor)
            Text("·")
                .foregroundStyle(.secondary)
            Text("Token \(activeItem.finalUsage.map { formatTokens($0.totalTokens) } ?? "—")")
                .font(.caption.monospacedDigit())
            Text("·")
                .foregroundStyle(.secondary)
            Text("耗时 \(AutoModelFormatter.formatMs(activeItem.totalCompletionMs))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)

            Spacer()

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 12, height: 3)
                    Text("Token (k)")
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.7)).frame(width: 8, height: 8)
                    Text("耗时 (s)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func stagePathBar(segments: [MergedPathSegment], activeTurn: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                    if idx > 0 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    let swColor = colorForModel(seg.shortModel)
                    let isActiveStage = activeTurn >= seg.startTurn && activeTurn <= seg.endTurn
                    Button {
                        if let target = seg.records.first {
                            onSelectRecord?(target.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(swColor).frame(width: 6, height: 6)
                            Text(seg.turnRangeLabel)
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(seg.shortModel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(swColor)
                            effortPill(seg.effort)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(swColor.opacity(isActiveStage ? 0.16 : 0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(swColor.opacity(isActiveStage ? 0.65 : 0.22), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("\(seg.subtaskCategory.displayName)：\(seg.reasonNote)")
                }
            }
        }
    }

    private func sessionTimelineChart(
        timeline: [CallRecord],
        segments: [MergedPathSegment],
        maxTokensK: Double,
        maxLatencySec: Double,
        activeTurn: Int
    ) -> some View {
        let labeledSwitchTurns = nonOverlappingSwitchTurns(segments: segments, totalTurns: timeline.count)
        let indexedTimeline = Array(timeline.enumerated())

        return Chart {
            // 1) Colored model-phase background bands
            ForEach(segments) { seg in
                let bandColor = colorForModel(seg.shortModel)
                RectangleMark(
                    xStart: .value("开始", Double(seg.startTurn) - 0.5),
                    xEnd: .value("结束", Double(seg.endTurn) + 0.5),
                    yStart: .value("底", 0.0),
                    yEnd: .value("顶", maxTokensK * 1.22)
                )
                .foregroundStyle(bandColor.opacity(0.08))
            }

            // 2) Model switch vertical markers (non-overlapping top annotations)
            ForEach(Array(segments.dropFirst())) { seg in
                let switchColor = colorForModel(seg.shortModel)
                let showLabel = labeledSwitchTurns.contains(seg.startTurn)
                RuleMark(x: .value("切换", Double(seg.startTurn) - 0.5))
                    .foregroundStyle(switchColor.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        if showLabel {
                            Text("T\(seg.startTurn)→\(seg.shortModel)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(switchColor.opacity(0.16))
                                .foregroundStyle(switchColor)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Circle()
                                .fill(switchColor)
                                .frame(width: 5, height: 5)
                        }
                    }
            }

            // 3) Latency bars (normalized onto chart height in orange)
            ForEach(indexedTimeline, id: \.element.id) { index, item in
                let turn = index + 1
                let latencyScaled = (item.totalCompletionMs / 1000.0) / maxLatencySec * (maxTokensK * 0.85)
                BarMark(
                    x: .value("轮次", turn),
                    y: .value("耗时归一化", latencyScaled),
                    width: timeline.count > 40 ? .fixed(3) : .automatic
                )
                .foregroundStyle(Color.orange.opacity(0.32))
            }

            // 4) Token consumption line + points colored by model
            ForEach(indexedTimeline, id: \.element.id) { index, item in
                let turn = index + 1
                let tokK = Double(item.finalUsage?.totalTokens ?? 0) / 1000.0
                let shortName = shortModelName(item.executedModelShortLabel)
                let modelColor = colorForModel(shortName)

                LineMark(
                    x: .value("轮次", turn),
                    y: .value("Tokens (k)", tokK)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("轮次", turn),
                    y: .value("Tokens (k)", tokK)
                )
                .foregroundStyle(modelColor)
                .symbolSize(turn == activeTurn ? 105 : (timeline.count > 30 ? 28 : 50))
            }

            // 5) Active/selected turn rule
            RuleMark(x: .value("当前", activeTurn))
                .foregroundStyle(Color.primary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartXScale(domain: 0.5...(Double(timeline.count) + 0.5))
        .chartYScale(domain: 0...(maxTokensK * 1.25))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(8, timeline.count))) { val in
                AxisGridLine()
                AxisValueLabel {
                    if let t = val.as(Int.self), t >= 1, t <= timeline.count {
                        Text("T\(t)")
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .chartYAxisLabel("k tokens")
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if let plotFrame = proxy.plotFrame {
                                let origin = geo[plotFrame].origin
                                let relX = location.x - origin.x
                                if let turnVal: Double = proxy.value(atX: relX) {
                                    let clamped = min(max(1, Int(turnVal.rounded())), timeline.count)
                                    hoveredTurn = clamped
                                }
                            }
                        case .ended:
                            hoveredTurn = nil
                        }
                    }
                    .onTapGesture { location in
                        if let plotFrame = proxy.plotFrame {
                            let origin = geo[plotFrame].origin
                            let relX = location.x - origin.x
                            if let turnVal: Double = proxy.value(atX: relX) {
                                let clamped = min(max(1, Int(turnVal.rounded())), timeline.count)
                                onSelectRecord?(timeline[clamped - 1].id)
                            }
                        }
                    }
            }
        }
        .frame(height: 210)
        .padding(.top, 6)
    }

    private var singleTurnBar: some View {
        let tokK = Double(record.finalUsage?.totalTokens ?? 0) / 1000.0
        let sec = record.totalCompletionMs / 1000.0
        return HStack(spacing: 16) {
            Chart {
                BarMark(x: .value("指标", "输入"), y: .value("数量", record.finalUsage?.promptTokens ?? 0))
                    .foregroundStyle(Color.blue)
                BarMark(x: .value("指标", "输出"), y: .value("数量", record.finalUsage?.completionTokens ?? 0))
                    .foregroundStyle(Color.green)
            }
            .frame(height: 120)

            VStack(alignment: .leading, spacing: 6) {
                Text("Token: \(formatTokens(Int(tokK * 1000)))")
                Text("耗时: \(String(format: "%.2f s", sec))")
            }
            .font(.caption.monospacedDigit())
            .frame(width: 140, alignment: .leading)
        }
    }

    private func modelSummaryStrip(stats: [ModelAggregateStat]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(stats) { stat in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(stat.color)
                            .frame(width: 8, height: 8)
                        Text(stat.shortModel)
                            .font(.caption.weight(.semibold))
                        Text("\(stat.turnCount)轮")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(AutoModelFormatter.formatMs(stat.totalDurationMs))
                            .font(.caption2.monospacedDigit())
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("\(formatTokens(stat.totalTokens)) tok")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(stat.color.opacity(0.1))
                    .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - 3b. Per-Model Share Pie Charts (Tokens / Cost / Runtime)

    private struct PieSliceItem: Identifiable {
        let id: String
        let label: String
        let value: Double
        let color: Color
    }

    private var modelSharePieChartsCard: some View {
        let stats = modelAggregateStats
        let totalTok = max(0, totalSessionTokens)
        let totalMs = max(0.0, totalSessionDurationMs)
        let pricedCostSum = stats.filter(\.hasCostData).map(\.totalCostUSD).reduce(0, +)
        let hasAnyPricedModel = stats.contains(where: { $0.hasCostData })

        let tokenSlices = stats
            .filter { $0.totalTokens > 0 }
            .map { PieSliceItem(id: "tok-\($0.id)", label: $0.shortModel, value: Double($0.totalTokens), color: $0.color) }
        let costSlices = stats
            .filter { $0.hasCostData && $0.totalCostUSD > 0 }
            .map { PieSliceItem(id: "cost-\($0.id)", label: $0.shortModel, value: $0.totalCostUSD, color: $0.color) }
        let durationSlices = stats
            .filter { $0.totalDurationMs > 0 }
            .map { PieSliceItem(id: "dur-\($0.id)", label: $0.shortModel, value: $0.totalDurationMs, color: $0.color) }

        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    shareDonutTile(
                        title: "Token 占比",
                        centerLabel: totalTok > 0 ? formatTokens(totalTok) : "无用量",
                        slices: tokenSlices,
                        emptyText: "无 Token"
                    )
                    Divider().frame(height: 112)
                    shareDonutTile(
                        title: "费用占比",
                        centerLabel: hasAnyPricedModel ? AutoModelFormatter.formatUSD(pricedCostSum) : "未计价",
                        slices: costSlices,
                        emptyText: hasAnyPricedModel ? "$0" : "未配单价"
                    )
                    Divider().frame(height: 112)
                    shareDonutTile(
                        title: "运行时长占比",
                        centerLabel: AutoModelFormatter.formatMs(totalMs),
                        slices: durationSlices,
                        emptyText: "无耗时"
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(stats) { stat in
                        let tokPct = totalTok > 0 ? (Double(stat.totalTokens) / Double(totalTok)) * 100.0 : 0.0
                        let durPct = totalMs > 0 ? (stat.totalDurationMs / totalMs) * 100.0 : 0.0
                        let costText: String = {
                            guard stat.hasCostData else { return "未配单价" }
                            if pricedCostSum > 0 {
                                let pct = (stat.totalCostUSD / pricedCostSum) * 100.0
                                return String(format: "%@ (%.1f%%)", AutoModelFormatter.formatUSD(stat.totalCostUSD), pct)
                            }
                            return AutoModelFormatter.formatUSD(stat.totalCostUSD)
                        }()

                        HStack(spacing: 8) {
                            HStack(spacing: 5) {
                                Circle().fill(stat.color).frame(width: 7, height: 7)
                                Text(stat.shortModel)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text("· \(stat.turnCount)轮")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 130, alignment: .leading)

                            Spacer(minLength: 6)

                            Text(totalTok > 0 ? String(format: "Token %@ (%.1f%%)", formatTokens(stat.totalTokens), tokPct) : "Token —")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.primary)
                                .frame(width: 136, alignment: .trailing)

                            Text("费用 \(costText)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(stat.hasCostData ? .green : .secondary)
                                .frame(width: 144, alignment: .trailing)

                            Text(totalMs > 0 ? String(format: "耗时 %@ (%.1f%%)", AutoModelFormatter.formatMs(stat.totalDurationMs), durPct) : "耗时 —")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.orange)
                                .frame(width: 130, alignment: .trailing)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(stat.color.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .padding(4)
        } label: {
            HStack {
                Label("不同模型占比分布（Token / 费用 / 运行时长）", systemImage: "chart.pie.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("共 \(stats.count) 个模型 · \(effectiveTimeline.count) 轮")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shareDonutTile(
        title: String,
        centerLabel: String,
        slices: [PieSliceItem],
        emptyText: String
    ) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ZStack {
                if slices.isEmpty {
                    Circle()
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 12)
                        .frame(width: 82, height: 82)
                    Text(emptyText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Chart(slices) { slice in
                        SectorMark(
                            angle: .value("数值", slice.value),
                            innerRadius: .ratio(0.58),
                            angularInset: 1.5
                        )
                        .cornerRadius(3)
                        .foregroundStyle(slice.color)
                    }
                    .chartLegend(.hidden)
                    .frame(width: 92, height: 92)

                    Text(centerLabel)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: 50)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 4. Collapsed Raw Details

    private var rawDetailsDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox {
                DisclosureGroup("子任务与 Effort 路由明细 (\(mergedPathSegments.count) 段)", isExpanded: $showSubtaskTable) {
                    subtaskEffortTableCard
                        .padding(.top, 6)
                }
                .font(.caption.weight(.medium))
                .padding(4)
            }

            GroupBox {
                DisclosureGroup("路由规则与候选模型 (\(record.decision.candidateEvaluations.count) 个)", isExpanded: $showRawAudit) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(record.decision.matchedRules, id: \.self) { rule in
                            Text("• \(rule)")
                                .font(.caption)
                        }
                        Divider()
                        ForEach(record.decision.candidateEvaluations) { candidate in
                            let isSelected = (candidate.modelUUID == record.decision.selectedModelUUID)
                            HStack {
                                Image(systemName: isSelected ? "star.fill" : (candidate.passedHardConstraints ? "checkmark.circle" : "xmark.circle"))
                                    .foregroundStyle(isSelected ? .yellow : (candidate.passedHardConstraints ? .green : .red))
                                Text("\(shortModelName(candidate.displayName)) · \(candidate.providerName)")
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                Spacer()
                                if let score = candidate.score {
                                    Text(String(format: "%.1f", score))
                                        .font(.caption2.monospacedDigit())
                                } else {
                                    Text(candidate.exclusionReasons.first ?? "已排除")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption.weight(.medium))
                .padding(4)
            }

            if record.requestPreview != nil || record.reasoningPreview != nil || record.responsePreview != nil {
                GroupBox {
                    DisclosureGroup("请求与响应正文", isExpanded: $showPayloads) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let req = record.requestPreview {
                                Text(req)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            if let reasoning = record.reasoningPreview, !reasoning.isEmpty {
                                Text(reasoning)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            if let resp = record.responsePreview, !resp.isEmpty {
                                Text(resp)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption.weight(.medium))
                    .padding(4)
                }
            }
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private func agentSymbol(_ agent: String) -> String {
        let lower = agent.lowercased()
        if lower.contains("claude") { return "sparkles" }
        if lower.contains("codex") { return "terminal" }
        if lower.contains("测试") { return "play.circle" }
        return "cpu"
    }

    private func nonOverlappingSwitchTurns(segments: [MergedPathSegment], totalTurns: Int) -> Set<Int> {
        let switches = Array(segments.dropFirst())
        guard !switches.isEmpty else { return [] }
        // Require ~22% of total chart width between labeled annotations so pills never collide
        let minGap = max(3, Int(ceil(Double(totalTurns) * 0.22)))
        var accepted = Set<Int>()
        var lastTurn = Int.min
        for seg in switches {
            // Also avoid placing a full label right at the far right edge where it clips
            let nearRightEdge = seg.startTurn > totalTurns - max(2, totalTurns / 8)
            if !nearRightEdge && (lastTurn == Int.min || seg.startTurn - lastTurn >= minGap) {
                accepted.insert(seg.startTurn)
                lastTurn = seg.startTurn
            }
        }
        return accepted
    }
}

struct StatusPill: View {
    let status: CallStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(pillColor.opacity(0.15))
            .foregroundStyle(pillColor)
            .clipShape(Capsule())
    }

    private var pillColor: Color {
        switch status {
        case .success: return .green
        case .failed: return .red
        case .rejected: return .orange
        }
    }
}
