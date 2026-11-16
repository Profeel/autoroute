import Foundation

public struct AgentIntegrationStatus: Identifiable, Equatable, Sendable {
    public var id: String { kind.rawValue }
    public var kind: AgentKind
    public var configFilePath: String
    public var isInstalled: Bool
    public var isConnectedToAutoModel: Bool
    public var hasBackup: Bool
    public var currentBaseURL: String?
    public var currentModelSummary: String?
    public var statusNote: String?

    public init(
        kind: AgentKind,
        configFilePath: String,
        isInstalled: Bool,
        isConnectedToAutoModel: Bool,
        hasBackup: Bool,
        currentBaseURL: String? = nil,
        currentModelSummary: String? = nil,
        statusNote: String? = nil
    ) {
        self.kind = kind
        self.configFilePath = configFilePath
        self.isInstalled = isInstalled
        self.isConnectedToAutoModel = isConnectedToAutoModel
        self.hasBackup = hasBackup
        self.currentBaseURL = currentBaseURL
        self.currentModelSummary = currentModelSummary
        self.statusNote = statusNote
    }
}

public enum AgentConfigError: Error, LocalizedError, Sendable {
    case invalidExistingConfig(String)
    case backupNotFound(String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExistingConfig(let msg): return "现有配置文件解析失败：\(msg)"
        case .backupNotFound(let msg): return "未找到原始备份：\(msg)"
        case .ioFailed(let msg): return "文件读写失败：\(msg)"
        }
    }
}

private struct AgentBackupManifestEntry: Codable {
    var originalFileExisted: Bool
    var backupFileName: String
    var createdAt: Date
}

