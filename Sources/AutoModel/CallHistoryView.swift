import AutoModelCore
import Charts
import SwiftUI

struct CallHistoryView: View {
    @ObservedObject var engine: AutoModelEngine
    var requestedRecordID: UUID? = nil
    var onConsumeRequestedRecord: (() -> Void)? = nil
    var onNavigateToProviders: (() -> Void)? = nil

    @State private var selectedRecordID: UUID?
    @State private var filterMode: FilterMode = .all
    @State private var groupMode: GroupMode = .bySession
    @State private var complexityFilter: RoutingComplexityLevel? = nil
    @State private var modelFilter: String? = nil
    @State private var searchText: String = ""
    @State private var showAdvancedPolicyPopover = false
    @State private var activeTierPopover: ModelTier? = nil
    @State private var showTrafficDetailPopover = false
    @State private var maxInInput: String = ""
    @State private var maxOutInput: String = ""
    @State private var clearHistoryError: String?
    @State private var showClearHistoryError = false

    enum FilterMode: String, CaseIterable {
        case all = "全部"
        case success = "成功"
        case failed = "失败"
    }

    enum GroupMode: String, CaseIterable {
        case bySession = "按会话"
        case chronological = "按时间"
    }

    private struct SessionSummaryItem: Identifiable {
        let id: String
        let representativeRecord: CallRecord
        let recordsChronological: [CallRecord]
        let agentName: String
        let title: String
        let mergedPathText: String
        let switchCount: Int
        let totalDurationMs: Double
        let totalTokens: Int
        let totalCostUSD: Double?
        let hasFailure: Bool
        let latestTimestamp: Date
    }

    private var hasActiveExtraFilters: Bool {
        filterMode != .all || complexityFilter != nil || modelFilter != nil
    }

