import Foundation

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func markTrue() {
        lock.withLock { flag = true }
    }

    var value: Bool {
        lock.withLock { flag }
    }
}

public enum LocalTokenPersistenceError: Error, LocalizedError, Sendable {
    case verificationFailed

    public var errorDescription: String? {
        "Keychain 未返回刚写入的本地 API token；无法确认凭据已持久化。"
    }
}

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

    @Published public internal(set) var config: AppConfigBundle
    @Published public private(set) var callHistory: [CallRecord]
    @Published public private(set) var dailyUsageLedger: DailyUsageLedger
    @Published public private(set) var onboardingFunnel: LocalOnboardingFunnelState
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
    @Published public private(set) var cooldownUntilByModelID: [UUID: Date] = [:]
    @Published public private(set) var liveRoutingState: LiveRoutingState = LiveRoutingState()
    @Published public private(set) var localAPITokenPersistenceError: String?
    @Published public private(set) var localModelAPIKey: String?
    @Published public private(set) var localModelAPIKeyError: String?
    private var transientFailureCountByModelID: [UUID: Int] = [:]
    private var retryNotBeforeByProviderID: [UUID: UInt64] = [:]

    public var isLocalAPITokenPersistent: Bool { localAPITokenPersistenceError == nil }
    public var manualAgentAPIKey: String? {
        guard isLocalAPITokenPersistent, localModelAPIKeyError == nil else { return nil }
        return localModelAPIKey ?? localAPIToken
    }

    public var manualAgentRootURL: String {
        if case .running(let port) = proxyState { return "http://127.0.0.1:\(port)" }
        return config.proxySettings.rootURLString
    }

    public enum EngineAlertLevel: Equatable, Sendable {
        case normal
        case warning(String)
        case error(String)
    }

    public let persistence: LocalPersistenceStore
    public let keychain: any KeychainServiceProtocol
    public let router: ModelRouter
    public let upstreamClient: UpstreamClient
    public let discoveryService: LocalModelDiscoveryService
    public let agentConfigService: AgentConfigService
    public let localTestUpstream: LocalTestUpstreamServer
    public let alertNotifier: any SystemAlertNotifierProtocol
    public let trafficLimiter: TrafficLimiter
    public let keyPoolRouter = ProviderKeyPoolRouter()
    public let codexOAuthClient: CodexOAuthClient
    private let codexRefreshCoordinator = CodexTokenRefreshCoordinator()
    private let codexHomeDirectory: URL
    public private(set) var localAPIToken: String
    private var proxyServer: ProxyServer?
    private var backgroundMaintenanceTask: Task<Void, Never>?
    private var activeRequestCount = 0
    private var requestDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShuttingDown = false
    var budgetLedger: BudgetLedger
    private var pendingSQLiteUpserts: [CallRecord] = []

    public init(
        persistence: LocalPersistenceStore = LocalPersistenceStore(),
        keychain: any KeychainServiceProtocol = MacOSKeychainService(),
        router: ModelRouter = ModelRouter(),
        upstreamClient: UpstreamClient = UpstreamClient(),
        discoveryService: LocalModelDiscoveryService = LocalModelDiscoveryService(),
        agentConfigService: AgentConfigService? = nil,
        alertNotifier: any SystemAlertNotifierProtocol = MacOSSystemAlertNotifier(),
        codexOAuthClient: CodexOAuthClient = CodexOAuthClient(),
        codexHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
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
        self.alertNotifier = alertNotifier
        self.trafficLimiter = TrafficLimiter()
        self.codexOAuthClient = codexOAuthClient
        self.codexHomeDirectory = codexHomeDirectory
        do {
            self.localAPIToken = try LocalAPITokenManager.loadOrCreate(keychain: keychain)
            self.localAPITokenPersistenceError = nil
        } catch {
            // Keep a random per-process credential only to avoid an insecure shared placeholder,
            // but block proxy startup and Agent writes until it is durably stored.
            self.localAPIToken = (try? LocalAPITokenManager.generate()) ?? UUID().uuidString + UUID().uuidString
            self.localAPITokenPersistenceError = "本地 API token 未能持久化到 Keychain：\(error.localizedDescription)。重启后 token 会变化，已接入的 Agent 将失效；在修复前不会自动启动代理或写入 Agent 配置。"
        }
        self.localModelAPIKey = nil
        self.localModelAPIKeyError = nil

        let loadedConfig = persistence.loadConfig()
        self.config = loadedConfig
        if loadedConfig.privacySettings.historyRetentionDays > 0 {
            _ = try? persistence.pruneHistory(olderThanDays: loadedConfig.privacySettings.historyRetentionDays)
        }
        let loadedHistory = persistence.loadHistory()
        self.callHistory = loadedHistory
        if let storedLedger = persistence.loadBudgetLedger() {
            self.budgetLedger = storedLedger
        } else {
            let backfilled = BudgetLedger(records: loadedHistory)
            self.budgetLedger = backfilled
            try? persistence.saveBudgetLedger(backfilled)
        }
        if let storedDailyUsage = persistence.loadDailyUsageLedger() {
            self.dailyUsageLedger = storedDailyUsage
        } else {
            let backfilledDaily = DailyUsageLedger(records: loadedHistory)
            self.dailyUsageLedger = backfilledDaily
            try? persistence.saveDailyUsageLedger(backfilledDaily)
        }
        self.onboardingFunnel = persistence.loadOnboardingFunnel()
        if isLocalAPITokenPersistent {
            try? reloadLocalModelAPIKey()
        } else {
            localModelAPIKeyError = "请先恢复本地管理 token，再读取模型密钥。"
        }
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
        guard isLocalAPITokenPersistent else {
            proxyState = .error("本地 API token 未持久化到 Keychain；拒绝启动代理，避免 Agent 使用重启后失效的临时凭据。")
            return
        }
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
                emitAlertIfEnabled(SystemAlertEvent(
                    category: .portConflict,
                    dedupKey: "port-\(occupiedPort)",
                    title: "AutoRoute 端口冲突",
                    body: "本地端口 127.0.0.1:\(occupiedPort) 已被占用，请在应用中切换端口。"
                ))
            default:
                proxyState = .error(err.localizedDescription)
            }
        } catch {
            proxyState = .error(error.localizedDescription)
        }
    }

    public func retryPersistingLocalAPIToken() throws {
        let wasUnavailable = !isLocalAPITokenPersistent
        do {
            // A successful Keychain read is already proof that an existing token
            // is stored. Reading it a second time may repeat the system prompt.
            let recovered: String
            if let existing = try keychain.getLocalAPIToken() {
                guard !existing.isEmpty else { throw LocalTokenPersistenceError.verificationFailed }
                recovered = existing
            } else {
                let created = try LocalAPITokenManager.loadOrCreate(keychain: keychain)
                guard let persisted = try keychain.getLocalAPIToken(),
                      LocalAPITokenManager.constantTimeEquals(persisted, created) else {
                    throw LocalTokenPersistenceError.verificationFailed
                }
                recovered = created
            }
            localAPIToken = recovered
            localAPITokenPersistenceError = nil
            try? reloadLocalModelAPIKey()
            if wasUnavailable && backgroundMaintenanceTask != nil {
                // Recovery must not trigger launch discovery or a nearly due health check.
                startBackgroundDiscoveryAndHealthLoop(runLaunchDiscovery: false)
            }
        } catch {
            localAPITokenPersistenceError = "本地 API token 仍未持久化：\(error.localizedDescription)。请检查 macOS Keychain 访问权限后重试；代理启动和 Agent 写入保持禁用。"
            throw error
        }
    }

    public func reloadLocalModelAPIKey() throws {
        do {
            guard isLocalAPITokenPersistent else { throw LocalModelAPIKeyError.managementTokenUnavailable }
            let key = try keychain.getLocalModelAPIKey()
            if let key { try LocalModelAPIKeyError.validate(key, managementToken: localAPIToken) }
            localModelAPIKey = key
            localModelAPIKeyError = nil
        } catch {
            localModelAPIKeyError = "无法读取本地模型密钥：\(error.localizedDescription)"
            throw error
        }
    }

    public func setLocalModelAPIKey(_ key: String) throws {
        guard isLocalAPITokenPersistent else { throw LocalModelAPIKeyError.managementTokenUnavailable }
        try LocalModelAPIKeyError.validate(key, managementToken: localAPIToken)
        try keychain.setLocalModelAPIKey(key)
        localModelAPIKey = key
        localModelAPIKeyError = nil
    }

    public func clearLocalModelAPIKey() throws {
        try keychain.deleteLocalModelAPIKey()
        localModelAPIKey = nil
        localModelAPIKeyError = nil
    }

    public func stopProxy() {
        proxyServer?.stop()
        proxyState = .stopped
    }

    public func shutdown() async throws {
        isShuttingDown = true
        let hadBackgroundTasks = backgroundMaintenanceTask != nil
        stopBackgroundTasks()
        if activeRequestCount > 0 {
            await withCheckedContinuation { requestDrainWaiters.append($0) }
        }
        do {
            try await persistence.flush()
            stopProxy()
            stopLocalTestUpstream()
        } catch {
            lastPersistenceError = "退出前持久化失败：\(error.localizedDescription)"
            isShuttingDown = false
            if hadBackgroundTasks { startBackgroundDiscoveryAndHealthLoop() }
            throw error
        }
    }

    public func stopBackgroundTasks() {
        backgroundMaintenanceTask?.cancel()
        backgroundMaintenanceTask = nil
    }

    private func startBackgroundDiscoveryAndHealthLoop(runLaunchDiscovery: Bool = true) {
        backgroundMaintenanceTask?.cancel()
        // Capture startup eligibility so an immediate recovery cannot launch discovery.
        let shouldDiscoverOnLaunch = runLaunchDiscovery && isLocalAPITokenPersistent
            && config.proxySettings.autoDiscoverAndProbeOnLaunch
        backgroundMaintenanceTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            if shouldDiscoverOnLaunch && self.isLocalAPITokenPersistent {
                _ = await self.discoverAndProbeLocalModels(credentialAccess: .cachedOnly)
            }
            while !Task.isCancelled {
                let mins = self.config.proxySettings.periodicHealthCheckMinutes
                if mins <= 0 {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    continue
                }
                try? await Task.sleep(nanoseconds: UInt64(mins) * 60 * 1_000_000_000)
                if Task.isCancelled { break }
                guard self.isLocalAPITokenPersistent else { continue }
                _ = await self.probeAllEnabledModels(credentialAccess: .cachedOnly)
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
        let keys: [String]? = apiKey.map { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        try upsertProvider(provider, apiKeys: keys)
    }

    public func upsertProvider(_ provider: ProviderConfig, apiKeys: [String]?) throws {
        var updated = provider
        if let keys = apiKeys {
            let cleaned = APIKeyPoolCodec.normalize(keys)
            try keychain.setAPIKeys(cleaned, for: provider.id)
            updated.configuredKeyCount = cleaned.count
            keyPoolRouter.reset(providerID: provider.id)
            // Reset authError when key pool changes so hard constraints allow re-verification
            if updated.healthStatus == .authError {
                updated.healthStatus = .unknown
                updated.lastErrorMessage = nil
            }
        } else if updated.configuredKeyCount == 0,
                  let existing = config.providers.first(where: { $0.id == updated.id }) {
            updated.configuredKeyCount = existing.configuredKeyCount
        }

        if let idx = config.providers.firstIndex(where: { $0.id == updated.id }) {
            config.providers[idx] = updated
        } else {
            config.providers.append(updated)
        }
        saveConfig()
    }

    @discardableResult
    public func addProviderFromPreset(
        _ preset: ProviderPreset,
        customName: String? = nil,
        customBaseURL: String? = nil,
        apiKeys: [String] = [],
        proxyURL: String? = nil,
        customHeaders: [String: String]? = nil,
        passThroughHeaderNames: [String] = [],
        keyRotationStrategy: ProviderKeyRotationStrategy = .roundRobin,
        seedRecommendedModels: Bool = true
    ) throws -> (provider: ProviderConfig, seededModelCount: Int) {
        let provider = preset.makeProviderConfig(
            customName: customName,
            customBaseURL: customBaseURL,
            proxyURL: proxyURL,
            customHeaders: customHeaders,
            passThroughHeaderNames: passThroughHeaderNames,
            keyRotationStrategy: keyRotationStrategy
        )
        try upsertProvider(provider, apiKeys: apiKeys)
        var seededCount = 0
        if seedRecommendedModels {
            for model in preset.makeModelConfigs(providerID: provider.id) {
                config.models.append(model)
                seededCount += 1
            }
            if seededCount > 0 {
                saveConfig()
                autoConfigureModelTiers(forceResetManual: false)
            }
        }
        let persisted = config.providers.first(where: { $0.id == provider.id }) ?? provider
        return (persisted, seededCount)
    }

    @discardableResult
    public func importProvidersFromMagpieJSON(_ data: Data) throws -> ProviderImportResult {
        let entries = try ProviderImportExportService.parseImportData(data)
        var addedProviders = 0
        var updatedProviders = 0
        var addedModels = 0
        var names: [String] = []

        for entry in entries {
            let normIncoming = normalizeBaseURLString(entry.baseURL)
            let providerID: UUID

            if let existingIdx = config.providers.firstIndex(where: {
                normalizeBaseURLString($0.baseURL) == normIncoming && $0.apiProtocol == entry.apiProtocol
            }) {
                var existing = config.providers[existingIdx]
                for (k, v) in entry.customHeaders where existing.customHeaders[k] == nil {
                    existing.customHeaders[k] = v
                }
                for h in entry.passThroughHeaderNames where !existing.passThroughHeaderNames.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) {
                    existing.passThroughHeaderNames.append(h)
                }
                if existing.proxyURL == nil, let proxy = entry.proxyURL {
                    existing.proxyURL = proxy
                }
                if existing.presetID == nil, let preset = entry.presetID {
                    existing.presetID = preset
                }
                if existing.discoveredSource == nil {
                    existing.discoveredSource = entry.source
                }
                if !entry.apiKeys.isEmpty {
                    let currentKeys = (try? keychain.getAPIKeys(for: existing.id)) ?? []
                    let mergedKeys = APIKeyPoolCodec.normalize(currentKeys + entry.apiKeys)
                    try keychain.setAPIKeys(mergedKeys, for: existing.id)
                    existing.configuredKeyCount = mergedKeys.count
                    keyPoolRouter.reset(providerID: existing.id)
                }
                config.providers[existingIdx] = existing
                providerID = existing.id
                updatedProviders += 1
                names.append(existing.name)
            } else {
                let provider = ProviderConfig(
                    name: entry.name,
                    baseURL: entry.baseURL,
                    isEnabled: true,
                    timeoutSeconds: 45,
                    healthStatus: .unknown,
                    discoveredSource: entry.source,
                    apiProtocol: entry.apiProtocol,
                    accountID: entry.accountID,
                    presetID: entry.presetID,
                    customHeaders: entry.customHeaders,
                    passThroughHeaderNames: entry.passThroughHeaderNames,
                    proxyURL: entry.proxyURL,
                    configuredKeyCount: entry.apiKeys.count
                )
                if !entry.apiKeys.isEmpty {
                    try keychain.setAPIKeys(entry.apiKeys, for: provider.id)
                }
                config.providers.append(provider)
                providerID = provider.id
                addedProviders += 1
                names.append(provider.name)
            }

            for mEntry in entry.models {
                if let existingIdx = config.models.firstIndex(where: { $0.providerID == providerID && $0.modelID == mEntry.modelID }) {
                    if mEntry.contextWindow != 128_000 {
                        config.models[existingIdx].contextWindow = mEntry.contextWindow
                    }
                    if config.models[existingIdx].inputPricePerMillion == nil, let inp = mEntry.inputPricePerMillion {
                        config.models[existingIdx].inputPricePerMillion = inp
                    }
                    if config.models[existingIdx].outputPricePerMillion == nil, let out = mEntry.outputPricePerMillion {
                        config.models[existingIdx].outputPricePerMillion = out
                    }
                } else {
                    config.models.append(ModelConfig(
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
                    ))
                    addedModels += 1
                }
            }
        }

        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)
        return ProviderImportResult(
            addedProvidersCount: addedProviders,
            updatedProvidersCount: updatedProviders,
            addedModelsCount: addedModels,
            importedProviderNames: names
        )
    }

    public func exportSanitizedProvidersJSON() throws -> Data {
        try ProviderImportExportService.exportSanitizedTemplate(
            providers: config.providers,
            models: config.models,
            secretsToRedact: keychain.allKnownSecretValues()
        )
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
        keyPoolRouter.reset(providerID: id)
        try? keychain.deleteAPIKey(for: id)
        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)
    }

    public func cachedAPIKey(for providerID: UUID) -> CachedAPIKey {
        keychain.cachedAPIKey(for: providerID)
    }

    public func cachedAPIKeys(for providerID: UUID) -> [String]? {
        keychain.cachedAPIKeys(for: providerID)
    }

    public func hasAPIKey(for providerID: UUID) -> Bool {
        if case .found(let key) = cachedAPIKey(for: providerID) { return !key.isEmpty }
        return false
    }

    public func apiKeyForProvider(_ providerID: UUID) -> String? {
        (try? keychain.getAPIKeys(for: providerID))?.first
    }

    public func apiKeysForProvider(_ providerID: UUID) -> [String] {
        (try? keychain.getAPIKeys(for: providerID)) ?? []
    }

    // MARK: - Codex Subscription Pool & OAuth Lifecycle

    public var codexSubscriptionProvider: ProviderConfig? {
        config.providers.first(where: { $0.apiProtocol == .codexChatGPT })
    }

    public func codexAccountCooldownUntil(providerID: UUID, accountID: UUID) -> Date? {
        keyPoolRouter.accountCooldownUntil(providerID: providerID, accountID: accountID)
    }

    public func assignModelAsBaseTier(_ modelID: UUID, tier: ModelTier) {
        setTierModel(tier: tier, modelUUID: modelID, isManual: true)
    }

    public func setPinnedModel(_ modelID: UUID?) {
        updatePolicy { $0.pinnedModelID = modelID }
    }

    @discardableResult
    public func importCodexCLIAuthAccount(
        homeDirectory: URL? = nil
    ) throws -> (provider: ProviderConfig, account: CodexAccountSummary, addedModelsCount: Int) {
        let resolvedHome = homeDirectory ?? codexHomeDirectory
        let codexDir = CodexAuthFileParser.defaultCodexDirectory(homeDirectory: resolvedHome)
        let authURL = codexDir.appendingPathComponent("auth.json")
        guard let account = CodexAuthFileParser.parseAuthFile(at: authURL) else {
            throw CodexOAuthError.invalidResponse("未在 ~/.codex/auth.json 找到有效的 ChatGPT OAuth 订阅凭据，请先登录 ChatGPT 账号或运行 codex login。")
        }
        let modelSlugs = CodexAuthFileParser.collectModelSlugs(codexDir: codexDir)
        return try addCodexSubscriptionAccount(account, modelSlugs: modelSlugs, discoveredSource: "codex/auth.json")
    }

    @discardableResult
    public func addCodexSubscriptionAccount(
        _ account: CodexSubscriptionAccount,
        modelSlugs: [String] = ["gpt-5.4", "gpt-5.3-codex", "gpt-5.4-mini"],
        discoveredSource: String = "codex/oauth"
    ) throws -> (provider: ProviderConfig, account: CodexAccountSummary, addedModelsCount: Int) {
        let providerID: UUID
        let mergedAccounts: [CodexSubscriptionAccount]

        if let idx = config.providers.firstIndex(where: { $0.apiProtocol == .codexChatGPT }) {
            providerID = config.providers[idx].id
            let existing = (try? keychain.getCodexAccounts(for: providerID, fallbackAccountID: config.providers[idx].accountID)) ?? []
            mergedAccounts = CodexAccountPoolCodec.mergeAccounts(existing: existing, incoming: [account])
            try keychain.setCodexAccounts(mergedAccounts, for: providerID)
            config.providers[idx].isEnabled = true
            config.providers[idx].healthStatus = .healthy
            config.providers[idx].lastErrorMessage = nil
            config.providers[idx].lastCheckedAt = Date()
            config.providers[idx].configuredKeyCount = mergedAccounts.count
            config.providers[idx].subscriptionAccounts = mergedAccounts.map(\.summary)
            if config.providers[idx].accountID == nil || config.providers[idx].accountID?.isEmpty == true {
                config.providers[idx].accountID = mergedAccounts.first?.accountID
            }
            if config.providers[idx].discoveredSource == nil {
                config.providers[idx].discoveredSource = discoveredSource
            }
        } else {
            mergedAccounts = [account]
            let newProvider = ProviderConfig(
                name: "Codex 订阅 (ChatGPT)",
                baseURL: "https://chatgpt.com/backend-api/codex",
                isEnabled: true,
                timeoutSeconds: 90,
                healthStatus: .healthy,
                lastCheckedAt: Date(),
                discoveredSource: discoveredSource,
                apiProtocol: .codexChatGPT,
                accountID: account.accountID,
                keyRotationStrategy: .priorityFailover,
                configuredKeyCount: mergedAccounts.count,
                subscriptionAccounts: mergedAccounts.map(\.summary)
            )
            try keychain.setCodexAccounts(mergedAccounts, for: newProvider.id)
            config.providers.append(newProvider)
            providerID = newProvider.id
        }

        keyPoolRouter.reset(providerID: providerID)

        // Restore any Codex models previously flagged unavailable due to expired auth
        for mIdx in config.models.indices where config.models[mIdx].providerID == providerID {
            if config.models[mIdx].isAutoEvicted {
                config.models[mIdx].isAutoEvicted = false
                config.models[mIdx].availabilityStatus = .available
                config.models[mIdx].lastAvailabilityNote = nil
            }
        }

        var addedModelsCount = 0
        for slug in modelSlugs where !slug.isEmpty {
            if !config.models.contains(where: { $0.providerID == providerID && $0.modelID == slug }) {
                let meta = LocalModelDiscoveryService.buildDiscoveredModelPublic(modelID: slug, source: discoveredSource)
                config.models.append(ModelConfig(
                    providerID: providerID,
                    modelID: meta.modelID,
                    displayName: meta.displayName,
                    isEnabled: true,
                    inputPricePerMillion: meta.inputPricePerMillion,
                    outputPricePerMillion: meta.outputPricePerMillion,
                    contextWindow: meta.contextWindow,
                    capabilities: meta.capabilities,
                    defaultRole: meta.defaultRole,
                    qualityScore: meta.qualityScore,
                    speedScore: meta.speedScore,
                    availabilityStatus: .available,
                    discoveredSource: discoveredSource
                ))
                addedModelsCount += 1
            }
        }

        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)

        let persistedProvider = config.providers.first(where: { $0.id == providerID })!
        let matchedSummary = persistedProvider.subscriptionAccounts.first(where: {
            ($0.accountID != nil && $0.accountID == account.accountID)
            || ($0.email != nil && $0.email == account.email)
        }) ?? account.summary
        return (persistedProvider, matchedSummary, addedModelsCount)
    }

    public func removeCodexSubscriptionAccount(accountID: UUID, from providerID: UUID) throws {
        guard let idx = config.providers.firstIndex(where: { $0.id == providerID }) else { return }
        let existing = try keychain.getCodexAccounts(for: providerID, fallbackAccountID: config.providers[idx].accountID)
        let remaining = existing.filter { $0.id != accountID }
        try keychain.setCodexAccounts(remaining, for: providerID)
        config.providers[idx].subscriptionAccounts = remaining.map(\.summary)
        config.providers[idx].configuredKeyCount = remaining.count
        config.providers[idx].accountID = remaining.first?.accountID
        if remaining.isEmpty {
            config.providers[idx].healthStatus = .unknown
        }
        keyPoolRouter.clearAccountCooldown(providerID: providerID, accountID: accountID)
        saveConfig()
    }

    @discardableResult
    public func refreshCodexSubscriptionAccount(accountID: UUID, providerID: UUID) async throws -> CodexAccountSummary {
        guard let idx = config.providers.firstIndex(where: { $0.id == providerID }) else {
            throw CodexOAuthError.invalidResponse("供应商不存在")
        }
        let existing = try keychain.getCodexAccounts(for: providerID, fallbackAccountID: config.providers[idx].accountID)
        guard let target = existing.first(where: { $0.id == accountID }) else {
            throw CodexOAuthError.invalidResponse("未找到指定的 Codex 订阅账号")
        }
        let refreshed = try await refreshOrSyncCodexAccountStrict(target, providerID: providerID, forceRefresh: true)
        keyPoolRouter.clearAccountCooldown(providerID: providerID, accountID: refreshed.id)
        updateProviderHealth(providerID: providerID, status: .healthy, error: nil)
        return refreshed.summary
    }

    private func refreshOrSyncCodexAccount(
        _ account: CodexSubscriptionAccount,
        providerID: UUID,
        forceRefresh: Bool
    ) async -> CodexSubscriptionAccount? {
        try? await refreshOrSyncCodexAccountStrict(account, providerID: providerID, forceRefresh: forceRefresh)
    }

    private func refreshOrSyncCodexAccountStrict(
        _ account: CodexSubscriptionAccount,
        providerID: UUID,
        forceRefresh: Bool
    ) async throws -> CodexSubscriptionAccount {
        // If imported from ~/.codex/auth.json, check whether Codex CLI already refreshed the token on disk.
        if account.source == "codex_cli" {
            let authURL = CodexAuthFileParser.defaultAuthURL(homeDirectory: codexHomeDirectory)
            if let diskAccount = CodexAuthFileParser.parseAuthFile(at: authURL),
               diskAccount.accessToken != account.accessToken,
               !diskAccount.isExpiredOrExpiringSoon(leeway: 60),
               (account.accountID == nil || diskAccount.accountID == nil || account.accountID == diskAccount.accountID) {
                var adopted = account
                adopted.accessToken = diskAccount.accessToken
                if let newRefresh = diskAccount.refreshToken {
                    adopted.refreshToken = newRefresh
                }
                adopted.expiresAt = diskAccount.effectiveExpiresAt
                adopted.email = diskAccount.email ?? adopted.email
                adopted.planType = diskAccount.planType ?? adopted.planType
                adopted.accountID = diskAccount.accountID ?? adopted.accountID
                adopted.lastRefreshedAt = Date()
                try persistUpdatedCodexAccount(adopted, providerID: providerID)
                return adopted
            }
        }

        if !forceRefresh, !account.isExpiredOrExpiringSoon() {
            return account
        }

        let refreshed = try await codexRefreshCoordinator.refresh(account: account, using: codexOAuthClient)
        try persistUpdatedCodexAccount(refreshed, providerID: providerID)
        return refreshed
    }

    private func persistUpdatedCodexAccount(_ updated: CodexSubscriptionAccount, providerID: UUID) throws {
        guard let pIdx = config.providers.firstIndex(where: { $0.id == providerID }) else { return }
        let current = (try? keychain.getCodexAccounts(for: providerID, fallbackAccountID: config.providers[pIdx].accountID)) ?? []
        let nextList: [CodexSubscriptionAccount]
        if let matchIdx = current.firstIndex(where: { $0.id == updated.id }) {
            var copy = current
            copy[matchIdx] = updated
            nextList = copy
        } else {
            nextList = CodexAccountPoolCodec.mergeAccounts(existing: current, incoming: [updated])
        }
        try keychain.setCodexAccounts(nextList, for: providerID)
        config.providers[pIdx].subscriptionAccounts = nextList.map(\.summary)
        config.providers[pIdx].configuredKeyCount = nextList.count
        if config.providers[pIdx].accountID == nil {
            config.providers[pIdx].accountID = nextList.first?.accountID
        }
        saveConfig()
    }

    public func testProviderConnection(providerID: UUID) async -> Result<[String], UpstreamError> {
        guard let provider = config.providers.first(where: { $0.id == providerID }) else {
            return .failure(.invalidResponse(message: "供应商不存在"))
        }

        if provider.apiProtocol == .codexChatGPT {
            do {
                let accounts = try keychain.getCodexAccounts(for: providerID, fallbackAccountID: provider.accountID)
                guard !accounts.isEmpty else {
                    let err = UpstreamError.authError(statusCode: 401, message: "尚未配置 Codex 订阅账号，请先登录或从 ~/.codex/auth.json 导入。")
                    updateProviderHealth(providerID: providerID, status: .authError, error: err.localizedDescription)
                    return .failure(err)
                }
                for acct in accounts where acct.isExpiredOrExpiringSoon() && acct.canRefresh {
                    _ = await refreshOrSyncCodexAccount(acct, providerID: providerID, forceRefresh: false)
                }
                updateProviderHealth(providerID: providerID, status: .healthy, error: nil)
                let modelIDs = config.models.filter { $0.providerID == providerID }.map(\.modelID)
                return .success(modelIDs)
            } catch {
                return .failure(.invalidResponse(message: "无法读取 Keychain；未测试连接。"))
            }
        }

        let key: String?
        do {
            let keys = try keychain.getAPIKeys(for: providerID)
            key = keyPoolRouter.orderedKeys(for: providerID, keys: keys, strategy: provider.keyRotationStrategy).first
        } catch {
            return .failure(.invalidResponse(message: "无法读取 Keychain；未测试连接。"))
        }
        updateProviderHealth(providerID: providerID, status: .checking, error: nil)
        let secrets = keychain.allKnownSecretValues()
        let result = await upstreamClient.fetchModels(provider: provider, apiKey: key, secretsToRedact: secrets)

        switch result {
        case .success(let models):
            if provider.apiProtocol == .workBuddy, config.providers.contains(where: { $0.id == providerID }) {
                addWorkBuddyModels(models, providerID: providerID)
                autoConfigureModelTiers(forceResetManual: false)
            }
            updateProviderHealth(providerID: providerID, status: .healthy, error: nil)
            return .success(models)
        case .failure(let err):
            let status: ProviderHealthStatus
            switch err {
            case .authError:
                status = .authError
            case .networkError, .invalidURL:
                status = .networkError
            case .clientDisconnected:
                status = .healthy
            case .requestDeadlineExceeded:
                status = .networkError
            case .httpError, .modelUnavailable, .invalidResponse:
                status = .serverError
            }
            let persistedError = persistedUpstreamErrorSummary(for: err, detailedMessage: err.localizedDescription)
            updateProviderHealth(providerID: providerID, status: status, error: persistedError)
            return .failure(err)
        }
    }

    private func addWorkBuddyModels(_ modelIDs: [String], providerID: UUID) {
        var existing = Set(config.models.lazy.filter { $0.providerID == providerID }.map(\.modelID))
        for id in modelIDs where existing.insert(id).inserted {
            config.models.append(ModelConfig(
                providerID: providerID,
                modelID: id,
                capabilities: [.chat, .tools],
                discoveredSource: "live:\(WorkBuddyProtocol.configPath)"
            ))
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

    /// Applies exponential cooldown for transient upstream errors (429 / 5xx / timeout)
    /// without permanently evicting the model or overwriting its tier assignment.
    private func recordTransientCooldown(for modelID: UUID, reason: String) {
        let count = (transientFailureCountByModelID[modelID] ?? 0) + 1
        transientFailureCountByModelID[modelID] = count
        let schedule: [TimeInterval] = [15, 45, 120, 300]
        let cooldownSec = schedule[min(count - 1, schedule.count - 1)]
        cooldownUntilByModelID[modelID] = Date().addingTimeInterval(cooldownSec)
        updateModelAvailability(
            modelID: modelID,
            status: .available,
            note: "限流/抖动冷却 \(Int(cooldownSec))s（第 \(count) 次，到期自动恢复）：\(reason)",
            autoEvicted: false
        )
        checkTierDegradationAlert(for: modelID)
    }

    private func emitAlertIfEnabled(_ event: SystemAlertEvent) {
        guard config.privacySettings.enableSystemNotifications else { return }
        alertNotifier.notify(event)
    }

    private func checkTierDegradationAlert(for modelID: UUID) {
        let now = Date()
        for tier in ModelTier.allCases {
            let pool = config.policy.modelIDs(for: tier)
            guard !pool.isEmpty, pool.contains(modelID) else { continue }
            let allCooling = pool.allSatisfy { id in
                guard let until = cooldownUntilByModelID[id] else { return false }
                return until > now
            }
            if allCooling {
                emitAlertIfEnabled(SystemAlertEvent(
                    category: .tierDegraded,
                    dedupKey: "tier-\(tier.rawValue)",
                    title: "AutoRoute \(tier.shortName) 档位模型已全部冷却",
                    body: "\(tier.shortName) 档位的 \(pool.count) 个模型均进入限流/抖动冷却，后续请求将自动降级或等待恢复。"
                ))
            }
        }
    }

    public func restoreEvictedModel(id: UUID) {
        guard let idx = config.models.firstIndex(where: { $0.id == id }) else { return }
        transientFailureCountByModelID[id] = 0
        cooldownUntilByModelID.removeValue(forKey: id)
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

    public enum CredentialAccess: Sendable { case interactive, cachedOnly }

    private func credential(for id: UUID, access: CredentialAccess) -> CachedAPIKey {
        if access == .cachedOnly { return keychain.cachedAPIKey(for: id) }
        do {
            if let key = try keychain.getAPIKey(for: id) { return .found(key) }
            return .missing
        } catch {
            return .unknown
        }
    }

    @discardableResult
    public func discoverAndProbeLocalModels(
        homeDirectory: URL? = nil,
        scanWellKnownLocalPorts: Bool = true,
        credentialAccess: CredentialAccess = .interactive
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
        var credentialFailures = Set<UUID>()

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
                for (k, v) in entry.customHeaders where config.providers[existingIdx].customHeaders[k] == nil {
                    config.providers[existingIdx].customHeaders[k] = v
                }
                for h in entry.passThroughHeaderNames where !config.providers[existingIdx].passThroughHeaderNames.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) {
                    config.providers[existingIdx].passThroughHeaderNames.append(h)
                }
                if config.providers[existingIdx].proxyURL == nil, let proxy = entry.proxyURL {
                    config.providers[existingIdx].proxyURL = proxy
                }
                if config.providers[existingIdx].presetID == nil, let preset = entry.presetID {
                    config.providers[existingIdx].presetID = preset
                }
                // Only explicit discovery may authorize reads or import credentials.
                // A failed read is unknown, never evidence that an item is missing.
                if credentialAccess == .interactive {
                    if entry.apiProtocol == .codexChatGPT, !entry.codexAccounts.isEmpty {
                        let existing = credential(for: providerID, access: .interactive)
                        if existing == .unknown {
                            credentialFailures.insert(providerID)
                        } else {
                            let currentAccounts = (try? keychain.getCodexAccounts(for: providerID, fallbackAccountID: config.providers[existingIdx].accountID)) ?? []
                            let mergedAccounts = CodexAccountPoolCodec.mergeAccounts(existing: currentAccounts, incoming: entry.codexAccounts)
                            do {
                                try keychain.setCodexAccounts(mergedAccounts, for: providerID)
                                config.providers[existingIdx].configuredKeyCount = mergedAccounts.count
                                config.providers[existingIdx].subscriptionAccounts = mergedAccounts.map(\.summary)
                            } catch {
                                credentialFailures.insert(providerID)
                            }
                        }
                    } else if !entry.apiKeys.isEmpty {
                        let existing = credential(for: providerID, access: .interactive)
                        if existing == .unknown {
                            credentialFailures.insert(providerID)
                        } else if existing == .missing || entry.apiProtocol == .codexChatGPT {
                            do {
                                try keychain.setAPIKeys(entry.apiKeys, for: providerID)
                                config.providers[existingIdx].configuredKeyCount = entry.apiKeys.count
                            } catch {
                                credentialFailures.insert(providerID)
                            }
                        }
                    }
                }
            } else {
                var newProvider = ProviderConfig(
                    name: entry.name,
                    baseURL: entry.baseURL,
                    isEnabled: false,
                    timeoutSeconds: 45,
                    healthStatus: .unknown,
                    discoveredSource: entry.source,
                    apiProtocol: entry.apiProtocol,
                    accountID: entry.accountID,
                    presetID: entry.presetID,
                    customHeaders: entry.customHeaders,
                    passThroughHeaderNames: entry.passThroughHeaderNames,
                    proxyURL: entry.proxyURL,
                    configuredKeyCount: 0,
                    subscriptionAccounts: entry.codexAccounts.map(\.summary),
                    discoverySourceLabel: "本机发现 \(entry.source)",
                    isAutoDiscovered: true
                )
                if credentialAccess == .interactive {
                    if entry.apiProtocol == .codexChatGPT, !entry.codexAccounts.isEmpty {
                        do {
                            try keychain.setCodexAccounts(entry.codexAccounts, for: newProvider.id)
                            newProvider.configuredKeyCount = entry.codexAccounts.count
                        } catch {
                            credentialFailures.insert(newProvider.id)
                        }
                    } else if !entry.apiKeys.isEmpty {
                        do {
                            try keychain.setAPIKeys(entry.apiKeys, for: newProvider.id)
                            newProvider.configuredKeyCount = entry.apiKeys.count
                        } catch {
                            credentialFailures.insert(newProvider.id)
                        }
                    }
                }
                config.providers.append(newProvider)
                providerID = newProvider.id
                addedProviders += 1
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
            sourcesScanned: discovery.sourcesScanned,
            credentialAccess: credentialAccess,
            credentialFailures: credentialFailures
        )
        return probeSummary
    }

    @discardableResult
    public func probeAllEnabledModels(credentialAccess: CredentialAccess = .interactive) async -> DiscoveryAndProbeSummary {
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
            sourcesScanned: [],
            credentialAccess: credentialAccess
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
        var effectiveProvider = provider
        let key: String?
        do {
            if provider.apiProtocol == .codexChatGPT {
                let accounts = try keychain.getCodexAccounts(for: provider.id, fallbackAccountID: provider.accountID)
                if var activeAccount = keyPoolRouter.orderedCodexAccounts(for: provider.id, accounts: accounts, strategy: provider.keyRotationStrategy).first {
                    if activeAccount.isExpiredOrExpiringSoon(), activeAccount.canRefresh,
                       let refreshed = await refreshOrSyncCodexAccount(activeAccount, providerID: provider.id, forceRefresh: false) {
                        activeAccount = refreshed
                    }
                    effectiveProvider.accountID = activeAccount.accountID ?? provider.accountID
                    key = activeAccount.accessToken
                } else {
                    key = nil
                }
            } else {
                let keys = try keychain.getAPIKeys(for: provider.id)
                key = keyPoolRouter.orderedKeys(for: provider.id, keys: keys, strategy: provider.keyRotationStrategy).first
            }
        } catch { return }
        let secrets = keychain.allKnownSecretValues()

        probeProgressText = "正在测试模型 \(model.displayName)..."
        let result = await upstreamClient.probeModelHealth(
            provider: effectiveProvider,
            model: model,
            apiKey: key,
            timeoutSeconds: 6.0,
            secretsToRedact: secrets
        )
        probeProgressText = nil

        if result.isAvailable {
            transientFailureCountByModelID[model.id] = 0
            cooldownUntilByModelID.removeValue(forKey: model.id)
            config.models[modelIdx].availabilityStatus = .available
            config.models[modelIdx].isAutoEvicted = false
            config.models[modelIdx].lastProbeLatencyMs = result.latencyMs
            config.models[modelIdx].lastProbedAt = Date()
            config.models[modelIdx].lastAvailabilityNote = persistedProbeNote(for: result)
            updateProviderHealth(providerID: provider.id, status: .healthy, error: nil)
        } else if result.isTransientFailure {
            recordTransientCooldown(for: model.id, reason: persistedProbeNote(for: result))
        } else {
            cooldownUntilByModelID.removeValue(forKey: model.id)
            config.models[modelIdx].availabilityStatus = result.availability
            config.models[modelIdx].isAutoEvicted = true
            config.models[modelIdx].lastProbedAt = Date()
            config.models[modelIdx].lastAvailabilityNote = persistedProbeNote(for: result)
        }
        saveConfig()
        autoConfigureModelTiers(forceResetManual: false)
    }

    private func runActiveHealthProbe(
        targetProviderID: UUID?,
        discoveredProvidersCount: Int,
        discoveredModelsCount: Int,
        sourcesScanned: [String],
        credentialAccess: CredentialAccess = .interactive,
        credentialFailures: Set<UUID> = []
    ) async -> DiscoveryAndProbeSummary {
        let candidates = config.providers.filter { p in
            p.isEnabled && !credentialFailures.contains(p.id) && (targetProviderID == nil || p.id == targetProviderID)
        }
        // Resolve once, so both stages use the same authorized snapshot. Unknown
        // credentials never become an unauthenticated probe or an eviction.
        var credentials: [UUID: CachedAPIKey] = [:]
        for provider in candidates {
            credentials[provider.id] = credential(for: provider.id, access: credentialAccess)
        }
        let providersToCheck = candidates.filter { credentials[$0.id] != .unknown }
        let secrets = keychain.allKnownSecretValues()

        // Stage 1: Fast provider reachability checks in parallel
        probeProgressText = "正在检测 \(providersToCheck.count) 个供应商连通性..."
        var reachabilityByProviderID: [UUID: ProviderReachabilityOutcome] = [:]

        await withTaskGroup(of: (UUID, ProviderReachabilityOutcome).self) { group in
            for provider in providersToCheck {
                let apiKey: String?
                if case .found(let raw) = credentials[provider.id] {
                    let keys = APIKeyPoolCodec.decode(raw)
                    apiKey = keyPoolRouter.orderedKeys(for: provider.id, keys: keys, strategy: provider.keyRotationStrategy).first
                } else {
                    apiKey = nil
                }
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
                // Seed models for providers that do not have any configured yet.
                let existingModelsCount = config.models.filter { $0.providerID == provider.id }.count
                if existingModelsCount == 0 && provider.apiProtocol == .workBuddy {
                    addWorkBuddyModels(Array(discoveredIDs.prefix(12)), providerID: provider.id)
                } else if existingModelsCount == 0 {
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
                let safeMessage = persistedUpstreamNote(msg, fallback: "供应商连接检测失败")
                updateProviderHealth(providerID: provider.id, status: status, error: safeMessage)
                for idx in config.models.indices where config.models[idx].providerID == provider.id {
                    config.models[idx].availabilityStatus = .unavailable
                    config.models[idx].isAutoEvicted = true
                    config.models[idx].lastProbedAt = Date()
                    config.models[idx].lastAvailabilityNote = "自动剔除（供应商不可用）：\(safeMessage)"
                }
            }
        }

        // Stage 2: Per-model completion probe on reachable providers with bounded concurrency (max 6)
        var modelsToProbe: [(provider: ProviderConfig, model: ModelConfig, apiKey: String?)] = []
        for provider in providersToCheck where reachableProviderIDs.contains(provider.id) {
            var effectiveProvider = provider
            let apiKey: String?
            if case .found(let raw) = credentials[provider.id] {
                if provider.apiProtocol == .codexChatGPT {
                    let accounts = CodexAccountPoolCodec.decode(raw, fallbackAccountID: provider.accountID)
                    if var active = keyPoolRouter.orderedCodexAccounts(for: provider.id, accounts: accounts, strategy: provider.keyRotationStrategy).first {
                        if credentialAccess == .interactive, active.isExpiredOrExpiringSoon(), active.canRefresh,
                           let refreshed = await refreshOrSyncCodexAccount(active, providerID: provider.id, forceRefresh: false) {
                            active = refreshed
                        }
                        effectiveProvider.accountID = active.accountID ?? provider.accountID
                        apiKey = active.accessToken
                    } else {
                        apiKey = nil
                    }
                } else {
                    let keys = APIKeyPoolCodec.decode(raw)
                    apiKey = keyPoolRouter.orderedKeys(for: provider.id, keys: keys, strategy: provider.keyRotationStrategy).first
                }
            } else {
                apiKey = nil
            }
            let models = config.models.filter { $0.providerID == provider.id && $0.isEnabled }
            for model in models {
                modelsToProbe.append((effectiveProvider, model, apiKey))
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
                transientFailureCountByModelID[modelID] = 0
                cooldownUntilByModelID.removeValue(forKey: modelID)
                config.models[idx].availabilityStatus = .available
                config.models[idx].isAutoEvicted = false
                config.models[idx].lastProbeLatencyMs = res.latencyMs
                config.models[idx].lastAvailabilityNote = persistedProbeNote(for: res)
            } else if res.isTransientFailure {
                recordTransientCooldown(for: modelID, reason: persistedProbeNote(for: res))
            } else {
                cooldownUntilByModelID.removeValue(forKey: modelID)
                config.models[idx].availabilityStatus = res.availability
                config.models[idx].isAutoEvicted = true
                config.models[idx].lastProbeLatencyMs = nil
                config.models[idx].lastAvailabilityNote = persistedProbeNote(for: res)
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

    public func isProviderAvailable(_ provider: ProviderConfig) -> Bool {
        guard provider.isEnabled else { return false }
        switch provider.healthStatus {
        case .networkError, .authError, .serverError:
            return false
        case .healthy, .checking, .unknown:
            let providerModels = config.models.filter { $0.providerID == provider.id }
            if providerModels.isEmpty { return true }
            return providerModels.contains { isModelAvailable($0, provider: provider) }
        }
    }

    public func isModelAvailable(_ model: ModelConfig, provider: ProviderConfig? = nil) -> Bool {
        let resolvedProvider = provider ?? config.providers.first(where: { $0.id == model.providerID })
        if let p = resolvedProvider {
            guard p.isEnabled else { return false }
            if p.healthStatus == .networkError || p.healthStatus == .authError || p.healthStatus == .serverError {
                return false
            }
        }
        return model.isEnabled && !model.isAutoEvicted && model.availabilityStatus == .available
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

    /// Automatically fills empty/deleted Low / Medium / High tier slots with healthy models.
    /// Existing tier bindings (both manual and already-assigned distinct tiers) and backup queues
    /// are strictly preserved across probes, discovery, and strategy switches unless `forceResetManual` is true.
    public func autoConfigureModelTiers(forceResetManual: Bool = false) {
        let healthy = healthyAvailableModels()
        let healthyIDs = Set(healthy.map(\.id))
        let allKnownIDs = Set(config.models.map(\.id))
        var nextPolicy = config.policy

        // Only prune models that were deleted from config.models; never wipe temporarily unhealthy backups
        // or overwrite primary tier bindings during transient faults.
        for tier in ModelTier.allCases {
            if let cid = nextPolicy.modelID(for: tier), !allKnownIDs.contains(cid) {
                nextPolicy.setTier(tier, modelID: nil, isManual: false)
            }
            let existingBackups = nextPolicy.backupModelIDs(for: tier).filter { allKnownIDs.contains($0) }
            nextPolicy.setBackupModelIDs(existingBackups, for: tier)
        }

        // Detect bootstrap-shared auto tiers (e.g., when models were added one-by-one so multiple
        // non-manual tiers temporarily pointed to the same single model).
        var nonManualTierCounts: [UUID: Int] = [:]
        var distinctAssignedHealthyIDs = Set<UUID>()
        for tier in ModelTier.allCases {
            if let cid = nextPolicy.modelID(for: tier) {
                if healthyIDs.contains(cid) {
                    distinctAssignedHealthyIDs.insert(cid)
                }
                if !nextPolicy.isManual(for: tier) {
                    nonManualTierCounts[cid, default: 0] += 1
                }
            }
        }
        let sharedAutoIDs = Set(nonManualTierCounts.filter { $0.value > 1 }.keys)
        let hasMoreDistinctHealthyModels = healthyIDs.count > distinctAssignedHealthyIDs.count

        // Determine which tiers currently need (re)assignment
        func needsAssignment(for tier: ModelTier) -> Bool {
            if forceResetManual { return true }
            guard nextPolicy.autoConfigureTiers else { return false }
            guard let cid = nextPolicy.modelID(for: tier) else {
                return true
            }
            if !allKnownIDs.contains(cid) {
                return true
            }
            if nextPolicy.isManual(for: tier) {
                return false
            }
            // Only split shared bootstrap tiers when additional distinct healthy models become available
            return sharedAutoIDs.contains(cid) && hasMoreDistinctHealthyModels
        }

        if !healthy.isEmpty {
            var reservedIDs = Set<UUID>()
            for tier in ModelTier.allCases where !needsAssignment(for: tier) {
                if let existingID = nextPolicy.modelID(for: tier), allKnownIDs.contains(existingID) {
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
        guard isLocalAPITokenPersistent else {
            throw AgentConfigError.localTokenNotPersisted
        }
        let binding = binding(for: kind)
        let agentToken = manualAgentAPIKey ?? localAPIToken
        let status = try agentConfigService.applyAgentConfig(
            kind: kind,
            binding: binding,
            proxyPort: config.proxySettings.port,
            localAPIToken: agentToken,
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
        updatePolicy { policy in
            let currentStrategy = policy.activeStrategy
            if policy.perStrategyTiers[currentStrategy] == nil {
                var snapshot: [ModelTier: TierModelAssignment] = [:]
                for tier in ModelTier.allCases {
                    snapshot[tier] = TierModelAssignment(
                        primaryModelID: policy.modelID(for: tier),
                        backupModelIDs: policy.backupModelIDs(for: tier)
                    )
                }
                policy.perStrategyTiers[currentStrategy] = snapshot
            }
            policy.applyStrategyTierSnapshot(strategy)
        }
        autoConfigureModelTiers(forceResetManual: false)
    }

    public func setTierAssignment(
        strategy: RoutingStrategyPreset? = nil,
        tier: ModelTier,
        primaryModelID: UUID?,
        backupModelIDs: [UUID]
    ) {
        updatePolicy { policy in
            policy.setTierAssignment(
                TierModelAssignment(primaryModelID: primaryModelID, backupModelIDs: backupModelIDs),
                for: tier,
                strategy: strategy
            )
        }
    }

    public func autoModelGroups(connectedOnly: Bool = false) -> [AutoModelGroup] {
        var avgLatencyByModelID: [UUID: Double] = [:]
        for record in callHistory where record.status == .success {
            if let modelUUID = record.decision.selectedModelUUID, avgLatencyByModelID[modelUUID] == nil {
                avgLatencyByModelID[modelUUID] = record.totalCompletionMs
            }
        }
        return CanonicalModelGroupingBuilder.buildGroups(
            providers: config.providers,
            models: config.models,
            cooldownUntilByModelID: cooldownUntilByModelID,
            avgLatencyByModelID: avgLatencyByModelID,
            connectedOnly: connectedOnly
        )
    }

    public func publicBenchmarkPoints() -> [MatchedBenchmarkPoint] {
        PublicBenchmarkCatalog.matchPoints(
            providers: config.providers,
            models: config.models,
            cooldownUntilByModelID: cooldownUntilByModelID
        )
    }

    public func backupModels(for tier: ModelTier) -> [ModelConfig] {
        let byID = Dictionary(uniqueKeysWithValues: config.models.map { ($0.id, $0) })
        return config.policy.backupModelIDs(for: tier).compactMap { byID[$0] }
    }

    public func addTierBackupModel(tier: ModelTier, modelUUID: UUID) {
        updatePolicy { policy in
            policy.addBackupModel(modelUUID, to: tier, isManual: true)
        }
    }

    public func removeTierBackupModel(tier: ModelTier, modelUUID: UUID) {
        updatePolicy { policy in
            policy.removeBackupModel(modelUUID, from: tier)
        }
    }

    public func setRecordRequestBody(_ enabled: Bool) {
        config.privacySettings.recordRequestBody = enabled
        saveConfig()
    }

    public func setOnboardingCompleted(_ completed: Bool) {
        config.privacySettings.hasCompletedOnboarding = completed
        saveConfig()
    }

    public func setHistoryRetentionDays(_ days: Int) {
        let clamped = max(0, days)
        config.privacySettings.historyRetentionDays = clamped
        if clamped > 0 {
            _ = try? persistence.pruneHistory(olderThanDays: clamped)
        }
        saveConfig()
    }

    public func setSystemNotificationsEnabled(_ enabled: Bool) {
        config.privacySettings.enableSystemNotifications = enabled
        saveConfig()
    }

    public func setAutoCheckUpdates(_ enabled: Bool) {
        config.privacySettings.autoCheckUpdates = enabled
        saveConfig()
    }

    public func updateAgentPolicyProfile(_ profile: AgentPolicyProfile) {
        config.agentPolicyProfiles[profile.kind.rawValue] = profile
        router.clearSessionStickiness()
        saveConfig()
    }

    public func clearCallHistory() throws {
        var historyCleared = false
        var ledgerCleared = false
        var dailyUsageCleared = false
        do {
            try persistence.clearHistory()
            historyCleared = true
            try persistence.clearBudgetLedger()
            ledgerCleared = true
            try persistence.clearDailyUsageLedger()
            dailyUsageCleared = true
            try persistence.clearMetrics()
        } catch {
            if historyCleared { try? persistence.saveHistory(callHistory) }
            if ledgerCleared { try? persistence.saveBudgetLedger(budgetLedger) }
            if dailyUsageCleared { try? persistence.saveDailyUsageLedger(dailyUsageLedger) }
            throw error
        }
        callHistory.removeAll()
        budgetLedger.removeAll()
        dailyUsageLedger.removeAll()
        onboardingFunnel = LocalOnboardingFunnelState()
        router.clearSessionStickiness()
    }

    public func recordOnboardingStarted() {
        let previous = onboardingFunnel
        onboardingFunnel.recordStart()
        if onboardingFunnel != previous {
            try? persistence.saveOnboardingFunnel(onboardingFunnel)
        }
    }

    public func recordOnboardingDemoValidation() {
        onboardingFunnel.recordDemoValidation()
        try? persistence.saveOnboardingFunnel(onboardingFunnel)
    }

    public func recordOnboardingSkipped() {
        onboardingFunnel.recordSkip()
        try? persistence.saveOnboardingFunnel(onboardingFunnel)
    }

    public func clearAllKeychainKeys() throws {
        try keychain.clearAll()
        localModelAPIKey = nil
        localModelAPIKeyError = nil
        for idx in config.providers.indices {
            config.providers[idx].healthStatus = .unknown
            config.providers[idx].lastErrorMessage = nil
        }
        saveConfig()
    }

    public func saveConfig() {
        persistence.enqueueConfig(config) { [weak self] result in
            if case .failure(let error) = result {
                Task { @MainActor [weak self] in
                    self?.lastPersistenceError = "配置持久化失败：\(error.localizedDescription)"
                }
            }
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
            return .failure(.badRequest(status: 400, code: "unsupported_parameter", message: "AutoRoute 第一版暂不支持 'audio' 参数。"))
        }
        if let modalities = payload["modalities"] as? [String], modalities.contains("audio") {
            return .failure(.badRequest(status: 400, code: "unsupported_parameter", message: "AutoRoute 第一版暂不支持 audio modalities。"))
        }
        if let n = payload["n"] as? Int, n > 1 {
            return .failure(.badRequest(status: 400, code: "unsupported_parameter", message: "AutoRoute 第一版暂不支持 n > 1 的多候选采样。"))
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
        agentHeader: String? = nil,
        nativeResponsesPayload: [String: Any]? = nil,
        nativeAnthropicPayload: [String: Any]? = nil,
        nativeAnthropicHeaders: [String: String] = [:],
        clientHeaders: [String: String] = [:],
        onStreamHeadersReady: (@Sendable ([String: String]) async throws -> Void)? = nil,
        onStreamChunk: (@Sendable (Data) async throws -> Void)? = nil
    ) async -> ExecutionOutcome {
        activeRequestCount += 1
        defer {
            activeRequestCount -= 1
            if activeRequestCount == 0 {
                let waiters = requestDrainWaiters
                requestDrainWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        let resolvedClientName = clientName ?? (source == .testBench ? "测试台" : nil)
        let requestedModel = (payload["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "auto"
        let effectiveRequestedModel = requestedModel.isEmpty ? "auto" : requestedModel
        let stream = (payload["stream"] as? Bool) ?? false
        var features = RequestFeatureExtractor.extract(from: payload, sessionHeader: sessionHeader)
        if let previousResponseID = nativeResponsesPayload?["previous_response_id"] as? String,
           !previousResponseID.isEmpty {
            features.isUserTurnBoundary = false
        }
        if let effort = (nativeAnthropicPayload?["output_config"] as? [String: Any])?["effort"] as? String {
            features.clientProvidedEffort = ReasoningEffort(rawValue: effort)
        }
        let secrets = keychain.allKnownSecretValues()
        if !config.privacySettings.recordRequestBody {
            // Subtask summaries are derived from message text and are body data too.
            features.subtaskSummary = nil
        }
        let requestPreview = config.privacySettings.recordRequestBody ? buildRequestPreview(payload: payload, secrets: secrets) : nil

        let agentResolution: ResolvedAgentRequest
        do {
            if isShuttingDown {
                throw AgentRequestResolutionError(message: "AutoRoute 正在退出，已停止接收新请求")
            }
            agentResolution = try AgentRequestResolver.resolve(
                requestedModel: effectiveRequestedModel,
                agentHeader: agentHeader,
                globalPolicy: config.policy,
                profiles: config.agentPolicyProfiles
            )
        } catch {
            let resolutionError = (error as? AgentRequestResolutionError)
                ?? AgentRequestResolutionError(message: "无法解析 Agent 身份，请检查模型别名。")
            let decision = RoutingDecision(
                requestedModel: effectiveRequestedModel,
                isAutoRouted: true,
                strategyName: config.policy.activeStrategy.displayName,
                policyVersion: config.policy.policyVersion,
                deciderPluginID: config.policy.activeDeciderPluginID,
                decisionDurationMs: 0,
                errorSummary: resolutionError.message
            )
            let record = CallRecord(
                source: source,
                status: .rejected,
                requestedModel: effectiveRequestedModel,
                executedModelID: nil,
                executedModelDisplayName: nil,
                executedProviderName: nil,
                httpStatusCode: resolutionError.statusCode,
                requestFeatures: features,
                decision: decision,
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
                errorMessage: resolutionError.message,
                clientName: resolvedClientName,
                endpointPath: endpointPath
            )
            if !isShuttingDown { await appendCallRecord(record) }
            return ExecutionOutcome(
                httpStatusCode: resolutionError.statusCode,
                headers: [:],
                responseBody: openAIErrorJSON(
                    message: resolutionError.message,
                    type: "invalid_request_error",
                    code: resolutionError.code
                ),
                callRecord: record
            )
        }
        let routingRequestedModel = agentResolution.effectiveRequestedModel

        if let budgetError = budgetRejection(agentID: agentResolution.agentKind?.rawValue) {
            emitAlertIfEnabled(SystemAlertEvent(
                category: .budgetHardLimit,
                dedupKey: agentResolution.agentKind?.rawValue ?? "global",
                title: "AutoRoute 已触发月度预算硬上限",
                body: budgetError.message
            ))
            let decision = RoutingDecision(
                requestedModel: effectiveRequestedModel,
                isAutoRouted: true,
                strategyName: agentResolution.policy.activeStrategy.displayName,
                policyVersion: agentResolution.policy.policyVersion,
                deciderPluginID: agentResolution.policy.activeDeciderPluginID,
                decisionDurationMs: 0,
                errorSummary: budgetError.message,
                agentID: agentResolution.agentKind?.rawValue,
                agentIdentitySource: agentResolution.identitySource,
                agentPolicyOverrideReason: agentResolution.overrideReason
            )
            let record = CallRecord(
                source: source,
                status: .rejected,
                requestedModel: effectiveRequestedModel,
                executedModelID: nil,
                executedModelDisplayName: nil,
                executedProviderName: nil,
                httpStatusCode: budgetError.statusCode,
                requestFeatures: features,
                decision: decision,
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
                errorMessage: budgetError.message,
                clientName: resolvedClientName,
                endpointPath: endpointPath
            )
            await appendCallRecord(record)
            return ExecutionOutcome(
                httpStatusCode: budgetError.statusCode,
                headers: ["Retry-After": "3600"],
                responseBody: openAIErrorJSON(message: budgetError.message, type: "rate_limit_error", code: budgetError.code),
                callRecord: record
            )
        }

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
            await appendCallRecord(record)
            return ExecutionOutcome(
                httpStatusCode: status,
                headers: [:],
                responseBody: openAIErrorJSON(message: message, type: "invalid_request_error", code: code),
                callRecord: record
            )
        }

        let runtimeMetrics = buildRuntimeMetricsMap()
        let eligibleProviders = config.providers.filter { provider in
            nativeResponsesPayload == nil || provider.apiProtocol == .openAIResponses || provider.apiProtocol == .codexChatGPT
        }
        let eligibleProviderIDs = Set(eligibleProviders.map(\.id))
        var decision: RoutingDecision
        if let nativeAnthropicPayload,
           NativeAnthropicRouting.hasNativeFeatures(nativeAnthropicPayload) {
            let anthropicProviders = eligibleProviders.filter { $0.apiProtocol == .anthropicMessages }
            let anthropicProviderIDs = Set(anthropicProviders.map(\.id))
            if !anthropicProviderIDs.isEmpty {
                let nativeDecision = router.route(
                    requestedModel: routingRequestedModel,
                    features: features,
                    providers: anthropicProviders,
                    models: config.models.filter { anthropicProviderIDs.contains($0.providerID) },
                    policy: agentResolution.policy,
                    runtimeMetricsByModelID: runtimeMetrics,
                    stickinessNamespace: agentResolution.agentKind?.rawValue
                )
                if nativeDecision.selectedModelUUID != nil {
                    decision = nativeDecision
                    decision.matchedRules.append("优先匹配 Anthropic 原生透传供应商")
                } else {
                    decision = router.route(
                        requestedModel: routingRequestedModel,
                        features: features,
                        providers: eligibleProviders,
                        models: config.models.filter { eligibleProviderIDs.contains($0.providerID) },
                        policy: agentResolution.policy,
                        runtimeMetricsByModelID: runtimeMetrics,
                        stickinessNamespace: agentResolution.agentKind?.rawValue
                    )
                }
            } else {
                decision = router.route(
                    requestedModel: routingRequestedModel,
                    features: features,
                    providers: eligibleProviders,
                    models: config.models.filter { eligibleProviderIDs.contains($0.providerID) },
                    policy: agentResolution.policy,
                    runtimeMetricsByModelID: runtimeMetrics,
                    stickinessNamespace: agentResolution.agentKind?.rawValue
                )
            }
        } else {
            decision = router.route(
                requestedModel: routingRequestedModel,
                features: features,
                providers: eligibleProviders,
                models: config.models.filter { eligibleProviderIDs.contains($0.providerID) },
                policy: agentResolution.policy,
                runtimeMetricsByModelID: runtimeMetrics,
                stickinessNamespace: agentResolution.agentKind?.rawValue
            )
        }
        decision.requestedModel = effectiveRequestedModel
        decision.agentID = agentResolution.agentKind?.rawValue
        decision.agentIdentitySource = agentResolution.identitySource
        decision.agentPolicyOverrideReason = agentResolution.overrideReason

        guard let primaryID = decision.selectedModelUUID else {
            let status = (decision.isAutoRouted ? 503 : 404)
            let errCode = nativeResponsesPayload != nil ? "native_responses_route_unavailable" : (decision.isAutoRouted ? "no_eligible_model" : "model_not_found")
            let msg = nativeResponsesPayload != nil
                ? "此请求包含必须保留的原生 Responses 工具或上下文，所选模型没有可用的 Responses 上游。请使用 Responses 供应商。"
                : (decision.errorSummary ?? "没有满足条件的可用模型")
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
            await appendCallRecord(record)
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
        if decision.isAutoRouted && candidateQueue.count > 1 {
            let nowDate = Date()
            let modelsByID = Dictionary(uniqueKeysWithValues: config.models.map { ($0.id, $0) })
            let providersByID = Dictionary(uniqueKeysWithValues: config.providers.map { ($0.id, $0) })
            var unsat: [UUID] = []
            var sat: [UUID] = []
            for cid in candidateQueue {
                if let m = modelsByID[cid], let p = providersByID[m.providerID],
                   trafficLimiter.isSaturated(model: m, provider: p, now: nowDate) {
                    sat.append(cid)
                } else {
                    unsat.append(cid)
                }
            }
            if !unsat.isEmpty && !sat.isEmpty && candidateQueue.first != unsat.first {
                candidateQueue = unsat + sat
                decision.matchedRules.append("并发/RPM 软限流已优先分流到同档备用模型")
            }
        }
        let allowedAttempts = config.policy.enableRetryOnUpstreamFailure && decision.isAutoRouted
            ? max(1, config.policy.maxUpstreamAttempts)
            : 1
        if candidateQueue.count > allowedAttempts {
            decision.matchedRules.append("最大尝试次数 \(allowedAttempts)，跳过其余候选")
            candidateQueue.removeSubrange(allowedAttempts..<candidateQueue.count)
        }

        let overallStart = DispatchTime.now()
        let requestDeadlineNanos = DispatchTime.now().uptimeNanoseconds &+ UInt64(max(1, config.policy.maxRequestDurationSeconds) * 1_000_000_000)
        var attempts: [UpstreamAttemptRecord] = []
        var lastError: UpstreamError?
        let explicitTier = ModelTier.matchExplicitTier(requestedModel: routingRequestedModel)

        let activeAgentLabel = agentResolution.agentKind?.displayName
            ?? resolvedClientName
            ?? decision.agentID
        let targetTierForLive: ModelTier? = explicitTier ?? decision.subtaskCategory?.recommendedTier
        liveRoutingState = LiveRoutingState(
            inFlightCount: liveRoutingState.inFlightCount + 1,
            activeAgentName: activeAgentLabel,
            targetModelDisplayName: decision.selectedDisplayName ?? decision.selectedModelID,
            targetTier: targetTierForLive,
            lastCompletedSummary: liveRoutingState.lastCompletedSummary,
            updatedAt: Date()
        )
        defer {
            let nextCount = max(0, liveRoutingState.inFlightCount - 1)
            liveRoutingState = LiveRoutingState(
                inFlightCount: nextCount,
                activeAgentName: nextCount > 0 ? liveRoutingState.activeAgentName : nil,
                targetModelDisplayName: nextCount > 0 ? liveRoutingState.targetModelDisplayName : nil,
                targetTier: nextCount > 0 ? liveRoutingState.targetTier : nil,
                lastCompletedSummary: liveRoutingState.lastCompletedSummary,
                updatedAt: Date()
            )
        }

        var previousGroupChannelName: String?
        candidateAttempts: for candidateID in candidateQueue {
            guard let model = config.models.first(where: { $0.id == candidateID }),
                  let provider = config.providers.first(where: { $0.id == model.providerID }) else {
                continue
            }
            if let canonicalGroup = decision.canonicalGroupID,
               CanonicalModelNormalizer.canonicalID(for: model) == canonicalGroup {
                if let prevName = previousGroupChannelName {
                    decision.groupChannelSwitchTrace.append("\(prevName) ↪ \(provider.name) (同模型健康通道)")
                }
                previousGroupChannelName = provider.name
            }

            while let notBefore = retryNotBeforeByProviderID[provider.id], notBefore > DispatchTime.now().uptimeNanoseconds {
                let now = DispatchTime.now().uptimeNanoseconds
                if notBefore > now {
                    guard notBefore < requestDeadlineNanos else {
                        decision.matchedRules.append("Retry-After 超出剩余 deadline，跳过候选 \(model.modelID)")
                        if lastError == nil {
                            lastError = .httpError(statusCode: 429, rawBody: Data(), message: "供应商仍处于 Retry-After 冷却中")
                        }
                        continue candidateAttempts
                    }
                    decision.matchedRules.append("遵守供应商 Retry-After，等待后尝试 \(model.modelID)")
                    do {
                        try await Task.sleep(nanoseconds: notBefore - now)
                    } catch {
                        lastError = .clientDisconnected
                        decision.matchedRules.append("等待 Retry-After 时请求取消，停止后续候选")
                        break candidateAttempts
                    }
                }
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < requestDeadlineNanos else {
                lastError = .requestDeadlineExceeded
                decision.matchedRules.append("累计 deadline 到期，停止后续候选")
                break candidateAttempts
            }
            enum AttemptCredential {
                case apiKey(String?)
                case codexAccount(CodexSubscriptionAccount)

                var label: String? {
                    if case .codexAccount(let acct) = self {
                        return acct.summary.displayTitle
                    }
                    return nil
                }
            }

            let orderedCredentials: [AttemptCredential]
            if provider.apiProtocol == .codexChatGPT {
                let accounts = (try? keychain.getCodexAccounts(for: provider.id, fallbackAccountID: provider.accountID)) ?? []
                if accounts.isEmpty {
                    orderedCredentials = [.apiKey(nil)]
                } else {
                    orderedCredentials = keyPoolRouter
                        .orderedCodexAccounts(for: provider.id, accounts: accounts, strategy: provider.keyRotationStrategy)
                        .map { .codexAccount($0) }
                }
            } else {
                let rawKeys = (try? keychain.getAPIKeys(for: provider.id)) ?? []
                orderedCredentials = rawKeys.isEmpty
                    ? [.apiKey(nil)]
                    : keyPoolRouter.orderedKeys(for: provider.id, keys: rawKeys, strategy: provider.keyRotationStrategy).map { .apiKey($0) }
            }

            keyAttempts: for (keyIdx, credential) in orderedCredentials.enumerated() {
                var activeCodexAccount: CodexSubscriptionAccount?
                var activeAPIKey: String?
                var attemptProvider = provider

                switch credential {
                case .apiKey(let k):
                    activeAPIKey = k
                case .codexAccount(var acct):
                    if acct.isExpiredOrExpiringSoon(), acct.canRefresh,
                       let refreshed = await refreshOrSyncCodexAccount(acct, providerID: provider.id, forceRefresh: false) {
                        acct = refreshed
                        if !decision.matchedRules.contains("Codex 订阅 Token 到期前自动静默刷新") {
                            decision.matchedRules.append("Codex 订阅 Token 到期前自动静默刷新")
                        }
                    }
                    activeCodexAccount = acct
                    activeAPIKey = acct.accessToken
                    attemptProvider.accountID = acct.accountID ?? provider.accountID
                }

                var didAttemptReactiveRefresh = false
                accountAttemptLoop: while true {
                    let keyCheckNow = DispatchTime.now().uptimeNanoseconds
                    guard keyCheckNow < requestDeadlineNanos else {
                        lastError = .requestDeadlineExceeded
                        decision.matchedRules.append("累计 deadline 到期，停止后续候选")
                        break candidateAttempts
                    }

                    var mutableResponseHeaders = buildAutoModelHeaders(
                        decision: decision,
                        executedModel: model,
                        executedProvider: attemptProvider,
                        attemptNumber: attempts.count + 1
                    )
                    if nativeAnthropicPayload != nil && attemptProvider.apiProtocol == .anthropicMessages {
                        mutableResponseHeaders["X-AutoModel-Wire-Format"] = "anthropic-native"
                    }
                    let responseHeaders = mutableResponseHeaders

                    let headerFlag = LockedFlag()
                    let attemptEstimatedInputTokens = features.estimatedInputTokens
                    let attemptSelectedEffort = decision.selectedEffort
                    let attemptClientProvidedEffort = features.clientProvidedEffort
                    let upstreamClient = self.upstreamClient
                    let remainingNanos = requestDeadlineNanos - keyCheckNow
                    let attemptSecrets = keychain.allKnownSecretValues()
                    let capturedProvider = attemptProvider
                    let capturedAPIKey = activeAPIKey
                    trafficLimiter.beginAttempt(providerID: capturedProvider.id, modelID: model.id)
                    defer { trafficLimiter.endAttempt(providerID: capturedProvider.id) }
                    let result = await executeWithDeadline(nanoseconds: remainingNanos) {
                        await upstreamClient.executeChatCompletion(
                            provider: capturedProvider,
                            model: model,
                            apiKey: capturedAPIKey,
                            originalPayload: payload,
                            estimatedInputTokens: attemptEstimatedInputTokens,
                            stream: stream,
                            nativeResponsesPayload: nativeResponsesPayload,
                            nativeAnthropicPayload: nativeAnthropicPayload,
                            nativeAnthropicHeaders: nativeAnthropicHeaders,
                            clientHeaders: clientHeaders,
                            resolvedEffort: attemptSelectedEffort,
                            clientProvidedEffort: attemptClientProvidedEffort,
                            secretsToRedact: attemptSecrets,
                            onStreamHeadersReady: {
                                headerFlag.markTrue()
                                if let onStreamHeadersReady {
                                    try await onStreamHeadersReady(responseHeaders)
                                }
                            },
                            onStreamChunk: onStreamChunk
                        )
                    }
                    let hasEmittedStreamHeaders = headerFlag.value

                    switch result {
                    case .success(let completion):
                        if let acct = activeCodexAccount {
                            keyPoolRouter.clearAccountCooldown(providerID: provider.id, accountID: acct.id)
                        } else if let usedKey = activeAPIKey {
                            keyPoolRouter.clearCooldown(providerID: provider.id, key: usedKey)
                        }
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
                            attemptIndex: attempts.count + 1,
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
                            errorMessage: nil,
                            accountLabel: activeCodexAccount?.summary.displayTitle ?? credential.label
                        )
                        attempts.append(attemptRecord)

                        transientFailureCountByModelID[model.id] = 0
                        cooldownUntilByModelID.removeValue(forKey: model.id)

                        if decision.isAutoRouted {
                            let bodySnippet = String(data: completion.responseBody, encoding: .utf8) ?? ""
                            let hasToolCalls = completion.hasToolCalls
                                || bodySnippet.contains("\"tool_calls\"")
                                || bodySnippet.contains("\"function_call\"")
                            let toolChoice = payload["tool_choice"]
                            let requiresToolCall = (toolChoice as? String) == "required"
                                || (toolChoice as? [String: Any])?["type"] as? String == "function"
                            let wasToolStarved = features.requiresTools && requiresToolCall && !hasToolCalls
                                && completion.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            let isRoutineSubtask = features.subtaskCategory.recommendedTier != .high
                                && !decision.selectedEffort.requiresDeepReasoning
                            router.recordSuccessfulSessionModel(
                                fingerprint: features.conversationFingerprint,
                                modelUUID: model.id,
                                policyVersion: decision.policyVersion,
                                isRoutineSubtask: isRoutineSubtask,
                                wasToolStarved: wasToolStarved,
                                requestedModel: routingRequestedModel,
                                explicitTier: explicitTier,
                                isMultiTurn: features.isMultiTurn,
                                stickinessNamespace: agentResolution.agentKind?.rawValue,
                                isUserTurnBoundary: features.isUserTurnBoundary != false
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
                            ? SecretRedactor.redact(String(completion.assistantText.prefix(2000)), secrets: attemptSecrets)
                            : nil
                        let reasoningPreview = config.privacySettings.recordRequestBody
                            ? completion.reasoningText.map { SecretRedactor.redact(String($0.prefix(2000)), secrets: attemptSecrets) }
                            : nil

                        // Real A/B comparisons are attached only by the auditable interleaved runner.
                        var comparison: ComparisonAnalysis? = nil
                        if decision.isAutoRouted {
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
                            endpointPath: endpointPath,
                            executionOrigin: executionOrigin(for: provider)
                        )
                        await appendCallRecord(callRecord)

                        return ExecutionOutcome(
                            httpStatusCode: completion.statusCode,
                            headers: responseHeaders,
                            responseBody: completion.responseBody,
                            callRecord: callRecord
                        )

                    case .failure(let upstreamErr):
                        lastError = upstreamErr
                        let currentSecrets = keychain.allKnownSecretValues()
                        let cleanErrMsg = SecretRedactor.redact(upstreamErr.localizedDescription, secrets: currentSecrets)
                        let persistedErrMsg = persistedUpstreamErrorSummary(for: upstreamErr, detailedMessage: cleanErrMsg)

                        let isKeyAuthError: Bool
                        let isKeyRateLimit: Bool
                        switch upstreamErr {
                        case .authError:
                            isKeyAuthError = true
                            isKeyRateLimit = false
                        case .httpError(let code, _, _, _) where code == 429:
                            isKeyAuthError = false
                            isKeyRateLimit = true
                        case .modelUnavailable(_, _, .insufficientCredits) where provider.apiProtocol == .codexChatGPT:
                            isKeyAuthError = false
                            isKeyRateLimit = true
                        default:
                            isKeyAuthError = false
                            isKeyRateLimit = false
                        }

                        // Reactive 401 refresh for Codex subscription accounts before failing over or evicting
                        if isKeyAuthError,
                           let acct = activeCodexAccount,
                           !didAttemptReactiveRefresh,
                           acct.canRefresh,
                           !(stream && hasEmittedStreamHeaders),
                           DispatchTime.now().uptimeNanoseconds < requestDeadlineNanos {
                            didAttemptReactiveRefresh = true
                            if let refreshed = await refreshOrSyncCodexAccount(acct, providerID: provider.id, forceRefresh: true),
                               refreshed.accessToken != activeAPIKey {
                                activeCodexAccount = refreshed
                                activeAPIKey = refreshed.accessToken
                                attemptProvider.accountID = refreshed.accountID ?? provider.accountID
                                if !decision.matchedRules.contains("Codex 订阅 Token 401 自动静默刷新并重试") {
                                    decision.matchedRules.append("Codex 订阅 Token 401 自动静默刷新并重试")
                                }
                                attempts.append(UpstreamAttemptRecord(
                                    attemptIndex: attempts.count + 1,
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
                                    errorMessage: persistedErrMsg,
                                    accountLabel: acct.summary.displayTitle
                                ))
                                continue accountAttemptLoop
                            }
                        }

                        let hasNextKey = (keyIdx + 1 < orderedCredentials.count)
                            && !(stream && hasEmittedStreamHeaders)
                            && DispatchTime.now().uptimeNanoseconds < requestDeadlineNanos

                        if (isKeyAuthError || isKeyRateLimit), hasNextKey {
                            if let acct = activeCodexAccount {
                                if isKeyAuthError {
                                    keyPoolRouter.markAccountAuthFailed(providerID: provider.id, accountID: acct.id)
                                } else {
                                    let cooldown = upstreamErr.retryAfterSeconds ?? (cleanErrMsg.lowercased().contains("limit") || cleanErrMsg.lowercased().contains("quota") ? 300 : 60)
                                    keyPoolRouter.markAccountRateLimited(providerID: provider.id, accountID: acct.id, cooldownSeconds: cooldown)
                                }
                                if !decision.matchedRules.contains("Codex 多订阅账号池配额切换备用账号") {
                                    decision.matchedRules.append("Codex 多订阅账号池配额切换备用账号")
                                }
                            } else if let failedKey = activeAPIKey {
                                if isKeyAuthError {
                                    keyPoolRouter.markAuthFailed(providerID: provider.id, key: failedKey)
                                } else {
                                    keyPoolRouter.markRateLimited(providerID: provider.id, key: failedKey, cooldownSeconds: upstreamErr.retryAfterSeconds ?? 60)
                                }
                                if !decision.matchedRules.contains("供应商多 Key 池自动切换备用密钥") {
                                    decision.matchedRules.append("供应商多 Key 池自动切换备用密钥")
                                }
                            }
                            attempts.append(UpstreamAttemptRecord(
                                attemptIndex: attempts.count + 1,
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
                                errorMessage: persistedErrMsg,
                                accountLabel: activeCodexAccount?.summary.displayTitle ?? credential.label
                            ))
                            continue keyAttempts
                        }

                        switch upstreamErr {
                        case .authError:
                            if let acct = activeCodexAccount {
                                keyPoolRouter.markAccountAuthFailed(providerID: provider.id, accountID: acct.id)
                            } else if let failedKey = activeAPIKey {
                                keyPoolRouter.markAuthFailed(providerID: provider.id, key: failedKey)
                            }
                            updateProviderHealth(providerID: provider.id, status: .authError, error: persistedErrMsg)
                            updateModelAvailability(modelID: model.id, status: .unavailable, note: "运行时自动剔除（鉴权失败）：\(persistedErrMsg)", autoEvicted: true)
                            emitAlertIfEnabled(SystemAlertEvent(
                                category: .providerAuthFailure,
                                dedupKey: provider.id.uuidString,
                                title: "AutoRoute 供应商鉴权失败",
                                body: "供应商「\(provider.name)」返回鉴权错误，已暂停自动路由到该供应商的模型。"
                            ))
                        case .networkError:
                            recordTransientCooldown(for: model.id, reason: persistedErrMsg)
                        case .modelUnavailable(_, _, let avail):
                            if avail == .insufficientCredits || avail == .retired {
                                updateModelAvailability(modelID: model.id, status: avail, note: "运行时自动剔除：\(persistedErrMsg)", autoEvicted: true)
                            } else {
                                recordTransientCooldown(for: model.id, reason: persistedErrMsg)
                            }
                        case .httpError(let code, _, _, _):
                            if code == 429 {
                                if let acct = activeCodexAccount {
                                    keyPoolRouter.markAccountRateLimited(providerID: provider.id, accountID: acct.id, cooldownSeconds: upstreamErr.retryAfterSeconds ?? 60)
                                } else if let failedKey = activeAPIKey {
                                    keyPoolRouter.markRateLimited(providerID: provider.id, key: failedKey, cooldownSeconds: upstreamErr.retryAfterSeconds ?? 60)
                                }
                            }
                            if code == 402 || code == 404 || code == 410 {
                                let mappedAvail: ModelAvailabilityStatus = (code == 402) ? .insufficientCredits : (code == 410 ? .retired : .unavailable)
                                updateModelAvailability(modelID: model.id, status: mappedAvail, note: "运行时自动剔除：\(persistedErrMsg)", autoEvicted: true)
                            } else if code == 429 || code == 408 || code >= 500 {
                                recordTransientCooldown(for: model.id, reason: persistedErrMsg)
                            }
                        case .clientDisconnected:
                            // The caller, not the provider, ended the request. Do not cooldown or retry another model.
                            break
                        case .requestDeadlineExceeded:
                            // This is the request-level budget, not evidence that this provider is unhealthy.
                            break
                        case .invalidURL, .invalidResponse:
                            recordTransientCooldown(for: model.id, reason: persistedErrMsg)
                        }

                        attempts.append(UpstreamAttemptRecord(
                            attemptIndex: attempts.count + 1,
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
                            errorMessage: persistedErrMsg,
                            accountLabel: activeCodexAccount?.summary.displayTitle ?? credential.label
                        ))

                        if let seconds = upstreamErr.retryAfterSeconds {
                            attempts[attempts.count - 1].retryAfterSeconds = seconds
                            let now = DispatchTime.now().uptimeNanoseconds
                            let safeSeconds = min(seconds, Double((UInt64.max - now) / 1_000_000_000))
                            retryNotBeforeByProviderID[provider.id] = now + UInt64(ceil(safeSeconds * 1_000_000_000))
                        }

                        // A client disconnect is terminal for this request. Retrying another provider would
                        // spend upstream capacity for a response nobody can receive.
                        if case .clientDisconnected = upstreamErr {
                            break candidateAttempts
                        }
                        if case .requestDeadlineExceeded = upstreamErr {
                            break candidateAttempts
                        }

                        // Once SSE headers/chunks have been emitted to the caller socket, never switch models mid-stream.
                        if stream && hasEmittedStreamHeaders {
                            decision.matchedRules.append("流式响应已开始，停止后续候选")
                            break candidateAttempts
                        }
                        break keyAttempts
                    }
                }
            }
        }

        // All candidate attempts failed
        let finalStatus = lastError?.statusCode ?? 502
        let finalClientMessage = SecretRedactor.redact(lastError?.localizedDescription ?? "上游调用失败", secrets: secrets)
        let finalPersistedMessage = lastError.map {
            persistedUpstreamErrorSummary(for: $0, detailedMessage: finalClientMessage)
        } ?? "上游调用失败"
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
            errorMessage: finalPersistedMessage,
            clientName: resolvedClientName,
            endpointPath: endpointPath,
            executionOrigin: attempts.last?.providerID.flatMap { providerID in
                config.providers.first(where: { $0.id == providerID }).map { executionOrigin(for: $0) }
            }
        )
        await appendCallRecord(failedRecord)

        return ExecutionOutcome(
            httpStatusCode: finalStatus,
            headers: [:],
            responseBody: openAIErrorJSON(message: finalClientMessage, type: "upstream_error", code: "upstream_failed"),
            callRecord: failedRecord
        )
    }

    private func executeWithDeadline(
        nanoseconds: UInt64,
        operation: @escaping @Sendable () async -> Result<UpstreamCompletionResult, UpstreamError>
    ) async -> Result<UpstreamCompletionResult, UpstreamError> {
        guard nanoseconds > 0 else { return .failure(.requestDeadlineExceeded) }

        return await withTaskGroup(of: Result<UpstreamCompletionResult, UpstreamError>.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                    return .failure(.requestDeadlineExceeded)
                } catch {
                    return .failure(.requestDeadlineExceeded)
                }
            }

            let firstResult = await group.next() ?? .failure(.requestDeadlineExceeded)
            group.cancelAll()
            return firstResult
        }
    }

    // MARK: - Cost, Comparison & Helpers

    private func persistedUpstreamErrorSummary(for error: UpstreamError, detailedMessage: String) -> String {
        guard !config.privacySettings.recordRequestBody else { return detailedMessage }
        switch error {
        case .invalidURL:
            return "供应商 URL 无效"
        case .clientDisconnected:
            return "客户端已断开流式连接"
        case .requestDeadlineExceeded:
            return "请求达到累计 deadline"
        case .authError(let statusCode, _):
            return "上游鉴权失败 (HTTP \(statusCode))"
        case .modelUnavailable(let statusCode, _, _):
            return "上游模型不可用 (HTTP \(statusCode))"
        case .networkError:
            return "上游网络连接失败"
        case .httpError(let statusCode, _, _, _):
            return "上游返回 HTTP \(statusCode)"
        case .invalidResponse:
            return "上游响应格式异常"
        }
    }

    private func persistedUpstreamNote(_ detailedNote: String, fallback: String) -> String {
        config.privacySettings.recordRequestBody ? detailedNote : fallback
    }

    private func persistedProbeNote(for result: ModelProbeResult) -> String {
        if config.privacySettings.recordRequestBody {
            return result.note
        }
        if result.isAvailable {
            return "测活可用"
        }
        if result.isTransientFailure {
            return "测活瞬时限流/抖动"
        }
        return "自动测活剔除（\(result.availability.displayName)）"
    }

    private func executionOrigin(for provider: ProviderConfig) -> CallExecutionOrigin {
        if provider.name.hasPrefix("本地测试模拟上游") {
            return .demo
        }
        if isLocalTestUpstreamRunning,
           let localTestUpstreamPort,
           provider.baseURL == "http://127.0.0.1:\(localTestUpstreamPort)" {
            return .demo
        }
        return .real
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

    func setComparison(_ comparison: ComparisonAnalysis?, forRecordID recordID: UUID) {
        guard let index = callHistory.firstIndex(where: { $0.id == recordID }) else { return }
        callHistory[index].comparison = comparison
        pendingSQLiteUpserts.append(callHistory[index])
    }

    func persistCallHistory(latestRecord: CallRecord? = nil) async {
        var batch = pendingSQLiteUpserts
        pendingSQLiteUpserts.removeAll()
        if let latestRecord {
            batch.append(latestRecord)
        }
        persistence.enqueueCompletionSnapshot(
            config: config,
            history: callHistory,
            ledger: budgetLedger,
            dailyUsage: dailyUsageLedger,
            funnel: onboardingFunnel,
            changedRecords: batch
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                if case .failure(let error) = result {
                    self?.lastPersistenceError = "请求状态持久化失败：\(error.localizedDescription)"
                } else if case .success = result {
                    self?.lastPersistenceError = nil
                }
            }
        }
    }

    private func appendCallRecord(_ record: CallRecord) async {
        callHistory.insert(record, at: 0)
        if callHistory.count > 500 {
            callHistory = Array(callHistory.prefix(500))
        }
        let baselineImpact = baselineEstimatesForLedger(record: record)
        dailyUsageLedger.record(
            record,
            baselineCostUSD: baselineImpact.costUSD,
            baselineLatencyMs: baselineImpact.latencyMs
        )
        if record.executionOrigin != .demo {
            let agentTitle = record.decision.agentID.flatMap { AgentKind(rawValue: $0)?.displayName }
                ?? record.clientName
                ?? "客户端"
            let modelTitle = record.executedModelDisplayName ?? record.executedModelID ?? record.requestedModel
            let latencySec = String(format: "%.2fs", record.totalCompletionMs / 1000.0)
            let tierText = record.decision.subtaskCategory?.recommendedTier.shortName ?? "自动"
            liveRoutingState = LiveRoutingState(
                inFlightCount: liveRoutingState.inFlightCount,
                activeAgentName: liveRoutingState.activeAgentName,
                targetModelDisplayName: liveRoutingState.targetModelDisplayName,
                targetTier: liveRoutingState.targetTier,
                lastCompletedSummary: "\(agentTitle) → \(modelTitle) (\(tierText) · \(latencySec))",
                updatedAt: Date()
            )
        }
        if record.source == .externalProxy,
           record.status == .success,
           record.executionOrigin == .real,
           onboardingFunnel.isAwaitingFirstRealRoute {
            onboardingFunnel.recordRealSuccess(at: record.timestamp)
        }
        if !record.attempts.isEmpty {
            budgetLedger.record(record)
            let globalWarning = monthlyBudgetWarning(agentID: nil, now: record.timestamp)
            if globalWarning.level == .warning {
                emitAlertIfEnabled(SystemAlertEvent(
                    category: .budgetWarning,
                    dedupKey: "global-\(globalWarning.period)",
                    title: "AutoRoute 月度预算预警",
                    body: globalWarning.message
                ))
            }
            if let agentID = record.decision.agentID {
                let agentWarning = monthlyBudgetWarning(agentID: agentID, now: record.timestamp)
                if agentWarning.level == .warning {
                    emitAlertIfEnabled(SystemAlertEvent(
                        category: .budgetWarning,
                        dedupKey: "\(agentID)-\(agentWarning.period)",
                        title: "AutoRoute \(agentID) 月度预算预警",
                        body: agentWarning.message
                    ))
                }
            }
        }
        await persistCallHistory(latestRecord: record)
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

    public func cooldownRemainingSeconds(for modelID: UUID) -> Int? {
        guard let until = cooldownUntilByModelID[modelID], until > Date() else { return nil }
        return max(1, Int(ceil(until.timeIntervalSinceNow)))
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
        let now = Date()
        var result: [UUID: ModelRuntimeMetrics] = [:]
        for (mid, s) in stats where s.totalCount > 0 {
            let avg = s.successCount > 0 ? (s.totalLatency / Double(s.successCount)) : 10_000.0
            let rate = Double(s.successCount) / Double(s.totalCount)
            let cooldown = cooldownUntilByModelID[mid].flatMap { $0 > now ? $0 : nil }
            result[mid] = ModelRuntimeMetrics(
                averageLatencyMs: avg,
                successRate: rate,
                sampleCount: s.totalCount,
                cooldownUntil: cooldown
            )
        }
        for (mid, until) in cooldownUntilByModelID where until > now && result[mid] == nil {
            result[mid] = ModelRuntimeMetrics(
                averageLatencyMs: 5_000.0,
                successRate: 1.0,
                sampleCount: 0,
                cooldownUntil: until
            )
        }
        return result
    }

    private func elapsedMs(since start: DispatchTime) -> Double {
        let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000.0
    }
}
