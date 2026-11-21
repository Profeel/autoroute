import AppKit
import AutoModelCore
import SwiftUI

struct CallHistoryView: View {
    @ObservedObject var engine: AutoModelEngine
    var requestedRecordID: UUID? = nil
    var onConsumeRequestedRecord: (() -> Void)? = nil
    var onNavigateToProviders: (() -> Void)? = nil
    var onNavigate: ((SidebarTab) -> Void)? = nil

    @State private var selectedRecordID: UUID?
    @State private var inspectedTurnRecord: CallRecord?
    @State private var filterMode: FilterMode = .all
    @State private var groupMode: GroupMode = .bySession
    @State private var searchText: String = ""
    @State private var clearHistoryError: String?
    @State private var showClearHistoryError = false
    @State private var cachedFilteredRecords: [CallRecord] = []
    @State private var cachedSessionItems: [SessionSummaryItem] = []
    @State private var cachedSignature: String = ""

    enum FilterMode: String, CaseIterable {
        case all = "全部"
        case success = "成功"
        case failed = "失败"
    }

    enum GroupMode: String, CaseIterable {
        case bySession = "按会话任务"
        case chronological = "按单次调用"
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

    private var listCacheSignature: String {
        let headID = engine.callHistory.first?.id.uuidString ?? "empty"
        let tailID = engine.callHistory.last?.id.uuidString ?? "empty"
        let hasHermes = engine.agentStatuses.contains(where: { $0.kind == .hermes && $0.isConnectedToAutoModel })
        return "\(engine.callHistory.count)|\(headID)|\(tailID)|\(filterMode.rawValue)|\(searchText)|\(hasHermes)"
    }

    private var baseFilteredRecords: [CallRecord] {
        if cachedSignature == listCacheSignature {
            return cachedFilteredRecords
        }
        return computeFilteredRecords()
    }

    private var sessionItems: [SessionSummaryItem] {
        if cachedSignature == listCacheSignature {
            return cachedSessionItems
        }
        return computeSessionItems(from: computeFilteredRecords())
    }

    private func rebuildListCache() {
        let sig = listCacheSignature
        guard sig != cachedSignature else { return }
        let filtered = computeFilteredRecords()
        cachedFilteredRecords = filtered
        cachedSessionItems = computeSessionItems(from: filtered)
        cachedSignature = sig
    }

