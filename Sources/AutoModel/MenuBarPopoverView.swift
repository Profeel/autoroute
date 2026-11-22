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

    @State private var currentDayKey = DailyUsageLedger.dayKey(for: Date())

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ConnectionStatusView(engine: engine, onNavigate: { onOpenMainWindow($0, nil) }, onOpenReceipt: { onOpenMainWindow(.history, $0) })
                    ActivitySummaryView(engine: engine, onOpenReceipt: { onOpenMainWindow(.history, $0) })
                    liveRoutingRow
                    DisclosureGroup("策略与档位") { strategyAndTiersSection }
                }
                .padding(14)
            }
            Divider()
            footerSection
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 320, height: 380)
        .onAppear {
            currentDayKey = DailyUsageLedger.dayKey(for: Date())
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            currentDayKey = DailyUsageLedger.dayKey(for: Date())
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            currentDayKey = DailyUsageLedger.dayKey(for: Date())
        }
    }

    private var liveRoutingRow: some View {
        let state = engine.liveRoutingState
        return HStack(spacing: 6) {
            if state.inFlightCount > 0 {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("正在使用")
                    .font(.caption.weight(.semibold))
                Text("\(state.targetModelDisplayName ?? "路由中…")")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            } else if let summary = state.lastCompletedSummary {
                Circle()
                    .fill(Color.blue.opacity(0.75))
                    .frame(width: 6, height: 6)
                Text("上次完成")
                    .font(.caption.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(engine.proxyState.isRunning ? "等待 Agent 请求…" : "代理已停止")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
    }

    private var strategyAndTiersSection: some View {
        let modelsByID = Dictionary(uniqueKeysWithValues: engine.config.models.map { ($0.id, $0) })
        return VStack(alignment: .leading, spacing: 8) {
            Picker("策略", selection: Binding(
                get: { engine.config.policy.activeStrategy },
                set: { engine.setStrategy($0) }
            )) {
                Text("省钱").tag(RoutingStrategyPreset.costFirst)
                Text("均衡").tag(RoutingStrategyPreset.balanced)
                Text("质量").tag(RoutingStrategyPreset.qualityFirst)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                ForEach(ModelTier.allCases) { tier in
                    let assignment = engine.config.policy.tierAssignment(for: tier)
                    let modelName = assignment.primaryModelID.flatMap { modelsByID[$0]?.displayName } ?? "自动"
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tier.shortName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(modelName)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color(.controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Button("打开主窗口") {
                onOpenMainWindow(nil, nil)
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
