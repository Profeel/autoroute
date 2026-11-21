import AutoModelCore
import Charts
import SwiftUI

struct PublicBenchmarkChartView: View {
    @ObservedObject var engine: AutoModelEngine
    @State private var selectedPointID: String?
    @State private var showingUnmatched = false

    var body: some View {
        let coverage = PublicBenchmarkCatalog.coverage(providers: engine.config.providers, models: engine.config.models)
        let points = coverage.points
        let litCount = points.filter(\.isLit).count
        let selected = points.first(where: { $0.id == selectedPointID }) ?? points.first(where: \.isLit) ?? points.first
        let maxCost = max(5, ceil((points.map(\.entry.avgCostPerTaskUSD).max() ?? 0) * 1.1 / 5) * 5)
        let minScore = max(0, floor((points.map(\.entry.benchmarkScore).min() ?? 0) / 10) * 10 - 10)
        let maxScore = ceil((points.map(\.entry.benchmarkScore).max() ?? 0) / 10) * 10 + 10
        let sortedPoints = points.sorted { lhs, rhs in
            if lhs.isLit != rhs.isLit { return lhs.isLit }
            return lhs.entry.benchmarkScore > rhs.entry.benchmarkScore
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PublicBenchmarkCatalog.benchmarkName)
                        .font(.subheadline.weight(.semibold))
                    Text("\(PublicBenchmarkCatalog.catalogVersion) · 离线快照 \(PublicBenchmarkCatalog.updatedAt) · 已启用 \(litCount)/\(points.count) 个参考模型")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("\(coverage.unmatchedModels.count) 个已启用模型未收录") {
                    showingUnmatched.toggle()
                }
                .buttonStyle(.link)
                .font(.caption2)
                .popover(isPresented: $showingUnmatched, arrowEdge: .bottom) {
                    unmatchedList(coverage.unmatchedModels)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("指数分数 ↑")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Chart {
                        if let selected {
                            RuleMark(x: .value("参考成本", maxCost - selected.entry.avgCostPerTaskUSD))
                                .foregroundStyle(Color.secondary.opacity(0.3))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            RuleMark(y: .value("指数", selected.entry.benchmarkScore))
                                .foregroundStyle(Color.secondary.opacity(0.3))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                        ForEach(points) { point in
                            PointMark(
                                x: .value("参考成本", maxCost - point.entry.avgCostPerTaskUSD),
                                y: .value("指数", point.entry.benchmarkScore)
                            )
                            .symbol {
                                benchmarkSymbol(point, selected: selected?.id == point.id)
                            }
                        }
                    }
                    .chartXScale(domain: 0...maxCost)
                    .chartYScale(domain: minScore...maxScore)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: maxCost / 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                                .foregroundStyle(Color.secondary.opacity(0.2))
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(String(format: "$%.0f", maxCost - v))
                                        .font(.system(size: 9).monospacedDigit())
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .stride(by: 10)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                                .foregroundStyle(Color.secondary.opacity(0.2))
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text("\(Int(v))")
                                        .font(.system(size: 9).monospacedDigit())
                                }
                            }
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    selectNearestPoint(at: location, proxy: proxy, geo: geo, points: points, maxCost: maxCost)
                                }
                                .onContinuousHover { phase in
                                    if case .active(let location) = phase {
                                        selectNearestPoint(at: location, proxy: proxy, geo: geo, points: points, maxCost: maxCost)
                                    }
                                }
                        }
                    }
                    .frame(height: 160)
                    Text("参考 API 成本 / 任务（USD）· 越省越靠右 →")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sortedPoints) { point in
                            Button {
                                selectedPointID = point.id
                            } label: {
                                HStack(spacing: 5) {
                                    benchmarkSymbol(point, selected: false)
                                    ModelFamilyIcon(modelID: point.id)
                                        .font(.system(size: 10))
                                    Text(point.entry.displayName)
                                        .font(.caption2)
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text("\(Int(point.entry.benchmarkScore))")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 3)
                                .background(selected?.id == point.id ? Color.primary.opacity(0.08) : .clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(point.entry.displayName)，\(point.isLit ? "已启用" : "未启用")，指数 \(Int(point.entry.benchmarkScore)) 分")
                        }
                    }
                }
                .frame(width: 205, height: 176)
            }

            if let selected {
                detailRow(for: selected)
            }
            Text("实心：已启用 · 空心：未启用。结果取决于所列 Agent 与推理配置，参考成本不等于当前渠道计费。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func benchmarkSymbol(_ point: MatchedBenchmarkPoint, selected: Bool) -> some View {
        let color = ModelChartPalette.color(for: point.id)
        return Circle()
            .fill(point.isLit ? color : Color(.controlBackgroundColor))
            .overlay(Circle().strokeBorder(color, lineWidth: point.isLit ? 1 : 1.7))
            .frame(width: selected ? 12 : 8, height: selected ? 12 : 8)
            .accessibilityHidden(true)
    }

    private func detailRow(for point: MatchedBenchmarkPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ModelFamilyIcon(modelID: point.id)
                Text(point.entry.displayName).font(.caption.weight(.semibold))
                Text(point.isLit ? "已启用" : "未启用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: "指数 %.0f 分 · $%.2f / 任务", point.entry.benchmarkScore, point.entry.avgCostPerTaskUSD))
                    .font(.caption2.monospacedDigit())
                Text("\(point.entry.harness) · \(point.entry.configuration)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Link("原始结果", destination: point.entry.sourceURL)
                Link("方法", destination: PublicBenchmarkCatalog.methodologyURL)
            }
            .font(.caption2)
            if let note = point.entry.versionNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            if let summary = point.channelSummaryLabel {
                Text("已启用通道：\(summary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private func unmatchedList(_ models: [UnmatchedBenchmarkModel]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已启用但此快照未收录")
                .font(.headline)
            Text("此图不推断这些模型是否有其他公开结果，也不赋予估算分数。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if models.isEmpty {
                Text("没有未覆盖的已启用模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(models) { model in
                            HStack {
                                ModelFamilyIcon(modelID: model.id)
                                Text(model.displayName).lineLimit(1)
                                Spacer()
                                if model.channelCount > 1 {
                                    Text("\(model.channelCount) 通道").foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
    }

    private func selectNearestPoint(
        at location: CGPoint,
        proxy: ChartProxy,
        geo: GeometryProxy,
        points: [MatchedBenchmarkPoint],
        maxCost: Double
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geo[plotFrame]
        let relX = location.x - frame.origin.x
        let relY = location.y - frame.origin.y
        guard relX >= 0, relY >= 0, relX <= frame.width, relY <= frame.height else { return }
        var bestID: String?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for point in points {
            guard let position = proxy.position(for: (x: maxCost - point.entry.avgCostPerTaskUSD, y: point.entry.benchmarkScore)) else { continue }
            let distance = hypot(position.x - relX, position.y - relY)
            if distance < bestDist {
                bestDist = distance
                bestID = point.id
            }
        }
        if bestDist <= 24 { selectedPointID = bestID }
    }
}
