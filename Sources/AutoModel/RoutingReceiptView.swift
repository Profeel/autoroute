import AutoModelCore
import Charts
import SwiftUI

struct RoutingReceiptView: View {
    let record: CallRecord
    var sessionRecords: [CallRecord] = []
    var sessionImpact: RoutingImpactSummary? = nil
    var onSelectRecord: ((UUID) -> Void)? = nil

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
        }

        return order.map { key in
            let display = displayByKey[key] ?? key
            return ModelAggregateStat(
                id: key,
                shortModel: display,
                turnCount: counts[key] ?? 0,
                totalDurationMs: durations[key] ?? 0,
                totalTokens: tokens[key] ?? 0,
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
            VStack(alignment: .leading, spacing: 14) {
                compactHeaderStrip
                routingPathDiagramCard
                subtaskEffortTableCard
                unifiedSessionChartCard
                rawDetailsDisclosure
            }
            .padding(16)
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

    // MARK: - 2. Merged Visual Routing Path Diagram

    private var routingPathDiagramCard: some View {
        let segments = mergedPathSegments
        let activeSegmentID = segments.first(where: { $0.containsRecord(record.id) })?.id ?? segments.last?.id
        return Group {
            if segments.count <= 1, let onlySeg = segments.first {
                let segColor = colorForModel(onlySeg.shortModel)
                GroupBox {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Label(record.displayClientAgent, systemImage: agentSymbol(record.displayClientAgent))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.1))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())

                            Image(systemName: "arrow.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 6) {
                                Circle().fill(segColor).frame(width: 7, height: 7)
                                Text("\(onlySeg.turnRangeLabel) (\(onlySeg.records.count)轮)")
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(onlySeg.shortModel)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(segColor)
                                effortPill(onlySeg.effort)
                                Text("· \(AutoModelFormatter.formatMs(onlySeg.totalDurationMs)) · \(formatTokens(onlySeg.totalTokens)) tok")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(segColor.opacity(0.1))
                            .clipShape(Capsule())

                            Spacer()

                            Text(onlySeg.subtaskCategory.displayName)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                GroupBox {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                VStack(spacing: 4) {
                                    Image(systemName: agentSymbol(record.displayClientAgent))
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                    Text(record.displayClientAgent)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(record.hasConversationFingerprint ? record.shortSessionLabel : "请求")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                                )

                                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                                    let prev = index > 0 ? segments[index - 1] : nil
                                    segmentConnector(previous: prev, current: segment)
                                    segmentNode(segment)
                                        .id(segment.id)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 2)
                        }
                        .onAppear {
                            if let targetID = activeSegmentID ?? segments.last?.id {
                                DispatchQueue.main.async {
                                    proxy.scrollTo(targetID, anchor: .trailing)
                                }
                            }
                        }
                        .onChange(of: segments.count) { _, _ in
                            if let lastID = segments.last?.id {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(lastID, anchor: .trailing)
                                }
                            }
                        }
                        .onChange(of: record.id) { _, _ in
                            if let targetID = activeSegmentID ?? segments.last?.id {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(targetID, anchor: .trailing)
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Label("调用路径", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(segments.count) 段 · 切换 \(max(0, segments.count - 1)) 次 · 已自动定位当前切换")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func segmentConnector(previous: MergedPathSegment?, current: MergedPathSegment) -> some View {
        let label = previous == nil ? "开始" : "切"
        let color: Color = previous == nil ? .secondary : colorForModel(current.shortModel)
        return VStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
        }
        .frame(minWidth: 24)
    }

    private func segmentNode(_ segment: MergedPathSegment) -> some View {
        let isSelected = segment.containsRecord(record.id)
        let color = colorForModel(segment.shortModel)
        let turnCount = segment.records.count

        return Button {
            if let latestInSeg = segment.records.last {
                onSelectRecord?(latestInSeg.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(segment.turnRangeLabel)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(isSelected ? color : .secondary)

                    if turnCount > 1 {
                        Text("\(turnCount)轮")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(color.opacity(0.15))
                            .foregroundStyle(color)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    effortPill(segment.effort)

                    Circle()
                        .fill(segment.hasFailure ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                }

                Text(segment.shortModel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(segment.subtaskCategory.displayName) · \(segment.subtaskSummary)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(AutoModelFormatter.formatMs(segment.totalDurationMs))
                    Text("·")
                    Text(segment.totalTokens > 0 ? "\(formatTokens(segment.totalTokens)) tok" : "—")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minWidth: 168, maxWidth: 220, alignment: .leading)
            .background(isSelected ? color.opacity(0.13) : Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? color : color.opacity(0.32), lineWidth: isSelected ? 1.8 : 1)
            )
        }
        .buttonStyle(.plain)
    }

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
                // Active / Hovered Turn Readout Bar (zero overlap!)
                HStack(spacing: 10) {
                    let activeShort = shortModelName(activeItem.executedModelShortLabel)
                    let activeColor = colorForModel(activeShort)
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

                // Reserved non-overlapping strip for all model switch nodes
                if segments.count > 1 {
                    let switchSegments = Array(segments.dropFirst())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text("切换节点:")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                            ForEach(switchSegments) { seg in
                                let swColor = colorForModel(seg.shortModel)
                                let isActiveSwitch = activeTurn >= seg.startTurn && activeTurn <= seg.endTurn
                                Button {
                                    if let target = seg.records.first {
                                        onSelectRecord?(target.id)
                                    }
                                } label: {
                                    Text("T\(seg.startTurn)→\(seg.shortModel)")
                                        .font(.caption2.weight(.semibold).monospacedDigit())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(swColor.opacity(isActiveSwitch ? 0.22 : 0.12))
                                        .foregroundStyle(swColor)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(swColor.opacity(isActiveSwitch ? 0.65 : 0.25), lineWidth: 1)
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if timeline.count >= 2 {
                    let labeledSwitchTurns = nonOverlappingSwitchTurns(segments: segments, totalTurns: timeline.count)
                    Chart {
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
                        ForEach(Array(timeline.enumerated()), id: \.element.id) { index, item in
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
                        ForEach(Array(timeline.enumerated()), id: \.element.id) { index, item in
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
                } else {
                    // Single-turn clean comparison bar
                    let tokK = Double(record.finalUsage?.totalTokens ?? 0) / 1000.0
                    let sec = record.totalCompletionMs / 1000.0
                    HStack(spacing: 16) {
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

                Divider()

                // Per-Model Summary Strip (Short name + turns + duration + tokens)
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

    // MARK: - 4. Collapsed Raw Details

    private var rawDetailsDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
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
