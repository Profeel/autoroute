import Foundation

public struct DiscoveredProviderEntry: Sendable {
    public var name: String
    public var baseURL: String
    public var apiKey: String?
    public var apiKeys: [String]
    public var source: String
    public var models: [DiscoveredModelEntry]
    public var apiProtocol: ProviderProtocol
    public var accountID: String?
    public var customHeaders: [String: String]
    public var passThroughHeaderNames: [String]
    public var proxyURL: String?
    public var presetID: String?
    public var codexAccounts: [CodexSubscriptionAccount]

    public init(
        name: String,
        baseURL: String,
        apiKey: String?,
        apiKeys: [String]? = nil,
        source: String,
        models: [DiscoveredModelEntry],
        apiProtocol: ProviderProtocol = .openAIChatCompletions,
        accountID: String? = nil,
        customHeaders: [String: String] = [:],
        passThroughHeaderNames: [String] = [],
        proxyURL: String? = nil,
        presetID: String? = nil,
        codexAccounts: [CodexSubscriptionAccount] = []
    ) {
        let normalizedKeys: [String]
        if let apiKeys {
            normalizedKeys = APIKeyPoolCodec.normalize(apiKeys)
        } else if let apiKey {
            normalizedKeys = APIKeyPoolCodec.normalize([apiKey])
        } else if !codexAccounts.isEmpty {
            normalizedKeys = APIKeyPoolCodec.normalize(codexAccounts.map(\.accessToken))
        } else {
            normalizedKeys = []
        }
        self.name = name
        self.baseURL = baseURL
        self.apiKeys = normalizedKeys
        self.apiKey = normalizedKeys.first
        self.source = source
        self.models = models
        self.apiProtocol = apiProtocol
        self.accountID = accountID ?? codexAccounts.first?.accountID
        self.customHeaders = customHeaders
        self.passThroughHeaderNames = passThroughHeaderNames
        self.proxyURL = proxyURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.presetID = presetID
        self.codexAccounts = codexAccounts
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct DiscoveredModelEntry: Sendable {
    public var modelID: String
    public var displayName: String
    public var inputPricePerMillion: Double?
    public var outputPricePerMillion: Double?
    public var contextWindow: Int
    public var capabilities: Set<ModelCapability>
    public var defaultRole: ModelDefaultUsage
    public var qualityScore: Int
    public var speedScore: Int
    public var source: String
}

public struct LocalDiscoveryResult: Sendable {
    public var providers: [DiscoveredProviderEntry]
    public var sourcesScanned: [String]
}

public final class LocalModelDiscoveryService: @unchecked Sendable {
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2.5
        cfg.timeoutIntervalForResource = 3.5
        self.session = URLSession(configuration: cfg)
    }

    public func scanLocalEnvironment(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        excludeLoopbackPort: Int? = nil,
        scanWellKnownLocalPorts: Bool = true
    ) async -> LocalDiscoveryResult {
        var providersByBaseURL: [String: DiscoveredProviderEntry] = [:]
        var sourcesScanned: [String] = []

        func mergeProvider(_ incoming: DiscoveredProviderEntry) {
            let norm = normalizeBaseURL(incoming.baseURL)
            guard !norm.isEmpty else { return }
            if let excludePort = excludeLoopbackPort,
               let parsed = URL(string: norm),
               (parsed.host == "127.0.0.1" || parsed.host == "localhost"),
               parsed.port == excludePort {
                return
            }

            let key = "\(norm)|\(incoming.apiProtocol.rawValue)"
            if var existing = providersByBaseURL[key] {
                let mergedKeys = APIKeyPoolCodec.normalize(existing.apiKeys + incoming.apiKeys)
                existing.apiKeys = mergedKeys
                existing.apiKey = mergedKeys.first
                if !incoming.codexAccounts.isEmpty {
                    existing.codexAccounts = CodexAccountPoolCodec.mergeAccounts(
                        existing: existing.codexAccounts,
                        incoming: incoming.codexAccounts
                    )
                }
                if existing.accountID == nil, let acct = incoming.accountID, !acct.isEmpty {
                    existing.accountID = acct
                }
                for (hk, hv) in incoming.customHeaders where existing.customHeaders[hk] == nil {
                    existing.customHeaders[hk] = hv
                }
                for headerName in incoming.passThroughHeaderNames where !existing.passThroughHeaderNames.contains(where: { $0.caseInsensitiveCompare(headerName) == .orderedSame }) {
                    existing.passThroughHeaderNames.append(headerName)
                }
                if existing.proxyURL == nil, let proxy = incoming.proxyURL {
                    existing.proxyURL = proxy
                }
                if existing.presetID == nil, let preset = incoming.presetID {
                    existing.presetID = preset
                }
                if !existing.source.contains(incoming.source) {
                    existing.source += ", \(incoming.source)"
                }
                var existingModelIDs = Set(existing.models.map(\.modelID))
                for model in incoming.models where !existingModelIDs.contains(model.modelID) {
                    existing.models.append(model)
                    existingModelIDs.insert(model.modelID)
                }
                providersByBaseURL[key] = existing
            } else {
                providersByBaseURL[key] = incoming
            }
        }

        // 1. OpenCode (~/.config/opencode/opencode.json & config.json)
        for rel in [".config/opencode/opencode.json", ".config/opencode/config.json"] {
            let fileURL = homeDirectory.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                sourcesScanned.append("~/\(rel)")
                for entry in parseOpenCodeConfig(at: fileURL, sourceLabel: "opencode.json") {
                    mergeProvider(entry)
                }
            }
        }

        // 2. Codex (~/.codex/auth.json + ~/.codex/models_cache.json + ~/.codex/config.toml)
        let codexDir = homeDirectory.appendingPathComponent(".codex")
        let codexAuthURL = codexDir.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: codexAuthURL.path) {
            sourcesScanned.append("~/.codex/auth.json")
            if let authEntry = parseCodexAuthAndModels(codexDir: codexDir) {
                mergeProvider(authEntry)
            }
        }
        let codexURL = codexDir.appendingPathComponent("config.toml")
        if FileManager.default.fileExists(atPath: codexURL.path) {
            sourcesScanned.append("~/.codex/config.toml")
            for entry in parseCodexConfigEntries(at: codexURL) {
                mergeProvider(entry)
            }
        }

