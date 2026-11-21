import Foundation

public enum ABRunSide: String, Codable, Equatable, Sendable {
    case auto
    case baseline
}

public enum ABQualityAssessmentMethod: String, Codable, Equatable, Sendable {
    case notAssessed = "not_assessed"
    case humanReview = "human_review"
    case deterministicExactMatch = "deterministic_exact_match"
}

public struct ABRequestParameters: Codable, Equatable, Hashable, Sendable {
    public var endpointPath: String
    public var stream: Bool
    public var messageCount: Int
    public var promptCharacterCount: Int
    public var includesTools: Bool
    public var includesVision: Bool

    public init(
        endpointPath: String = "engine://ab-experiment",
        stream: Bool = false,
        messageCount: Int = 1,
        promptCharacterCount: Int = 0,
        includesTools: Bool = false,
        includesVision: Bool = false
    ) {
        self.endpointPath = endpointPath
        self.stream = stream
        self.messageCount = max(0, messageCount)
        self.promptCharacterCount = max(0, promptCharacterCount)
        self.includesTools = includesTools
        self.includesVision = includesVision
    }
}

public struct ABExperimentConfiguration: Equatable, Sendable {
    public var baselineModelID: String
    public var autoRequestedModel: String
    public var repetitions: Int
    public var policyVersion: Int
    public var sampleVersion: String
    public var agentID: String?
    public var policyStrategyName: String
    public var requestParameters: ABRequestParameters
    public var qualityAssessmentMethod: ABQualityAssessmentMethod

    public init(
        baselineModelID: String,
        autoRequestedModel: String = "auto",
        repetitions: Int,
        policyVersion: Int,
        sampleVersion: String = "public-text-v1",
        agentID: String? = nil,
        policyStrategyName: String = "均衡模式",
        requestParameters: ABRequestParameters = ABRequestParameters(),
        qualityAssessmentMethod: ABQualityAssessmentMethod = .notAssessed
    ) {
        self.baselineModelID = baselineModelID
        self.autoRequestedModel = autoRequestedModel
        self.repetitions = max(1, repetitions)
        self.policyVersion = policyVersion
        self.sampleVersion = sampleVersion
        self.agentID = agentID
        self.policyStrategyName = policyStrategyName
        self.requestParameters = requestParameters
        self.qualityAssessmentMethod = qualityAssessmentMethod
    }
}

public struct ABRunRequest: Equatable, Sendable {
    public var side: ABRunSide
    public var repetitionIndex: Int
    public var sessionID: String
    public var requestedModel: String
    public var parameters: ABRequestParameters

    public init(
        side: ABRunSide,
        repetitionIndex: Int,
        sessionID: String,
        requestedModel: String,
        parameters: ABRequestParameters
    ) {
        self.side = side
        self.repetitionIndex = repetitionIndex
        self.sessionID = sessionID
        self.requestedModel = requestedModel
        self.parameters = parameters
    }
}

public struct ABExperimentSample: Codable, Equatable, Sendable {
    public var repetitionIndex: Int
    public var side: ABRunSide
    public var sessionID: String
    public var timestamp: String
    public var requestedModel: String
    public var executedModelID: String?
    public var agentID: String?
    public var succeeded: Bool
    public var httpStatusCode: Int
    public var routingDecisionMs: Double
    public var upstreamFirstTokenMs: Double?
    public var totalCompletionMs: Double
    public var retryCount: Int
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var usageSource: UsageDataSource
    public var totalCostUSD: Double?
    public var measuredCostUSD: Double?
    public var estimatedCostUSD: Double?
    public var costStatus: CostCalculationStatus

    public init(run: ABRunRequest, record: CallRecord) {
        repetitionIndex = run.repetitionIndex
        side = run.side
        sessionID = run.sessionID
        timestamp = ISO8601DateFormatter().string(from: record.timestamp)
        requestedModel = record.requestedModel
        executedModelID = record.executedModelID
        agentID = record.decision.agentID
        succeeded = record.status == .success
        httpStatusCode = record.httpStatusCode
        routingDecisionMs = record.routingDecisionMs
        upstreamFirstTokenMs = record.upstreamFirstTokenMs
        totalCompletionMs = record.totalCompletionMs
        retryCount = max(0, record.attempts.count - 1)
        promptTokens = record.finalUsage?.promptTokens
        completionTokens = record.finalUsage?.completionTokens
        totalTokens = record.finalUsage?.totalTokens
        usageSource = record.usageSource
        let attemptCosts = record.attempts.compactMap(\.costUSD)
        totalCostUSD = record.totalCostUSD ?? (attemptCosts.isEmpty ? nil : attemptCosts.reduce(0, +))
        let measuredCosts = record.attempts
            .filter { $0.usageSource == .upstreamReported }
            .compactMap(\.costUSD)
        let estimatedCosts = record.attempts
            .filter { $0.usageSource == .estimatedWhenMissing }
            .compactMap(\.costUSD)
        measuredCostUSD = measuredCosts.isEmpty ? nil : measuredCosts.reduce(0, +)
        estimatedCostUSD = estimatedCosts.isEmpty ? nil : estimatedCosts.reduce(0, +)
        costStatus = record.costStatus
    }
}

public struct ABExperimentSummary: Codable, Equatable, Sendable {
    public var comparablePricedPairs: Int
    public var measuredCostDifferenceUSD: Double?
    public var estimatedCostDifferenceUSD: Double?
    public var meanLatencyDifferenceMs: Double?
    public var autoSuccessCount: Int
    public var baselineSuccessCount: Int
    public var costNote: String
    public var qualityNote: String
}