/// Manages Magpie-style detection, one-click Auto Model injection (with Low/Med/High tier models),
/// atomic backup creation, and clean restoration of local AI coding agents.
public final class AgentConfigService: @unchecked Sendable {
    public let homeDirectory: URL
    public let backupDirectory: URL
    private let fileManager = FileManager.default

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        if let backupDirectory {
            self.backupDirectory = backupDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.backupDirectory = appSupport
                .appendingPathComponent("AutoModel", isDirectory: true)
                .appendingPathComponent("agent_backups", isDirectory: true)
        }
    }

    // MARK: - Paths

    public func primaryConfigURL(for kind: AgentKind) -> URL {
        switch kind {
        case .codex:
            return homeDirectory.appendingPathComponent(".codex/config.toml")
        case .opencode:
            return homeDirectory.appendingPathComponent(".config/opencode/opencode.json")
        case .hermes:
            return homeDirectory.appendingPathComponent(".hermes/config.yaml")
        case .claudeCode:
            return homeDirectory.appendingPathComponent(".claude/settings.json")
        case .shellAndContinue:
            return homeDirectory.appendingPathComponent(".automodel/agent-env.sh")
        }
    }

    private func continueConfigURL() -> URL {
        homeDirectory.appendingPathComponent(".continue/config.json")
    }

    private func manifestURL() -> URL {
        backupDirectory.appendingPathComponent("manifest.json")
    }

    // MARK: - Inspection

    public func inspectAllAgents(proxyPort: Int) -> [AgentIntegrationStatus] {
        AgentKind.allCases.map { inspectAgent($0, proxyPort: proxyPort) }
    }

    public func inspectAgent(_ kind: AgentKind, proxyPort: Int) -> AgentIntegrationStatus {
        let configURL = primaryConfigURL(for: kind)
        let hasBackup = backupEntry(for: kind) != nil
        let targetBase = "http://127.0.0.1:\(proxyPort)/v1"

        switch kind {
        case .codex:
            let dirExists = fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".codex").path)
            let fileExists = fileManager.fileExists(atPath: configURL.path)
            guard fileExists, let text = try? String(contentsOf: configURL, encoding: .utf8) else {
                return AgentIntegrationStatus(
                    kind: kind,
                    configFilePath: configURL.path,
                    isInstalled: dirExists,
                    isConnectedToAutoModel: false,
                    hasBackup: hasBackup,
                    statusNote: dirExists ? "检测到 ~/.codex 目录，可点击「一键接入」生成 config.toml。" : "未检测到 ~/.codex 配置。"
                )
            }
            let base = extractTopLevelTOMLString(text: text, key: "openai_base_url")
            let model = extractTopLevelTOMLString(text: text, key: "model")
            let connected = isPointingAtAutoModel(baseURL: base, port: proxyPort) || text.contains("# automodel:")
            return AgentIntegrationStatus(
                kind: kind,
                configFilePath: configURL.path,
                isInstalled: true,
                isConnectedToAutoModel: connected,
                hasBackup: hasBackup,
                currentBaseURL: base,
                currentModelSummary: model,
                statusNote: connected ? "已接入 Auto Model (\(targetBase))。" : "当前独立运行（保留现有供应商或 Magpie 配置）。"
            )

        case .opencode:
            let dirExists = fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".config/opencode").path)
            let fileExists = fileManager.fileExists(atPath: configURL.path)
            guard fileExists,
                  let data = try? Data(contentsOf: configURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return AgentIntegrationStatus(
                    kind: kind,
                    configFilePath: configURL.path,
                    isInstalled: dirExists,
                    isConnectedToAutoModel: false,
                    hasBackup: hasBackup,
                    statusNote: dirExists ? "检测到 OpenCode 目录，可生成或接入 opencode.json。" : "未检测到 ~/.config/opencode/opencode.json。"
                )
            }
            let model = root["model"] as? String
            let smallModel = root["small_model"] as? String
            let providers = root["provider"] as? [String: Any]
            let autoProvider = providers?["automodel"] as? [String: Any]
            let autoOptions = autoProvider?["options"] as? [String: Any]
            let autoBase = autoOptions?["baseURL"] as? String

            var activeBase: String? = autoBase
            if activeBase == nil, let model, model.contains("/") {
                let provKey = String(model.split(separator: "/").first ?? "")
                if let p = providers?[provKey] as? [String: Any],
                   let opt = p["options"] as? [String: Any],
                   let b = opt["baseURL"] as? String {
                    activeBase = b
                }
            }
            let connected = (model?.hasPrefix("automodel/") == true) && isPointingAtAutoModel(baseURL: autoBase, port: proxyPort)
            let summary = [model, smallModel.map { "轻量: \($0)" }].compactMap { $0 }.joined(separator: " | ")
            return AgentIntegrationStatus(
                kind: kind,
                configFilePath: configURL.path,
                isInstalled: true,
                isConnectedToAutoModel: connected,
                hasBackup: hasBackup,
                currentBaseURL: activeBase,
                currentModelSummary: summary.isEmpty ? nil : summary,
                statusNote: connected ? "已注册 automodel 供应商并启用三档虚拟模型。" : "检测到已有 OpenCode 配置，可无损附加 automodel 供应商。"
            )

        case .hermes:
            let dirExists = fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".hermes").path)
            let fileExists = fileManager.fileExists(atPath: configURL.path)
            guard fileExists, let text = try? String(contentsOf: configURL, encoding: .utf8) else {
                return AgentIntegrationStatus(
                    kind: kind,
                    configFilePath: configURL.path,
                    isInstalled: dirExists,
                    isConnectedToAutoModel: false,
                    hasBackup: hasBackup,
                    statusNote: dirExists ? "检测到 ~/.hermes 目录，可一键接入 Auto Model。" : "未检测到 ~/.hermes/config.yaml。"
                )
            }
            let parsed = inspectHermesYAML(text: text)
            let connected = (parsed.provider == "automodel") && isPointingAtAutoModel(baseURL: parsed.baseURL, port: proxyPort)
            return AgentIntegrationStatus(
                kind: kind,
                configFilePath: configURL.path,
                isInstalled: true,
                isConnectedToAutoModel: connected,
                hasBackup: hasBackup,
                currentBaseURL: parsed.baseURL,
                currentModelSummary: parsed.defaultModel,
                statusNote: connected ? "已写入 automodel 供应商及低/中/高三档别名。" : "检测到 Hermes 配置，保留已有 providers，可随时接入。"
            )

        case .claudeCode:
            let dirExists = fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".claude").path)
            let fileExists = fileManager.fileExists(atPath: configURL.path)
            guard fileExists,
                  let data = try? Data(contentsOf: configURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return AgentIntegrationStatus(
                    kind: kind,
                    configFilePath: configURL.path,
                    isInstalled: dirExists,
                    isConnectedToAutoModel: false,
                    hasBackup: hasBackup,
                    statusNote: "未检测到 ~/.claude/settings.json。"
                )
            }
            let env = root["env"] as? [String: Any]
            let anthropicBase = env?["ANTHROPIC_BASE_URL"] as? String
            let openAIBase = env?["OPENAI_BASE_URL"] as? String
            let base = anthropicBase ?? openAIBase
            let haiku = env?["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String
            let sonnet = env?["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String
            let opus = env?["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String
            let connected = isPointingAtAutoModel(baseURL: anthropicBase, port: proxyPort) || isPointingAtAutoModel(baseURL: openAIBase, port: proxyPort)
            let summaryParts = [haiku.map { "低:\($0)" }, sonnet.map { "中:\($0)" }, opus.map { "高:\($0)" }].compactMap { $0 }
            return AgentIntegrationStatus(
                kind: kind,
                configFilePath: configURL.path,
                isInstalled: true,
                isConnectedToAutoModel: connected,
                hasBackup: hasBackup,
                currentBaseURL: base,
                currentModelSummary: summaryParts.isEmpty ? nil : summaryParts.joined(separator: " | "),
                statusNote: connected
                    ? "已接入 Auto Model /v1/messages 协议转换网关 (http://127.0.0.1:\(proxyPort))。"
                    : "检测到 ~/.claude/settings.json，可保留 hooks 并一键接入本地 /v1/messages 转换网关。"
            )

        case .shellAndContinue:
            let scriptExists = fileManager.fileExists(atPath: configURL.path)
            let continueURL = continueConfigURL()
            let continueExists = fileManager.fileExists(atPath: continueURL.path)
            var currentBase: String?
            var modelSummary: String?
            if scriptExists, let content = try? String(contentsOf: configURL, encoding: .utf8) {
                currentBase = extractExportValue(in: content, name: "OPENAI_BASE_URL")
                let low = extractExportValue(in: content, name: "AUTOMODEL_LOW_MODEL") ?? "auto/low"
                let med = extractExportValue(in: content, name: "AUTOMODEL_MEDIUM_MODEL") ?? "auto/medium"
                let high = extractExportValue(in: content, name: "AUTOMODEL_HIGH_MODEL") ?? "auto/high"
                modelSummary = "低:\(low) | 中:\(med) | 高:\(high)"
            }
            let connected = scriptExists && isPointingAtAutoModel(baseURL: currentBase, port: proxyPort)
            let note = continueExists
                ? "检测到 Continue 配置 (~/.continue/config.json)，应用时将同步注入并生成 ~/.automodel/agent-env.sh。"
                : "生成 source ~/.automodel/agent-env.sh 环境变量，适用于 Cursor、Aider 及各类 CLI。"
            return AgentIntegrationStatus(
                kind: kind,
                configFilePath: configURL.path,
                isInstalled: true,
                isConnectedToAutoModel: connected,
                hasBackup: hasBackup,
                currentBaseURL: currentBase,
                currentModelSummary: modelSummary,
                statusNote: note
            )
        }
    }

    // MARK: - Apply & Restore

    public func previewAgentConfig(
        kind: AgentKind,
        binding: AgentModelBinding,
        proxyPort: Int,
        resolvedTierDisplayNames: [ModelTier: String] = [:]
    ) throws -> (before: String, after: String) {
        let originalURL = primaryConfigURL(for: kind)
        let beforeText = (try? String(contentsOf: originalURL, encoding: .utf8)) ?? "(文件尚不存在，将新建配置)"

        let scratchHome = fileManager.temporaryDirectory.appendingPathComponent("AutoModelPreview-\(UUID().uuidString)", isDirectory: true)
        let scratchBackup = scratchHome.appendingPathComponent("_backups", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratchHome) }

        let previewService = AgentConfigService(homeDirectory: scratchHome, backupDirectory: scratchBackup)
        let targetURL = previewService.primaryConfigURL(for: kind)
        if fileManager.fileExists(atPath: originalURL.path) {
            try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: originalURL)
            try data.write(to: targetURL)
        }
        _ = try previewService.applyAgentConfig(
            kind: kind,
            binding: binding,
            proxyPort: proxyPort,
            resolvedTierDisplayNames: resolvedTierDisplayNames
        )
        let afterText = (try? String(contentsOf: targetURL, encoding: .utf8)) ?? ""
        return (beforeText, afterText)
    }

    @discardableResult
    public func applyAgentConfig(
        kind: AgentKind,
        binding: AgentModelBinding,
        proxyPort: Int,
        resolvedTierDisplayNames: [ModelTier: String] = [:]
    ) throws -> AgentIntegrationStatus {
        let baseURL = "http://127.0.0.1:\(proxyPort)/v1"
        let configURL = primaryConfigURL(for: kind)

        // Ensure original config is backed up once before we mutate it
        try ensureBackupIfNeeded(for: kind, fileURL: configURL)

        switch kind {
        case .codex:
            try applyCodexConfig(at: configURL, baseURL: baseURL, binding: binding)
        case .opencode:
            try applyOpenCodeConfig(at: configURL, baseURL: baseURL, binding: binding, tierLabels: resolvedTierDisplayNames)
        case .hermes:
            try applyHermesConfig(at: configURL, baseURL: baseURL, binding: binding)
        case .claudeCode:
            try applyClaudeCodeConfig(at: configURL, baseURL: baseURL, binding: binding)
        case .shellAndContinue:
            try applyShellAndContinue(envURL: configURL, baseURL: baseURL, binding: binding)
        }

        return inspectAgent(kind, proxyPort: proxyPort)
    }

    @discardableResult
    public func restoreAgentConfig(kind: AgentKind, proxyPort: Int) throws -> AgentIntegrationStatus {
        guard let entry = backupEntry(for: kind) else {
            throw AgentConfigError.backupNotFound("\(kind.displayName) 尚无备份记录")
        }

        let targetURL = primaryConfigURL(for: kind)
        let backupFileURL = backupDirectory.appendingPathComponent(entry.backupFileName)

        if entry.originalFileExisted {
            guard fileManager.fileExists(atPath: backupFileURL.path) else {
                throw AgentConfigError.backupNotFound("备份文件缺失：\(backupFileURL.path)")
            }
            let data = try Data(contentsOf: backupFileURL)
            try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: targetURL, options: .atomic)
            try? fileManager.removeItem(at: backupFileURL)
        } else {
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
        }

        // Also restore ~/.continue/config.json if we backed it up for shellAndContinue
        if kind == .shellAndContinue {
            let continueBak = backupDirectory.appendingPathComponent("continue_config.json.bak")
            let continueTarget = continueConfigURL()
            if fileManager.fileExists(atPath: continueBak.path) {
                let data = try Data(contentsOf: continueBak)
                try fileManager.createDirectory(at: continueTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: continueTarget, options: .atomic)
                try? fileManager.removeItem(at: continueBak)
            }
        }

        var manifest = loadManifest()
        manifest.removeValue(forKey: kind.rawValue)
        try saveManifest(manifest)

        return inspectAgent(kind, proxyPort: proxyPort)
    }

    // MARK: - Backup Helpers

    private func ensureBackupIfNeeded(for kind: AgentKind, fileURL: URL) throws {
        var manifest = loadManifest()
        if manifest[kind.rawValue] != nil {
            // Preserve the original pre-AutoModel backup instead of overwriting with our own edit
            return
        }

        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let existed = fileManager.fileExists(atPath: fileURL.path)
        let backupName = "\(kind.rawValue).bak"
        let backupURL = backupDirectory.appendingPathComponent(backupName)

        if existed {
            let data = try Data(contentsOf: fileURL)
            try data.write(to: backupURL, options: .atomic)
        }

        manifest[kind.rawValue] = AgentBackupManifestEntry(
            originalFileExisted: existed,
            backupFileName: backupName,
            createdAt: Date()
        )
        try saveManifest(manifest)
    }

    private func backupEntry(for kind: AgentKind) -> AgentBackupManifestEntry? {
        loadManifest()[kind.rawValue]
    }

    private func loadManifest() -> [String: AgentBackupManifestEntry] {
        let url = manifestURL()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? dec.decode([String: AgentBackupManifestEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveManifest(_ manifest: [String: AgentBackupManifestEntry]) throws {
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(manifest)
        try data.write(to: manifestURL(), options: .atomic)
    }

    // MARK: - Agent-Specific Config Writers

    private func applyCodexConfig(at url: URL, baseURL: String, binding: AgentModelBinding) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = original.components(separatedBy: "\n")

        var topLevel: [String] = []
        var sections: [String] = []
        var inSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inSection && trimmed.hasPrefix("[") {
                inSection = true
            }
            if inSection {
                sections.append(line)
            } else {
                // Strip previous automodel / magpie pointer comments & managed keys so we rewrite cleanly
                if trimmed.hasPrefix("# automodel:") { continue }
                if isTopLevelTOMLKey(line: trimmed, key: "model") { continue }
                if isTopLevelTOMLKey(line: trimmed, key: "openai_base_url") { continue }
                topLevel.append(line)
            }
        }

        // Remove trailing empty lines in topLevel before appending managed block
        while let last = topLevel.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            topLevel.removeLast()
        }

        topLevel.append("model = \"\(escapeTOMLString(binding.defaultModelOption))\"")
        topLevel.append("# automodel: points at Auto Model local router; click Restore in Auto Model to undo")
        topLevel.append("openai_base_url = \"\(escapeTOMLString(baseURL))\"")

        var combined: [String] = topLevel
        if !sections.isEmpty {
            combined.append("")
            combined.append(contentsOf: sections)
        }
        let result = combined.joined(separator: "\n")
        try result.write(to: url, atomically: true, encoding: .utf8)
    }

    private func applyOpenCodeConfig(
        at url: URL,
        baseURL: String,
        binding: AgentModelBinding,
        tierLabels: [ModelTier: String]
    ) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any]
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentConfigError.invalidExistingConfig("opencode.json 不是有效的 JSON 对象")
            }
            root = parsed
        } else {
            root = ["$schema": "https://opencode.ai/config.json"]
        }

        let lowLabel = tierLabels[.low].map { "Auto Low (\($0))" } ?? "Auto Low (轻量低价)"
        let medLabel = tierLabels[.medium].map { "Auto Medium (\($0))" } ?? "Auto Medium (均衡主力)"
        let highLabel = tierLabels[.high].map { "Auto High (\($0))" } ?? "Auto High (旗舰推理)"

        var modelsDict: [String: Any] = [
            "auto": [
                "name": "Auto Model (智能路由)",
                "limit": ["context": 200_000, "output": 16_384]
            ],
            "auto/low": [
                "name": lowLabel,
                "limit": ["context": 128_000, "output": 8_192]
            ],
            "auto/medium": [
                "name": medLabel,
                "limit": ["context": 200_000, "output": 16_384]
            ],
            "auto/high": [
                "name": highLabel,
                "limit": ["context": 200_000, "output": 32_768]
            ]
        ]

        // Ensure custom explicit model choices selected by the user also exist under provider.automodel.models
        for custom in [binding.defaultModelOption, binding.lowModelOption, binding.mediumModelOption, binding.highModelOption] {
            if !custom.isEmpty && modelsDict[custom] == nil {
                modelsDict[custom] = [
                    "name": custom,
                    "limit": ["context": 200_000, "output": 16_384]
                ]
            }
        }

        var providers = (root["provider"] as? [String: Any]) ?? [:]
        providers["automodel"] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": "Auto Model Local Router",
            "options": [
                "baseURL": baseURL,
                "apiKey": "automodel-local"
            ],
            "models": modelsDict
        ]

        root["provider"] = providers
        root["model"] = "automodel/\(binding.defaultModelOption)"
        root["small_model"] = "automodel/\(binding.lowModelOption)"

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try outData.write(to: url, options: .atomic)
    }

    private func applyHermesConfig(at url: URL, baseURL: String, binding: AgentModelBinding) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = original.isEmpty ? [] : original.components(separatedBy: "\n")

        // 1. Update or create top-level `model:` block
        let modelKeysToSet: [(String, String)] = [
            ("default", binding.defaultModelOption),
            ("provider", "automodel"),
            ("base_url", baseURL),
            ("api_mode", "chat_completions")
        ]
        lines = upsertTopLevelYAMLMappingSection(lines: lines, sectionName: "model", entries: modelKeysToSet, insertAtTopIfMissing: true)

        // 2. Update or create `providers.automodel:` block preserving all existing providers
        var modelEntries = ["auto", "auto/low", "auto/medium", "auto/high", "anthropic/haiku", "anthropic/sonnet", "anthropic/opus"]
        for custom in [binding.defaultModelOption, binding.lowModelOption, binding.mediumModelOption, binding.highModelOption] {
            if !custom.isEmpty && !modelEntries.contains(custom) {
                modelEntries.append(custom)
            }
        }
        var providerSubBlock: [String] = [
            "  automodel:",
            "    name: automodel",
            "    base_url: \(baseURL)",
            "    api_key: automodel-local",
            "    api_mode: chat_completions",
            "    model: \(binding.defaultModelOption)",
            "    models:"
        ]
        for m in modelEntries {
            providerSubBlock.append("      \(m): {}")
        }

        lines = upsertNestedYAMLSubSection(
            lines: lines,
            parentKey: "providers",
            childKey: "automodel",
            newChildBlock: providerSubBlock
        )

        let output = lines.joined(separator: "\n")
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    private func applyClaudeCodeConfig(at url: URL, baseURL: String, binding: AgentModelBinding) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any]
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentConfigError.invalidExistingConfig("settings.json 不是有效的 JSON 对象")
            }
            root = parsed
        } else {
            root = [:]
        }

        let rootURL = baseURL.hasSuffix("/v1") ? String(baseURL.dropLast(3)) : baseURL
        var env = (root["env"] as? [String: Any]) ?? [:]
        env["ANTHROPIC_BASE_URL"] = rootURL
        env["ANTHROPIC_AUTH_TOKEN"] = "automodel-local"
        env["OPENAI_BASE_URL"] = baseURL
        env["AUTOMODEL_GATEWAY_URL"] = baseURL
        env["AUTOMODEL_DEFAULT_MODEL"] = binding.defaultModelOption
        env["ANTHROPIC_MODEL"] = binding.defaultModelOption
        env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = binding.lowModelOption
        env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = binding.mediumModelOption
        env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = binding.highModelOption
        root["env"] = env

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try outData.write(to: url, options: .atomic)
    }

    private func applyShellAndContinue(envURL: URL, baseURL: String, binding: AgentModelBinding) throws {
        try fileManager.createDirectory(at: envURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        # Auto Model local router environment (source ~/.automodel/agent-env.sh)
        export OPENAI_BASE_URL="\(baseURL)"
        export OPENAI_API_BASE="\(baseURL)"
        export OPENAI_API_KEY="automodel-local"
        export AUTOMODEL_DEFAULT_MODEL="\(binding.defaultModelOption)"
        export AUTOMODEL_LOW_MODEL="\(binding.lowModelOption)"
        export AUTOMODEL_MEDIUM_MODEL="\(binding.mediumModelOption)"
        export AUTOMODEL_HIGH_MODEL="\(binding.highModelOption)"
        """
        try script.write(to: envURL, atomically: true, encoding: .utf8)

        let continueURL = continueConfigURL()
        if fileManager.fileExists(atPath: continueURL.path),
           let data = try? Data(contentsOf: continueURL),
           var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let continueBak = backupDirectory.appendingPathComponent("continue_config.json.bak")
            if !fileManager.fileExists(atPath: continueBak.path) {
                try? fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                try? data.write(to: continueBak, options: .atomic)
            }

            var models = (root["models"] as? [[String: Any]] ?? []).filter {
                ($0["title"] as? String)?.hasPrefix("Auto Model") != true
            }
            let newEntries: [[String: Any]] = [
                ["title": "Auto Model (智能路由)", "provider": "openai", "model": binding.defaultModelOption, "apiBase": baseURL, "apiKey": "automodel-local"],
                ["title": "Auto Model (低档 Low)", "provider": "openai", "model": binding.lowModelOption, "apiBase": baseURL, "apiKey": "automodel-local"],
                ["title": "Auto Model (中档 Medium)", "provider": "openai", "model": binding.mediumModelOption, "apiBase": baseURL, "apiKey": "automodel-local"],
                ["title": "Auto Model (高档 High)", "provider": "openai", "model": binding.highModelOption, "apiBase": baseURL, "apiKey": "automodel-local"]
            ]
            models.insert(contentsOf: newEntries, at: 0)
            root["models"] = models
            if let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try outData.write(to: continueURL, options: .atomic)
            }
        }
    }

    // MARK: - Text Parsing / Editing Utilities

    private func isPointingAtAutoModel(baseURL: String?, port: Int) -> Bool {
        guard let baseURL else { return false }
        let lower = baseURL.lowercased()
        return lower.contains("127.0.0.1:\(port)") || lower.contains("localhost:\(port)")
    }

    private func isTopLevelTOMLKey(line trimmed: String, key: String) -> Bool {
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return false }
        return trimmed[..<eq].trimmingCharacters(in: .whitespaces) == key
    }

    private func extractTopLevelTOMLString(text: String, key: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            if trimmed.hasPrefix("[") { break }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let lhs = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard lhs == key else { continue }
            var rhs = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let hash = rhs.firstIndex(of: "#") {
                rhs = rhs[..<hash].trimmingCharacters(in: .whitespaces)
            }
            if rhs.hasPrefix("\"") && rhs.hasSuffix("\"") && rhs.count >= 2 {
                return String(rhs.dropFirst().dropLast())
            }
        }
        return nil
    }

    private func escapeTOMLString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func extractExportValue(in script: String, name: String) -> String? {
        for raw in script.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let prefix = "export \(name)=\""
            if trimmed.hasPrefix(prefix) && trimmed.hasSuffix("\"") {
                return String(trimmed.dropFirst(prefix.count).dropLast())
            }
        }
        return nil
    }

    private func inspectHermesYAML(text: String) -> (defaultModel: String?, provider: String?, baseURL: String?) {
        let lines = text.components(separatedBy: .newlines)
        var inModel = false
        var defaultModel: String?
        var provider: String?
        var baseURL: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                inModel = (trimmed == "model:")
                continue
            }
            if inModel, indent >= 2, let colon = trimmed.firstIndex(of: ":") {
                let k = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let v = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if k == "default" { defaultModel = v }
                else if k == "provider" { provider = v }
                else if k == "base_url" { baseURL = v }
            }
        }
        return (defaultModel, provider, baseURL)
    }

    private func upsertTopLevelYAMLMappingSection(
        lines: [String],
        sectionName: String,
        entries: [(String, String)],
        insertAtTopIfMissing: Bool
    ) -> [String] {
        var result = lines
        let targetHeader = "\(sectionName):"

        if let startIdx = result.firstIndex(where: { !$0.hasPrefix(" ") && $0.trimmingCharacters(in: .whitespaces) == targetHeader }) {
            var endIdx = result.count
            for i in (startIdx + 1)..<result.count {
                let l = result[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { continue }
                if !l.hasPrefix(" ") {
                    endIdx = i
                    break
                }
            }

            let managedKeys = Set(entries.map(\.0))
            var preservedLines: [String] = []
            for i in (startIdx + 1)..<endIdx {
                let l = result[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if let colon = t.firstIndex(of: ":") {
                    let k = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
                    if managedKeys.contains(k) { continue }
                }
                if !t.isEmpty {
                    preservedLines.append(l)
                }
            }

            var replacement = [targetHeader]
            for (k, v) in entries {
                replacement.append("  \(k): \(v)")
            }
            replacement.append(contentsOf: preservedLines)
            result.replaceSubrange(startIdx..<endIdx, with: replacement)
            return result
        } else {
            var newBlock = [targetHeader]
            for (k, v) in entries {
                newBlock.append("  \(k): \(v)")
            }
            if insertAtTopIfMissing {
                return newBlock + result
            } else {
                return result + newBlock
            }
        }
    }

    private func upsertNestedYAMLSubSection(
        lines: [String],
        parentKey: String,
        childKey: String,
        newChildBlock: [String]
    ) -> [String] {
        var result = lines
        let parentHeader = "\(parentKey):"

        guard let parentStart = result.firstIndex(where: { !$0.hasPrefix(" ") && $0.trimmingCharacters(in: .whitespaces) == parentHeader }) else {
            result.append(parentHeader)
            result.append(contentsOf: newChildBlock)
            return result
        }

        var parentEnd = result.count
        for i in (parentStart + 1)..<result.count {
            let l = result[i]
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if !l.hasPrefix(" ") {
                parentEnd = i
                break
            }
        }

        let childHeader = "  \(childKey):"
        if let childStart = (parentStart + 1..<parentEnd).first(where: {
            let l = result[$0]
            return l.hasPrefix("  ") && !l.hasPrefix("   ") && l.trimmingCharacters(in: .whitespaces) == "\(childKey):"
        }) {
            var childEnd = parentEnd
            for i in (childStart + 1)..<parentEnd {
                let l = result[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { continue }
                let indent = l.prefix(while: { $0 == " " }).count
                if indent <= 2 {
                    childEnd = i
                    break
                }
            }
            result.replaceSubrange(childStart..<childEnd, with: newChildBlock)
            return result
        } else {
            _ = childHeader
            result.insert(contentsOf: newChildBlock, at: parentStart + 1)
            return result
        }
    }
}