        // 2b. Magpie (~/.config/magpie/providers.json)
        let magpieProvidersURL = homeDirectory.appendingPathComponent(".config/magpie/providers.json")
        if FileManager.default.fileExists(atPath: magpieProvidersURL.path) {
            sourcesScanned.append("~/.config/magpie/providers.json")
            for entry in parseMagpieProviders(at: magpieProvidersURL) {
                mergeProvider(entry)
            }
        }

        // 2c. Claude Code (~/.claude/settings.json)
        let claudeSettingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
        if FileManager.default.fileExists(atPath: claudeSettingsURL.path) {
            sourcesScanned.append("~/.claude/settings.json")
            if let claudeEntry = parseClaudeSettings(at: claudeSettingsURL) {
                mergeProvider(claudeEntry)
            }
        }

        // 3. LM Studio (~/.lmstudio/.internal/...)
        let lmStudioInternal = homeDirectory.appendingPathComponent(".lmstudio/.internal")
        if FileManager.default.fileExists(atPath: lmStudioInternal.path) {
            sourcesScanned.append("~/.lmstudio")
            if let lmEntry = parseLMStudioConfig(internalDir: lmStudioInternal) {
                mergeProvider(lmEntry)
            }
        }

        // 4. Ollama local manifests (~/.ollama/models/manifests/registry.ollama.ai/library)
        let ollamaManifests = homeDirectory.appendingPathComponent(".ollama/models/manifests/registry.ollama.ai/library")
        if FileManager.default.fileExists(atPath: ollamaManifests.path) {
            sourcesScanned.append("~/.ollama")
            if let ollamaEntry = parseOllamaManifests(libraryDir: ollamaManifests) {
                mergeProvider(ollamaEntry)
            }
        }