    private func computeFilteredRecords() -> [CallRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return engine.callHistory.filter { record in
            switch filterMode {
            case .all: break
            case .success: if record.status != .success { return false }
            case .failed: if record.status == .success { return false }
            }
            if !query.isEmpty {
                let haystacks = [
                    record.requestedModel,
                    record.executedModelID ?? "",
                    record.executedModelDisplayName ?? "",
                    record.executedProviderName ?? "",
                    record.displayClientAgent,
                    record.requestPreview ?? ""
                ]
                if !haystacks.contains(where: { $0.lowercased().contains(query) }) {
                    return false
                }
            }
            return true
        }
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

    private var selectedSession: SessionSummaryItem? {
        if let current = selectedRecord,
           let matched = sessionItems.first(where: { $0.recordsChronological.contains(where: { $0.id == current.id }) }) {
            return matched
        }
        return sessionItems.first
    }

    var body: some View {
        VStack(spacing: 12) {
            ConnectionStatusView(engine: engine, onNavigate: { onNavigate?($0) }, onOpenReceipt: openReceipt)
            ActivitySummaryView(engine: engine, onOpenReceipt: openReceipt)
            DisclosureGroup("策略、档位与统计详情") {
                VStack(spacing: 10) {
                    LiveRoutingBannerView(engine: engine)
                    StrategyTierStripView(engine: engine)
                    SavingsDetailsView(engine: engine)
                    TodayOverviewChartsView(engine: engine)
                }.padding(.top, 6)
            }

            // 4. History Split Workspace
            VStack(spacing: 0) {
                historyToolbar
                Divider()
                historySplitBody
            }
            .background(Color(.controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .padding(14)
        .onAppear {
            rebuildListCache()
            consumeRequestedRecordIfNeeded()
        }
        .onChange(of: listCacheSignature) { _, _ in
            rebuildListCache()
        }
        .onChange(of: requestedRecordID) { _, _ in
            consumeRequestedRecordIfNeeded()
        }
        .sheet(item: $inspectedTurnRecord) { record in
            VStack(spacing: 0) {
                HStack {
                    Text("单次路由收据 · \(record.executedModelShortLabel)")
                        .font(.headline)
                    Spacer()
                    Button("关闭") {
                        inspectedTurnRecord = nil
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                RoutingReceiptView(
                    record: record,
                    sessionRecords: sessionPeers(for: record),
                    sessionImpact: engine.sessionImpactSummary(for: sessionPeers(for: record))
                )
            }
            .frame(minWidth: 720, minHeight: 540)
        }
        .alert("清除历史失败", isPresented: $showClearHistoryError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(clearHistoryError ?? "未知错误")
        }
    }

    private var historyToolbar: some View {
        HStack(spacing: 10) {
            Picker("视图模式", selection: $groupMode) {
                ForEach(GroupMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)

            Picker("状态", selection: $filterMode) {
                ForEach(FilterMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

            TextField("搜索 Agent / 模型 / 提示词…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Spacer()

            if !engine.callHistory.isEmpty {
                Button("清空列表") {
                    do {
                        try engine.clearCallHistory()
                        selectedRecordID = nil
                    } catch {
                        clearHistoryError = error.localizedDescription
                        showClearHistoryError = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var historySplitBody: some View {
        if baseFilteredRecords.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(engine.callHistory.isEmpty ? "暂无路由记录" : "当前筛选条件下无匹配记录")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                if engine.config.providers.filter(\.isEnabled).isEmpty, let onNavigateToProviders {
                    Button("前往「提供商」接入模型") {
                        onNavigateToProviders()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            HSplitView {
                Group {
                    if groupMode == .bySession {
                        List(sessionItems, selection: Binding(
                            get: { selectedSession?.id },
                            set: { newKey in
                                if let newKey, let matched = sessionItems.first(where: { $0.id == newKey }) {
                                    selectedRecordID = matched.representativeRecord.id
                                }
                            }
                        )) { session in
                            sessionRow(session)
                                .tag(session.id)
                        }
                        .listStyle(.inset)
                    } else {
                        List(baseFilteredRecords, selection: Binding(
                            get: { selectedRecord?.id },
                            set: { selectedRecordID = $0 }
                        )) { record in
                            singleCallRow(record)
                                .tag(record.id)
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 290, idealWidth: 330, maxWidth: 400)

                Group {
                    if groupMode == .bySession, let session = selectedSession {
                        SessionTaskDetailView(
                            engine: engine,
                            agentName: session.agentName,
                            title: session.title,
                            recordsChronological: session.recordsChronological,
                            switchCount: session.switchCount,
                            totalDurationMs: session.totalDurationMs,
                            totalTokens: session.totalTokens,
                            totalCostUSD: session.totalCostUSD,
                            onSelectTurn: { turn in
                                inspectedTurnRecord = turn
                            }
                        )
                    } else if let record = selectedRecord {
                        let peers = sessionPeers(for: record)
                        RoutingReceiptView(
                            record: record,
                            sessionRecords: peers,
                            sessionImpact: engine.sessionImpactSummary(for: peers),
                            onSelectRecord: { selectedRecordID = $0 }
                        )
                    } else {
                        Text("选择一条记录查看详情")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func sessionRow(_ session: SessionSummaryItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.hasFailure ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text(session.agentName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(session.latestTimestamp, style: .relative)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(session.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(AutoModelFormatter.formatMs(session.totalDurationMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("切换 \(session.switchCount) 次")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(session.switchCount > 0 ? .blue : .secondary)
                Spacer()
                Text(session.totalCostUSD.map { AutoModelFormatter.formatUSD($0) } ?? "未定价")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func singleCallRow(_ record: CallRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(record.status == .success ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(record.executedModelShortLabel)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(AutoModelFormatter.formatMs(record.totalCompletionMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(record.displayClientAgent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let provider = record.executedProviderName {
                    Text("· \(provider)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if let cost = record.totalCostUSD {
                    Text(AutoModelFormatter.formatUSD(cost))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func consumeRequestedRecordIfNeeded() {
        guard let reqID = requestedRecordID else { return }
        openReceipt(reqID)
        onConsumeRequestedRecord?()
    }

    private func openReceipt(_ id: UUID) {
        selectedRecordID = id
        inspectedTurnRecord = engine.callHistory.first { $0.id == id }
    }

    // MARK: - Session Aggregation Helpers

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

    private func computeSessionItems(from records: [CallRecord]) -> [SessionSummaryItem] {
        mergedSessionBuckets(from: records).compactMap { bucket in
            let chronological = bucket.records
            guard let latest = chronological.last, let oldest = chronological.first else { return nil }

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

            return SessionSummaryItem(
                id: bucket.key,
                representativeRecord: latest,
                recordsChronological: chronological,
                agentName: resolvedAgentLabel(for: chronological),
                title: cleanSessionTitle(for: oldest),
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

    private func sessionPeers(for record: CallRecord) -> [CallRecord] {
        if let matchedBucket = mergedSessionBuckets(from: engine.callHistory)
            .first(where: { bucket in bucket.records.contains(where: { $0.id == record.id }) }) {
            return matchedBucket.records
        }
        return [record]
    }
}