    private var baseFilteredRecords: [CallRecord] {
        engine.callHistory.filter { record in
            switch filterMode {
            case .all: break
            case .success: if record.status != .success { return false }
            case .failed: if record.status == .success { return false }
            }

            if let complexityFilter, record.routingComplexityLevel != complexityFilter {
                return false
            }

            if let modelFilter, record.executedModelShortLabel != modelFilter {
                return false
            }

            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return true }
            return record.displayClientAgent.lowercased().contains(q)
                || (record.executedModelID?.lowercased().contains(q) ?? false)
                || (record.executedModelDisplayName?.lowercased().contains(q) ?? false)
                || (record.executedProviderName?.lowercased().contains(q) ?? false)
                || record.requestedModel.lowercased().contains(q)
                || (record.requestFeatures.conversationFingerprint?.lowercased().contains(q) ?? false)
                || (record.requestPreview?.lowercased().contains(q) ?? false)
                || (record.errorMessage?.lowercased().contains(q) ?? false)
        }
    }

    private var distinctExecutedModels: [(model: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in engine.callHistory {
            counts[r.executedModelShortLabel, default: 0] += 1
        }
        return counts
            .map { (model: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.model < rhs.model
            }
    }

    private func mergedSessionBuckets(from records: [CallRecord]) -> [(key: String, records: [CallRecord])] {
        let rawGrouped = Dictionary(grouping: records, by: \.sessionGroupKey)
        struct Bucket {
            var key: String
            var titleKey: String
            var records: [CallRecord]
            var earliest: Date
            var latest: Date
        }

        let initialBuckets: [Bucket] = rawGrouped.compactMap { key, items in
            let sorted = items.sorted { $0.timestamp < $1.timestamp }
            guard let first = sorted.first, let last = sorted.last else { return nil }
            let title = cleanSessionTitle(for: first)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return Bucket(key: key, titleKey: title, records: sorted, earliest: first.timestamp, latest: last.timestamp)
        }
        .sorted { $0.earliest < $1.earliest }

        var merged: [Bucket] = []
        for bucket in initialBuckets {
            if bucket.titleKey.count >= 6,
               let matchIdx = merged.lastIndex(where: { existing in
                   guard existing.titleKey == bucket.titleKey else { return false }
                   let gap = max(0, bucket.earliest.timeIntervalSince(existing.latest))
                   return gap <= 1800
               }) {
                merged[matchIdx].records.append(contentsOf: bucket.records)
                merged[matchIdx].records.sort { $0.timestamp < $1.timestamp }
                merged[matchIdx].earliest = min(merged[matchIdx].earliest, bucket.earliest)
                merged[matchIdx].latest = max(merged[matchIdx].latest, bucket.latest)
            } else {
                merged.append(bucket)
            }
        }
        return merged.map { (key: $0.key, records: $0.records) }
    }

    private func resolvedAgentLabel(for chronological: [CallRecord]) -> String {
        if let explicitHermes = chronological.first(where: { $0.displayClientAgent.lowercased().contains("hermes") }) {
            return explicitHermes.displayClientAgent
        }
        let raw = chronological.first?.displayClientAgent ?? "外部客户端"
        let hasHermesConfigured = engine.agentStatuses.contains(where: { $0.kind == .hermes && $0.isConnectedToAutoModel })
        if raw == "Python SDK", hasHermesConfigured, chronological.first?.source == .externalProxy {
            return "Hermes Agent"
        }
        return raw
    }

    /// One compact, merged row per session — consecutive same-model turns are collapsed into "Model ×N".
    private var sessionItems: [SessionSummaryItem] {
        mergedSessionBuckets(from: baseFilteredRecords).compactMap { bucket in
            let chronological = bucket.records
            guard let latest = chronological.last, let oldest = chronological.first else { return nil }

            // Merge consecutive identical models (case-insensitive): [(model, count)]
            var segments: [(model: String, count: Int)] = []
            for r in chronological {
                let label = shortModelName(r.executedModelShortLabel)
                if let lastIdx = segments.indices.last,
                   segments[lastIdx].model.lowercased() == label.lowercased() {
                    segments[lastIdx].count += 1
                } else {
                    segments.append((model: label, count: 1))
                }
            }

            let mergedPathText: String = {
                if segments.isEmpty { return "" }
                if segments.count == 1 { return segments[0].model }
                if segments.count == 2 { return "\(segments[0].model) → \(segments[1].model)" }
                return "\(segments.first!.model) → … → \(segments.last!.model)"
            }()

            let totalDur = chronological.map(\.totalCompletionMs).reduce(0, +)
            let totalTok = chronological.compactMap { $0.finalUsage?.totalTokens }.reduce(0, +)
            let costValues = chronological.compactMap(\.totalCostUSD)
            let totalCost: Double? = costValues.isEmpty ? nil : costValues.reduce(0, +)
            let hasFailure = chronological.contains { $0.status != .success }

            let title = cleanSessionTitle(for: oldest)

            return SessionSummaryItem(
                id: bucket.key,
                representativeRecord: latest,
                recordsChronological: chronological,
                agentName: resolvedAgentLabel(for: chronological),
                title: title,
                mergedPathText: mergedPathText,
                switchCount: max(0, segments.count - 1),
                totalDurationMs: totalDur,
                totalTokens: totalTok,
                totalCostUSD: totalCost,
                hasFailure: hasFailure,
                latestTimestamp: latest.timestamp
            )
        }
        .sorted { $0.latestTimestamp > $1.latestTimestamp }
    }

    private var selectedRecord: CallRecord? {
        if let id = selectedRecordID, let found = baseFilteredRecords.first(where: { $0.id == id }) {
            return found
        }
        if groupMode == .bySession, let firstSession = sessionItems.first {
            return firstSession.representativeRecord
        }
        return baseFilteredRecords.first
    }

    private var selectedSessionKeyBinding: Binding<String?> {
        Binding<String?>(
            get: {
                if let current = selectedRecord {
                    if let matched = sessionItems.first(where: { $0.recordsChronological.contains(where: { $0.id == current.id }) }) {
                        return matched.id
                    }
                    return current.sessionGroupKey
                }
                return sessionItems.first?.id
            },
            set: { newKey in
                if let newKey, let matched = sessionItems.first(where: { $0.id == newKey }) {
                    selectedRecordID = matched.representativeRecord.id
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            homeDashboardHeader
            Divider()
            HStack(spacing: 0) {
                listColumn
                    .frame(minWidth: 330, idealWidth: 370, maxWidth: 430)
                Divider()
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("首页")
        .onAppear {
            syncPriceCapInputs()
            if let reqID = requestedRecordID {
                selectedRecordID = reqID
                onConsumeRequestedRecord?()
            }
        }
        .onChange(of: requestedRecordID) { _, newValue in
            if let newValue {
                selectedRecordID = newValue
                onConsumeRequestedRecord?()
            }
        }
        .alert("清空失败", isPresented: $showClearHistoryError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(clearHistoryError ?? "调用历史未能删除，请检查本机存储权限。")
        }
    }

    // MARK: - Clash Verge Style Home Header

    private var homeDashboardHeader: some View {
        let healthyModels = engine.healthyAvailableModels()
        let healthyIDs = Set(healthyModels.map(\.id))
        let totalCost = engine.callHistory.compactMap(\.totalCostUSD).reduce(0, +)
        let impact = engine.routingImpactSummary(todayOnly: false)

        return HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // 1. Strategy preset pills
                    HStack(spacing: 3) {
                        ForEach(RoutingStrategyPreset.allCases, id: \.self) { preset in
                            let selected = engine.config.policy.activeStrategy == preset
                            Button {
                                engine.setStrategy(preset)
                            } label: {
                                Text(strategyShortTitle(preset))
                                    .font(.caption2.weight(selected ? .semibold : .regular))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(selected ? Color.accentColor.opacity(0.18) : Color(.controlBackgroundColor))
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider().frame(height: 18)

                    // 2. Clickable 3-tier model pills (click to change primary / backups)
                    HStack(spacing: 6) {
                        ForEach(ModelTier.allCases) { tier in
                            let assigned = engine.model(for: tier)
                            let cooldownSecs = assigned.flatMap { engine.cooldownRemainingSeconds(for: $0.id) }
                            let isHealthy = assigned.map { healthyIDs.contains($0.id) } ?? false
                            let tierColor: Color = (tier == .low ? .green : (tier == .medium ? .blue : .purple))
                            let backupCount = engine.config.policy.backupModelIDs(for: tier).count

                            Button {
                                activeTierPopover = (activeTierPopover == tier) ? nil : tier
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(assigned == nil ? Color.gray.opacity(0.4) : ((isHealthy && cooldownSecs == nil) ? tierColor : Color.orange))
                                        .frame(width: 6, height: 6)
                                    Text(tier.shortName)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(tierColor)
                                    Text(assigned.map { shortModelName($0.displayName) } ?? "未分配")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let cooldownSecs {
                                        Text("冷却\(cooldownSecs)s")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.orange)
                                    } else if backupCount > 0 {
                                        Text("+\(backupCount)")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.controlBackgroundColor))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(tierColor.opacity(0.25), lineWidth: 0.8)
                                )
                            }
                            .buttonStyle(.plain)
                            .popover(
                                isPresented: Binding(
                                    get: { activeTierPopover == tier },
                                    set: { if !$0 && activeTierPopover == tier { activeTierPopover = nil } }
                                ),
                                arrowEdge: .bottom
                            ) {
                                tierConfigPopover(for: tier)
                            }
                        }
                    }

                    Button {
                        syncPriceCapInputs()
                        showAdvancedPolicyPopover.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("高级路由规则、防抖开关与三档锁死设置")
                    .popover(isPresented: $showAdvancedPolicyPopover, arrowEdge: .bottom) {
                        advancedPolicyPopoverContent
                    }
                }
            }

            // 3. Headline savings/speed strip (click to open full traffic & 20-turn trend popover)
            Button {
                showTrafficDetailPopover.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(AutoModelFormatter.formatUSD(totalCost))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)

                    if let impact {
                        let costSavedPositive = impact.costSavedUSD >= 0
                        if let pct = impact.costSavingsPercent {
                            Text(String(format: "%@ %@%.1f%%", costSavedPositive ? "省费" : "多花", pct >= 0 ? "-" : "+", abs(pct)))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background((costSavedPositive ? Color.green : Color.orange).opacity(0.14))
                                .foregroundStyle(costSavedPositive ? Color.green : Color.orange)
                                .clipShape(Capsule())
                        }
                        if let speedPct = impact.speedGainPercent {
                            Text(String(format: "速度 %@%.1f%%", speedPct >= 0 ? "+" : "-", abs(speedPct)))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(Color.blue.opacity(0.14))
                                .foregroundStyle(Color.blue)
                                .clipShape(Capsule())
                        }
                    }

                    Image(systemName: "chart.xyaxis.line")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color(.controlBackgroundColor).opacity(0.8))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("点击查看详细流量、20 轮趋势与 Top10% 长尾成本")
            .popover(isPresented: $showTrafficDetailPopover, arrowEdge: .bottom) {
                trafficOverviewCard
                    .frame(width: 520)
                    .padding(12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
    }

    private func tierConfigPopover(for tier: ModelTier) -> some View {
        let healthyModels = engine.healthyAvailableModels()
        let providersByID = Dictionary(uniqueKeysWithValues: engine.config.providers.map { ($0.id, $0) })
        let assigned = engine.model(for: tier)
        let cooldownSecs = assigned.flatMap { engine.cooldownRemainingSeconds(for: $0.id) }
        let tierColor: Color = (tier == .low ? .green : (tier == .medium ? .blue : .purple))
        let poolIDs = Set(engine.config.policy.modelIDs(for: tier))
        let backups = engine.backupModels(for: tier)
        let addableBackups = healthyModels.filter { !poolIDs.contains($0.id) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(tier.displayName)（\(tierEffortHint(tier))）")
                    .font(.headline)
                    .foregroundStyle(tierColor)
                Spacer()
                Button("自动配平") {
                    engine.autoConfigureModelTiers(forceResetManual: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(healthyModels.isEmpty)
            }

            if let cooldownSecs {
                Text("当前主模型正在限流/抖动冷却中（约 \(cooldownSecs)s 后自动恢复），请求会自动转由同档备选模型执行。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("首选主模型").font(.caption).foregroundStyle(.secondary)
                Picker(tier.shortName, selection: Binding(
                    get: { engine.config.policy.modelID(for: tier) },
                    set: { newID in
                        engine.setTierModel(tier: tier, modelUUID: newID, isManual: newID != nil)
                    }
                )) {
                    Text("未分配").tag(UUID?.none)
                    ForEach(healthyModels) { m in
                        let pName = providersByID[m.providerID]?.name ?? "未知"
                        Text("\(shortModelName(m.displayName)) · \(pName)").tag(UUID?.some(m.id))
                    }
                    if let assigned, !healthyModels.contains(where: { $0.id == assigned.id }) {
                        Text("\(shortModelName(assigned.displayName)) [不可用]").tag(UUID?.some(assigned.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("失败自动切换备选池（按顺序）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !addableBackups.isEmpty {
                        Menu("+ 添加备选") {
                            ForEach(addableBackups) { candidate in
                                let cProvider = providersByID[candidate.providerID]?.name ?? "未知"
                                Button("\(shortModelName(candidate.displayName)) · \(cProvider)") {
                                    engine.addTierBackupModel(tier: tier, modelUUID: candidate.id)
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                }

                if backups.isEmpty {
                    Text("尚未添加备选模型。主模型 429 限流或报错时将按策略回退。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(backups) { bk in
                        let bkProv = providersByID[bk.providerID]?.name ?? "未知"
                        HStack {
                            Text("\(shortModelName(bk.displayName)) · \(bkProv)")
                                .font(.caption)
                            Spacer()
                            Button {
                                engine.removeTierBackupModel(tier: tier, modelUUID: bk.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var trafficOverviewCard: some View {
        let records = engine.callHistory
        let cal = Calendar.current
        let todayRecords = records.filter { cal.isDateInToday($0.timestamp) }

        let totalTokens = records.compactMap { $0.finalUsage?.totalTokens }.reduce(0, +)
        let todayTokens = todayRecords.compactMap { $0.finalUsage?.totalTokens }.reduce(0, +)

        let totalCost = records.compactMap(\.totalCostUSD).reduce(0, +)
        let todayCost = todayRecords.compactMap(\.totalCostUSD).reduce(0, +)

        let sessionCount = Set(records.map(\.sessionGroupKey)).count
        let successRecords = records.filter { $0.status == .success }
        let avgLatencySec = successRecords.isEmpty
            ? 0
            : (successRecords.map(\.totalCompletionMs).reduce(0, +) / Double(successRecords.count)) / 1000.0
        let successRatePct = records.isEmpty ? 100 : Int((Double(successRecords.count) / Double(records.count) * 100).rounded())

        let recent20 = Array(records.sorted { $0.timestamp < $1.timestamp }.suffix(20))
        let healthyCount = engine.healthyAvailableModels().count

        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("流量与消耗统计", systemImage: "chart.xyaxis.line")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(healthyCount) 可用模型 · \(engine.config.providers.count) 供应商")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            compactTrafficTile(
                                title: "累计 Token",
                                value: formatCompactTokenTotal(totalTokens),
                                sub: "今日 \(formatCompactTokenTotal(todayTokens))"
                            )
                            compactTrafficTile(
                                title: "累计费用",
                                value: AutoModelFormatter.formatUSD(totalCost),
                                sub: "今日 \(AutoModelFormatter.formatUSD(todayCost))"
                            )
                        }
                        HStack(spacing: 8) {
                            compactTrafficTile(
                                title: "会话 / 轮次",
                                value: "\(sessionCount) / \(records.count)",
                                sub: "今日 \(todayRecords.count) 轮"
                            )
                            compactTrafficTile(
                                title: "平均耗时",
                                value: String(format: "%.2fs", avgLatencySec),
                                sub: "成功率 \(successRatePct)%"
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Mini trend chart for recent 20 turns
                    VStack(alignment: .trailing, spacing: 2) {
                        if recent20.count >= 2 {
                            Chart {
                                ForEach(Array(recent20.enumerated()), id: \.element.id) { idx, item in
                                    let tokK = Double(item.finalUsage?.totalTokens ?? 0) / 1000.0
                                    AreaMark(
                                        x: .value("i", idx),
                                        y: .value("k", tokK)
                                    )
                                    .foregroundStyle(Color.accentColor.opacity(0.18))
                                    .interpolationMethod(.catmullRom)

                                    LineMark(
                                        x: .value("i", idx),
                                        y: .value("k", tokK)
                                    )
                                    .foregroundStyle(Color.accentColor)
                                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                                    .interpolationMethod(.catmullRom)
                                }
                            }
                            .chartXAxis(.hidden)
                            .chartYAxis(.hidden)
                            .frame(width: 165, height: 68)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(.controlBackgroundColor).opacity(0.5))
                                .frame(width: 165, height: 68)
                                .overlay(
                                    Text("暂无流量趋势")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                )
                        }
                        Text("近 \(recent20.count) 轮 Token 走势")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                if let impact = engine.routingImpactSummary(todayOnly: false) {
                    Divider()
                    routingImpactStrip(impact)
                }
            }
            .padding(2)
        }
    }

    private func routingImpactStrip(_ impact: RoutingImpactSummary) -> some View {
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
                    ? String(format: "均快 %.1fs/轮 · %@", sec, impact.speedBasisLabel)
                    : String(format: "均慢 %.1fs/轮 · %@", sec, impact.speedBasisLabel)
            }
            return impact.speedBasisLabel
        }()

        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.circle.fill")
                    .font(.caption)
                    .foregroundStyle(costSavedPositive ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(costSavedPositive ? "花费减少" : "较基准多花")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(costPctText)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(costSavedPositive ? Color.green : Color.orange)
                    }
                    Text("\(costSavedPositive ? "省" : "多") \(AutoModelFormatter.formatUSD(abs(impact.costSavedUSD))) · 基准 \(impact.baselineModelDisplayName)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background((costSavedPositive ? Color.green : Color.orange).opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 6) {
                Image(systemName: "bolt.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.blue)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("速度提升")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(speedPctText)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Color.blue)
                    }
                    Text(speedSubText)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text("长尾与重试")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let top10 = impact.top10PercentCostSharePercent {
                    Text(String(format: "Top10%% 难题占 %.0f%% 花费", top10))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                } else {
                    Text("样本积累中")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text("成功率 \(impact.successRatePercent)% · 重试 \(impact.retryCount) 次")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(.controlBackgroundColor).opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func compactTrafficTile(title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .lineLimit(1)
            Text(sub)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(.controlBackgroundColor).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var advancedPolicyPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("高级路由规则")
                .font(.headline)

            Toggle("保持多轮会话稳定", isOn: Binding(
                get: { engine.config.policy.enableSessionStickiness },
                set: { val in engine.updatePolicy { $0.enableSessionStickiness = val } }
            ))
            Toggle("失败自动切换备选", isOn: Binding(
                get: { engine.config.policy.enableRetryOnUpstreamFailure },
                set: { val in engine.updatePolicy { $0.enableRetryOnUpstreamFailure = val } }
            ))
            Toggle("自动用三档模型覆盖 model=auto", isOn: Binding(
                get: { engine.config.policy.preferTierMappingInAuto },
                set: { val in engine.updatePolicy { $0.preferTierMappingInAuto = val } }
            ))
            Toggle("三段式防抖降档（高档规划后连续常规任务回落中档）", isOn: Binding(
                get: { engine.config.policy.enablePhaseDowngradeHysteresis },
                set: { val in engine.updatePolicy { $0.enablePhaseDowngradeHysteresis = val } }
            ))
            Toggle("严格仅限已配三档及备选模型（不越界使用其他模型）", isOn: Binding(
                get: { engine.config.policy.strictThreeTierPoolOnly },
                set: { val in engine.updatePolicy { $0.strictThreeTierPoolOnly = val } }
            ))

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("固定使用模型").font(.caption).foregroundStyle(.secondary)
                    Picker("固定模型", selection: Binding(
                        get: { engine.config.policy.pinnedModelID },
                        set: { val in engine.updatePolicy { $0.pinnedModelID = val } }
                    )) {
                        Text("按策略自动路由").tag(UUID?.none)
                        ForEach(engine.config.models) { model in
                            Text(shortModelName(model.displayName)).tag(UUID?.some(model.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("默认回退模型").font(.caption).foregroundStyle(.secondary)
                    Picker("回退模型", selection: Binding(
                        get: { engine.config.policy.fallbackModelID },
                        set: { val in engine.updatePolicy { $0.fallbackModelID = val } }
                    )) {
                        Text("无").tag(UUID?.none)
                        ForEach(engine.config.models) { model in
                            Text(shortModelName(model.displayName)).tag(UUID?.some(model.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            HStack(spacing: 8) {
                Text("价格上限 ($/1M):").font(.caption).foregroundStyle(.secondary)
                TextField("输入", text: $maxInInput).textFieldStyle(.roundedBorder).frame(width: 64)
                TextField("输出", text: $maxOutInput).textFieldStyle(.roundedBorder).frame(width: 64)
                Button("应用") { applyPriceCaps() }.buttonStyle(.bordered).controlSize(.small)
                Button("清除") {
                    maxInInput = ""
                    maxOutInput = ""
                    engine.updatePolicy {
                        $0.maxInputPricePerMillion = nil
                        $0.maxOutputPricePerMillion = nil
                    }
                }.buttonStyle(.bordered).controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Anthropic 子任务 × 思考程度 (Effort) 路由对照表")
                    .font(.caption.weight(.semibold))
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text("任务").frame(width: 105, alignment: .leading)
                        Text("档位/模型").frame(width: 90, alignment: .leading)
                        Text("Effort").frame(width: 55, alignment: .center)
                        Text("备注（原因）").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(.controlBackgroundColor))

                    ForEach(AgentSubtaskCategory.allCases, id: \.self) { cat in
                        Divider().opacity(0.4)
                        let tierModel = engine.model(for: cat.recommendedTier).map { shortModelName($0.displayName) } ?? cat.recommendedTier.shortName
                        HStack(spacing: 6) {
                            Text(cat.displayName)
                                .frame(width: 105, alignment: .leading)
                                .lineLimit(1)
                            Text("\(cat.recommendedTier.shortName): \(tierModel)")
                                .frame(width: 90, alignment: .leading)
                                .lineLimit(1)
                            Text(cat.recommendedEffort.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .frame(width: 55, alignment: .center)
                            Text(cat.defaultRationale)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(2)
                        }
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 490)
    }

    private func tierEffortHint(_ tier: ModelTier) -> String {
        switch tier {
        case .low: return "effort: low"
        case .medium: return "effort: medium"
        case .high: return "effort: high/max"
        }
    }

    private func strategyShortTitle(_ preset: RoutingStrategyPreset) -> String {
        switch preset {
        case .costFirst: return "省钱"
        case .balanced: return "均衡"
        case .qualityFirst: return "质量"
        }
    }

    private func formatCompactTokenTotal(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        }
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private func syncPriceCapInputs() {
        maxInInput = engine.config.policy.maxInputPricePerMillion.map { String(format: "%.2f", $0) } ?? ""
        maxOutInput = engine.config.policy.maxOutputPricePerMillion.map { String(format: "%.2f", $0) } ?? ""
    }

    private func applyPriceCaps() {
        let inCap = Double(maxInInput.trimmingCharacters(in: .whitespaces))
        let outCap = Double(maxOutInput.trimmingCharacters(in: .whitespaces))
        engine.updatePolicy { policy in
            policy.maxInputPricePerMillion = inCap
            policy.maxOutputPricePerMillion = outCap
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField("搜索 Agent、模型或会话", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    Menu {
                        Section("状态") {
                            ForEach(FilterMode.allCases, id: \.self) { mode in
                                Button {
                                    filterMode = mode
                                } label: {
                                    HStack {
                                        Text(mode.rawValue)
                                        if filterMode == mode { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }

                        Section("复杂度") {
                            Button {
                                complexityFilter = nil
                            } label: {
                                HStack {
                                    Text("全部复杂度")
                                    if complexityFilter == nil { Image(systemName: "checkmark") }
                                }
                            }
                            ForEach(RoutingComplexityLevel.allCases) { level in
                                Button {
                                    complexityFilter = level
                                } label: {
                                    HStack {
                                        Text(level.displayName)
                                        if complexityFilter == level { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }

                        if !distinctExecutedModels.isEmpty {
                            Section("执行模型") {
                                Button {
                                    modelFilter = nil
                                } label: {
                                    HStack {
                                        Text("全部模型")
                                        if modelFilter == nil { Image(systemName: "checkmark") }
                                    }
                                }
                                ForEach(distinctExecutedModels, id: \.model) { item in
                                    Button {
                                        modelFilter = item.model
                                    } label: {
                                        HStack {
                                            Text("\(item.model) (\(item.count))")
                                            if modelFilter == item.model { Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                            }
                        }

                        if hasActiveExtraFilters {
                            Divider()
                            Button("重置筛选") {
                                filterMode = .all
                                complexityFilter = nil
                                modelFilter = nil
                            }
                        }
                    } label: {
                        Image(systemName: hasActiveExtraFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .foregroundStyle(hasActiveExtraFilters ? Color.accentColor : Color.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 26)
                    .help("筛选")

                    Button {
                        do {
                            try engine.clearCallHistory()
                            selectedRecordID = nil
                            complexityFilter = nil
                            modelFilter = nil
                        } catch {
                            clearHistoryError = error.localizedDescription
                            showClearHistoryError = true
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(engine.callHistory.isEmpty)
                    .help("清空记录")
                }

                Picker("分组", selection: $groupMode) {
                    ForEach(GroupMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(10)

            Divider()

            if baseFilteredRecords.isEmpty {
                ContentUnavailableView {
                    Label("暂无调用记录", systemImage: "waveform.path.ecg")
                } description: {
                    Text("接入 Agent 或按 ⌘T 快速测试后，这里将展示调用路径与耗时/Token 曲线。")
                }
                .frame(maxHeight: .infinity)
            } else {
                switch groupMode {
                case .bySession:
                    List(sessionItems, selection: selectedSessionKeyBinding) { session in
                        sessionRow(session)
                            .tag(session.id)
                    }
                case .chronological:
                    List(baseFilteredRecords, selection: $selectedRecordID) { record in
                        recordRow(record)
                            .tag(record.id)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: SessionSummaryItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.hasFailure ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)

                Text(session.agentName)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(0.14))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())

                Text(session.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Text(session.latestTimestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(session.mergedPathText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if session.switchCount > 0 {
                    Text("切\(session.switchCount)次")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.12))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("\(session.recordsChronological.count)轮")
                    Text("·")
                    Text("\(formatTokenCount(session.totalTokens))")
                    if let cost = session.totalCostUSD {
                        Text("·")
                        Text(AutoModelFormatter.formatUSD(cost))
                            .fontWeight(.medium)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private func recordRow(_ record: CallRecord) -> some View {
        let complexity = record.routingComplexityLevel
        let compColor = complexityColor(complexity)
        let tokensText: String = {
            if let tok = record.finalUsage?.totalTokens {
                return "\(formatTokenCount(tok)) tok"
            }
            return "—"
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(record.status == .success ? Color.green : Color.red)
                    .frame(width: 7, height: 7)

                Text(record.executedModelShortLabel)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Text(complexity.shortBadge)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(compColor.opacity(0.12))
                    .foregroundStyle(compColor)
                    .clipShape(Capsule())

                Spacer()

                Text(record.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(record.displayClientAgent)
                    .fontWeight(.medium)
                if record.hasConversationFingerprint {
                    Text(record.shortSessionLabel)
                        .font(.caption2.monospaced())
                }
                Spacer()
                Text(AutoModelFormatter.formatMs(record.totalCompletionMs))
                    .monospacedDigit()
                Text("·")
                Text(tokensText)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    /// Extract a readable session title, skipping `[system]` boilerplate when possible.
    private func cleanSessionTitle(for record: CallRecord) -> String {
        if let preview = record.requestPreview {
            let lines = preview
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let userLine = lines.first(where: { $0.hasPrefix("[user]") }) {
                let cleaned = userLine.replacingOccurrences(of: "[user]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return String(cleaned.prefix(24)) + (cleaned.count > 24 ? "…" : "")
                }
            }
            if let firstNonSystem = lines.first(where: { !$0.hasPrefix("[system]") }) {
                return String(firstNonSystem.prefix(24)) + (firstNonSystem.count > 24 ? "…" : "")
            }
        }
        return record.hasConversationFingerprint ? "会话 \(record.shortSessionLabel)" : "单次调用"
    }

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

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private func complexityColor(_ level: RoutingComplexityLevel) -> Color {
        switch level {
        case .low: return .green
        case .medium: return .blue
        case .high: return .purple
        case .direct: return .gray
        }
    }

    private func sessionPeers(for record: CallRecord) -> [CallRecord] {
        if let matchedBucket = mergedSessionBuckets(from: engine.callHistory)
            .first(where: { bucket in bucket.records.contains(where: { $0.id == record.id }) }) {
            return matchedBucket.records
        }
        return [record]
    }

    private var detailColumn: some View {
        Group {
            if let record = selectedRecord {
                let peers = sessionPeers(for: record)
                RoutingReceiptView(
                    record: record,
                    sessionRecords: peers,
                    sessionImpact: engine.sessionImpactSummary(for: peers),
                    onSelectRecord: { targetID in
                        selectedRecordID = targetID
                    }
                )
            } else {
                ContentUnavailableView {
                    Label("选择一条会话或调用", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                } description: {
                    Text("右侧将展示 Agent、合并后的模型调用路径图，以及耗时与 Token 消耗曲线。")
                }
            }
        }
    }
}