        // 5. AutoRoute legacy config (~/.autoroute/config.json)
        let autorouteURL = homeDirectory.appendingPathComponent(".autoroute/config.json")
        if FileManager.default.fileExists(atPath: autorouteURL.path) {
            sourcesScanned.append("~/.autoroute/config.json")
            for entry in parseAutorouteConfig(at: autorouteURL) {
                mergeProvider(entry)
            }
        }

        // 6. Probe well-known local loopback OpenAI-compatible ports via GET /v1/models
        if scanWellKnownLocalPorts {
            let wellKnownLocalEndpoints: [(name: String, baseURL: String, port: Int)] = [
                ("Local Gateway (3425)", "http://127.0.0.1:3425", 3425),
                ("Ollama (11434)", "http://127.0.0.1:11434", 11434),
                ("LM Studio (1234)", "http://127.0.0.1:1234", 1234),
                ("llama.cpp / MLX (8080)", "http://127.0.0.1:8080", 8080),
                ("vLLM / LocalAI (8000)", "http://127.0.0.1:8000", 8000),
                ("OneAPI / LiteLLM (4000)", "http://127.0.0.1:4000", 4000)
            ]
            sourcesScanned.append("localhost OpenAI 端口探测")

            await withTaskGroup(of: DiscoveredProviderEntry?.self) { group in
                for ep in wellKnownLocalEndpoints {
                    if let excludePort = excludeLoopbackPort, ep.port == excludePort {
                        continue
                    }
                    let norm = normalizeBaseURL(ep.baseURL)
                    let existingEntry = providersByBaseURL["\(norm)|\(ProviderProtocol.openAIChatCompletions.rawValue)"]
                    // Skip live /v1/models dump if config file already curated models for this port
                    if let existing = existingEntry, !existing.models.isEmpty {
                        continue
                    }
                    let existingKey = existingEntry?.apiKey
                    group.addTask { [session] in
                        await Self.probeLoopbackModelsEndpoint(
                            session: session,
                            name: ep.name,
                            baseURL: ep.baseURL,
                            apiKey: existingKey
                        )
                    }
                }
                for await discovered in group {
                    if let discovered {
                        mergeProvider(discovered)
                    }
                }
            }
        }

