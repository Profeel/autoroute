import Foundation

@MainActor
public final class AutoModelEngine: ObservableObject {
    public enum ProxyRuntimeState: Equatable, Sendable {
        case stopped
        case running(port: Int)
        case portConflict(port: Int, suggestedPort: Int?)
        case error(String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        public var statusText: String {
            switch self {
            case .stopped:
                return "已停止"
            case .running(let port):
                return "运行中 127.0.0.1:\(port)"
            case .portConflict(let port, _):
                return "端口 \(port) 被占用"
            case .error(let msg):
                return "启动异常: \(msg)"
            }
        }
    }

    @Published public private(set) var config: AppConfigBundle
    @Published public private(set) var callHistory: [CallRecord]
    @Published public private(set) var proxyState: ProxyRuntimeState = .stopped
    @Published public private(set) var isLocalTestUpstreamRunning: Bool = false
    @Published public private(set) var localTestUpstreamPort: Int?
    @Published public private(set) var lastPersistenceError: String?
    @Published public private(set) var isDiscoveringAndProbing: Bool = false
    @Published public private(set) var probeProgressText: String?
    @Published public private(set) var lastDiscoverySummary: DiscoveryAndProbeSummary?
    @Published public private(set) var agentStatuses: [AgentIntegrationStatus] = []
    @Published public private(set) var probeAuditLogs: [String] = []
    @Published public private(set) var portSyncNeededForConnectedAgents: Bool = false

    public let persistence: LocalPersistenceStore
    public let keychain: any KeychainServiceProtocol
    public let router: ModelRouter
    public let upstreamClient: UpstreamClient
    public let discoveryService: LocalModelDiscoveryService
    public let agentConfigService: AgentConfigService
    public let localTestUpstream: LocalTestUpstreamServer
    private var proxyServer: ProxyServer?
    private var backgroundMaintenanceTask: Task<Void, Never>?

    public init(
        persistence: LocalPersistenceStore = LocalPersistenceStore(),
        keychain: any KeychainServiceProtocol = MacOSKeychainService(),
        router: ModelRouter = ModelRouter(),
        upstreamClient: UpstreamClient = UpstreamClient(),
        discoveryService: LocalModelDiscoveryService = LocalModelDiscoveryService(),
        agentConfigService: AgentConfigService? = nil,
        autoStartProxyIfConfigured: Bool = true
    ) {
        self.persistence = persistence
        self.keychain = keychain
        self.router = router
        self.upstreamClient = upstreamClient
        self.discoveryService = discoveryService
        self.agentConfigService = agentConfigService ?? AgentConfigService(
            backupDirectory: persistence.baseDirectoryURL.appendingPathComponent("agent_backups", isDirectory: true)
        )
        self.localTestUpstream = LocalTestUpstreamServer()

        self.config = persistence.loadConfig()
        self.callHistory = persistence.loadHistory()
        self.autoConfigureModelTiers(forceResetManual: false)
        self.refreshAgentStatuses()

        if autoStartProxyIfConfigured && config.proxySettings.autoStartProxy {
            startProxy()
        }
        if autoStartProxyIfConfigured {
            startBackgroundDiscoveryAndHealthLoop()
        }
    }

    // MARK: - Proxy Lifecycle

    public func startProxy() {
        let port = config.proxySettings.port
        if proxyServer == nil {
            proxyServer = ProxyServer(engine: self)
        }
        do {
            let actualPort = try proxyServer!.start(port: port)
            proxyState = .running(port: actualPort)
        } catch let err as LoopbackServerError {
            switch err {
            case .portInUse(let occupiedPort):
                let suggestion = LoopbackHTTPServer.findAvailablePort(startingFrom: occupiedPort + 1)
                proxyState = .portConflict(port: occupiedPort, suggestedPort: suggestion)
            default:
                proxyState = .error(err.localizedDescription)
            }
        } catch {
            proxyState = .error(error.localizedDescription)
        }
    }

    public func stopProxy() {
        proxyServer?.stop()
        proxyState = .stopped
    }

    public func stopBackgroundTasks() {
        backgroundMaintenanceTask?.cancel()
        backgroundMaintenanceTask = nil
    }

    private func startBackgroundDiscoveryAndHealthLoop() {
        backgroundMaintenanceTask?.cancel()
        backgroundMaintenanceTask = Task { [weak self] in
            guard let self else { return }
            if self.config.proxySettings.autoDiscoverAndProbeOnLaunch {
                _ = await self.discoverAndProbeLocalModels()
            }
            while !Task.isCancelled {
                let mins = self.config.proxySettings.periodicHealthCheckMinutes
                if mins <= 0 {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    continue
                }
                try? await Task.sleep(nanoseconds: UInt64(mins) * 60 * 1_000_000_000)
                if Task.isCancelled { break }
                _ = await self.probeAllEnabledModels()
            }
        }
    }

    public func updateProxyPort(_ newPort: Int) {
        let portChanged = config.proxySettings.port != newPort
        config.proxySettings.port = newPort
        saveConfig()
        if proxyState.isRunning || proxyState != .stopped {
            startProxy()
        }
        if portChanged {
            let previouslyConnected = agentStatuses.contains { $0.isConnectedToAutoModel }
            refreshAgentStatuses()
            portSyncNeededForConnectedAgents = previouslyConnected
        } else {
            refreshAgentStatuses()
        }
    }

    public func updateAutoStartProxy(_ enabled: Bool) {
        config.proxySettings.autoStartProxy = enabled
        saveConfig()
    }

    // MARK: - Built-in Local Test Upstream Toggle

    public func startLocalTestUpstream(port: Int = 18765) throws -> Int {
        let actualPort = try localTestUpstream.start(port: port)
        isLocalTestUpstreamRunning = true
        localTestUpstreamPort = actualPort
        return actualPort
    }

    public func stopLocalTestUpstream() {
        localTestUpstream.stop()
        isLocalTestUpstreamRunning = false
        localTestUpstreamPort = nil
    }

    public func installLocalTestPreset() throws {
        let port = try localTestUpstreamRunningPortOrStart()
        let baseURL = "http://127.0.0.1:\(port)"
        let existingProvider = config.providers.first { $0.baseURL == baseURL }
        let providerID: UUID

        if let existing = existingProvider {
            providerID = existing.id
            updateProviderHealth(providerID: providerID, status: .healthy, error: nil)
        } else {
            let provider = ProviderConfig(
                name: "本地测试模拟上游 (127.0.0.1:\(port))",
                baseURL: baseURL,
                isEnabled: true,
                timeoutSeconds: 30,
                healthStatus: .healthy
            )
            config.providers.append(provider)
            providerID = provider.id
        }

        let existingModelIDs = Set(config.models.filter { $0.providerID == providerID }.map(\.modelID))
        let presets: [ModelConfig] = [
            ModelConfig(
                providerID: providerID,
                modelID: "mock-fast-mini",
                displayName: "Local Fast Mini (模拟低价)",
                inputPricePerMillion: 0.15,
                outputPricePerMillion: 0.60,
                contextWindow: 128_000,
                capabilities: [.chat, .tools, .jsonMode],
                defaultRole: .fastEconomy,
                qualityScore: 68,
                speedScore: 95
            ),
            ModelConfig(
                providerID: providerID,
                modelID: "mock-coder-pro",
                displayName: "Local Coder Pro (模拟代码)",
                inputPricePerMillion: 1.50,
                outputPricePerMillion: 6.00,
                contextWindow: 200_000,
                capabilities: [.chat, .coding, .reasoning, .tools, .jsonMode],
                defaultRole: .coding,
                qualityScore: 88,
                speedScore: 78
            ),
            ModelConfig(
                providerID: providerID,
                modelID: "mock-vision-max",
                displayName: "Local Vision Max (模拟旗舰)",
                inputPricePerMillion: 5.00,
                outputPricePerMillion: 15.00,
                contextWindow: 200_000,
                capabilities: [.chat, .coding, .reasoning, .tools, .vision, .jsonMode],
                defaultRole: .complexReasoning,
                qualityScore: 96,
                speedScore: 65
            )
        ]

        for preset in presets where !existingModelIDs.contains(preset.modelID) {
            config.models.append(preset)
        }

        config.privacySettings.hasCompletedOnboarding = true
        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)
    }

    private func localTestUpstreamRunningPortOrStart() throws -> Int {
        if let port = localTestUpstream.port, localTestUpstream.isRunning {
            return port
        }
        return try startLocalTestUpstream(port: 18765)
    }

    // MARK: - Provider & Model Management

    public func upsertProvider(_ provider: ProviderConfig, apiKey: String?) throws {
        var updated = provider
        if let key = apiKey {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try keychain.deleteAPIKey(for: provider.id)
            } else {
                try keychain.setAPIKey(trimmed, for: provider.id)
            }
            // Reset authError when key changes so hard constraints allow re-verification
            if updated.healthStatus == .authError {
                updated.healthStatus = .unknown
                updated.lastErrorMessage = nil
            }
        }