public struct ABExperimentReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var definitionVersion: String
    public var createdAt: String
    public var policyVersion: Int
    public var baselineModelID: String
    public var autoRequestedModel: String
    public var repetitions: Int
    public var sampleVersion: String
    public var agentID: String?
    public var policyStrategyName: String
    public var requestParameters: ABRequestParameters
    public var qualityAssessmentMethod: ABQualityAssessmentMethod
    public var samples: [ABExperimentSample]
    public var summary: ABExperimentSummary

    public init(
        schemaVersion: Int = 2,
        definitionVersion: String = "ab-report-v2",
        createdAt: String,
        policyVersion: Int,
        baselineModelID: String,
        autoRequestedModel: String,
        repetitions: Int,
        sampleVersion: String = "public-text-v1",
        agentID: String? = nil,
        policyStrategyName: String = "均衡模式",
        requestParameters: ABRequestParameters = ABRequestParameters(),
        qualityAssessmentMethod: ABQualityAssessmentMethod,
        samples: [ABExperimentSample],
        summary: ABExperimentSummary
    ) {
        self.schemaVersion = schemaVersion
        self.definitionVersion = definitionVersion
        self.createdAt = createdAt
        self.policyVersion = policyVersion
        self.baselineModelID = baselineModelID
        self.autoRequestedModel = autoRequestedModel
        self.repetitions = repetitions
        self.sampleVersion = sampleVersion
        self.agentID = agentID
        self.policyStrategyName = policyStrategyName
        self.requestParameters = requestParameters
        self.qualityAssessmentMethod = qualityAssessmentMethod
        self.samples = samples
        self.summary = summary
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public struct ABExperimentRunner: Sendable {
    public init() {}

    public func run(
        configuration: ABExperimentConfiguration,
        now: Date = Date(),
        executor: (ABRunRequest) async -> CallRecord
    ) async -> ABExperimentReport {
        var samples: [ABExperimentSample] = []
        for repetition in 0..<configuration.repetitions {
            let sides: [ABRunSide] = repetition.isMultiple(of: 2) ? [.auto, .baseline] : [.baseline, .auto]
            for side in sides {
                let run = ABRunRequest(
                    side: side,
                    repetitionIndex: repetition,
                    sessionID: "ab-\(UUID().uuidString)",
                    requestedModel: side == .auto ? configuration.autoRequestedModel : configuration.baselineModelID,
                    parameters: configuration.requestParameters
                )
                let record = await executor(run)
                samples.append(ABExperimentSample(run: run, record: record))
            }
        }

        var pricedPairs = 0
        var measuredDifferences: [Double] = []
        var estimatedDifferences: [Double] = []
        var latencyDifferences: [Double] = []
        for repetition in 0..<configuration.repetitions {
            guard let auto = samples.first(where: { $0.repetitionIndex == repetition && $0.side == .auto }),
                  let baseline = samples.first(where: { $0.repetitionIndex == repetition && $0.side == .baseline }) else {
                continue
            }
            if auto.totalCostUSD != nil && baseline.totalCostUSD != nil {
                pricedPairs += 1
            }
            if let autoMeasured = auto.measuredCostUSD, let baselineMeasured = baseline.measuredCostUSD {
                measuredDifferences.append(baselineMeasured - autoMeasured)
            }
            if let autoEstimated = auto.estimatedCostUSD, let baselineEstimated = baseline.estimatedCostUSD {
                estimatedDifferences.append(baselineEstimated - autoEstimated)
            }
            latencyDifferences.append(baseline.totalCompletionMs - auto.totalCompletionMs)
        }

        let missingPrice = pricedPairs < configuration.repetitions
        let qualityNote: String
        switch configuration.qualityAssessmentMethod {
        case .notAssessed:
            qualityNote = "本报告未评估输出质量，不能声称质量不下降或成功率等价。"
        case .humanReview:
            qualityNote = "质量字段仅记录人工复核方法；结论仍需查看逐样本复核证据。"
        case .deterministicExactMatch:
            qualityNote = "质量字段仅记录确定性精确匹配方法；不覆盖开放式回答质量。"
        }
        let summary = ABExperimentSummary(
            comparablePricedPairs: pricedPairs,
            measuredCostDifferenceUSD: measuredDifferences.isEmpty ? nil : measuredDifferences.reduce(0, +),
            estimatedCostDifferenceUSD: estimatedDifferences.isEmpty ? nil : estimatedDifferences.reduce(0, +),
            meanLatencyDifferenceMs: latencyDifferences.isEmpty ? nil : latencyDifferences.reduce(0, +) / Double(latencyDifferences.count),
            autoSuccessCount: samples.filter { $0.side == .auto && $0.succeeded }.count,
            baselineSuccessCount: samples.filter { $0.side == .baseline && $0.succeeded }.count,
            costNote: missingPrice
                ? "存在未定价或缺少费用的样本，未按 0 元处理；成本差只统计双方同口径且均有价格的配对。"
                : "成本差为固定基线费用减去 auto 实际费用；按每个 attempt 的 usage 来源拆分实测与本地估算。",
            qualityNote: qualityNote
        )
        return ABExperimentReport(
            createdAt: ISO8601DateFormatter().string(from: now),
            policyVersion: configuration.policyVersion,
            baselineModelID: configuration.baselineModelID,
            autoRequestedModel: configuration.autoRequestedModel,
            repetitions: configuration.repetitions,
            sampleVersion: configuration.sampleVersion,
            agentID: configuration.agentID,
            policyStrategyName: configuration.policyStrategyName,
            requestParameters: configuration.requestParameters,
            qualityAssessmentMethod: configuration.qualityAssessmentMethod,
            samples: samples,
            summary: summary
        )
    }
}