        let ordered = providersByBaseURL.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return LocalDiscoveryResult(providers: ordered, sourcesScanned: sourcesScanned)
    }

    // MARK: - Config Parsers

    private func parseOpenCodeConfig(at url: URL, sourceLabel: String) -> [DiscoveredProviderEntry] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providersDict = root["provider"] as? [String: Any] else {
            return []
        }

        let disabledSet = Set(root["disabled_providers"] as? [String] ?? [])
        var entries: [DiscoveredProviderEntry] = []

        for (providerKey, rawVal) in providersDict {
            if disabledSet.contains(providerKey) { continue }
            if providerKey.lowercased() == "automodel" { continue }
            guard let pDict = rawVal as? [String: Any],
                  let options = pDict["options"] as? [String: Any],
                  let rawBaseURL = options["baseURL"] as? String else {
                continue
            }
            // Skip Anthropic-specific endpoint paths in v1 OpenAI Chat Completions router
            if rawBaseURL.lowercased().contains("/apps/anthropic") {
                continue
            }

            let apiKey = (options["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelsDict = pDict["models"] as? [String: Any] ?? [:]
            let prioritizedKeys = prioritizeOpenCodeModelKeys(Array(modelsDict.keys), maxCount: 24)

            var modelEntries: [DiscoveredModelEntry] = []
            for modelID in prioritizedKeys {
                if isRecursiveAutoModelID(modelID) { continue }
                let meta = modelsDict[modelID] as? [String: Any] ?? [:]
                modelEntries.append(buildDiscoveredModel(modelID: modelID, metadata: meta, source: sourceLabel))
            }

            entries.append(DiscoveredProviderEntry(
                name: providerKey,
                baseURL: rawBaseURL,
                apiKey: (apiKey?.isEmpty == false) ? apiKey : nil,
                source: sourceLabel,
                models: modelEntries
            ))
        }
        return entries
    }

    private func prioritizeOpenCodeModelKeys(_ keys: [String], maxCount: Int) -> [String] {
        let filtered = keys.filter { !isRecursiveAutoModelID($0) }
        if filtered.count <= maxCount {
            return filtered.sorted()
        }

        // Ensure broad coverage across groups, cheap/flash models, coding, reasoning, and vision
        var chosen: [String] = []
        var chosenSet = Set<String>()

        func addIfMatch(_ predicate: (String) -> Bool, limit: Int) {
            var count = 0
            for k in filtered.sorted() where !chosenSet.contains(k) && predicate(k) {
                chosen.append(k)
                chosenSet.insert(k)
                count += 1
                if count >= limit || chosen.count >= maxCount { break }
            }
        }

        addIfMatch({ $0.hasPrefix("group/") }, limit: 6)
        addIfMatch({ $0.hasPrefix("codex/") }, limit: 4)
        addIfMatch({ $0.hasPrefix("paiyun/") }, limit: 4)
        addIfMatch({ $0.hasPrefix("auto/") && ($0.contains("flash") || $0.contains("haiku") || $0.contains("mini")) }, limit: 5)
        addIfMatch({ $0.hasPrefix("auto/") && ($0.contains("sonnet") || $0.contains("opus") || $0.contains("sol") || $0.contains("pro") || $0.contains("vision")) }, limit: 5)
        addIfMatch({ $0.hasPrefix("antigravity/") }, limit: 3)
        addIfMatch({ _ in true }, limit: maxCount)

        return Array(chosen.prefix(maxCount))
    }

    private func parseCodexAuthAndModels(codexDir: URL) -> DiscoveredProviderEntry? {
        let authURL = codexDir.appendingPathComponent("auth.json")
        guard let authData = try? Data(contentsOf: authURL),
              let authRoot = try? JSONSerialization.jsonObject(with: authData) as? [String: Any] else {
            return nil
        }

        let modelSlugs = CodexAuthFileParser.collectModelSlugs(codexDir: codexDir)
            .filter { !isRecursiveAutoModelID($0) }

        if let account = CodexAuthFileParser.parseAuthFile(at: authURL) {
            let models = modelSlugs.map {
                buildDiscoveredModel(modelID: $0, metadata: [:], source: "codex/auth.json")
            }
            return DiscoveredProviderEntry(
                name: "Codex 订阅 (ChatGPT)",
                baseURL: "https://chatgpt.com/backend-api/codex",
                apiKey: account.accessToken,
                source: "codex/auth.json",
                models: models,
                apiProtocol: .codexChatGPT,
                accountID: account.accountID,
                codexAccounts: [account]
            )
        }

        if let openAIKey = (authRoot["OPENAI_API_KEY"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !openAIKey.isEmpty {
            let models = modelSlugs.map {
                buildDiscoveredModel(modelID: $0, metadata: [:], source: "codex/auth.json")
            }
            return DiscoveredProviderEntry(
                name: "Codex (OpenAI Key)",
                baseURL: "https://api.openai.com",
                apiKey: openAIKey,
                source: "codex/auth.json",
                models: models,
                apiProtocol: .openAIResponses
            )
        }

        return nil
    }

    private func parseCodexConfigEntries(at url: URL) -> [DiscoveredProviderEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var topBaseURL: String?
        var topModelID: String?
        var currentSection: String?
        var providersBySection: [String: [String: String]] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                currentSection = inner
                continue
            }

            if currentSection == nil {
                if let val = extractTomlStringValue(line: line, key: "openai_base_url") {
                    topBaseURL = val
                } else if let val = extractTomlStringValue(line: line, key: "model") {
                    topModelID = val
                }
            } else if let section = currentSection,
                      section.hasPrefix("model_providers."),
                      section.components(separatedBy: ".").count == 2 {
                let providerKey = String(section.dropFirst("model_providers.".count))
                for key in ["name", "base_url", "wire_api", "experimental_bearer_token", "env_key"] {
                    if let val = extractTomlStringValue(line: line, key: key) {
                        providersBySection[providerKey, default: [:]][key] = val
                    }
                }
            }
        }

        var entries: [DiscoveredProviderEntry] = []

        if var resolvedBase = topBaseURL, !resolvedBase.isEmpty {
            if let parsed = URL(string: resolvedBase), resolvedBase.contains("/backend-api/"),
               let scheme = parsed.scheme, let host = parsed.host {
                let portPart = parsed.port.map { ":\($0)" } ?? ""
                resolvedBase = "\(scheme)://\(host)\(portPart)"
            }
            var models: [DiscoveredModelEntry] = []
            if let m = topModelID, !m.isEmpty, !isRecursiveAutoModelID(m) {
                models.append(buildDiscoveredModel(modelID: m, metadata: [:], source: "codex/config.toml"))
            }
            entries.append(DiscoveredProviderEntry(
                name: "codex-configured",
                baseURL: resolvedBase,
                apiKey: nil,
                source: "codex/config.toml",
                models: models
            ))
        }

        for (key, fields) in providersBySection.sorted(by: { $0.key < $1.key }) {
            let lowerKey = key.lowercased()
            if lowerKey == "automodel" || lowerKey == "magpie" { continue }
            guard let rawBase = fields["base_url"], !rawBase.isEmpty else { continue }
            var bearer = fields["experimental_bearer_token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if (bearer == nil || bearer?.isEmpty == true),
               let envKey = fields["env_key"],
               let envVal = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !envVal.isEmpty {
                bearer = envVal
            }
            let wireAPI = fields["wire_api"]?.lowercased() ?? "chat"
            let proto: ProviderProtocol = (wireAPI == "responses") ? .openAIResponses : .openAIChatCompletions
            var models: [DiscoveredModelEntry] = []
            if let m = topModelID, !m.isEmpty, !isRecursiveAutoModelID(m) {
                models.append(buildDiscoveredModel(modelID: m, metadata: [:], source: "codex/model_providers"))
            }
            entries.append(DiscoveredProviderEntry(
                name: fields["name"] ?? key,
                baseURL: rawBase,
                apiKey: (bearer?.isEmpty == false) ? bearer : nil,
                source: "codex/model_providers.\(key)",
                models: models,
                apiProtocol: proto
            ))
        }

        return entries
    }

    private func parseMagpieProviders(at url: URL) -> [DiscoveredProviderEntry] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        return Self.parseMagpieProviders(from: data, sourceLabel: "magpie/providers.json", requireAPIKey: true)
    }

    public static func parseMagpieProviders(
        from data: Data,
        sourceLabel: String = "magpie/providers.json",
        requireAPIKey: Bool = true
    ) -> [DiscoveredProviderEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [[String: Any]] else {
            return []
        }

        var entries: [DiscoveredProviderEntry] = []
        for p in providers {
            if (p["off"] as? Bool) == true { continue }
            let id = (p["id"] as? String) ?? ""
            if id.isEmpty || id.lowercased() == "automodel" || id.lowercased() == "autoroute" { continue }

            var rawKeys: [String] = []
            if let singleKey = p["key"] as? String {
                rawKeys.append(singleKey)
            }
            if let keysArr = p["keys"] as? [String] {
                rawKeys.append(contentsOf: keysArr)
            }
            let apiKeys = APIKeyPoolCodec.normalize(rawKeys)
            if requireAPIKey && apiKeys.isEmpty { continue }

            let chatURL = (p["chat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let responsesURL = (p["responses"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let anthropicURL = (p["anthropic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawModels = (p["models"] as? [String] ?? []).filter { !$0.isEmpty && !isRecursiveAutoModelIDStatic($0) }
            let modelsAreClaudeOnly = !rawModels.isEmpty && rawModels.allSatisfy { $0.lowercased().contains("claude") }

            let baseURL: String
            let proto: ProviderProtocol
            if modelsAreClaudeOnly, let anthropicURL, !anthropicURL.isEmpty {
                baseURL = anthropicURL
                proto = .anthropicMessages
            } else if let chatURL, !chatURL.isEmpty {
                baseURL = chatURL
                proto = .openAIChatCompletions
            } else if let responsesURL, !responsesURL.isEmpty {
                baseURL = responsesURL
                proto = .openAIResponses
            } else if let anthropicURL, !anthropicURL.isEmpty {
                baseURL = anthropicURL
                proto = .anthropicMessages
            } else {
                continue
            }

            var customHeaders: [String: String] = [:]
            if let hdrs = p["headers"] as? [String: Any] {
                for (k, v) in hdrs {
                    let cleanKey = k.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanVal = String(describing: v).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanKey.isEmpty && !cleanVal.isEmpty {
                        customHeaders[cleanKey] = cleanVal
                    }
                }
            }
            let passHeaders = (p["passHeaders"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let proxyURL = (p["proxy"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            let contextsDict = p["contexts"] as? [String: Any]
            let wildcardContext = (contextsDict?["*"] as? Int) ?? (contextsDict?["*"] as? NSNumber)?.intValue

            let models = rawModels.map { modelID -> DiscoveredModelEntry in
                var entry = buildDiscoveredModelStatic(modelID: modelID, metadata: [:], source: sourceLabel)
                if let exactCtx = (contextsDict?[modelID] as? Int) ?? (contextsDict?[modelID] as? NSNumber)?.intValue,
                   exactCtx >= 1024 {
                    entry.contextWindow = exactCtx
                } else if let wildcardContext, wildcardContext >= 1024 {
                    entry.contextWindow = wildcardContext
                }
                return entry
            }

            let displayName = (p["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let matchedPresetID = ProviderPresetCatalog.matchPreset(baseURL: baseURL, name: id)?.id
            entries.append(DiscoveredProviderEntry(
                name: displayName,
                baseURL: baseURL,
                apiKey: apiKeys.first,
                apiKeys: apiKeys,
                source: sourceLabel,
                models: models,
                apiProtocol: proto,
                customHeaders: customHeaders,
                passThroughHeaderNames: passHeaders,
                proxyURL: proxyURL,
                presetID: matchedPresetID
            ))
        }
        return entries
    }

    private func parseClaudeSettings(at url: URL) -> DiscoveredProviderEntry? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any] else {
            return nil
        }

        guard let baseURL = (env["ANTHROPIC_BASE_URL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !baseURL.isEmpty else {
            return nil
        }
        let token = ((env["ANTHROPIC_AUTH_TOKEN"] as? String) ?? (env["ANTHROPIC_API_KEY"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = token, !apiKey.isEmpty else { return nil }

        let modelKeys = [
            "ANTHROPIC_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL"
        ]
        var seen = Set<String>()
        var models: [DiscoveredModelEntry] = []
        for k in modelKeys {
            if let m = (env[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !m.isEmpty,
               !isRecursiveAutoModelID(m),
               seen.insert(m).inserted {
                models.append(buildDiscoveredModel(modelID: m, metadata: [:], source: "claude/settings.json"))
            }
        }

        return DiscoveredProviderEntry(
            name: "Claude Code Configured",
            baseURL: baseURL,
            apiKey: apiKey,
            source: "claude/settings.json",
            models: models,
            apiProtocol: .anthropicMessages
        )
    }

    private func parseLMStudioConfig(internalDir: URL) -> DiscoveredProviderEntry? {
        let httpCfgURL = internalDir.appendingPathComponent("http-server-config.json")
        var port = 1234
        if let data = try? Data(contentsOf: httpCfgURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = json["port"] as? Int {
            port = p
        }

        var models: [DiscoveredModelEntry] = []
        let modelDataURL = internalDir.appendingPathComponent("model-data.json")
        if let data = try? Data(contentsOf: modelDataURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = root["json"] as? [[Any]] {
            for pair in entries {
                guard let key = pair.first as? String, !key.isEmpty else { continue }
                // Prefer canonical model keys without `.gguf` duplicate if hub key exists
                if key.hasSuffix(".gguf") && entries.contains(where: { ($0.first as? String) == key.split(separator: "/").prefix(2).joined(separator: "/") }) {
                    continue
                }
                models.append(buildDiscoveredModel(modelID: key, metadata: [:], source: "lmstudio"))
            }
        }

        guard !models.isEmpty else { return nil }
        return DiscoveredProviderEntry(
            name: "LM Studio (Local)",
            baseURL: "http://127.0.0.1:\(port)",
            apiKey: nil,
            source: "lmstudio",
            models: models
        )
    }

    private func parseOllamaManifests(libraryDir: URL) -> DiscoveredProviderEntry? {
        let fm = FileManager.default
        guard let modelDirs = try? fm.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil) else {
            return nil
        }

        var models: [DiscoveredModelEntry] = []
        for dir in modelDirs where !dir.lastPathComponent.hasPrefix(".") {
            guard let tags = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for tagURL in tags where !tagURL.lastPathComponent.hasPrefix(".") {
                let modelID = "\(dir.lastPathComponent):\(tagURL.lastPathComponent)"
                models.append(buildDiscoveredModel(modelID: modelID, metadata: [:], source: "ollama"))
            }
        }

        guard !models.isEmpty else { return nil }
        return DiscoveredProviderEntry(
            name: "Ollama (Local)",
            baseURL: "http://127.0.0.1:11434",
            apiKey: nil,
            source: "ollama",
            models: models
        )
    }

    private func parseAutorouteConfig(at url: URL) -> [DiscoveredProviderEntry] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["providers"] as? [[String: Any]] else {
            return []
        }
        var entries: [DiscoveredProviderEntry] = []
        for item in list {
            let enabled = (item["enabled"] as? Bool) ?? true
            guard enabled,
                  let name = item["name"] as? String,
                  let baseURL = item["base_url"] as? String else {
                continue
            }
            let apiKey = (item["api_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(DiscoveredProviderEntry(
                name: name,
                baseURL: baseURL,
                apiKey: (apiKey?.isEmpty == false) ? apiKey : nil,
                source: "autoroute/config.json",
                models: []
            ))
        }
        return entries
    }

    private static func probeLoopbackModelsEndpoint(
        session: URLSession,
        name: String,
        baseURL: String,
        apiKey: String?
    ) async -> DiscoveredProviderEntry? {
        guard let url = URL(string: "\(baseURL)/v1/models") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataList = obj["data"] as? [[String: Any]] else {
                return nil
            }
            let ids = dataList.compactMap { $0["id"] as? String }
                .filter { !$0.isEmpty && !isRecursiveAutoModelIDStatic($0) }
                .prefix(20)
            let models = ids.map { buildDiscoveredModelStatic(modelID: $0, metadata: [:], source: "localhost:/v1/models") }
            return DiscoveredProviderEntry(
                name: name,
                baseURL: baseURL,
                apiKey: apiKey,
                source: "localhost:/v1/models",
                models: models
            )
        } catch {
            return nil
        }
    }

    // MARK: - Model Metadata Inference

    public static func buildDiscoveredModelPublic(modelID: String, metadata: [String: Any] = [:], source: String) -> DiscoveredModelEntry {
        buildDiscoveredModelStatic(modelID: modelID, metadata: metadata, source: source)
    }

    private func buildDiscoveredModel(modelID: String, metadata: [String: Any], source: String) -> DiscoveredModelEntry {
        Self.buildDiscoveredModelStatic(modelID: modelID, metadata: metadata, source: source)
    }

    private static func buildDiscoveredModelStatic(modelID: String, metadata: [String: Any], source: String) -> DiscoveredModelEntry {
        let displayName = (metadata["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let costDict = metadata["cost"] as? [String: Any]
        let inputPrice = costDict?["input"] as? Double ?? (costDict?["input"] as? Int).map(Double.init)
        let outputPrice = costDict?["output"] as? Double ?? (costDict?["output"] as? Int).map(Double.init)

        let limitDict = metadata["limit"] as? [String: Any]
        let contextWindow = (limitDict?["context"] as? Int) ?? (modelID.lowercased().contains("gpt-5") ? 272_000 : 128_000)

        let modalitiesDict = metadata["modalities"] as? [String: Any]
        let inputMods = modalitiesDict?["input"] as? [String] ?? []
        let hasReasoningFlag = (metadata["reasoning"] as? Bool) ?? false
        let hasVariants = (metadata["variants"] as? [String: Any])?.isEmpty == false

        let lower = modelID.lowercased()
        var caps: Set<ModelCapability> = [.chat, .tools]
        if inputMods.contains("image") || lower.contains("vision") || lower.contains("image") || lower.contains("gpt-") || lower.contains("claude-") || lower.contains("gemini-") {
            caps.insert(.vision)
        }
        if hasReasoningFlag || hasVariants || lower.contains("opus") || lower.contains("pro") || lower.contains("reasoning") || lower.contains("k3") || lower.contains("gpt-6") || lower.contains("gpt-5") || lower.contains("codex") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
            caps.insert(.reasoning)
        }
        if lower.contains("coder") || lower.contains("code") || lower.contains("codex") || lower.contains("gpt-5") || lower.contains("sonnet") || lower.contains("opus") || lower.contains("glm-5.3") {
            caps.insert(.coding)
        }
        if lower.contains("gpt-") || lower.contains("claude-") || lower.contains("gemini-") || lower.contains("glm-") || lower.contains("deepseek") {
            caps.insert(.jsonMode)
        }

        let role: ModelDefaultUsage
        let quality: Int
        let speed: Int

        if lower.contains("flash") || lower.contains("lite") || lower.contains("haiku") || lower.contains("mini") || lower.contains("eco") || lower.contains("spark") {
            role = .fastEconomy
            quality = 75
            speed = 92
        } else if lower.contains("codex-max") || lower.contains("gpt-5.4") || lower.contains("opus") || lower.contains("pro") || lower.contains("terra") || lower.contains("sol") || lower.contains("k3") || lower.contains("671b") || lower.contains("480b") || lower.hasPrefix("o3") {
            role = .complexReasoning
            quality = 94
            speed = 68
        } else if lower.contains("coder") || lower.contains("codex") || lower.contains("-code") {
            role = .coding
            quality = 90
            speed = 78
        } else if lower.contains("vision") {
            role = .vision
            quality = 82
            speed = 78
        } else {
            role = .general
            quality = 82
            speed = 80
        }

        return DiscoveredModelEntry(
            modelID: modelID,
            displayName: (displayName?.isEmpty == false) ? displayName! : modelID,
            inputPricePerMillion: inputPrice,
            outputPricePerMillion: outputPrice,
            contextWindow: contextWindow,
            capabilities: caps,
            defaultRole: role,
            qualityScore: quality,
            speedScore: speed,
            source: source
        )
    }

    private func extractTomlStringValue(line: String, key: String) -> String? {
        guard let eqIdx = line.firstIndex(of: "=") else { return nil }
        let lhs = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
        guard lhs == key else { return nil }
        var rhs = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
        if let commentIdx = rhs.firstIndex(of: "#") {
            rhs = rhs[..<commentIdx].trimmingCharacters(in: .whitespaces)
        }
        if rhs.hasPrefix("\"") && rhs.hasSuffix("\"") && rhs.count >= 2 {
            return String(rhs.dropFirst().dropLast())
        }
        return nil
    }

    private func normalizeBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/v1") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed
    }

    private func isRecursiveAutoModelID(_ modelID: String) -> Bool {
        Self.isRecursiveAutoModelIDStatic(modelID)
    }

    private static func isRecursiveAutoModelIDStatic(_ modelID: String) -> Bool {
        let lower = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let reserved: Set<String> = [
            "auto", "auto/auto", "workbuddy/auto",
            "automodel/auto", "automodel/auto/low", "automodel/auto/medium", "automodel/auto/high",
            "auto/low", "auto/medium", "auto/high",
            "low", "medium", "high"
        ]
        return reserved.contains(lower)
    }
}