        if let idx = config.providers.firstIndex(where: { $0.id == updated.id }) {
            config.providers[idx] = updated
        } else {
            config.providers.append(updated)
        }
        saveConfig()
    }

    public func deleteProvider(id: UUID) {
        config.providers.removeAll { $0.id == id }
        let removedModelIDs = Set(config.models.filter { $0.providerID == id }.map(\.id))
        config.models.removeAll { $0.providerID == id }
        if let pinned = config.policy.pinnedModelID, removedModelIDs.contains(pinned) {
            config.policy.pinnedModelID = nil
        }
        if let fallback = config.policy.fallbackModelID, removedModelIDs.contains(fallback) {
            config.policy.fallbackModelID = nil
        }
        try? keychain.deleteAPIKey(for: id)
        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)
    }

    public func hasAPIKey(for providerID: UUID) -> Bool {
        keychain.hasAPIKey(for: providerID)
    }

    public func apiKeyForProvider(_ providerID: UUID) -> String? {
        try? keychain.getAPIKey(for: providerID)
    }

    public func testProviderConnection(providerID: UUID) async -> Result<[String], UpstreamError> {
        guard let provider = config.providers.first(where: { $0.id == providerID }) else {
            return .failure(.invalidResponse(message: "供应商不存在"))
        }

        updateProviderHealth(providerID: providerID, status: .checking, error: nil)
        let key = try? keychain.getAPIKey(for: providerID)
        let secrets = keychain.allKnownSecretValues()
        let result = await upstreamClient.fetchModels(provider: provider, apiKey: key, secretsToRedact: secrets)

        switch result {
        case .success(let models):
            updateProviderHealth(providerID: providerID, status: .healthy, error: nil)
            return .success(models)
        case .failure(let err):
            let status: ProviderHealthStatus
            switch err {
            case .authError:
                status = .authError
            case .networkError, .invalidURL:
                status = .networkError
            case .httpError, .modelUnavailable, .invalidResponse:
                status = .serverError
            }
            updateProviderHealth(providerID: providerID, status: status, error: err.localizedDescription)
            return .failure(err)
        }
    }

    public func updateProviderHealth(providerID: UUID, status: ProviderHealthStatus, error: String?) {
        guard let idx = config.providers.firstIndex(where: { $0.id == providerID }) else { return }
        config.providers[idx].healthStatus = status
        config.providers[idx].lastErrorMessage = error
        config.providers[idx].lastCheckedAt = Date()
        saveConfig()
    }

    public func upsertModel(_ model: ModelConfig) {
        if let idx = config.models.firstIndex(where: { $0.id == model.id }) {
            config.models[idx] = model
        } else {
            config.models.append(model)
        }
        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)
    }

    public func deleteModel(id: UUID) {
        config.models.removeAll { $0.id == id }
        if config.policy.pinnedModelID == id {
            config.policy.pinnedModelID = nil
        }
        if config.policy.fallbackModelID == id {
            config.policy.fallbackModelID = nil
        }
        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)
    }

    public func updateModelAvailability(modelID: UUID, status: ModelAvailabilityStatus, note: String?, autoEvicted: Bool? = nil) {
        guard let idx = config.models.firstIndex(where: { $0.id == modelID }) else { return }
        config.models[idx].availabilityStatus = status
        config.models[idx].lastAvailabilityNote = note
        if let autoEvicted {
            config.models[idx].isAutoEvicted = autoEvicted
            if autoEvicted {
                appendProbeAuditLog("剔除模型「\(config.models[idx].displayName)」：\(note ?? status.displayName)")
            }
        }
        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)
    }

    public func restoreEvictedModel(id: UUID) {
        guard let idx = config.models.firstIndex(where: { $0.id == id }) else { return }
        config.models[idx].isAutoEvicted = false
        config.models[idx].availabilityStatus = .available
        config.models[idx].lastAvailabilityNote = "用户手动恢复（等待下次测活或请求验证）"
        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)
    }

    public func updateAutoDiscoverAndProbe(_ enabled: Bool) {
        config.proxySettings.autoDiscoverAndProbeOnLaunch = enabled
        saveConfig()
    }

    // MARK: - Local Discovery & Active Model Health Probing

    @discardableResult
    public func discoverAndProbeLocalModels(
        homeDirectory: URL? = nil,
        scanWellKnownLocalPorts: Bool = true
    ) async -> DiscoveryAndProbeSummary {
        if isDiscoveringAndProbing {
            return lastDiscoverySummary ?? DiscoveryAndProbeSummary(
                discoveredProvidersCount: 0,
                discoveredModelsCount: 0,
                probedModelsCount: 0,
                healthyModelsCount: config.models.filter { $0.isEnabled && !$0.isAutoEvicted && $0.availabilityStatus == .available }.count,
                evictedModelsCount: config.models.filter { $0.isAutoEvicted || $0.availabilityStatus != .available }.count,
                sourcesScanned: []
            )
        }

        isDiscoveringAndProbing = true
        probeProgressText = "正在扫描本机已配置的模型与本地服务..."
        defer {
            isDiscoveringAndProbing = false
            probeProgressText = nil
        }

        let resolvedHome = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let discovery = await discoveryService.scanLocalEnvironment(
            homeDirectory: resolvedHome,
            excludeLoopbackPort: config.proxySettings.port,
            scanWellKnownLocalPorts: scanWellKnownLocalPorts
        )

        var addedProviders = 0
        var addedModels = 0

        for entry in discovery.providers {
            let normIncoming = normalizeBaseURLString(entry.baseURL)
            let providerID: UUID

            if let existingIdx = config.providers.firstIndex(where: {
                normalizeBaseURLString($0.baseURL) == normIncoming && $0.apiProtocol == entry.apiProtocol
            }) {
                providerID = config.providers[existingIdx].id
                if config.providers[existingIdx].discoveredSource == nil {
                    config.providers[existingIdx].discoveredSource = entry.source
                }
                if config.providers[existingIdx].accountID == nil, let acct = entry.accountID {
                    config.providers[existingIdx].accountID = acct
                }
                // Refresh Codex OAuth token if newly discovered from ~/.codex/auth.json
                if entry.apiProtocol == .codexChatGPT, let key = entry.apiKey, !key.isEmpty {
                    try? keychain.setAPIKey(key, for: providerID)
                } else if !hasAPIKey(for: providerID), let key = entry.apiKey, !key.isEmpty {
                    try? keychain.setAPIKey(key, for: providerID)
                }
            } else {
                let newProvider = ProviderConfig(
                    name: entry.name,
                    baseURL: entry.baseURL,
                    isEnabled: true,
                    timeoutSeconds: 45,
                    healthStatus: .unknown,
                    discoveredSource: entry.source,
                    apiProtocol: entry.apiProtocol,
                    accountID: entry.accountID
                )
                config.providers.append(newProvider)
                providerID = newProvider.id
                addedProviders += 1
                if let key = entry.apiKey, !key.isEmpty {
                    try? keychain.setAPIKey(key, for: providerID)
                }
            }

            for mEntry in entry.models {
                if let existingModelIdx = config.models.firstIndex(where: { $0.providerID == providerID && $0.modelID == mEntry.modelID }) {
                    if config.models[existingModelIdx].inputPricePerMillion == nil, let inp = mEntry.inputPricePerMillion {
                        config.models[existingModelIdx].inputPricePerMillion = inp
                    }
                    if config.models[existingModelIdx].outputPricePerMillion == nil, let out = mEntry.outputPricePerMillion {
                        config.models[existingModelIdx].outputPricePerMillion = out
                    }
                    if config.models[existingModelIdx].discoveredSource == nil {
                        config.models[existingModelIdx].discoveredSource = mEntry.source
                    }
                } else {
                    let newModel = ModelConfig(
                        providerID: providerID,
                        modelID: mEntry.modelID,
                        displayName: mEntry.displayName,
                        isEnabled: true,
                        inputPricePerMillion: mEntry.inputPricePerMillion,
                        outputPricePerMillion: mEntry.outputPricePerMillion,
                        contextWindow: mEntry.contextWindow,
                        capabilities: mEntry.capabilities,
                        defaultRole: mEntry.defaultRole,
                        qualityScore: mEntry.qualityScore,
                        speedScore: mEntry.speedScore,
                        availabilityStatus: .available,
                        discoveredSource: mEntry.source
                    )
                    config.models.append(newModel)
                    addedModels += 1
                }
            }
        }

        saveConfig()

        let probeSummary = await runActiveHealthProbe(
            targetProviderID: nil,
            discoveredProvidersCount: addedProviders,
            discoveredModelsCount: addedModels,
            sourcesScanned: discovery.sourcesScanned
        )
        return probeSummary
    }

    @discardableResult
    public func probeAllEnabledModels() async -> DiscoveryAndProbeSummary {
        if isDiscoveringAndProbing {
            return lastDiscoverySummary ?? DiscoveryAndProbeSummary(
                discoveredProvidersCount: 0,
                discoveredModelsCount: 0,
                probedModelsCount: 0,
                healthyModelsCount: config.models.filter { $0.isEnabled && !$0.isAutoEvicted && $0.availabilityStatus == .available }.count,
                evictedModelsCount: config.models.filter { $0.isAutoEvicted || $0.availabilityStatus != .available }.count,
                sourcesScanned: []
            )
        }
        isDiscoveringAndProbing = true
        defer {
            isDiscoveringAndProbing = false
            probeProgressText = nil
        }
        return await runActiveHealthProbe(
            targetProviderID: nil,
            discoveredProvidersCount: 0,
            discoveredModelsCount: 0,
            sourcesScanned: []
        )
    }

    public func probeProviderModels(providerID: UUID) async {
        guard !isDiscoveringAndProbing else { return }
        isDiscoveringAndProbing = true
        defer {
            isDiscoveringAndProbing = false
            probeProgressText = nil
        }
        _ = await runActiveHealthProbe(
            targetProviderID: providerID,
            discoveredProvidersCount: 0,
            discoveredModelsCount: 0,
            sourcesScanned: []
        )
    }

    public func probeSingleModel(modelID: UUID) async {
        guard let modelIdx = config.models.firstIndex(where: { $0.id == modelID }) else { return }
        let model = config.models[modelIdx]
        guard let provider = config.providers.first(where: { $0.id == model.providerID }) else { return }
        let key = try? keychain.getAPIKey(for: provider.id)
        let secrets = keychain.allKnownSecretValues()

        probeProgressText = "正在测试模型 \(model.displayName)..."
        let result = await upstreamClient.probeModelHealth(
            provider: provider,
            model: model,
            apiKey: key,
            timeoutSeconds: 6.0,
            secretsToRedact: secrets
        )
        probeProgressText = nil

        if result.isAvailable {
            config.models[modelIdx].availabilityStatus = .available
            config.models[modelIdx].isAutoEvicted = false
            config.models[modelIdx].lastProbeLatencyMs = result.latencyMs
            config.models[modelIdx].lastProbedAt = Date()
            config.models[modelIdx].lastAvailabilityNote = result.note
            updateProviderHealth(providerID: provider.id, status: .healthy, error: nil)
        } else {
            config.models[modelIdx].availabilityStatus = result.availability
            config.models[modelIdx].isAutoEvicted = true
            config.models[modelIdx].lastProbedAt = Date()
            config.models[modelIdx].lastAvailabilityNote = result.note
        }
        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)
    }

    private func runActiveHealthProbe(
        targetProviderID: UUID?,
        discoveredProvidersCount: Int,
        discoveredModelsCount: Int,
        sourcesScanned: [String]
    ) async -> DiscoveryAndProbeSummary {
        let providersToCheck = config.providers.filter { p in
            p.isEnabled && (targetProviderID == nil || p.id == targetProviderID)
        }
        let secrets = keychain.allKnownSecretValues()

        // Stage 1: Fast provider reachability checks in parallel
        probeProgressText = "正在检测 \(providersToCheck.count) 个供应商连通性..."
        var reachabilityByProviderID: [UUID: ProviderReachabilityOutcome] = [:]

        await withTaskGroup(of: (UUID, ProviderReachabilityOutcome).self) { group in
            for provider in providersToCheck {
                let apiKey = try? keychain.getAPIKey(for: provider.id)
                group.addTask { [upstreamClient] in
                    let outcome = await upstreamClient.checkProviderReachability(
                        provider: provider,
                        apiKey: apiKey,
                        timeoutSeconds: 3.0,
                        secretsToRedact: secrets
                    )
                    return (provider.id, outcome)
                }
            }
            for await (pid, outcome) in group {
                reachabilityByProviderID[pid] = outcome
            }
        }

        var reachableProviderIDs = Set<UUID>()
        for provider in providersToCheck {
            guard let outcome = reachabilityByProviderID[provider.id] else { continue }
            switch outcome {
            case .reachable(let discoveredIDs):
                reachableProviderIDs.insert(provider.id)
                updateProviderHealth(providerID: provider.id, status: .healthy, error: nil)
                // If provider had 0 models configured yet, attach up to 12 discovered models from /v1/models
                let existingModelsCount = config.models.filter { $0.providerID == provider.id }.count
                if existingModelsCount == 0 {
                    for modelID in discoveredIDs.prefix(12) {
                        let lower = modelID.lowercased()
                        if lower == "auto" || lower == "auto/auto" { continue }
                        config.models.append(ModelConfig(
                            providerID: provider.id,
                            modelID: modelID,
                            discoveredSource: "live:/v1/models"
                        ))
                    }
                }
            case .reachableNoModelList:
                reachableProviderIDs.insert(provider.id)
                updateProviderHealth(providerID: provider.id, status: .unknown, error: nil)
            case .unreachable(let status, let msg):
                updateProviderHealth(providerID: provider.id, status: status, error: msg)
                for idx in config.models.indices where config.models[idx].providerID == provider.id {
                    config.models[idx].availabilityStatus = .unavailable
                    config.models[idx].isAutoEvicted = true
                    config.models[idx].lastProbedAt = Date()
                    config.models[idx].lastAvailabilityNote = "自动剔除（供应商不可用）：\(msg)"
                }
            }
        }

        // Stage 2: Per-model completion probe on reachable providers with bounded concurrency (max 6)
        var modelsToProbe: [(provider: ProviderConfig, model: ModelConfig, apiKey: String?)] = []
        for provider in providersToCheck where reachableProviderIDs.contains(provider.id) {
            let apiKey = try? keychain.getAPIKey(for: provider.id)
            let models = config.models.filter { $0.providerID == provider.id && $0.isEnabled }
            for model in models {
                modelsToProbe.append((provider, model, apiKey))
            }
        }

        probeProgressText = "正在测活 \(modelsToProbe.count) 个模型（不可用将自动剔除）..."
        var probeResults: [UUID: ModelProbeResult] = [:]
        let maxConcurrent = 6
        var nextIndex = 0

        await withTaskGroup(of: (UUID, ModelProbeResult).self) { group in
            while nextIndex < min(maxConcurrent, modelsToProbe.count) {
                let item = modelsToProbe[nextIndex]
                nextIndex += 1
                group.addTask { [upstreamClient] in
                    let res = await upstreamClient.probeModelHealth(
                        provider: item.provider,
                        model: item.model,
                        apiKey: item.apiKey,
                        timeoutSeconds: 6.0,
                        secretsToRedact: secrets
                    )
                    return (item.model.id, res)
                }
            }

            for await (mid, res) in group {
                probeResults[mid] = res
                if nextIndex < modelsToProbe.count {
                    let item = modelsToProbe[nextIndex]
                    nextIndex += 1
                    group.addTask { [upstreamClient] in
                        let res = await upstreamClient.probeModelHealth(
                            provider: item.provider,
                            model: item.model,
                            apiKey: item.apiKey,
                            timeoutSeconds: 6.0,
                            secretsToRedact: secrets
                        )
                        return (item.model.id, res)
                    }
                }
            }
        }

        let now = Date()
        for idx in config.models.indices {
            let modelID = config.models[idx].id
            guard let res = probeResults[modelID] else { continue }
            config.models[idx].lastProbedAt = now
            if res.isAvailable {
                config.models[idx].availabilityStatus = .available
                config.models[idx].isAutoEvicted = false
                config.models[idx].lastProbeLatencyMs = res.latencyMs
                config.models[idx].lastAvailabilityNote = res.note
            } else {
                config.models[idx].availabilityStatus = res.availability
                config.models[idx].isAutoEvicted = true
                config.models[idx].lastProbeLatencyMs = nil
                config.models[idx].lastAvailabilityNote = res.note
            }
        }

        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)

        let healthyCount = config.models.filter { $0.isEnabled && !$0.isAutoEvicted && $0.availabilityStatus == .available }.count
        let evictedCount = config.models.filter { $0.isAutoEvicted || $0.availabilityStatus != .available }.count

        let summary = DiscoveryAndProbeSummary(
            timestamp: now,
            discoveredProvidersCount: discoveredProvidersCount,
            discoveredModelsCount: discoveredModelsCount,
            probedModelsCount: modelsToProbe.count,
            healthyModelsCount: healthyCount,
            evictedModelsCount: evictedCount,
            sourcesScanned: sourcesScanned
        )
        lastDiscoverySummary = summary
        appendProbeAuditLog("巡检完成：新增 \(discoveredProvidersCount) 供应商 / \(discoveredModelsCount) 模型，实测 \(modelsToProbe.count) 个，可用 \(healthyCount)，自动剔除 \(evictedCount)")
        return summary
    }

    private func appendProbeAuditLog(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        probeAuditLogs.insert("[\(stamp)] \(line)", at: 0)
        if probeAuditLogs.count > 40 {
            probeAuditLogs = Array(probeAuditLogs.prefix(40))
        }
    }

    /// Explicitly fills public reference pricing for unpriced models when requested by user.
    /// Does not overwrite models where user already configured input/output prices.
    @discardableResult
    public func fillReferencePricingForUnpricedModels() -> Int {
        var updatedCount = 0
        for idx in config.models.indices {
            if config.models[idx].hasCompletePricing { continue }
            if let pair = Self.referencePricingPair(for: config.models[idx].modelID) {
                config.models[idx].inputPricePerMillion = pair.input
                config.models[idx].outputPricePerMillion = pair.output
                updatedCount += 1
            }
        }
        if updatedCount > 0 {
            saveConfig()
            autoConfigureModelTiers(forceResetManual: false)
        }
        return updatedCount
    }

    private static func referencePricingPair(for modelID: String) -> (input: Double, output: Double)? {
        let lower = modelID.lowercased()
        if lower.contains("flash") || lower.contains("lite") || lower.contains("nano") {
            return (0.10, 0.40)
        }
        if lower.contains("haiku") {
            return (0.80, 4.00)
        }
        if lower.contains("mini") || lower.contains("sol") {
            return (0.40, 1.60)
        }
        if lower.contains("deepseek") {
            return (0.27, 1.10)
        }
        if lower.contains("glm-5") {
            return (0.50, 2.00)
        }
        if lower.contains("sonnet") || lower.contains("codex") || lower.contains("gpt-5") {
            return (2.50, 10.00)
        }
        if lower.contains("opus") || lower.contains("gpt-6") || lower.contains("terra") || lower.contains("astra") {
            return (5.00, 15.00)
        }
        return nil
    }

    // MARK: - Three-Tier (Low / Medium / High) Auto-Configuration & Management

    public func healthyAvailableModels() -> [ModelConfig] {
        let providersByID = Dictionary(uniqueKeysWithValues: config.providers.map { ($0.id, $0) })
        return config.models.filter { model in
            guard model.isEnabled,
                  !model.isAutoEvicted,
                  model.availabilityStatus == .available,
                  let provider = providersByID[model.providerID],
                  provider.isEnabled,
                  provider.healthStatus != .authError,
                  provider.healthStatus != .networkError else {
                return false
            }
            return true
        }
    }

    public func model(for tier: ModelTier) -> ModelConfig? {
        guard let uuid = config.policy.modelID(for: tier) else { return nil }
        return config.models.first { $0.id == uuid }
    }

    public func resolvedTierDisplayNames() -> [ModelTier: String] {
        var map: [ModelTier: String] = [:]
        for tier in ModelTier.allCases {
            if let m = model(for: tier) {
                map[tier] = m.displayName
            }
        }
        return map
    }

    public func setTierModel(tier: ModelTier, modelUUID: UUID?, isManual: Bool = true) {
        updatePolicy { policy in
            policy.setTier(tier, modelID: modelUUID, isManual: isManual)
        }
    }

    /// Automatically selects healthy models for Low / Medium / High tiers.
    /// Manual choices are preserved unless `forceResetManual` is true OR the manually chosen model became evicted/deleted.
    public func autoConfigureModelTiers(forceResetManual: Bool = false) {
        let healthy = healthyAvailableModels()
        let healthyIDs = Set(healthy.map(\.id))
        var nextPolicy = config.policy

        // Determine which tiers currently need (re)assignment
        func needsAssignment(for tier: ModelTier) -> Bool {
            if forceResetManual { return true }
            if let cid = nextPolicy.modelID(for: tier) {
                if !healthyIDs.contains(cid) {
                    // Assigned model was deleted, disabled, or auto-evicted -> repair automatically
                    return nextPolicy.autoConfigureTiers
                }
                if nextPolicy.isManual(for: tier) {
                    return false
                }
                // Non-manual tier should re-evaluate as new healthy models arrive or probes complete
                return nextPolicy.autoConfigureTiers
            }
            return nextPolicy.autoConfigureTiers
        }

        // If all healthy models vanished, clear dangling IDs that don't even exist anymore
        let allKnownIDs = Set(config.models.map(\.id))
        for tier in ModelTier.allCases {
            if let cid = nextPolicy.modelID(for: tier), !allKnownIDs.contains(cid) {
                nextPolicy.setTier(tier, modelID: nil, isManual: false)
            }
        }

        if !healthy.isEmpty {
            var reservedIDs = Set<UUID>()
            for tier in ModelTier.allCases where !needsAssignment(for: tier) {
                if let existingID = nextPolicy.modelID(for: tier), healthyIDs.contains(existingID) {
                    reservedIDs.insert(existingID)
                }
            }

            // Pick High first, then Low, then Medium (maximizing distinctness when >= 3 models exist)
            let strategy = nextPolicy.activeStrategy
            if needsAssignment(for: .high) {
                let picked = pickBestModelForTier(
                    .high,
                    candidates: healthy,
                    avoidIDs: healthy.count >= 2 ? reservedIDs : [],
                    strategy: strategy
                )
                nextPolicy.setTier(.high, modelID: picked?.id, isManual: false)
                if let pid = picked?.id { reservedIDs.insert(pid) }
            }

            if needsAssignment(for: .low) {
                let picked = pickBestModelForTier(
                    .low,
                    candidates: healthy,
                    avoidIDs: healthy.count >= 2 ? reservedIDs : [],
                    strategy: strategy
                )
                nextPolicy.setTier(.low, modelID: picked?.id, isManual: false)
                if let pid = picked?.id { reservedIDs.insert(pid) }
            }

            if needsAssignment(for: .medium) {
                let picked = pickBestModelForTier(
                    .medium,
                    candidates: healthy,
                    avoidIDs: healthy.count >= 3 ? reservedIDs : [],
                    strategy: strategy
                )
                nextPolicy.setTier(.medium, modelID: picked?.id, isManual: false)
            }
        } else if forceResetManual {
            nextPolicy.setTier(.low, modelID: nil, isManual: false)
            nextPolicy.setTier(.medium, modelID: nil, isManual: false)
            nextPolicy.setTier(.high, modelID: nil, isManual: false)
        }

        if nextPolicy != config.policy {
            nextPolicy.policyVersion += 1
            config.policy = nextPolicy
            saveConfig()
        }
    }

    private func pickBestModelForTier(
        _ tier: ModelTier,
        candidates: [ModelConfig],
        avoidIDs: Set<UUID>,
        strategy: RoutingStrategyPreset
    ) -> ModelConfig? {
        guard !candidates.isEmpty else { return nil }
        let preferredPool = candidates.filter { !avoidIDs.contains($0.id) }
        let pool = preferredPool.isEmpty ? candidates : preferredPool

        return pool.max { lhs, rhs in
            let s1 = tierSuitabilityScore(model: lhs, tier: tier, strategy: strategy)
            let s2 = tierSuitabilityScore(model: rhs, tier: tier, strategy: strategy)
            if abs(s1 - s2) > 0.0001 {
                return s1 < s2
            }
            return lhs.modelID > rhs.modelID
        }
    }

    private func tierSuitabilityScore(
        model: ModelConfig,
        tier: ModelTier,
        strategy: RoutingStrategyPreset
    ) -> Double {
        let lower = model.modelID.lowercased()
        let speedBonus: Double
        if let probeMs = model.lastProbeLatencyMs {
            speedBonus = min(30.0, max(0.0, 30.0 - probeMs / 180.0))
        } else {
            speedBonus = Double(model.speedScore) * 0.25
        }
        let priceEfficiency = model.blendedPricePerMillion.map { 100.0 / (1.0 + $0 * 0.8) } ?? 12.0
        let blendedPrice = model.blendedPricePerMillion ?? 0
        let isEconomyKeyword = lower.contains("flash") || lower.contains("mini") || lower.contains("haiku") || lower.contains("lite") || lower.contains("eco") || lower.contains("nano")
        let isFlagshipKeyword = lower.contains("terra") || lower.contains("opus") || lower.contains("gpt-6") || lower.contains("astra") || lower.contains("luna") || lower.contains("max") || lower.contains("pro") || lower.contains("480b") || lower.contains("671b") || lower.contains("r1")

        var score: Double
        switch tier {
        case .low:
            if strategy == .qualityFirst {
                score = Double(model.qualityScore) * 0.75 + Double(model.speedScore) * 0.25 + speedBonus
                if model.defaultRole == .coding || model.defaultRole == .general { score += 14.0 }
                if model.capabilities.contains(.coding) { score += 8.0 }
                if model.capabilities.contains(.reasoning) { score += 6.0 }
            } else {
                score = Double(model.speedScore) * 0.45 + speedBonus + priceEfficiency * 0.45
                if model.defaultRole == .fastEconomy { score += 35.0 }
                else if model.defaultRole == .general { score += 15.0 }
                if isEconomyKeyword { score += 25.0 }
                if model.defaultRole == .complexReasoning || lower.contains("opus") || lower.contains("terra") || lower.contains("astra") {
                    score -= 22.0
                }
                if strategy == .costFirst {
                    score += priceEfficiency * 0.55 - min(40.0, blendedPrice * 3.0)
                }
            }

        case .medium:
            score = Double(model.qualityScore) * 0.45 + Double(model.speedScore) * 0.28 + speedBonus
            if model.defaultRole == .coding || model.defaultRole == .general { score += 24.0 }
            if lower.contains("sonnet") || lower.contains("glm-5.3") || lower.contains("deepseek-v4") || lower.contains("sol") || lower.contains("arc") || lower.contains("coder") {
                if !lower.contains("flash") {
                    score += 18.0
                }
            }
            if model.capabilities.contains(.coding) { score += 8.0 }
            if model.capabilities.contains(.tools) { score += 6.0 }

            if strategy == .costFirst {
                score += priceEfficiency * 0.65 + Double(model.speedScore) * 0.25 - min(42.0, blendedPrice * 2.4)
                if model.defaultRole == .fastEconomy || isEconomyKeyword { score += 22.0 }
                if model.defaultRole == .complexReasoning { score -= 24.0 }
            } else if strategy == .qualityFirst {
                score += Double(model.qualityScore) * 0.45
                if model.defaultRole == .complexReasoning { score += 22.0 }
                if model.capabilities.contains(.reasoning) { score += 12.0 }
                if isFlagshipKeyword { score += 14.0 }
            }

        case .high:
            score = Double(model.qualityScore) * 0.80
            if model.defaultRole == .complexReasoning { score += 26.0 }
            else if model.defaultRole == .coding { score += 12.0 }
            if model.capabilities.contains(.reasoning) { score += 14.0 }
            if model.capabilities.contains(.coding) { score += 8.0 }
            if isFlagshipKeyword { score += 18.0 }
            if let blended = model.blendedPricePerMillion {
                score += min(12.0, blended * 1.2)
            }
            if model.defaultRole == .fastEconomy || lower.contains("flash") || lower.contains("mini") || lower.contains("haiku") || lower.contains("lite") {
                score -= 25.0
            }

            if strategy == .costFirst {
                score += priceEfficiency * 0.70 + Double(model.speedScore) * 0.25 - min(48.0, blendedPrice * 2.8)
            } else if strategy == .qualityFirst {
                score += Double(model.qualityScore) * 0.35
                if model.defaultRole == .complexReasoning { score += 15.0 }
                if model.capabilities.contains(.reasoning) { score += 10.0 }
                if isFlagshipKeyword { score += 12.0 }
            }
        }
        return score
    }

    // MARK: - Magpie-Style Multi-Agent Auto Configuration

    public func refreshAgentStatuses() {
        agentStatuses = agentConfigService.inspectAllAgents(proxyPort: config.proxySettings.port)
    }

    public func binding(for kind: AgentKind) -> AgentModelBinding {
        config.binding(for: kind)
    }

    public func updateAgentBinding(_ binding: AgentModelBinding, for kind: AgentKind) {
        config.agentBindings[kind.rawValue] = binding
        saveConfig()
    }

    @discardableResult
    public func applyAgentIntegration(kind: AgentKind) throws -> AgentIntegrationStatus {
        let binding = binding(for: kind)
        let status = try agentConfigService.applyAgentConfig(
            kind: kind,
            binding: binding,
            proxyPort: config.proxySettings.port,
            resolvedTierDisplayNames: resolvedTierDisplayNames()
        )
        refreshAgentStatuses()
        return status
    }

    @discardableResult
    public func applyAllInstalledAgents() -> (succeeded: Int, errors: [String]) {
        refreshAgentStatuses()
        var succeeded = 0
        var errors: [String] = []
        for status in agentStatuses where status.isInstalled {
            do {
                _ = try applyAgentIntegration(kind: status.kind)
                succeeded += 1
            } catch {
                errors.append("\(status.kind.displayName): \(error.localizedDescription)")
            }
        }
        refreshAgentStatuses()
        portSyncNeededForConnectedAgents = false
        return (succeeded, errors)
    }

    @discardableResult
    public func syncConnectedAgentsToCurrentPort() -> (succeeded: Int, errors: [String]) {
        refreshAgentStatuses()
        var succeeded = 0
        var errors: [String] = []
        for status in agentStatuses where status.hasBackup || status.isConnectedToAutoModel {
            do {
                _ = try applyAgentIntegration(kind: status.kind)
                succeeded += 1
            } catch {
                errors.append("\(status.kind.displayName): \(error.localizedDescription)")
            }
        }
        portSyncNeededForConnectedAgents = false
        refreshAgentStatuses()
        return (succeeded, errors)
    }

    @discardableResult
    public func restoreAgentIntegration(kind: AgentKind) throws -> AgentIntegrationStatus {
        let status = try agentConfigService.restoreAgentConfig(kind: kind, proxyPort: config.proxySettings.port)
        refreshAgentStatuses()
        return status
    }

    private func normalizeBaseURLString(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/v1") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed.lowercased()
    }

    // MARK: - Policy & Privacy

    public func updatePolicy(_ mutate: (inout RoutingPolicyConfig) -> Void) {
        var next = config.policy
        mutate(&next)
        if next != config.policy {
            next.policyVersion += 1
            config.policy = next
            saveConfig()
        }
    }

    public func setStrategy(_ strategy: RoutingStrategyPreset) {
        updatePolicy { $0.activeStrategy = strategy }
        autoConfigureModelTiers(forceResetManual: false)
    }

    public func setRecordRequestBody(_ enabled: Bool) {
        config.privacySettings.recordRequestBody = enabled
        saveConfig()
    }

    public func setOnboardingCompleted(_ completed: Bool) {
        config.privacySettings.hasCompletedOnboarding = completed
        saveConfig()
    }

    public func clearCallHistory() {
        callHistory.removeAll()
        router.clearSessionStickiness()
        try? persistence.clearHistory()
    }

    public func clearAllKeychainKeys() throws {
        try keychain.clearAll()
        for idx in config.providers.indices {
            config.providers[idx].healthStatus = .unknown
            config.providers[idx].lastErrorMessage = nil
        }
        saveConfig()
    }

    public func saveConfig() {
        do {
            try persistence.saveConfig(config)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }

    // MARK: - Request Validation & Chat Completion Execution Pipeline

    public enum ProxyRequestValidationError: Error, Sendable {
        case badRequest(status: Int, code: String, message: String)
    }

    public func validateChatCompletionsPayload(_ payload: [String: Any]) -> Result<Void, ProxyRequestValidationError> {
        guard let messages = payload["messages"] as? [[String: Any]], !messages.isEmpty else {
            return .failure(.badRequest(status: 400, code: "invalid_messages", message: "请求缺少非空的 'messages' 数组。"))
        }
        if payload["audio"] != nil {
            return .failure(.badRequest(status: 400, code: "unsupported_parameter", message: "Auto Model 第一版暂不支持 'audio' 参数。"))
        }
        if let modalities = payload["modalities"] as? [String], modalities.contains("audio") {
            return .failure(.badRequest(status: 400, code: "unsupported_parameter", message: "Auto Model 第一版暂不支持 audio modalities。"))
        }
        if let n = payload["n"] as? Int, n > 1 {
            return .failure(.badRequest(status: 400, code: "unsupported_parameter", message: "Auto Model 第一版暂不支持 n > 1 的多候选采样。"))
        }
        return .success(())
    }

    public struct ExecutionOutcome: Sendable {
        public var httpStatusCode: Int
        public var headers: [String: String]
        public var responseBody: Data
        public var callRecord: CallRecord
    }

    public func executeChatCompletion(
        payload: [String: Any],
        source: CallSource,
        sessionHeader: String? = nil,
        clientName: String? = nil,
        endpointPath: String? = nil,
        abBaselineModelUUID: UUID? = nil,
        onStreamHeadersReady: (@Sendable ([String: String]) async throws -> Void)? = nil,
        onStreamChunk: (@Sendable (Data) async throws -> Void)? = nil
    ) async -> ExecutionOutcome {
        let resolvedClientName = clientName ?? (source == .testBench ? "测试台" : nil)
        let requestedModel = (payload["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "auto"
        let effectiveRequestedModel = requestedModel.isEmpty ? "auto" : requestedModel
        let stream = (payload["stream"] as? Bool) ?? false
        let features = RequestFeatureExtractor.extract(from: payload, sessionHeader: sessionHeader)
        let secrets = keychain.allKnownSecretValues()
        let requestPreview = config.privacySettings.recordRequestBody ? buildRequestPreview(payload: payload, secrets: secrets) : nil

        if case .failure(let valErr) = validateChatCompletionsPayload(payload),
           case .badRequest(let status, let code, let message) = valErr {
            let emptyDecision = RoutingDecision(
                requestedModel: effectiveRequestedModel,
                isAutoRouted: effectiveRequestedModel.caseInsensitiveCompare("auto") == .orderedSame || ModelTier.matchExplicitTier(requestedModel: effectiveRequestedModel) != nil,
                strategyName: config.policy.activeStrategy.displayName,
                policyVersion: config.policy.policyVersion,
                deciderPluginID: config.policy.activeDeciderPluginID,
                decisionDurationMs: 0,
                errorSummary: message
            )
            let record = CallRecord(
                source: source,
                status: .rejected,
                requestedModel: effectiveRequestedModel,
                executedModelID: nil,
                executedModelDisplayName: nil,
                executedProviderName: nil,
                httpStatusCode: status,
                requestFeatures: features,
                decision: emptyDecision,
                attempts: [],
                routingDecisionMs: 0,
                upstreamFirstTokenMs: nil,
                totalCompletionMs: 0,
                finalUsage: nil,
                usageSource: .unavailable,
                usageEstimationMethod: nil,
                costStatus: .noUsage,
                primaryAttemptCostUSD: nil,
                retryAttemptsCostUSD: 0,
                totalCostUSD: nil,
                requestPreview: requestPreview,
                errorMessage: message,
                clientName: resolvedClientName,
                endpointPath: endpointPath
            )
            appendCallRecord(record)
            return ExecutionOutcome(
                httpStatusCode: status,
                headers: [:],
                responseBody: openAIErrorJSON(message: message, type: "invalid_request_error", code: code),
                callRecord: record
            )
        }

        let runtimeMetrics = buildRuntimeMetricsMap()
        let decision = router.route(
            requestedModel: effectiveRequestedModel,
            features: features,
            providers: config.providers,
            models: config.models,
            policy: config.policy,
            runtimeMetricsByModelID: runtimeMetrics
        )

        guard let primaryID = decision.selectedModelUUID else {
            let status = (decision.isAutoRouted ? 503 : 404)
            let errCode = decision.isAutoRouted ? "no_eligible_model" : "model_not_found"
            let msg = decision.errorSummary ?? "没有满足条件的可用模型"
            let record = CallRecord(
                source: source,
                status: .rejected,
                requestedModel: effectiveRequestedModel,
                executedModelID: nil,
                executedModelDisplayName: nil,
                executedProviderName: nil,
                httpStatusCode: status,
                requestFeatures: features,
                decision: decision,
                attempts: [],
                routingDecisionMs: decision.decisionDurationMs,
                upstreamFirstTokenMs: nil,
                totalCompletionMs: decision.decisionDurationMs,
                finalUsage: nil,
                usageSource: .unavailable,
                usageEstimationMethod: nil,
                costStatus: .noUsage,
                primaryAttemptCostUSD: nil,
                retryAttemptsCostUSD: 0,
                totalCostUSD: nil,
                requestPreview: requestPreview,
                errorMessage: msg,
                clientName: resolvedClientName,
                endpointPath: endpointPath
            )
            appendCallRecord(record)
            return ExecutionOutcome(
                httpStatusCode: status,
                headers: [:],
                responseBody: openAIErrorJSON(message: msg, type: "routing_error", code: errCode),
                callRecord: record
            )
        }

        // Build candidate attempt queue: primary + optional fallback candidates if retry is enabled
        var candidateQueue: [UUID] = [primaryID]
        if config.policy.enableRetryOnUpstreamFailure && decision.isAutoRouted {
            candidateQueue.append(contentsOf: decision.orderedFallbackCandidateIDs)
        }

        let overallStart = DispatchTime.now()
        var attempts: [UpstreamAttemptRecord] = []
        var lastError: UpstreamError?

        for (idx, candidateID) in candidateQueue.enumerated() {
            guard let model = config.models.first(where: { $0.id == candidateID }),
                  let provider = config.providers.first(where: { $0.id == model.providerID }) else {
                continue
            }

            let apiKey = try? keychain.getAPIKey(for: provider.id)
            let responseHeaders = buildAutoModelHeaders(
                decision: decision,
                executedModel: model,
                executedProvider: provider,
                attemptNumber: idx + 1
            )

            let result = await upstreamClient.executeChatCompletion(
                provider: provider,
                model: model,
                apiKey: apiKey,
                originalPayload: payload,
                estimatedInputTokens: features.estimatedInputTokens,
                stream: stream,
                secretsToRedact: secrets,
                onStreamHeadersReady: {
                    if let onStreamHeadersReady {
                        try await onStreamHeadersReady(responseHeaders)
                    }
                },
                onStreamChunk: onStreamChunk
            )

            switch result {
            case .success(let completion):
                // Clear transient error state on provider & restore model if previously flagged
                if provider.healthStatus != .healthy {
                    updateProviderHealth(providerID: provider.id, status: .healthy, error: nil)
                }
                if let mIdx = config.models.firstIndex(where: { $0.id == model.id }) {
                    config.models[mIdx].availabilityStatus = .available
                    config.models[mIdx].isAutoEvicted = false
                    config.models[mIdx].lastProbeLatencyMs = completion.totalLatencyMs
                    config.models[mIdx].lastProbedAt = Date()
                    saveConfig()
                }

                let costInfo = computeAttemptCost(model: model, usage: completion.usage)
                let attemptRecord = UpstreamAttemptRecord(
                    attemptIndex: idx + 1,
                    modelUUID: model.id,
                    modelID: model.modelID,
                    providerID: provider.id,
                    providerName: provider.name,
                    httpStatusCode: completion.statusCode,
                    succeeded: true,
                    firstTokenMs: completion.firstTokenMs,
                    totalLatencyMs: completion.totalLatencyMs,
                    usage: completion.usage,
                    usageSource: completion.usageSource,
                    usageEstimationMethod: completion.usageEstimationMethod,
                    costUSD: costInfo.costUSD,
                    costStatus: costInfo.status,
                    errorMessage: nil
                )
                attempts.append(attemptRecord)

                if decision.isAutoRouted {
                    router.recordSuccessfulSessionModel(
                        fingerprint: features.conversationFingerprint,
                        modelUUID: model.id,
                        policyVersion: decision.policyVersion
                    )
                }

                let retryCost = attempts.dropLast().compactMap(\.costUSD).reduce(0.0, +)
                let totalCostUSD: Double?
                if let primaryCost = costInfo.costUSD {
                    totalCostUSD = primaryCost + retryCost
                } else {
                    totalCostUSD = nil
                }

                let totalMs = decision.decisionDurationMs + elapsedMs(since: overallStart)
                let responsePreview = config.privacySettings.recordRequestBody
                    ? SecretRedactor.redact(String(completion.assistantText.prefix(2000)), secrets: secrets)
                    : nil
                let reasoningPreview = config.privacySettings.recordRequestBody
                    ? completion.reasoningText.map { SecretRedactor.redact(String($0.prefix(2000)), secrets: secrets) }
                    : nil

                // Compute honest comparison (only real A/B test or historical samples)
                var comparison: ComparisonAnalysis? = nil
                if let baselineID = abBaselineModelUUID,
                   baselineID != model.id,
                   let baselineModel = config.models.first(where: { $0.id == baselineID }),
                   let baselineProvider = config.providers.first(where: { $0.id == baselineModel.providerID }) {
                    comparison = await runRealABComparison(
                        baselineModel: baselineModel,
                        baselineProvider: baselineProvider,
                        payload: payload,
                        estimatedInputTokens: features.estimatedInputTokens,
                        secrets: secrets,
                        autoTotalCostUSD: totalCostUSD,
                        autoTotalLatencyMs: totalMs
                    )
                } else if decision.isAutoRouted {
                    comparison = buildHistoricalComparison(
                        executedModel: model,
                        executedUsage: completion.usage,
                        autoTotalCostUSD: totalCostUSD,
                        autoTotalLatencyMs: totalMs
                    )
                }

                let callRecord = CallRecord(
                    source: source,
                    status: .success,
                    requestedModel: effectiveRequestedModel,
                    executedModelID: model.modelID,
                    executedModelDisplayName: model.displayName,
                    executedProviderName: provider.name,
                    httpStatusCode: completion.statusCode,
                    requestFeatures: features,
                    decision: decision,
                    attempts: attempts,
                    routingDecisionMs: decision.decisionDurationMs,
                    upstreamFirstTokenMs: completion.firstTokenMs,
                    totalCompletionMs: totalMs,
                    finalUsage: completion.usage,
                    usageSource: completion.usageSource,
                    usageEstimationMethod: completion.usageEstimationMethod,
                    costStatus: costInfo.status,
                    primaryAttemptCostUSD: costInfo.costUSD,
                    retryAttemptsCostUSD: retryCost,
                    totalCostUSD: totalCostUSD,
                    comparison: comparison,
                    requestPreview: requestPreview,
                    responsePreview: responsePreview,
                    reasoningPreview: reasoningPreview,
                    clientName: resolvedClientName,
                    endpointPath: endpointPath
                )
                appendCallRecord(callRecord)

                return ExecutionOutcome(
                    httpStatusCode: completion.statusCode,
                    headers: responseHeaders,
                    responseBody: completion.responseBody,
                    callRecord: callRecord
                )

            case .failure(let upstreamErr):
                lastError = upstreamErr
                let cleanErrMsg = SecretRedactor.redact(upstreamErr.localizedDescription, secrets: secrets)
                switch upstreamErr {
                case .authError:
                    updateProviderHealth(providerID: provider.id, status: .authError, error: cleanErrMsg)
                    updateModelAvailability(modelID: model.id, status: .unavailable, note: "运行时自动剔除（鉴权失败）：\(cleanErrMsg)", autoEvicted: true)
                case .networkError:
                    updateProviderHealth(providerID: provider.id, status: .networkError, error: cleanErrMsg)
                    updateModelAvailability(modelID: model.id, status: .unavailable, note: "运行时自动剔除（网络/超时）：\(cleanErrMsg)", autoEvicted: true)
                case .modelUnavailable(_, let msg, let avail):
                    updateModelAvailability(modelID: model.id, status: avail, note: "运行时自动剔除：\(msg)", autoEvicted: true)
                case .httpError(let code, _, let msg):
                    if code == 402 || code == 404 || code == 410 || code == 429 || code >= 500 {
                        let mappedAvail: ModelAvailabilityStatus = (code == 402) ? .insufficientCredits : (code == 410 ? .retired : .unavailable)
                        updateModelAvailability(modelID: model.id, status: mappedAvail, note: "运行时自动剔除 (HTTP \(code))：\(msg)", autoEvicted: true)
                    }
                case .invalidURL, .invalidResponse:
                    updateModelAvailability(modelID: model.id, status: .unavailable, note: "运行时自动剔除：\(cleanErrMsg)", autoEvicted: true)
                }

                attempts.append(UpstreamAttemptRecord(
                    attemptIndex: idx + 1,
                    modelUUID: model.id,
                    modelID: model.modelID,
                    providerID: provider.id,
                    providerName: provider.name,
                    httpStatusCode: upstreamErr.statusCode,
                    succeeded: false,
                    firstTokenMs: nil,
                    totalLatencyMs: elapsedMs(since: overallStart),
                    usage: nil,
                    usageSource: .unavailable,
                    usageEstimationMethod: nil,
                    costUSD: nil,
                    costStatus: .noUsage,
                    errorMessage: cleanErrMsg
                ))
            }
        }

        // All candidate attempts failed
        let finalStatus = lastError?.statusCode ?? 502
        let finalMessage = SecretRedactor.redact(lastError?.localizedDescription ?? "上游调用失败", secrets: secrets)
        let retryCost = attempts.compactMap(\.costUSD).reduce(0.0, +)
        let totalMs = decision.decisionDurationMs + elapsedMs(since: overallStart)

        let failedRecord = CallRecord(
            source: source,
            status: .failed,
            requestedModel: effectiveRequestedModel,
            executedModelID: attempts.last?.modelID,
            executedModelDisplayName: decision.selectedDisplayName,
            executedProviderName: attempts.last?.providerName,
            httpStatusCode: finalStatus,
            requestFeatures: features,
            decision: decision,
            attempts: attempts,
            routingDecisionMs: decision.decisionDurationMs,
            upstreamFirstTokenMs: nil,
            totalCompletionMs: totalMs,
            finalUsage: nil,
            usageSource: .unavailable,
            usageEstimationMethod: nil,
            costStatus: .noUsage,
            primaryAttemptCostUSD: nil,
            retryAttemptsCostUSD: retryCost,
            totalCostUSD: retryCost > 0 ? retryCost : nil,
            requestPreview: requestPreview,
            errorMessage: finalMessage,
            clientName: resolvedClientName,
            endpointPath: endpointPath
        )
        appendCallRecord(failedRecord)

        return ExecutionOutcome(
            httpStatusCode: finalStatus,
            headers: [:],
            responseBody: openAIErrorJSON(message: finalMessage, type: "upstream_error", code: "upstream_failed"),
            callRecord: failedRecord
        )
    }

    // MARK: - Cost, Comparison & Helpers

    private func computeAttemptCost(model: ModelConfig, usage: TokenUsage?) -> (costUSD: Double?, status: CostCalculationStatus) {
        guard let usage else {
            return (nil, .noUsage)
        }
        guard let calculated = model.calculateCostUSD(
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens
        ) else {
            return (nil, .missingPriceConfig)
        }
        return (calculated, .calculated)
    }

    private func runRealABComparison(
        baselineModel: ModelConfig,
        baselineProvider: ProviderConfig,
        payload: [String: Any],
        estimatedInputTokens: Int,
        secrets: [String],
        autoTotalCostUSD: Double?,
        autoTotalLatencyMs: Double
    ) async -> ComparisonAnalysis {
        let key = try? keychain.getAPIKey(for: baselineProvider.id)
        let result = await upstreamClient.executeChatCompletion(
            provider: baselineProvider,
            model: baselineModel,
            apiKey: key,
            originalPayload: payload,
            estimatedInputTokens: estimatedInputTokens,
            stream: false,
            secretsToRedact: secrets
        )

        switch result {
        case .success(let completion):
            let baselineCost = completion.usage.flatMap {
                baselineModel.calculateCostUSD(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens)
            }
            var costDiff: Double?
            var savingsPct: Double?
            if let autoCost = autoTotalCostUSD, let baseCost = baselineCost {
                costDiff = baseCost - autoCost
                if baseCost > 0 {
                    savingsPct = ((baseCost - autoCost) / baseCost) * 100.0
                }
            }
            let latencyDiff = completion.totalLatencyMs - autoTotalLatencyMs
            return ComparisonAnalysis(
                basis: .realABTest,
                baselineModelID: baselineModel.modelID,
                baselineModelDisplayName: baselineModel.displayName,
                costDifferenceUSD: costDiff,
                costSavingsPercent: savingsPct,
                latencyDifferenceMs: latencyDiff,
                sampleCount: 1,
                note: "同请求实测对照：基准模型「\(baselineModel.displayName)」实际耗时 \(AutoModelFormatter.formatMs(completion.totalLatencyMs))，费用 \(AutoModelFormatter.formatUSD(baselineCost))"
            )
        case .failure(let err):
            return ComparisonAnalysis(
                basis: .realABTest,
                baselineModelID: baselineModel.modelID,
                baselineModelDisplayName: baselineModel.displayName,
                costDifferenceUSD: nil,
                costSavingsPercent: nil,
                latencyDifferenceMs: nil,
                sampleCount: 0,
                note: "实测对照执行基准模型「\(baselineModel.displayName)」失败：\(err.localizedDescription)"
            )
        }
    }

    private func buildHistoricalComparison(
        executedModel: ModelConfig,
        executedUsage: TokenUsage?,
        autoTotalCostUSD: Double?,
        autoTotalLatencyMs: Double
    ) -> ComparisonAnalysis? {
        // Choose a comparable baseline model that actually has historical successful records in local history
        // Prefer user's pinned/fallback or highest-quality alternative model with real historical samples
        let alternativeModels = config.models.filter { $0.id != executedModel.id && $0.isEnabled }
            .sorted { $0.qualityScore > $1.qualityScore }

        for baseline in alternativeModels {
            let samples = callHistory.filter {
                $0.status == .success && $0.executedModelID == baseline.modelID
            }
            guard !samples.isEmpty else { continue }

            let avgBaselineLatency = samples.map(\.totalCompletionMs).reduce(0.0, +) / Double(samples.count)
            let latencyDiff = avgBaselineLatency - autoTotalLatencyMs

            var costDiff: Double?
            var savingsPct: Double?
            if let autoCost = autoTotalCostUSD,
               let usage = executedUsage,
               let estBaselineCost = baseline.calculateCostUSD(
                   promptTokens: usage.promptTokens,
                   completionTokens: usage.completionTokens
               ) {
                costDiff = estBaselineCost - autoCost
                if estBaselineCost > 0 {
                    savingsPct = ((estBaselineCost - autoCost) / estBaselineCost) * 100.0
                }
            }

            return ComparisonAnalysis(
                basis: .historicalEstimate,
                baselineModelID: baseline.modelID,
                baselineModelDisplayName: baseline.displayName,
                costDifferenceUSD: costDiff,
                costSavingsPercent: savingsPct,
                latencyDifferenceMs: latencyDiff,
                sampleCount: samples.count,
                note: "历史估算：基于「\(baseline.displayName)」在本机的 \(samples.count) 条真实历史样本（均值 \(AutoModelFormatter.formatMs(avgBaselineLatency))）与当前请求用量按单价估算。"
            )
        }
        return nil
    }

    /// Computes aggregate cost savings, speed improvement, retry rate, and top-10% hard-task cost share
    /// against a traditional single-flagship-model baseline, strictly grounded in recorded call history.
    public func routingImpactSummary(todayOnly: Bool = false) -> RoutingImpactSummary? {
        let cal = Calendar.current
        let scopedRecords = todayOnly
            ? callHistory.filter { cal.isDateInToday($0.timestamp) }
            : callHistory
        return computeImpactSummary(scopedRecords: scopedRecords)
    }

    /// Computes cost savings and speed improvement for a specific session's records
    /// compared against always using the highest-tier flagship model.
    public func sessionImpactSummary(for records: [CallRecord]) -> RoutingImpactSummary? {
        computeImpactSummary(scopedRecords: records)
    }

    private func computeImpactSummary(scopedRecords: [CallRecord]) -> RoutingImpactSummary? {
        guard !scopedRecords.isEmpty else { return nil }

        let baselineModel: ModelConfig? = {
            if let high = model(for: .high), high.blendedPricePerMillion != nil {
                return high
            }
            if let pricedFlagship = config.models
                .filter({ $0.isEnabled && $0.blendedPricePerMillion != nil })
                .max(by: { $0.qualityScore < $1.qualityScore }) {
                return pricedFlagship
            }
            return model(for: .high) ?? config.models.max(by: { $0.qualityScore < $1.qualityScore })
        }()

        guard let baseline = baselineModel else { return nil }

        let successRecords = scopedRecords.filter { $0.status == .success }
        let successRatePct = Int((Double(successRecords.count) / Double(scopedRecords.count) * 100.0).rounded())
        let retryCount = scopedRecords.filter { $0.attempts.count > 1 }.count

        var actualCostSum = 0.0
        var baselineCostSum = 0.0
        var evaluatedTurnCount = 0

        for record in successRecords {
            guard let actualCost = record.totalCostUSD else { continue }
            if let comparison = record.comparison,
               comparison.baselineModelID == baseline.modelID,
               let diff = comparison.costDifferenceUSD {
                actualCostSum += actualCost
                baselineCostSum += max(0.0, actualCost + diff)
                evaluatedTurnCount += 1
            } else if let usage = record.finalUsage,
                      let estBaselineCost = baseline.calculateCostUSD(
                          promptTokens: usage.promptTokens,
                          completionTokens: usage.completionTokens
                      ) {
                actualCostSum += actualCost
                baselineCostSum += estBaselineCost
                evaluatedTurnCount += 1
            }
        }

        let costSavedUSD = baselineCostSum - actualCostSum
        let costSavingsPercent: Double? = baselineCostSum > 0
            ? (costSavedUSD / baselineCostSum) * 100.0
            : nil

        let actualAvgLatencyMs = successRecords.isEmpty
            ? 0
            : successRecords.map(\.totalCompletionMs).reduce(0, +) / Double(successRecords.count)

        let baselineSamples = callHistory.filter {
            $0.status == .success && $0.executedModelID == baseline.modelID
        }
        let comparisonLatencyPairs: [(actual: Double, baseline: Double)] = successRecords.compactMap { rec in
            guard let comparison = rec.comparison,
                  comparison.baselineModelID == baseline.modelID,
                  let diff = comparison.latencyDifferenceMs else { return nil }
            return (rec.totalCompletionMs, max(0, rec.totalCompletionMs + diff))
        }

        var baselineAvgLatencyMs: Double?
        var speedSampleCount = 0
        var speedBasisLabel = "待采集基准耗时样本"

        if !baselineSamples.isEmpty {
            baselineAvgLatencyMs = baselineSamples.map(\.totalCompletionMs).reduce(0, +) / Double(baselineSamples.count)
            speedSampleCount = baselineSamples.count
            speedBasisLabel = "同机 \(baselineSamples.count) 条基准实测"
        } else if !comparisonLatencyPairs.isEmpty {
            baselineAvgLatencyMs = comparisonLatencyPairs.map(\.baseline).reduce(0, +) / Double(comparisonLatencyPairs.count)
            speedSampleCount = comparisonLatencyPairs.count
            speedBasisLabel = "对照样本 \(comparisonLatencyPairs.count) 条"
        }

        var speedSavedMsPerTurn: Double?
        var speedGainPercent: Double?
        if let baseAvg = baselineAvgLatencyMs, !successRecords.isEmpty, baseAvg > 0 {
            let saved = baseAvg - actualAvgLatencyMs
            speedSavedMsPerTurn = saved
            speedGainPercent = (saved / baseAvg) * 100.0
        }

        // Long-tail hard-task cost share (top 10% most expensive turns)
        let costedValues = successRecords.compactMap(\.totalCostUSD).filter { $0 > 0 }.sorted(by: >)
        var top10Share: Double?
        if costedValues.count >= 3 {
            let totalPositiveCost = costedValues.reduce(0, +)
            let topCount = max(1, Int(ceil(Double(costedValues.count) * 0.10)))
            let topSum = costedValues.prefix(topCount).reduce(0, +)
            if totalPositiveCost > 0 {
                top10Share = (topSum / totalPositiveCost) * 100.0
            }
        }

        return RoutingImpactSummary(
            baselineModelDisplayName: baseline.displayName,
            evaluatedTurnCount: evaluatedTurnCount,
            actualCostUSD: actualCostSum,
            baselineCostUSD: baselineCostSum,
            costSavedUSD: costSavedUSD,
            costSavingsPercent: costSavingsPercent,
            actualAvgLatencyMs: actualAvgLatencyMs,
            baselineAvgLatencyMs: baselineAvgLatencyMs,
            speedGainPercent: speedGainPercent,
            speedSavedMsPerTurn: speedSavedMsPerTurn,
            speedSampleCount: speedSampleCount,
            successRatePercent: successRatePct,
            retryCount: retryCount,
            top10PercentCostSharePercent: top10Share,
            speedBasisLabel: speedBasisLabel
        )
    }

    private func buildAutoModelHeaders(
        decision: RoutingDecision,
        executedModel: ModelConfig,
        executedProvider: ProviderConfig,
        attemptNumber: Int
    ) -> [String: String] {
        let reasonText = decision.matchedRules.joined(separator: " | ")
        let safeReason = String(reasonText.unicodeScalars.filter { $0.isASCII && $0.value >= 32 && $0.value < 127 })
        return [
            "X-AutoModel-Executed-Model": executedModel.modelID,
            "X-AutoModel-Provider": sanitizeHeaderASCII(executedProvider.name),
            "X-AutoModel-Strategy": decision.strategyName == "省钱优先" ? "cost_first" : (decision.strategyName == "质量优先" ? "quality_first" : "balanced"),
            "X-AutoModel-Effort": decision.selectedEffort.rawValue,
            "X-AutoModel-Subtask": decision.subtaskCategory?.rawValue ?? "routine_coding",
            "X-AutoModel-Policy-Version": "\(decision.policyVersion)",
            "X-AutoModel-Decision-Ms": String(format: "%.2f", decision.decisionDurationMs),
            "X-AutoModel-Attempt": "\(attemptNumber)",
            "X-AutoModel-Reason": safeReason.isEmpty ? "deterministic_local_route" : safeReason
        ]
    }

    private func sanitizeHeaderASCII(_ value: String) -> String {
        let filtered = String(value.unicodeScalars.filter { $0.isASCII && $0.value >= 32 && $0.value < 127 })
        return filtered.isEmpty ? "provider" : filtered
    }

    private func buildRequestPreview(payload: [String: Any], secrets: [String]) -> String? {
        guard let messages = payload["messages"] as? [[String: Any]] else { return nil }
        let summary = messages.suffix(4).map { msg -> String in
            let role = (msg["role"] as? String) ?? "unknown"
            if let text = msg["content"] as? String {
                return "[\(role)] \(text.prefix(400))"
            }
            if let arr = msg["content"] as? [[String: Any]] {
                let parts = arr.compactMap { part -> String? in
                    if let t = part["text"] as? String { return t }
                    if let type = part["type"] as? String { return "[\(type)]" }
                    return nil
                }.joined(separator: " ")
                return "[\(role)] \(parts.prefix(400))"
            }
            return "[\(role)]"
        }.joined(separator: "\n")
        return SecretRedactor.redact(summary, secrets: secrets)
    }

    private func appendCallRecord(_ record: CallRecord) {
        callHistory.insert(record, at: 0)
        if callHistory.count > 500 {
            callHistory = Array(callHistory.prefix(500))
        }
        try? persistence.saveHistory(callHistory)
    }

    private func openAIErrorJSON(message: String, type: String, code: String) -> Data {
        let obj: [String: Any] = [
            "error": [
                "message": message,
                "type": type,
                "code": code
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    private func buildRuntimeMetricsMap() -> [UUID: ModelRuntimeMetrics] {
        var stats: [UUID: (totalLatency: Double, successCount: Int, totalCount: Int)] = [:]
        for record in callHistory.prefix(150) {
            for attempt in record.attempts {
                guard let mid = attempt.modelUUID else { continue }
                var cur = stats[mid] ?? (0, 0, 0)
                cur.totalCount += 1
                if attempt.succeeded {
                    cur.successCount += 1
                    cur.totalLatency += attempt.firstTokenMs ?? attempt.totalLatencyMs
                }
                stats[mid] = cur
            }
        }
        var result: [UUID: ModelRuntimeMetrics] = [:]
        for (mid, s) in stats where s.totalCount > 0 {
            let avg = s.successCount > 0 ? (s.totalLatency / Double(s.successCount)) : 10_000.0
            let rate = Double(s.successCount) / Double(s.totalCount)
            result[mid] = ModelRuntimeMetrics(averageLatencyMs: avg, successRate: rate, sampleCount: s.totalCount)
        }
        return result
    }

    private func elapsedMs(since start: DispatchTime) -> Double {
        let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000.0
    }
}
