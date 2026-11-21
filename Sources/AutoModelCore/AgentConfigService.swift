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
    case backupManifestCorrupt(String)
    case ioFailed(String)
    case localTokenNotPersisted

    public var errorDescription: String? {
        switch self {
        case .invalidExistingConfig(let msg): return "现有配置文件解析失败：\(msg)"
        case .backupNotFound(let msg): return "未找到原始备份：\(msg)"
        case .backupManifestCorrupt(let msg): return "备份清单损坏，已拒绝覆盖或恢复：\(msg)"
        case .ioFailed(let msg): return "文件读写失败：\(msg)"
        case .localTokenNotPersisted:
            return "本地 API token 未能持久化到 Keychain，无法保证重启后 Agent 仍可连接。请在设置中重试保存凭据，成功后再接入 Agent；期间不会自动启动代理或写入 Agent 配置。"
        }
    }
}

private struct AgentBackupManifestEntry: Codable {
    var originalFileExisted: Bool
    var backupFileName: String
    var createdAt: Date
}

/// Manages Magpie-style detection, one-click AutoRoute injection (with Low/Med/High tier models),
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
        case .deepseekHarness:
            return homeDirectory.appendingPathComponent(".dsh/profiles/desktop/cordis.patch.yml")
        case .shellAndContinue:
            return homeDirectory.appendingPathComponent(".automodel/agent-env.sh")
        }
    }

    private func continueConfigURL() -> URL {
        homeDirectory.appendingPathComponent(".continue/config.json")
    }

    public func dshCredentialsURL() -> URL {
        homeDirectory.appendingPathComponent(".dsh/.credentials.yaml")
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
        let hasBackup = (try? backupEntry(for: kind)) != nil
            || fileManager.fileExists(atPath: backupDirectory.appendingPathComponent("\(kind.rawValue).bak").path)
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
            let providerKey = extractTopLevelTOMLString(text: text, key: "model_provider")
            let base = providerKey.flatMap {
                extractTOMLSectionString(text: text, section: "model_providers.\($0)", key: "base_url")
            }
            let model = extractTopLevelTOMLString(text: text, key: "model")
            let connected = (providerKey == "autoroute" || providerKey == "automodel")
                && isPointingAtAutoModel(baseURL: base, port: proxyPort, requiresV1: true)
            return AgentIntegrationStatus(
                kind: kind,
                configFilePath: configURL.path,
                isInstalled: true,
                isConnectedToAutoModel: connected,
                hasBackup: hasBackup,
                currentBaseURL: base,
                currentModelSummary: model,
                statusNote: connected ? "已接入 AutoRoute (\(targetBase))。" : "当前独立运行（保留现有供应商或 Magpie 配置）。"
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
            let connected = (model?.hasPrefix("automodel/") == true) && isPointingAtAutoModel(baseURL: autoBase, port: proxyPort, requiresV1: true)
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
                    statusNote: dirExists ? "检测到 ~/.hermes 目录，可一键接入 AutoRoute。" : "未检测到 ~/.hermes/config.yaml。"
                )
            }
            let parsed = inspectHermesYAML(text: text)
            let connected = (parsed.provider == "automodel") && isPointingAtAutoModel(baseURL: parsed.baseURL, port: proxyPort, requiresV1: true)
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
                    ? "已接入 AutoRoute /v1/messages 协议转换网关 (http://127.0.0.1:\(proxyPort))。"
                    : "检测到 ~/.claude/settings.json，可保留 hooks 并一键接入本地 /v1/messages 转换网关。"
            )

        case .deepseekHarness:
            let desktopDirExists = fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".dsh/profiles/desktop").path)
            let dshDirExists = fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".dsh").path)
            let fileExists = fileManager.fileExists(atPath: configURL.path)
            let installed = desktopDirExists || dshDirExists || fileExists
            let patchText = fileExists ? (try? String(contentsOf: configURL, encoding: .utf8)) : nil
            let credsText = try? String(contentsOf: dshCredentialsURL(), encoding: .utf8)
            let parsed = DeepSeekHarnessConfigSupport.inspect(patchText: patchText, credentialsText: credsText)
            let pointsAtProxy = isPointingAtAutoModel(baseURL: parsed.automodelBaseURL, port: proxyPort, requiresV1: true)
            let connected = (parsed.defaultProvider == DeepSeekHarnessConfigSupport.providerID)
                && pointsAtProxy
                && parsed.hasCredentialRef
            let summary = [parsed.defaultProvider, parsed.defaultModel].compactMap { $0 }.joined(separator: "/")
            let note: String
            if connected {
                note = "已注册 automodel 供应商并写入凭据引用 \(parsed.automodelAPIKeyEnv ?? DeepSeekHarnessConfigSupport.credentialRefName) 到 ~/.dsh/.credentials.yaml。"
            } else if parsed.defaultProvider == DeepSeekHarnessConfigSupport.providerID && pointsAtProxy && !parsed.hasCredentialRef {
                note = "配置已指向 AutoRoute，但 ~/.dsh/.credentials.yaml 缺少凭据引用 \(parsed.automodelAPIKeyEnv ?? DeepSeekHarnessConfigSupport.credentialRefName)；请重新一键写入。"
            } else if installed {
                note = "检测到 DeepSeek Harness (~/.dsh)，保留其他插件配置与登录态，可一键接入 AutoRoute。"
            } else {
                note = "未检测到 ~/.dsh/profiles/desktop；仍可点击「一键设置」预生成 DeepSeek Harness 配置。"
            }
            return AgentIntegrationStatus(
                kind: kind,
                configFilePath: configURL.path,
                isInstalled: installed,
                isConnectedToAutoModel: connected,
                hasBackup: hasBackup,
                currentBaseURL: parsed.automodelBaseURL,
                currentModelSummary: summary.isEmpty ? nil : summary,
                statusNote: note
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
            let connected = scriptExists && isPointingAtAutoModel(baseURL: currentBase, port: proxyPort, requiresV1: true)
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

    public func configurationUpdatedAt(for kind: AgentKind) -> Date? {
        (try? fileManager.attributesOfItem(atPath: primaryConfigURL(for: kind).path)[.modificationDate]) as? Date
    }

    public func previewAgentConfig(
        kind: AgentKind,
        binding: AgentModelBinding,
        proxyPort: Int,
        localAPIToken: String,
        resolvedTierDisplayNames: [ModelTier: String] = [:]
    ) throws -> (before: String, after: String) {
        let originalURL = primaryConfigURL(for: kind)
        let beforeText = (try? String(contentsOf: originalURL, encoding: .utf8)) ?? "(文件尚不存在，将新建配置)"

        let scratchHome = fileManager.temporaryDirectory.appendingPathComponent("AutoModelPreview-\(UUID().uuidString)", isDirectory: true)
        let scratchBackup = scratchHome.appendingPathComponent("_backups", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratchHome) }
        try fileManager.createDirectory(at: scratchHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let previewService = AgentConfigService(homeDirectory: scratchHome, backupDirectory: scratchBackup)
        let targetURL = previewService.primaryConfigURL(for: kind)
        if fileManager.fileExists(atPath: originalURL.path) {
            try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: originalURL)
            try data.write(to: targetURL)
        }
        if kind == .deepseekHarness {
            let origCreds = dshCredentialsURL()
            if fileManager.fileExists(atPath: origCreds.path) {
                let targetCreds = previewService.dshCredentialsURL()
                try fileManager.createDirectory(at: targetCreds.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: origCreds).write(to: targetCreds)
            }
        }
        _ = try previewService.applyAgentConfig(
            kind: kind,
            binding: binding,
            proxyPort: proxyPort,
            localAPIToken: localAPIToken,
            resolvedTierDisplayNames: resolvedTierDisplayNames
        )
        let afterText = ((try? String(contentsOf: targetURL, encoding: .utf8)) ?? "")
            .replacingOccurrences(of: localAPIToken, with: "[REDACTED_LOCAL_TOKEN]")
        return (
            beforeText.replacingOccurrences(of: localAPIToken, with: "[REDACTED_LOCAL_TOKEN]"),
            afterText
        )
    }

    @discardableResult
    public func applyAgentConfig(
        kind: AgentKind,
        binding: AgentModelBinding,
        proxyPort: Int,
        localAPIToken: String,
        resolvedTierDisplayNames: [ModelTier: String] = [:]
    ) throws -> AgentIntegrationStatus {
        let baseURL = "http://127.0.0.1:\(proxyPort)/v1"
        let configURL = primaryConfigURL(for: kind)

        // Ensure original config is backed up once before we mutate it
        try ensureBackupIfNeeded(for: kind, fileURL: configURL)

        switch kind {
        case .codex:
            try applyCodexConfig(at: configURL, baseURL: baseURL, binding: binding, localAPIToken: localAPIToken)
        case .opencode:
            try applyOpenCodeConfig(at: configURL, baseURL: baseURL, binding: binding, localAPIToken: localAPIToken, tierLabels: resolvedTierDisplayNames)
        case .hermes:
            try applyHermesConfig(at: configURL, baseURL: baseURL, binding: binding, localAPIToken: localAPIToken)
        case .claudeCode:
            try applyClaudeCodeConfig(at: configURL, baseURL: baseURL, binding: binding, localAPIToken: localAPIToken)
        case .deepseekHarness:
            try applyDeepSeekHarnessConfig(
                at: configURL,
                baseURL: baseURL,
                binding: binding,
                localAPIToken: localAPIToken,
                tierLabels: resolvedTierDisplayNames
            )
        case .shellAndContinue:
            try applyShellAndContinue(envURL: configURL, baseURL: baseURL, binding: binding, localAPIToken: localAPIToken)
        }
        try persistManagedSnapshots(for: kind, primaryURL: configURL)
        return inspectAgent(kind, proxyPort: proxyPort)
    }

    @discardableResult
    public func restoreAgentConfig(kind: AgentKind, proxyPort: Int) throws -> AgentIntegrationStatus {
        guard let entry = try backupEntry(for: kind) else {
            throw AgentConfigError.backupNotFound("\(kind.displayName) 尚无备份记录")
        }

        let targetURL = primaryConfigURL(for: kind)
        let backupFileURL = backupDirectory.appendingPathComponent(entry.backupFileName)
        let originalData: Data?
        if entry.originalFileExisted {
            guard fileManager.fileExists(atPath: backupFileURL.path) else {
                throw AgentConfigError.backupNotFound("备份文件缺失：\(backupFileURL.path)")
            }
            originalData = try Data(contentsOf: backupFileURL)
        } else {
            originalData = nil
        }

        let managedSnapshot = try? Data(contentsOf: managedSnapshotURL(for: kind))
        let currentPrimary = try? Data(contentsOf: targetURL)
        let primaryUntouched = managedSnapshot != nil && managedSnapshot == currentPrimary

        if primaryUntouched {
            try restoreExactPrimary(at: targetURL, originalData: originalData)
        } else {
            switch kind {
            case .codex:
                try restoreCodexConfig(at: targetURL, originalData: originalData)
            case .opencode:
                try restoreOpenCodeConfig(at: targetURL, originalData: originalData)
            case .hermes:
                try restoreHermesConfig(at: targetURL, originalData: originalData)
            case .claudeCode:
                try restoreClaudeCodeConfig(at: targetURL, originalData: originalData)
            case .deepseekHarness:
                try restoreDeepSeekHarnessPatch(at: targetURL, originalData: originalData)
            case .shellAndContinue:
                try restoreShellEnvironment(at: targetURL, originalData: originalData)
            }
        }
        if kind == .deepseekHarness {
            try restoreDeepSeekHarnessCredentials(at: dshCredentialsURL())
        }
        if kind == .shellAndContinue {
            try restoreContinueConfig(at: continueConfigURL())
        }
        if let originalData, !fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try originalData.write(to: targetURL, options: .atomic)
        }
        try? fileManager.removeItem(at: backupFileURL)
        try? fileManager.removeItem(at: backupDirectory.appendingPathComponent("continue_config.json.bak"))
        try? fileManager.removeItem(at: backupDirectory.appendingPathComponent("dsh_credentials.yaml.bak"))
        try? fileManager.removeItem(at: backupDirectory.appendingPathComponent("dsh_credentials_state.json"))
        try? fileManager.removeItem(at: managedSnapshotURL(for: kind))
        try? fileManager.removeItem(at: managedContinueSnapshotURL())

        var manifest = try loadManifest()
        manifest.removeValue(forKey: kind.rawValue)
        try saveManifest(manifest)

        return inspectAgent(kind, proxyPort: proxyPort)
    }

    // MARK: - Three-way Restore Helpers

    private func managedSnapshotURL(for kind: AgentKind) -> URL {
        backupDirectory.appendingPathComponent("\(kind.rawValue).managed")
    }

    private func managedContinueSnapshotURL() -> URL {
        backupDirectory.appendingPathComponent("continue_config.managed")
    }

    private func persistManagedSnapshots(for kind: AgentKind, primaryURL: URL) throws {
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: primaryURL) {
            try data.write(to: managedSnapshotURL(for: kind), options: .atomic)
        }
        if kind == .shellAndContinue {
            let continueURL = continueConfigURL()
            if let data = try? Data(contentsOf: continueURL) {
                try data.write(to: managedContinueSnapshotURL(), options: .atomic)
            } else {
                try? fileManager.removeItem(at: managedContinueSnapshotURL())
            }
        }
    }

    private func restoreExactPrimary(at url: URL, originalData: Data?) throws {
        if let originalData {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try originalData.write(to: url, options: .atomic)
        } else {
            try? fileManager.removeItem(at: url)
        }
    }

    private func decodeJSONObject(_ data: Data?, label: String) throws -> [String: Any]? {
        guard let data else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentConfigError.invalidExistingConfig("\(label) 不是有效的 JSON 对象")
        }
        return object
    }

    private func writeJSON(_ root: [String: Any], to url: URL) throws {
        guard !root.isEmpty else {
            try? fileManager.removeItem(at: url)
            return
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func restoreOpenCodeConfig(at url: URL, originalData: Data?) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let original = try decodeJSONObject(originalData, label: "opencode.json")
        guard var current = try decodeJSONObject(try Data(contentsOf: url), label: "opencode.json") else { return }

        var providers = (current["provider"] as? [String: Any]) ?? [:]
        providers.removeValue(forKey: "automodel")
        if providers.isEmpty {
            current.removeValue(forKey: "provider")
        } else {
            current["provider"] = providers
        }

        for key in ["model", "small_model"] {
            if let originalValue = original?[key] as? String {
                current[key] = originalValue
            } else if original == nil {
                current.removeValue(forKey: key)
            } else if (current[key] as? String)?.hasPrefix("automodel/") == true {
                current.removeValue(forKey: key)
            }
        }
        if original == nil, current.count == 1, current["$schema"] != nil {
            current.removeValue(forKey: "$schema")
        }
        try writeJSON(current, to: url)
    }

    private func restoreClaudeCodeConfig(at url: URL, originalData: Data?) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let original = try decodeJSONObject(originalData, label: "settings.json")
        guard var current = try decodeJSONObject(try Data(contentsOf: url), label: "settings.json") else { return }
        let originalEnv = original?["env"] as? [String: Any]
        var env = (current["env"] as? [String: Any]) ?? [:]
        let managedKeys = [
            "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "OPENAI_BASE_URL", "AUTOMODEL_GATEWAY_URL",
            "AUTOMODEL_DEFAULT_MODEL", "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL"
        ]
        for key in managedKeys {
            if let originalValue = originalEnv?[key] {
                env[key] = originalValue
            } else {
                env.removeValue(forKey: key)
            }
        }
        if env.isEmpty {
            current.removeValue(forKey: "env")
        } else {
            current["env"] = env
        }
        try writeJSON(current, to: url)
    }

    private func restoreCodexConfig(at url: URL, originalData: Data?) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let originalText = originalData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let managedKeys = ["model", "model_provider", "openai_base_url", "wire_api"]
        var result: [String] = []
        var inManagedSection = false

        for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inManagedSection = trimmed == "[model_providers.autoroute]" || trimmed == "[model_providers.automodel]"
                if inManagedSection { continue }
            }
            if inManagedSection { continue }
            if !trimmed.hasPrefix("["),
               trimmed.hasPrefix("# automodel:") || trimmed.hasPrefix("# autoroute:") || trimmed.hasPrefix("# magpie:") {
                continue
            }
            if (result.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }),
               managedKeys.contains(where: { isTopLevelTOMLKey(line: trimmed, key: $0) }) {
                continue
            }
            result.append(line)
        }

        var restoredTopLevel: [String] = []
        for key in managedKeys {
            if let value = extractTopLevelTOMLString(text: originalText, key: key) {
                restoredTopLevel.append("\(key) = \"\(escapeTOMLString(value))\"")
            }
        }
        if !restoredTopLevel.isEmpty {
            let insertIndex = result.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? result.count
            result.insert(contentsOf: restoredTopLevel, at: insertIndex)
        }
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        if result.isEmpty {
            try? fileManager.removeItem(at: url)
        } else {
            try (result.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func restoreHermesConfig(at url: URL, originalData: Data?) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let originalText = originalData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let originalModelBlock = topLevelYAMLBlock(in: originalText, sectionName: "model")
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        lines = removeTopLevelYAMLBlock(lines, sectionName: "model")
        lines = removeNestedYAMLSubSection(lines, parentKey: "providers", childKey: "automodel")
        if let originalModelBlock {
            lines.insert(contentsOf: originalModelBlock + [""], at: 0)
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if lines.isEmpty {
            try? fileManager.removeItem(at: url)
        } else {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func restoreShellEnvironment(at url: URL, originalData: Data?) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        var result: [String] = []
        var inManagedBlock = false
        for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# BEGIN AUTOROUTE MANAGED" {
                inManagedBlock = true
                continue
            }
            if inManagedBlock {
                if trimmed == "# END AUTOROUTE MANAGED" {
                    inManagedBlock = false
                }
                continue
            }
            let isLegacyManaged = trimmed.hasPrefix("# AutoRoute local router environment")
                || trimmed.hasPrefix("export OPENAI_BASE_URL=")
                || trimmed.hasPrefix("export OPENAI_API_BASE=")
                || trimmed.hasPrefix("export OPENAI_API_KEY=")
                || trimmed.hasPrefix("export AUTOMODEL_DEFAULT_MODEL=")
                || trimmed.hasPrefix("export AUTOMODEL_LOW_MODEL=")
                || trimmed.hasPrefix("export AUTOMODEL_MEDIUM_MODEL=")
                || trimmed.hasPrefix("export AUTOMODEL_HIGH_MODEL=")
            if !isLegacyManaged {
                result.append(line)
            }
        }
        while let first = result.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.removeFirst()
        }
        while let last = result.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.removeLast()
        }
        let remainder = result.joined(separator: "\n")
        if let originalData, let originalText = String(data: originalData, encoding: .utf8) {
            let original = originalText.trimmingCharacters(in: .newlines)
            let combined = remainder.isEmpty ? original : original + "\n" + remainder
            try (combined + (combined.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
        } else if remainder.isEmpty {
            try? fileManager.removeItem(at: url)
        } else {
            try (remainder + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func restoreContinueConfig(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard var current = try decodeJSONObject(try Data(contentsOf: url), label: "config.json") else { return }
        if var models = current["models"] as? [[String: Any]] {
            models.removeAll { entry in
                let title = (entry["title"] as? String) ?? ""
                return title.hasPrefix("AutoRoute") || title.hasPrefix("Auto Model")
            }
            if models.isEmpty {
                current.removeValue(forKey: "models")
            } else {
                current["models"] = models
            }
        }
        try writeJSON(current, to: url)
    }

    private func topLevelYAMLBlock(in text: String, sectionName: String) -> [String]? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            !$0.hasPrefix(" ") && $0.trimmingCharacters(in: .whitespaces) == "\(sectionName):"
        }) else { return nil }
        var end = lines.count
        for index in (start + 1)..<lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), !line.hasPrefix(" ") {
                end = index
                break
            }
        }
        return Array(lines[start..<end])
    }

    private func removeTopLevelYAMLBlock(_ lines: [String], sectionName: String) -> [String] {
        var result: [String] = []
        var skipping = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            if !skipping, indent == 0, trimmed == "\(sectionName):" {
                skipping = true
                continue
            }
            if skipping {
                if !trimmed.isEmpty, !trimmed.hasPrefix("#"), indent == 0 {
                    skipping = false
                    result.append(line)
                }
                continue
            }
            result.append(line)
        }
        return result
    }

    private func removeNestedYAMLSubSection(_ lines: [String], parentKey: String, childKey: String) -> [String] {
        var result = lines
        guard let parentStart = result.firstIndex(where: {
            !$0.hasPrefix(" ") && $0.trimmingCharacters(in: .whitespaces) == "\(parentKey):"
        }) else { return result }
        var parentEnd = result.count
        for index in (parentStart + 1)..<result.count {
            let line = result[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), !line.hasPrefix(" ") {
                parentEnd = index
                break
            }
        }
        guard let childStart = (parentStart + 1..<parentEnd).first(where: {
            let line = result[$0]
            return line.hasPrefix("  ") && !line.hasPrefix("   ")
                && line.trimmingCharacters(in: .whitespaces) == "\(childKey):"
        }) else { return result }
        var childEnd = parentEnd
        for index in (childStart + 1)..<parentEnd {
            let line = result[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"),
               line.prefix(while: { $0 == " " }).count <= 2 {
                childEnd = index
                break
            }
        }
        result.removeSubrange(childStart..<childEnd)
        let hasRemainingChildren = result[(parentStart + 1)..<min(parentEnd, result.count)].contains {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        if !hasRemainingChildren {
            result.remove(at: parentStart)
        }
        return result
    }

    // MARK: - Backup Helpers

    private func ensureBackupIfNeeded(for kind: AgentKind, fileURL: URL) throws {
        var manifest = try loadManifest()
        if manifest[kind.rawValue] != nil {
            // Preserve the original pre-AutoModel backup instead of overwriting with our own edit
            return
        }

        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let existed = fileManager.fileExists(atPath: fileURL.path)
        let backupName = "\(kind.rawValue).bak"
        let backupURL = backupDirectory.appendingPathComponent(backupName)
        if fileManager.fileExists(atPath: backupURL.path) {
            throw AgentConfigError.backupManifestCorrupt("检测到已有 \(backupName)，但清单没有对应记录；拒绝覆盖原始备份。")
        }

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

    private func backupEntry(for kind: AgentKind) throws -> AgentBackupManifestEntry? {
        try loadManifest()[kind.rawValue]
    }

    private func loadManifest() throws -> [String: AgentBackupManifestEntry] {
        let url = manifestURL()
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AgentConfigError.backupManifestCorrupt("无法读取 manifest.json：\(error.localizedDescription)")
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            return try dec.decode([String: AgentBackupManifestEntry].self, from: data)
        } catch {
            throw AgentConfigError.backupManifestCorrupt("manifest.json 解析失败：\(error.localizedDescription)")
        }
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

    private func applyCodexConfig(at url: URL, baseURL: String, binding: AgentModelBinding, localAPIToken: String) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = original.components(separatedBy: "\n")

        var topLevel: [String] = []
        var sections: [String] = []
        var inSection = false
        var skippingManagedSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inSection = true
                if trimmed == "[model_providers.autoroute]" || trimmed == "[model_providers.automodel]" {
                    skippingManagedSection = true
                    continue
                } else {
                    skippingManagedSection = false
                }
            }
            if inSection {
                if !skippingManagedSection {
                    sections.append(line)
                }
            } else {
                // Strip previous autoroute / automodel / magpie pointer comments & managed keys so we rewrite cleanly
                if trimmed.hasPrefix("# automodel:") || trimmed.hasPrefix("# autoroute:") || trimmed.hasPrefix("# magpie:") { continue }
                if isTopLevelTOMLKey(line: trimmed, key: "model") { continue }
                if isTopLevelTOMLKey(line: trimmed, key: "model_provider") { continue }
                if isTopLevelTOMLKey(line: trimmed, key: "openai_base_url") { continue }
                if isTopLevelTOMLKey(line: trimmed, key: "wire_api") { continue }
                topLevel.append(line)
            }
        }

        // Remove trailing empty lines in topLevel before appending managed block
        while let last = topLevel.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            topLevel.removeLast()
        }

        topLevel.append("# autoroute: points at AutoRoute local router; click Restore in AutoRoute to undo")
        topLevel.append("model = \"\(escapeTOMLString(binding.defaultModelOption))\"")
        topLevel.append("model_provider = \"autoroute\"")

        var combined: [String] = topLevel
        combined.append("")
        combined.append("[model_providers.autoroute]")
        combined.append("name = \"AutoRoute\"")
        combined.append("base_url = \"\(escapeTOMLString(baseURL))\"")
        combined.append("wire_api = \"responses\"")
        combined.append("requires_openai_auth = false")
        combined.append("http_headers = { \"Authorization\" = \"Bearer \(escapeTOMLString(localAPIToken))\" }")

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
        localAPIToken: String,
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
                "name": "AutoRoute (智能路由)",
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
            "name": "AutoRoute Local Router",
            "options": [
                "baseURL": baseURL,
                "apiKey": localAPIToken
            ],
            "models": modelsDict
        ]

        root["provider"] = providers
        root["model"] = "automodel/\(binding.defaultModelOption)"
        root["small_model"] = "automodel/\(binding.lowModelOption)"

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try outData.write(to: url, options: .atomic)
    }

    private func applyHermesConfig(at url: URL, baseURL: String, binding: AgentModelBinding, localAPIToken: String) throws {
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
            "    api_key: \(localAPIToken)",
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

    private func applyClaudeCodeConfig(at url: URL, baseURL: String, binding: AgentModelBinding, localAPIToken: String) throws {
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
        env["ANTHROPIC_AUTH_TOKEN"] = localAPIToken
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

    private func applyDeepSeekHarnessConfig(
        at patchURL: URL,
        baseURL: String,
        binding: AgentModelBinding,
        localAPIToken: String,
        tierLabels: [ModelTier: String]
    ) throws {
        try fileManager.createDirectory(at: patchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existingPatch = fileManager.fileExists(atPath: patchURL.path)
            ? try String(contentsOf: patchURL, encoding: .utf8)
            : nil
        let nextPatch = try DeepSeekHarnessConfigSupport.applyPatch(
            existingText: existingPatch,
            baseURL: baseURL,
            binding: binding,
            tierLabels: tierLabels
        )

        let credsURL = dshCredentialsURL()
        let credsStateURL = backupDirectory.appendingPathComponent("dsh_credentials_state.json")
        let credsBakURL = backupDirectory.appendingPathComponent("dsh_credentials.yaml.bak")
        if !fileManager.fileExists(atPath: credsStateURL.path) {
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let credsExisted = fileManager.fileExists(atPath: credsURL.path)
            if credsExisted {
                try Data(contentsOf: credsURL).write(to: credsBakURL, options: .atomic)
            }
            let stateData = try JSONSerialization.data(withJSONObject: ["originalFileExisted": credsExisted])
            try stateData.write(to: credsStateURL, options: .atomic)
        }

        let existingCreds = fileManager.fileExists(atPath: credsURL.path)
            ? try String(contentsOf: credsURL, encoding: .utf8)
            : nil
        let nextCreds = try DeepSeekHarnessConfigSupport.upsertCredentialRef(
            existingText: existingCreds,
            secretValue: localAPIToken
        )

        try DeepSeekHarnessConfigSupport.writeOwnerOnlyFile(nextCreds, to: credsURL, fileManager: fileManager)
        try nextPatch.write(to: patchURL, atomically: true, encoding: .utf8)
    }

    private func restoreDeepSeekHarnessPatch(at url: URL, originalData: Data?) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let currentText = try String(contentsOf: url, encoding: .utf8)
        let originalText = originalData.flatMap { String(data: $0, encoding: .utf8) }
        if let restored = try DeepSeekHarnessConfigSupport.restorePatch(currentText: currentText, originalText: originalText) {
            try restored.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? fileManager.removeItem(at: url)
        }
    }

    private func restoreDeepSeekHarnessCredentials(at credsURL: URL) throws {
        guard fileManager.fileExists(atPath: credsURL.path) else { return }
        let credsStateURL = backupDirectory.appendingPathComponent("dsh_credentials_state.json")
        var originalExisted = true
        if let stateData = try? Data(contentsOf: credsStateURL),
           let obj = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
           let existed = obj["originalFileExisted"] as? Bool {
            originalExisted = existed
        }
        let currentCreds = try String(contentsOf: credsURL, encoding: .utf8)
        if let updated = DeepSeekHarnessConfigSupport.removeCredentialRef(
            existingText: currentCreds,
            originalFileExisted: originalExisted
        ) {
            try DeepSeekHarnessConfigSupport.writeOwnerOnlyFile(updated, to: credsURL, fileManager: fileManager)
        } else {
            try? fileManager.removeItem(at: credsURL)
        }
    }

    private func applyShellAndContinue(envURL: URL, baseURL: String, binding: AgentModelBinding, localAPIToken: String) throws {
        try fileManager.createDirectory(at: envURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        # BEGIN AUTOROUTE MANAGED
        # AutoRoute local router environment (source ~/.automodel/agent-env.sh)
        export OPENAI_BASE_URL="\(baseURL)"
        export OPENAI_API_BASE="\(baseURL)"
        export OPENAI_API_KEY="\(localAPIToken)"
        export AUTOMODEL_DEFAULT_MODEL="\(binding.defaultModelOption)"
        export AUTOMODEL_LOW_MODEL="\(binding.lowModelOption)"
        export AUTOMODEL_MEDIUM_MODEL="\(binding.mediumModelOption)"
        export AUTOMODEL_HIGH_MODEL="\(binding.highModelOption)"
        # END AUTOROUTE MANAGED
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
                let title = ($0["title"] as? String) ?? ""
                return !title.hasPrefix("AutoRoute") && !title.hasPrefix("Auto Model")
            }
            let newEntries: [[String: Any]] = [
                ["title": "AutoRoute (智能路由)", "provider": "openai", "model": binding.defaultModelOption, "apiBase": baseURL, "apiKey": localAPIToken],
                ["title": "AutoRoute (低档 Low)", "provider": "openai", "model": binding.lowModelOption, "apiBase": baseURL, "apiKey": localAPIToken],
                ["title": "AutoRoute (中档 Medium)", "provider": "openai", "model": binding.mediumModelOption, "apiBase": baseURL, "apiKey": localAPIToken],
                ["title": "AutoRoute (高档 High)", "provider": "openai", "model": binding.highModelOption, "apiBase": baseURL, "apiKey": localAPIToken]
            ]
            models.insert(contentsOf: newEntries, at: 0)
            root["models"] = models
            if let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try outData.write(to: continueURL, options: .atomic)
            }
        }
    }

    // MARK: - Text Parsing / Editing Utilities

    private func isPointingAtAutoModel(baseURL: String?, port: Int, requiresV1: Bool = false) -> Bool {
        guard let baseURL, let url = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "http", let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost",
              url.port == port, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path == "v1" || (!requiresV1 && path.isEmpty)
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

    private func extractTOMLSectionString(text: String, section: String, key: String) -> String? {
        let targetHeader = "[\(section)]"
        var inTarget = false
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            if trimmed.hasPrefix("[") {
                inTarget = (trimmed == targetHeader)
                continue
            }
            guard inTarget, let eq = trimmed.firstIndex(of: "=") else { continue }
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
