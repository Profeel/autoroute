import Foundation

@MainActor
public extension AutoModelEngine {
    func runABExperiment(
        baselineModel: ModelConfig,
        prompt: String,
        repetitions: Int = 3,
        agentID: AgentKind? = nil,
        qualityAssessmentMethod: ABQualityAssessmentMethod = .notAssessed
    ) async -> ABExperimentReport {
        let requestParameters = ABRequestParameters(
            endpointPath: "engine://ab-experiment",
            stream: false,
            messageCount: 1,
            promptCharacterCount: prompt.count,
            includesTools: false,
            includesVision: false
        )
        let configuration = ABExperimentConfiguration(
            baselineModelID: baselineModel.modelID,
            autoRequestedModel: "auto",
            repetitions: repetitions,
            policyVersion: config.policy.policyVersion,
            agentID: agentID?.rawValue,
            policyStrategyName: config.policy.activeStrategy.displayName,
            requestParameters: requestParameters,
            qualityAssessmentMethod: qualityAssessmentMethod
        )
        var recordsBySession: [String: CallRecord] = [:]
        let report = await ABExperimentRunner().run(configuration: configuration) { run in
            let outcome = await executeChatCompletion(
                payload: [
                    "model": run.requestedModel,
                    "stream": run.parameters.stream,
                    "messages": [["role": "user", "content": prompt]]
                ],
                source: .testBench,
                sessionHeader: run.sessionID,
                clientName: "可复现 A/B 测试台",
                endpointPath: run.parameters.endpointPath,
                agentHeader: agentID?.rawValue
            )
            recordsBySession[run.sessionID] = outcome.callRecord
            return outcome.callRecord
        }

        await attachRealABComparisons(report: report, recordsBySession: recordsBySession, baselineModel: baselineModel)
        return report
    }

    private func attachRealABComparisons(
        report: ABExperimentReport,
        recordsBySession: [String: CallRecord],
        baselineModel: ModelConfig
    ) async {
        var changed = false
        for repetition in 0..<report.repetitions {
            guard let autoSample = report.samples.first(where: { $0.repetitionIndex == repetition && $0.side == .auto }),
                  let baselineSample = report.samples.first(where: { $0.repetitionIndex == repetition && $0.side == .baseline }),
                  autoSample.succeeded,
                  baselineSample.succeeded,
                  let autoRecord = recordsBySession[autoSample.sessionID] else {
                continue
            }
            let isMeasuredPair = autoSample.usageSource == .upstreamReported
                && baselineSample.usageSource == .upstreamReported
                && autoSample.measuredCostUSD != nil
                && baselineSample.measuredCostUSD != nil
                && autoSample.estimatedCostUSD == nil
                && baselineSample.estimatedCostUSD == nil
            let costDifference: Double?
            if isMeasuredPair,
               let autoMeasured = autoSample.measuredCostUSD,
               let baselineMeasured = baselineSample.measuredCostUSD {
                costDifference = baselineMeasured - autoMeasured
            } else {
                costDifference = nil
            }
            let savingsPercent: Double? = {
                guard let baselineMeasured = baselineSample.measuredCostUSD,
                      baselineMeasured > 0,
                      let costDifference else { return nil }
                return costDifference / baselineMeasured * 100
            }()
            setComparison(ComparisonAnalysis(
                basis: .realABTest,
                baselineModelID: baselineSample.executedModelID ?? baselineModel.modelID,
                baselineModelDisplayName: baselineModel.displayName,
                costDifferenceUSD: costDifference,
                costSavingsPercent: savingsPercent,
                latencyDifferenceMs: baselineSample.totalCompletionMs - autoSample.totalCompletionMs,
                sampleCount: 1,
                note: isMeasuredPair
                    ? "交错 A/B 独立会话；双方均为 upstreamReported 实测成本。"
                    : "交错 A/B 独立会话；存在本地估算或缺失成本，不进入实测成本对照。",
                isMeasuredPair: isMeasuredPair
            ), forRecordID: autoRecord.id)
            changed = true
        }
        if changed {
            await persistCallHistory()
        }
    }
}
