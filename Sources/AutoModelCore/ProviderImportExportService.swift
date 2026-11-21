import Foundation

public struct ProviderImportResult: Equatable, Sendable {
    public var addedProvidersCount: Int
    public var updatedProvidersCount: Int
    public var addedModelsCount: Int
    public var importedProviderNames: [String]

    public init(
        addedProvidersCount: Int,
        updatedProvidersCount: Int,
        addedModelsCount: Int,
        importedProviderNames: [String]
    ) {
        self.addedProvidersCount = addedProvidersCount
        self.updatedProvidersCount = updatedProvidersCount
        self.addedModelsCount = addedModelsCount
        self.importedProviderNames = importedProviderNames
    }
}

public enum ProviderImportError: Error, LocalizedError, Sendable {
    case invalidJSON
    case noProvidersFound
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "无法解析 JSON 文件；请选择有效的 Magpie providers.json 或 AutoRoute 供应商模板文件。"
        case .noProvidersFound:
            return "文件中未找到可导入的启用供应商配置。"
        case .fileNotFound(let path):
            return "未找到文件：\(path)"
        }
    }
}

public struct PortableModelTemplate: Codable, Equatable, Sendable {
    public var modelID: String
    public var displayName: String
    public var contextWindow: Int
    public var capabilities: Set<ModelCapability>
    public var defaultRole: ModelDefaultUsage
    public var qualityScore: Int
    public var speedScore: Int
    public var inputPricePerMillion: Double?
    public var outputPricePerMillion: Double?
    public var cachedInputPricePerMillion: Double?
    public var cacheCreationPricePerMillion: Double?
    public var maxRequestsPerMinute: Int?
}

public struct PortableProviderTemplate: Codable, Equatable, Sendable {
    public var name: String
    public var baseURL: String
    public var apiProtocol: ProviderProtocol
    public var timeoutSeconds: Double
    public var maxConcurrentRequests: Int?
    public var presetID: String?
    public var customHeaders: [String: String]
    public var passThroughHeaderNames: [String]
    public var proxyURL: String?
    public var keyRotationStrategy: ProviderKeyRotationStrategy
    public var models: [PortableModelTemplate]
}

public struct PortableProviderTemplateBundle: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var app: String
    public var exportedAt: Date
    public var providers: [PortableProviderTemplate]

    public init(
        schemaVersion: Int = 1,
        app: String = "AutoRoute",
        exportedAt: Date = Date(),
        providers: [PortableProviderTemplate]
    ) {
        self.schemaVersion = schemaVersion
        self.app = app
        self.exportedAt = exportedAt
        self.providers = providers
    }
}

public enum ProviderImportExportService {
    public static func defaultMagpieProvidersURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("magpie", isDirectory: true)
            .appendingPathComponent("providers.json")
    }

    public static func parseImportData(_ data: Data) throws -> [DiscoveredProviderEntry] {
        guard let rootObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderImportError.invalidJSON
        }

        // 1. AutoRoute portable sanitized template bundle
        if (rootObj["app"] as? String) == "AutoRoute",
           rootObj["schemaVersion"] != nil {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let bundle = try? dec.decode(PortableProviderTemplateBundle.self, from: data) {
                let entries = bundle.providers.map { p -> DiscoveredProviderEntry in
                    let models = p.models.map { m in
                        DiscoveredModelEntry(
                            modelID: m.modelID,
                            displayName: m.displayName,
                            inputPricePerMillion: m.inputPricePerMillion,
                            outputPricePerMillion: m.outputPricePerMillion,
                            contextWindow: m.contextWindow,
                            capabilities: m.capabilities,
                            defaultRole: m.defaultRole,
                            qualityScore: m.qualityScore,
                            speedScore: m.speedScore,
                            source: "autoroute/template"
                        )
                    }
                    return DiscoveredProviderEntry(
                        name: p.name,
                        baseURL: p.baseURL,
                        apiKey: nil,
                        apiKeys: [],
                        source: "autoroute/template",
                        models: models,
                        apiProtocol: p.apiProtocol,
                        customHeaders: p.customHeaders,
                        passThroughHeaderNames: p.passThroughHeaderNames,
                        proxyURL: p.proxyURL,
                        presetID: p.presetID
                    )
                }
                if !entries.isEmpty { return entries }
            }
        }

        // 2. Magpie providers.json format
        let magpieEntries = LocalModelDiscoveryService.parseMagpieProviders(
            from: data,
            sourceLabel: "magpie/providers.json",
            requireAPIKey: false
        )
        if !magpieEntries.isEmpty {
            return magpieEntries
        }

        throw ProviderImportError.noProvidersFound
    }

    public static func exportSanitizedTemplate(
        providers: [ProviderConfig],
        models: [ModelConfig],
        secretsToRedact: [String]
    ) throws -> Data {
        let modelsByProvider = Dictionary(grouping: models, by: \.providerID)
        let templates = providers.map { p -> PortableProviderTemplate in
            let safeHeaders = sanitizeHeadersForExport(p.customHeaders)
            let pModels = (modelsByProvider[p.id] ?? []).map { m in
                PortableModelTemplate(
                    modelID: m.modelID,
                    displayName: m.displayName,
                    contextWindow: m.contextWindow,
                    capabilities: m.capabilities,
                    defaultRole: m.defaultRole,
                    qualityScore: m.qualityScore,
                    speedScore: m.speedScore,
                    inputPricePerMillion: m.inputPricePerMillion,
                    outputPricePerMillion: m.outputPricePerMillion,
                    cachedInputPricePerMillion: m.cachedInputPricePerMillion,
                    cacheCreationPricePerMillion: m.cacheCreationPricePerMillion,
                    maxRequestsPerMinute: m.maxRequestsPerMinute
                )
            }
            return PortableProviderTemplate(
                name: p.name,
                baseURL: p.baseURL,
                apiProtocol: p.apiProtocol,
                timeoutSeconds: p.timeoutSeconds,
                maxConcurrentRequests: p.maxConcurrentRequests,
                presetID: p.presetID,
                customHeaders: safeHeaders,
                passThroughHeaderNames: p.passThroughHeaderNames,
                proxyURL: p.proxyURL,
                keyRotationStrategy: p.keyRotationStrategy,
                models: pModels
            )
        }
        let bundle = PortableProviderTemplateBundle(providers: templates)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let rawData = try enc.encode(bundle)
        guard let rawText = String(data: rawData, encoding: .utf8) else {
            return rawData
        }
        let redacted = SecretRedactor.redact(rawText, secrets: secretsToRedact)
        return Data(redacted.utf8)
    }

    static func sanitizeHeadersForExport(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        let sensitiveSubstrings = ["auth", "token", "key", "secret", "cookie"]
        for (k, v) in headers {
            let lower = k.lowercased()
            if sensitiveSubstrings.contains(where: { lower.contains($0) }) {
                result[k] = "[REDACTED]"
            } else {
                result[k] = v
            }
        }
        return result
    }
}
