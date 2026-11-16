import AutoModelCore
import SwiftUI

struct RoutingPolicyView: View {
    @ObservedObject var engine: AutoModelEngine

    @State private var maxInputPriceText: String = ""
    @State private var maxOutputPriceText: String = ""
    @State private var priceSavedFeedback: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                modelTiersCard
                strategyPresetsCard
                pinnedAndFallbackCard
                hardConstraintsCard
                sessionAndRetryCard
                pluggableDeciderCard
            }
            .padding(20)
        }
        .navigationTitle("路由策略与三档模型")
        .onAppear {
            syncPriceTextFields()
        }
    }

    private var modelTiersCard: some View {
        let healthy = engine.healthyAvailableModels()
        let providersByID = Dictionary(uniqueKeysWithValues: engine.config.providers.map { ($0.id, $0) })

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("自动根据健康测活结果、单价与能力分配三档模型；您可随时下拉修改，接入 Agent 时也会同步提供 auto/low、auto/medium、auto/high。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("自动填补失效档位", isOn: Binding(
                        get: { engine.config.policy.autoConfigureTiers },
                        set: { val in
                            engine.updatePolicy { $0.autoConfigureTiers = val }
                            if val {
                                engine.autoConfigureModelTiers(forceResetManual: false)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)

                    Toggle("auto 优先按三档路由", isOn: Binding(
                        get: { engine.config.policy.preferTierMappingInAuto },
                        set: { val in
                            engine.updatePolicy { $0.preferTierMappingInAuto = val }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)

                    Button {
                        engine.autoConfigureModelTiers(forceResetManual: true)
                    } label: {
                        Label("重新自动推荐三档", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if healthy.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("暂无实测可用的健康模型，请先在「供应商与模型」添加供应商或点击「自动发掘本机模型并测活剔除」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(ModelTier.allCases) { tier in
                            tierColumnCard(
                                tier: tier,
                                healthyModels: healthy,
                                providersByID: providersByID
                            )
                        }
                    }
                }
            }
            .padding(6)
        } label: {
            Label("低 / 中 / 高三档模型配置（自动推荐 + 手动可改）", systemImage: "square.stack.3d.up")
                .font(.headline)
        }
    }

    private func tierColumnCard(
        tier: ModelTier,
        healthyModels: [ModelConfig],
        providersByID: [UUID: ProviderConfig]
    ) -> some View {
        let assignedID = engine.config.policy.modelID(for: tier)
        let assignedModel = engine.model(for: tier)
        let isManual = engine.config.policy.isManual(for: tier)
        let accent: Color = {
            switch tier {
            case .low: return .green
            case .medium: return .blue
            case .high: return .purple
            }
        }()

        // Ensure current assigned model appears in Picker even if temporarily unhealthy
        var selectableModels = healthyModels
        if let assignedModel, !selectableModels.contains(where: { $0.id == assignedModel.id }) {
            selectableModels.insert(assignedModel, at: 0)
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tier.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer()
                Text(tier.virtualModelID)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.14))
                    .foregroundStyle(accent)
                    .clipShape(Capsule())
            }

            Text(tier.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(tier.shortName, selection: Binding(
                get: { assignedID },
                set: { newID in
                    engine.setTierModel(tier: tier, modelUUID: newID, isManual: newID != nil)
                }
            )) {
                Text("未指定（按评分兜底）").tag(UUID?.none)
                ForEach(selectableModels) { model in
                    let pName = providersByID[model.providerID]?.name ?? ""
                    let suffix = model.isAutoEvicted ? " [已剔除]" : ""
                    Text("\(model.displayName)\(suffix)\(pName.isEmpty ? "" : " · \(pName)")")
                        .tag(UUID?.some(model.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Text(isManual ? "手动指定" : "自动推荐")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((isManual ? Color.orange : Color.secondary).opacity(0.14))
                    .foregroundStyle(isManual ? .orange : .secondary)
                    .clipShape(Capsule())

                if let latency = assignedModel?.lastProbeLatencyMs {
                    Text("测活 \(AutoModelFormatter.formatMs(latency))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let model = assignedModel {
                Text(AutoModelFormatter.formatPricePair(input: model.inputPricePerMillion, output: model.outputPricePerMillion))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if model.isAutoEvicted || !model.isEnabled || model.availabilityStatus != .available {
                    Text("⚠️ 当前模型已不可用 (\(model.availabilityStatus.displayName))")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var strategyPresetsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("开箱即用路由预设")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("当前策略版本: v\(engine.config.policy.policyVersion)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14))
                        .clipShape(Capsule())
                }

                HStack(spacing: 12) {
                    ForEach(RoutingStrategyPreset.allCases, id: \.self) { preset in
                        let selected = engine.config.policy.activeStrategy == preset
                        Button {
                            engine.setStrategy(preset)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(preset.displayName)
                                        .font(.headline)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text(preset.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                            .background(selected ? Color.accentColor.opacity(0.12) : Color(.controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(6)
        } label: {
            Label("选择模式", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
    }

    private var pinnedAndFallbackCard: some View {
        let models = engine.config.models.filter(\.isEnabled)
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("固定模型（可选覆盖）")
                            .font(.callout.weight(.medium))
                        Text("若固定某模型，通过硬约束检查后将始终优先使用它；否则按上方策略在其余模型中选择。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("固定模型", selection: Binding(
                        get: { engine.config.policy.pinnedModelID },
                        set: { newID in
                            engine.updatePolicy { $0.pinnedModelID = newID }
                        }
                    )) {
                        Text("不固定（由策略动态选择）").tag(UUID?.none)
                        ForEach(models) { model in
                            Text("\(model.displayName) (\(model.modelID))").tag(UUID?.some(model.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("默认回退模型")
                            .font(.callout.weight(.medium))
                        Text("当首选模型上游失败（超时/限流/5xx）且启用自动回退时，优先尝试该模型。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("回退模型", selection: Binding(
                        get: { engine.config.policy.fallbackModelID },
                        set: { newID in
                            engine.updatePolicy { $0.fallbackModelID = newID }
                        }
                    )) {
                        Text("自动按评分顺延下一候选").tag(UUID?.none)
                        ForEach(models) { model in
                            Text("\(model.displayName) (\(model.modelID))").tag(UUID?.some(model.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }
            }
            .padding(6)
        } label: {
            Label("固定与回退规则", systemImage: "pin")
                .font(.headline)
        }
    }

    private var hardConstraintsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("以下硬约束会在评分前执行；未通过的模型将在「路由收据」中明确列出排除原因：")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("• 供应商已启用且未鉴权失败 · 模型已启用且可用 · 请求所需 Tools / Vision 能力 · 输入 token 未超上下文上限")
                    .font(.caption)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("输入单价上限 ($ / 1M tokens，留空不限)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("例如 2.0", text: $maxInputPriceText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("输出单价上限 ($ / 1M tokens，留空不限)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("例如 10.0", text: $maxOutputPriceText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    Button("应用价格上限") {
                        applyPriceCaps()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 16)

                    Button("清除上限") {
                        maxInputPriceText = ""
                        maxOutputPriceText = ""
                        applyPriceCaps()
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 16)
                }

                if let priceSavedFeedback {
                    Text(priceSavedFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        } label: {
            Label("硬约束与预算上限", systemImage: "shield.checkered")
                .font(.headline)
        }
    }

    private var sessionAndRetryCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { engine.config.policy.enableSessionStickiness },
                    set: { val in engine.updatePolicy { $0.enableSessionStickiness = val } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("多轮会话保持模型稳定（缓存保护）")
                            .font(.callout.weight(.medium))
                        Text("同一多轮会话在同一策略版本下保持选定模型，避免因单轮微小价差频繁切换导致上下文缓存失效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Toggle(isOn: Binding(
                    get: { engine.config.policy.enableRetryOnUpstreamFailure },
                    set: { val in engine.updatePolicy { $0.enableRetryOnUpstreamFailure = val } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("上游失败时自动切换候选模型重试")
                            .font(.callout.weight(.medium))
                        Text("若首选上游返回错误或超时，自动顺延到回退模型；重试产生的全部记录与费用都会计入最终收据。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        } label: {
            Label("稳定性与容错", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
        }
    }

    private var pluggableDeciderCard: some View {
        let plugins = engine.router.availablePlugins()
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plugins, id: \.pluginID) { plugin in
                    HStack {
                        Image(systemName: plugin.pluginID == engine.config.policy.activeDeciderPluginID ? "checkmark.seal.fill" : "puzzlepiece")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.displayName)
                                .font(.callout.weight(.semibold))
                            Text("\(plugin.pluginID) — \(plugin.summary)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("当前启用")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    .padding(8)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Text("架构扩展点：RoutingDeciderPlugin 协议已预留可替换接口，未来用户可按需启用 Jev、本地小模型或自定义决策插件，但不作为第一版运行前提。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("路由决策模块（可替换架构）", systemImage: "puzzlepiece.extension")
                .font(.headline)
        }
    }

    private func syncPriceTextFields() {
        if let maxIn = engine.config.policy.maxInputPricePerMillion {
            maxInputPriceText = String(maxIn)
        }
        if let maxOut = engine.config.policy.maxOutputPricePerMillion {
            maxOutputPriceText = String(maxOut)
        }
    }

    private func applyPriceCaps() {
        let inTrimmed = maxInputPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outTrimmed = maxOutputPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxIn = inTrimmed.isEmpty ? nil : Double(inTrimmed)
        let maxOut = outTrimmed.isEmpty ? nil : Double(outTrimmed)

        if !inTrimmed.isEmpty && (maxIn == nil || maxIn! < 0) {
            priceSavedFeedback = "输入单价上限格式无效。"
            return
        }
        if !outTrimmed.isEmpty && (maxOut == nil || maxOut! < 0) {
            priceSavedFeedback = "输出单价上限格式无效。"
            return
        }

        engine.updatePolicy {
            $0.maxInputPricePerMillion = maxIn
            $0.maxOutputPricePerMillion = maxOut
        }
        priceSavedFeedback = "已更新价格上限硬约束（策略版本升至 v\(engine.config.policy.policyVersion)）。"
    }
}
