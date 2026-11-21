import Foundation

/// Pure-Swift inspector, patcher, and restorer for DeepSeek Harness (`dsh`) configuration:
/// - `~/.dsh/profiles/desktop/cordis.patch.yml`
/// - `~/.dsh/.credentials.yaml` (owner-only 0600 permissions)
enum DeepSeekHarnessConfigSupport {
    static let providerID = "automodel"
    static let credentialRefName = "AUTOROUTE_API_KEY"
    static let llmPiAiEntryID = "llm-pi-ai"
    static let llmPiAiPackage = "@deepseek-ai/dsh-llm-pi-ai"
    static let defaultModelEntryID = "agent-default-model"
    static let defaultModelPackage = "@deepseek-ai/dsh-agent-default-model"

    private static let defaultPatchHeader = """
    # Your patch layer for this dsh profile, applied after every bundle layer:
    # a top-level YAML array of loader patch entries (id-targeted config
    # overrides, disables, and insert lists; `!!js` expressions allowed).
    """

    struct InspectionResult {
        var defaultProvider: String?
        var defaultModel: String?
        var automodelBaseURL: String?
        var automodelAPIKeyEnv: String?
        var hasCredentialRef: Bool
    }

    struct PatchEntry {
        var id: String?
        var rawLines: [String]
    }

    // MARK: - Inspection

    static func inspect(patchText: String?, credentialsText: String?) -> InspectionResult {
        let credRefs = parseCredentialRefs(credentialsText ?? "")
        guard let patchText, !patchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return InspectionResult(
                defaultProvider: nil,
                defaultModel: nil,
                automodelBaseURL: nil,
                automodelAPIKeyEnv: nil,
                hasCredentialRef: false
            )
        }

        let (_, entries) = splitPatchDocument(patchText)
        var defaultProvider: String?
        var defaultModel: String?
        var automodelBaseURL: String?
        var automodelAPIKeyEnv: String?

        for entry in entries {
            if entry.id == defaultModelEntryID {
                let parsed = parseDefaultModelEntry(entry.rawLines)
                defaultProvider = parsed.provider
                defaultModel = parsed.model
            } else if entry.id == llmPiAiEntryID {
                let parsed = parseLlmPiAiAutomodel(entry.rawLines)
                automodelBaseURL = parsed.baseURL
                automodelAPIKeyEnv = parsed.apiKeyEnv
            }
        }

        let hasRef = automodelAPIKeyEnv.map { !(credRefs[$0] ?? "").isEmpty } ?? false
        return InspectionResult(
            defaultProvider: defaultProvider,
            defaultModel: defaultModel,
            automodelBaseURL: automodelBaseURL,
            automodelAPIKeyEnv: automodelAPIKeyEnv,
            hasCredentialRef: hasRef
        )
    }

    // MARK: - Apply & Restore Patch YAML

    static func applyPatch(
        existingText: String?,
        baseURL: String,
        binding: AgentModelBinding,
        tierLabels: [ModelTier: String]
    ) throws -> String {
        let (header, entries) = splitPatchDocument(existingText ?? "")
        var nextEntries = entries

        let newDefaultEntry = PatchEntry(
            id: defaultModelEntryID,
            rawLines: renderDefaultModelEntry(model: binding.defaultModelOption)
        )
        if let idx = nextEntries.firstIndex(where: { $0.id == defaultModelEntryID }) {
            nextEntries[idx] = newDefaultEntry
        } else {
            nextEntries.insert(newDefaultEntry, at: 0)
        }

        let automodelBlock = renderAutomodelProviderLines(
            baseURL: baseURL,
            binding: binding,
            tierLabels: tierLabels,
            indent: 6
        )
        if let idx = nextEntries.firstIndex(where: { $0.id == llmPiAiEntryID }) {
            let updatedLines = try upsertAutomodelInLlmPiAi(
                entryLines: nextEntries[idx].rawLines,
                automodelLines: automodelBlock,
                baseURL: baseURL,
                binding: binding,
                tierLabels: tierLabels
            )
            nextEntries[idx] = PatchEntry(id: llmPiAiEntryID, rawLines: updatedLines)
        } else {
            nextEntries.append(PatchEntry(
                id: llmPiAiEntryID,
                rawLines: renderLlmPiAiEntry(automodelLines: automodelBlock)
            ))
        }

        return renderPatchDocument(header: header.isEmpty ? defaultPatchHeader.components(separatedBy: "\n") : header, entries: nextEntries)
    }

    static func restorePatch(currentText: String, originalText: String?) throws -> String? {
        let (header, currentEntries) = splitPatchDocument(currentText)
        let originalEntries = originalText.map { splitPatchDocument($0).1 } ?? []
        let originalDefaultEntry = originalEntries.first(where: { $0.id == defaultModelEntryID })
        let originalHadLlmPiAi = originalEntries.contains(where: { $0.id == llmPiAiEntryID })

        var nextEntries: [PatchEntry] = []
        for entry in currentEntries {
            if entry.id == defaultModelEntryID {
                let parsed = parseDefaultModelEntry(entry.rawLines)
                if parsed.provider == providerID {
                    if let orig = originalDefaultEntry {
                        nextEntries.append(orig)
                    }
                    // Otherwise drop the AutoRoute-inserted default model entry.
                } else {
                    nextEntries.append(entry)
                }
            } else if entry.id == llmPiAiEntryID {
                if let cleaned = try removeAutomodelFromLlmPiAi(
                    entryLines: entry.rawLines,
                    keepEmptyEntry: originalHadLlmPiAi
                ) {
                    nextEntries.append(PatchEntry(id: llmPiAiEntryID, rawLines: cleaned))
                }
            } else {
                nextEntries.append(entry)
            }
        }

        if nextEntries.isEmpty {
            if originalText == nil {
                return nil
            }
            var lines = header
            lines.append("[]")
            return lines.joined(separator: "\n") + "\n"
        }

        return renderPatchDocument(header: header, entries: nextEntries)
    }

    // MARK: - Credentials YAML (.credentials.yaml)

    static func upsertCredentialRef(
        existingText: String?,
        refName: String = credentialRefName,
        secretValue: String
    ) throws -> String {
        let escaped = escapeYAMLQuotedString(secretValue)
        let newRefLine = "  \(refName): \"\(escaped)\""

        guard let existingText, !existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "version: 1\nrefs:\n\(newRefLine)\n"
        }

        let lines = existingText.components(separatedBy: "\n")
        let hasVersion = lines.contains {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !$0.hasPrefix(" ") && (t == "version: 1" || t.hasPrefix("version: 1 "))
        }
        guard hasVersion else {
            throw AgentConfigError.invalidExistingConfig(".credentials.yaml 缺少 version: 1 或格式无效")
        }

        var updated = upsertYAMLMappingEntry(
            lines: lines,
            sectionKey: "refs",
            entryKey: refName,
            newEntryLine: newRefLine,
            insertAfterKey: "version"
        )
        while let last = updated.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.removeLast()
        }
        return updated.joined(separator: "\n") + "\n"
    }

    static func removeCredentialRef(
        existingText: String,
        refName: String = credentialRefName,
        originalFileExisted: Bool
    ) -> String? {
        let lines = existingText.components(separatedBy: "\n")
        var updated = removeYAMLMappingEntry(lines: lines, sectionKey: "refs", entryKey: refName)
        while let last = updated.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.removeLast()
        }
        let nonCommentLines = updated.filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        if !originalFileExisted && (nonCommentLines.isEmpty || nonCommentLines == ["version: 1"]) {
            return nil
        }
        if updated.isEmpty {
            return nil
        }
        return updated.joined(separator: "\n") + "\n"
    }

    static func writeOwnerOnlyFile(_ content: String, to url: URL, fileManager: FileManager = .default) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let data = Data(content.utf8)
        let tempURL = parent.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let created = fileManager.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw AgentConfigError.ioFailed("无法创建临时凭据文件：\(tempURL.path)")
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw AgentConfigError.ioFailed("写入 DeepSeek Harness 凭据失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Patch Document Splitting & Rendering

    static func splitPatchDocument(_ text: String) -> (header: [String], entries: [PatchEntry]) {
        let rawLines = text.components(separatedBy: "\n")
        var header: [String] = []
        var entries: [PatchEntry] = []
        var currentLines: [String]?

        var braceDepth = 0
        var bracketDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var seenFirstEntry = false

        func flushCurrent() {
            if var lines = currentLines {
                while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.removeLast()
                }
                if !lines.isEmpty {
                    entries.append(PatchEntry(id: extractEntryID(lines), rawLines: lines))
                }
                currentLines = nil
            }
        }

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isTopLevelStart = braceDepth == 0 && bracketDepth == 0 && !inSingleQuote && !inDoubleQuote
                && (line.hasPrefix("- ") || line == "-")

            if isTopLevelStart {
                seenFirstEntry = true
                flushCurrent()
                currentLines = [line]
            } else if !seenFirstEntry {
                if trimmed == "[]" {
                    // Ignore standalone empty-array placeholder once we add entries.
                } else {
                    header.append(line)
                }
            } else {
                currentLines?.append(line)
            }

            updateFlowState(
                line: line,
                braceDepth: &braceDepth,
                bracketDepth: &bracketDepth,
                inSingleQuote: &inSingleQuote,
                inDoubleQuote: &inDoubleQuote
            )
        }

        flushCurrent()
        while let last = header.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            header.removeLast()
        }
        return (header, entries)
    }

    private static func updateFlowState(
        line: String,
        braceDepth: inout Int,
        bracketDepth: inout Int,
        inSingleQuote: inout Bool,
        inDoubleQuote: inout Bool
    ) {
        var escaped = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inDoubleQuote {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inDoubleQuote = false
                }
            } else if inSingleQuote {
                if ch == "'" {
                    if i + 1 < chars.count && chars[i + 1] == "'" {
                        i += 1
                    } else {
                        inSingleQuote = false
                    }
                }
            } else {
                if ch == "#" {
                    // Comment if at start or preceded by whitespace
                    if i == 0 || chars[i - 1].isWhitespace {
                        break
                    }
                } else if ch == "\"" {
                    inDoubleQuote = true
                } else if ch == "'" {
                    inSingleQuote = true
                } else if ch == "{" {
                    braceDepth += 1
                } else if ch == "}" {
                    braceDepth = max(0, braceDepth - 1)
                } else if ch == "[" {
                    bracketDepth += 1
                } else if ch == "]" {
                    bracketDepth = max(0, bracketDepth - 1)
                }
            }
            i += 1
        }
    }

    private static func renderPatchDocument(header: [String], entries: [PatchEntry]) -> String {
        var out: [String] = []
        if !header.isEmpty {
            out.append(contentsOf: header)
        }
        for entry in entries {
            out.append(contentsOf: entry.rawLines)
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func extractEntryID(_ lines: [String]) -> String? {
        guard let first = lines.first else { return nil }
        let trimmedFirst = first.trimmingCharacters(in: .whitespaces)
        if trimmedFirst.hasPrefix("- {") {
            let joined = lines.joined(separator: "\n")
            if let value = try? parseFlowEntry(joined), case .map(let pairs) = value {
                return pairs.first(where: { $0.0 == "id" })?.1.stringValue
            }
        }
        // Block style: `- id: foo` or `  id: foo`
        let firstKeyLine = first.hasPrefix("- ") ? "  " + String(first.dropFirst(2)) : first
        for line in [firstKeyLine] + Array(lines.dropFirst()) {
            let indent = line.prefix(while: { $0 == " " }).count
            guard indent == 2 else { continue }
            if let (k, v) = splitYAMLKeyValue(line), k == "id" {
                return unquoteYAMLScalar(v)
            }
        }
        return nil
    }

    // MARK: - Entry Readers & Updaters

    private static func parseDefaultModelEntry(_ lines: [String]) -> (provider: String?, model: String?) {
        let joined = lines.joined(separator: "\n")
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("- {") {
            if let node = try? parseFlowEntry(joined),
               let config = node["config"] {
                return (config["provider"]?.stringValue, config["model"]?.stringValue)
            }
        }
        let normalized = normalizeSequenceItemBlock(lines)
        var inConfig = false
        var provider: String?
        var model: String?
        for line in normalized {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 2 {
                inConfig = (t == "config:")
                continue
            }
            if inConfig, indent == 4, let (k, v) = splitYAMLKeyValue(line) {
                if k == "provider" { provider = unquoteYAMLScalar(v) }
                else if k == "model" { model = unquoteYAMLScalar(v) }
            }
        }
        return (provider, model)
    }

    private static func parseLlmPiAiAutomodel(_ lines: [String]) -> (baseURL: String?, apiKeyEnv: String?) {
        let joined = lines.joined(separator: "\n")
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("- {") {
            if let node = try? parseFlowEntry(joined),
               let automodel = node["config"]?["providers"]?[providerID] {
                return (automodel["baseURL"]?.stringValue, automodel["apiKeyEnv"]?.stringValue)
            }
        }
        let normalized = normalizeSequenceItemBlock(lines)
        var inConfig = false
        var inProviders = false
        var inAutomodel = false
        var baseURL: String?
        var apiKeyEnv: String?
        for line in normalized {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 2 {
                inConfig = (t == "config:")
                inProviders = false
                inAutomodel = false
                continue
            }
            if inConfig, indent == 4 {
                inProviders = (t == "providers:")
                inAutomodel = false
                continue
            }
            if inProviders, indent == 6 {
                inAutomodel = (t == "\(providerID):")
                continue
            }
            if inAutomodel, indent == 8, let (k, v) = splitYAMLKeyValue(line) {
                if k == "baseURL" { baseURL = unquoteYAMLScalar(v) }
                else if k == "apiKeyEnv" { apiKeyEnv = unquoteYAMLScalar(v) }
            }
        }
        return (baseURL, apiKeyEnv)
    }

    private static func renderDefaultModelEntry(model: String) -> [String] {
        [
            "- id: \(defaultModelEntryID)",
            "  name: \"\(defaultModelPackage)\"",
            "  config:",
            "    provider: \(providerID)",
            "    model: \"\(escapeYAMLQuotedString(model))\""
        ]
    }

    private static func renderLlmPiAiEntry(automodelLines: [String]) -> [String] {
        var lines = [
            "- id: \(llmPiAiEntryID)",
            "  name: \"\(llmPiAiPackage)\"",
            "  config:",
            "    providers:"
        ]
        lines.append(contentsOf: automodelLines)
        return lines
    }

    private static func renderAutomodelProviderLines(
        baseURL: String,
        binding: AgentModelBinding,
        tierLabels: [ModelTier: String],
        indent: Int
    ) -> [String] {
        let p = String(repeating: " ", count: indent)
        let f = String(repeating: " ", count: indent + 2)
        let m = String(repeating: " ", count: indent + 4)
        let mf = String(repeating: " ", count: indent + 6)

        let models = buildProviderModels(binding: binding, tierLabels: tierLabels)
        var lines = [
            "\(p)\(providerID):",
            "\(f)displayName: \"AutoRoute\"",
            "\(f)apiKeyEnv: \"\(credentialRefName)\"",
            "\(f)api: \"openai-completions\"",
            "\(f)baseURL: \"\(escapeYAMLQuotedString(baseURL))\"",
            "\(f)defaultContextWindow: 200000",
            "\(f)defaultMaxTokens: 16384",
            "\(f)models:"
        ]
        for item in models {
            lines.append("\(m)- id: \"\(escapeYAMLQuotedString(item.id))\"")
            lines.append("\(mf)name: \"\(escapeYAMLQuotedString(item.name))\"")
            lines.append("\(mf)contextWindow: \(item.contextWindow)")
            lines.append("\(mf)maxTokens: \(item.maxTokens)")
        }
        return lines
    }

    private static func buildProviderModels(
        binding: AgentModelBinding,
        tierLabels: [ModelTier: String]
    ) -> [(id: String, name: String, contextWindow: Int, maxTokens: Int)] {
        let lowLabel = tierLabels[.low].map { "Auto Low (\($0))" } ?? "Auto Low (轻量低价)"
        let medLabel = tierLabels[.medium].map { "Auto Medium (\($0))" } ?? "Auto Medium (均衡主力)"
        let highLabel = tierLabels[.high].map { "Auto High (\($0))" } ?? "Auto High (旗舰推理)"
        let alias = "auto/agent/\(AgentKind.deepseekHarness.rawValue)"

        var result: [(id: String, name: String, contextWindow: Int, maxTokens: Int)] = [
            (alias, "AutoRoute (智能路由)", 200_000, 16_384),
            ("\(alias)/low", lowLabel, 128_000, 8_192),
            ("\(alias)/medium", medLabel, 200_000, 16_384),
            ("\(alias)/high", highLabel, 200_000, 32_768)
        ]
        var seen = Set(result.map(\.id))
        for custom in [binding.defaultModelOption, binding.lowModelOption, binding.mediumModelOption, binding.highModelOption] {
            if !custom.isEmpty && !seen.contains(custom) {
                result.append((custom, custom, 200_000, 16_384))
                seen.insert(custom)
            }
        }
        return result
    }

    private static func upsertAutomodelInLlmPiAi(
        entryLines: [String],
        automodelLines: [String],
        baseURL: String,
        binding: AgentModelBinding,
        tierLabels: [ModelTier: String]
    ) throws -> [String] {
        if let first = entryLines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("- {") {
            guard var root = try? parseFlowEntry(entryLines.joined(separator: "\n")) else {
                throw AgentConfigError.invalidExistingConfig("cordis.patch.yml 中的 llm-pi-ai 条目无法解析")
            }
            let modelsAST: YAMLNode = .array(buildProviderModels(binding: binding, tierLabels: tierLabels).map { item in
                .map([
                    ("id", .string(item.id)),
                    ("name", .string(item.name)),
                    ("contextWindow", .number(String(item.contextWindow))),
                    ("maxTokens", .number(String(item.maxTokens)))
                ])
            })
            let automodelAST: YAMLNode = .map([
                ("displayName", .string("AutoRoute")),
                ("apiKeyEnv", .string(credentialRefName)),
                ("api", .string("openai-completions")),
                ("baseURL", .string(baseURL)),
                ("defaultContextWindow", .number("200000")),
                ("defaultMaxTokens", .number("16384")),
                ("models", modelsAST)
            ])
            root.setNestedValue(path: ["config", "providers", providerID], value: automodelAST)
            return renderBlockEntry(from: root)
        }

        // Block-style entry
        var normalized = normalizeSequenceItemBlock(entryLines)
        if let configIdx = normalized.firstIndex(where: {
            $0.prefix(while: { $0 == " " }).count == 2 && $0.trimmingCharacters(in: .whitespaces) == "config:"
        }) {
            var configEnd = normalized.count
            for i in (configIdx + 1)..<normalized.count {
                let t = normalized[i].trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && !t.hasPrefix("#") && normalized[i].prefix(while: { $0 == " " }).count <= 2 {
                    configEnd = i
                    break
                }
            }
            if let provIdx = (configIdx + 1..<configEnd).first(where: {
                normalized[$0].prefix(while: { $0 == " " }).count == 4
                    && normalized[$0].trimmingCharacters(in: .whitespaces) == "providers:"
            }) {
                var provEnd = configEnd
                for i in (provIdx + 1)..<configEnd {
                    let t = normalized[i].trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty && !t.hasPrefix("#") && normalized[i].prefix(while: { $0 == " " }).count <= 4 {
                        provEnd = i
                        break
                    }
                }
                if let autoIdx = (provIdx + 1..<provEnd).first(where: {
                    normalized[$0].prefix(while: { $0 == " " }).count == 6
                        && normalized[$0].trimmingCharacters(in: .whitespaces) == "\(providerID):"
                }) {
                    var autoEnd = provEnd
                    for i in (autoIdx + 1)..<provEnd {
                        let t = normalized[i].trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty && !t.hasPrefix("#") && normalized[i].prefix(while: { $0 == " " }).count <= 6 {
                            autoEnd = i
                            break
                        }
                    }
                    normalized.replaceSubrange(autoIdx..<autoEnd, with: automodelLines)
                } else {
                    normalized.insert(contentsOf: automodelLines, at: provEnd)
                }
            } else {
                var insertion = ["    providers:"]
                insertion.append(contentsOf: automodelLines)
                normalized.insert(contentsOf: insertion, at: configEnd)
            }
        } else {
            normalized.append("  config:")
            normalized.append("    providers:")
            normalized.append(contentsOf: automodelLines)
        }

        return denormalizeSequenceItemBlock(normalized)
    }

    private static func removeAutomodelFromLlmPiAi(entryLines: [String], keepEmptyEntry: Bool) throws -> [String]? {
        if let first = entryLines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("- {") {
            guard var root = try? parseFlowEntry(entryLines.joined(separator: "\n")) else {
                throw AgentConfigError.invalidExistingConfig("cordis.patch.yml 中的 llm-pi-ai 条目无法解析")
            }
            root.removeNestedValue(path: ["config", "providers", providerID])
            if let providers = root["config"]?["providers"], case .map(let items) = providers, items.isEmpty {
                root.removeNestedValue(path: ["config", "providers"])
            }
            if let cfg = root["config"], case .map(let items) = cfg, items.isEmpty {
                root.removeNestedValue(path: ["config"])
            }
            if root["config"] == nil && !keepEmptyEntry {
                return nil
            }
            return renderBlockEntry(from: root)
        }

        var normalized = normalizeSequenceItemBlock(entryLines)
        if let configIdx = normalized.firstIndex(where: {
            $0.prefix(while: { $0 == " " }).count == 2 && $0.trimmingCharacters(in: .whitespaces) == "config:"
        }) {
            var configEnd = normalized.count
            for i in (configIdx + 1)..<normalized.count {
                let t = normalized[i].trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && !t.hasPrefix("#") && normalized[i].prefix(while: { $0 == " " }).count <= 2 {
                    configEnd = i
                    break
                }
            }
            if let provIdx = (configIdx + 1..<configEnd).first(where: {
                normalized[$0].prefix(while: { $0 == " " }).count == 4
                    && normalized[$0].trimmingCharacters(in: .whitespaces) == "providers:"
            }) {
                var provEnd = configEnd
                for i in (provIdx + 1)..<configEnd {
                    let t = normalized[i].trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty && !t.hasPrefix("#") && normalized[i].prefix(while: { $0 == " " }).count <= 4 {
                        provEnd = i
                        break
                    }
                }
                if let autoIdx = (provIdx + 1..<provEnd).first(where: {
                    normalized[$0].prefix(while: { $0 == " " }).count == 6
                        && normalized[$0].trimmingCharacters(in: .whitespaces) == "\(providerID):"
                }) {
                    var autoEnd = provEnd
                    for i in (autoIdx + 1)..<provEnd {
                        let t = normalized[i].trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty && !t.hasPrefix("#") && normalized[i].prefix(while: { $0 == " " }).count <= 6 {
                            autoEnd = i
                            break
                        }
                    }
                    normalized.removeSubrange(autoIdx..<autoEnd)
                }
                let hasRemainingProviders = normalized[(provIdx + 1)..<min(provEnd, normalized.count)].contains {
                    let t = $0.trimmingCharacters(in: .whitespaces)
                    return !t.isEmpty && !t.hasPrefix("#")
                }
                if !hasRemainingProviders {
                    normalized.remove(at: provIdx)
                }
            }
            // Recompute configEnd
            var newConfigEnd = normalized.count
            for i in (configIdx + 1)..<normalized.count {
                let t = normalized[i].trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && !t.hasPrefix("#") && normalized[i].prefix(while: { $0 == " " }).count <= 2 {
                    newConfigEnd = i
                    break
                }
            }
            let hasRemainingConfig = normalized[(configIdx + 1)..<newConfigEnd].contains {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("#")
            }
            if !hasRemainingConfig {
                normalized.remove(at: configIdx)
            }
        }

        let hasConfig = normalized.contains {
            $0.prefix(while: { $0 == " " }).count == 2 && $0.trimmingCharacters(in: .whitespaces) == "config:"
        }
        if !hasConfig && !keepEmptyEntry {
            return nil
        }
        return denormalizeSequenceItemBlock(normalized)
    }

    private static func normalizeSequenceItemBlock(_ lines: [String]) -> [String] {
        guard let first = lines.first else { return lines }
        var out = lines
        if first.hasPrefix("- ") {
            out[0] = "  " + String(first.dropFirst(2))
        }
        return out
    }

    private static func denormalizeSequenceItemBlock(_ lines: [String]) -> [String] {
        guard let first = lines.first else { return lines }
        var out = lines
        if first.hasPrefix("  ") {
            out[0] = "- " + String(first.dropFirst(2))
        }
        return out
    }

    // MARK: - Credentials YAML Utilities

    private static func parseCredentialRefs(_ text: String) -> [String: String] {
        var refs: [String: String] = [:]
        var inRefs = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                inRefs = (trimmed == "refs:")
                continue
            }
            if inRefs, indent == 2, let (k, v) = splitYAMLKeyValue(line) {
                refs[k] = unquoteYAMLScalar(v)
            }
        }
        return refs
    }

    private static func upsertYAMLMappingEntry(
        lines: [String],
        sectionKey: String,
        entryKey: String,
        newEntryLine: String,
        insertAfterKey: String
    ) -> [String] {
        var result = lines
        let header = "\(sectionKey):"
        if let start = result.firstIndex(where: { !$0.hasPrefix(" ") && $0.trimmingCharacters(in: .whitespaces) == header }) {
            var end = result.count
            for i in (start + 1)..<result.count {
                let t = result[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { continue }
                if !result[i].hasPrefix(" ") {
                    end = i
                    break
                }
            }
            if let existingIdx = (start + 1..<end).first(where: {
                result[$0].prefix(while: { $0 == " " }).count == 2 && splitYAMLKeyValue(result[$0])?.0 == entryKey
            }) {
                result[existingIdx] = newEntryLine
            } else {
                result.insert(newEntryLine, at: start + 1)
            }
            return result
        } else {
            if let afterIdx = result.firstIndex(where: {
                !$0.hasPrefix(" ") && splitYAMLKeyValue($0)?.0 == insertAfterKey
            }) {
                result.insert(contentsOf: [header, newEntryLine], at: afterIdx + 1)
            } else {
                result.append(header)
                result.append(newEntryLine)
            }
            return result
        }
    }

    private static func removeYAMLMappingEntry(
        lines: [String],
        sectionKey: String,
        entryKey: String
    ) -> [String] {
        var result = lines
        let header = "\(sectionKey):"
        guard let start = result.firstIndex(where: { !$0.hasPrefix(" ") && $0.trimmingCharacters(in: .whitespaces) == header }) else {
            return result
        }
        var end = result.count
        for i in (start + 1)..<result.count {
            let t = result[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if !result[i].hasPrefix(" ") {
                end = i
                break
            }
        }
        if let existingIdx = (start + 1..<end).first(where: {
            result[$0].prefix(while: { $0 == " " }).count == 2 && splitYAMLKeyValue(result[$0])?.0 == entryKey
        }) {
            result.remove(at: existingIdx)
            end -= 1
        }
        let hasRemaining = result[(start + 1)..<end].contains {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        if !hasRemaining {
            result.remove(at: start)
        }
        return result
    }

    private static func splitYAMLKeyValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func unquoteYAMLScalar(_ raw: String) -> String {
        let s = stripTrailingYAMLComment(raw).trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
            let inner = String(s.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    private static func stripTrailingYAMLComment(_ raw: String) -> String {
        var inSingle = false
        var inDouble = false
        var escaped = false
        let chars = Array(raw)
        for i in 0..<chars.count {
            let ch = chars[i]
            if inDouble {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inDouble = false }
            } else if inSingle {
                if ch == "'" { inSingle = false }
            } else {
                if ch == "\"" { inDouble = true }
                else if ch == "'" { inSingle = true }
                else if ch == "#", i == 0 || chars[i - 1].isWhitespace {
                    return String(chars[..<i])
                }
            }
        }
        return raw
    }

    private static func escapeYAMLQuotedString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Lightweight Flow-YAML AST (for `- { id: llm-pi-ai, ... }` entries)

    private indirect enum YAMLNode {
        case map([(String, YAMLNode)])
        case array([YAMLNode])
        case string(String)
        case number(String)
        case bool(Bool)
        case null

        var stringValue: String? {
            switch self {
            case .string(let s): return s
            case .number(let n): return n
            default: return nil
            }
        }

        subscript(key: String) -> YAMLNode? {
            guard case .map(let pairs) = self else { return nil }
            return pairs.first(where: { $0.0 == key })?.1
        }

        mutating func setNestedValue(path: [String], value: YAMLNode) {
            guard let first = path.first else {
                self = value
                return
            }
            var pairs: [(String, YAMLNode)]
            if case .map(let existing) = self {
                pairs = existing
            } else {
                pairs = []
            }
            if path.count == 1 {
                if let idx = pairs.firstIndex(where: { $0.0 == first }) {
                    pairs[idx] = (first, value)
                } else {
                    pairs.append((first, value))
                }
            } else {
                var child = pairs.first(where: { $0.0 == first })?.1 ?? .map([])
                child.setNestedValue(path: Array(path.dropFirst()), value: value)
                if let idx = pairs.firstIndex(where: { $0.0 == first }) {
                    pairs[idx] = (first, child)
                } else {
                    pairs.append((first, child))
                }
            }
            self = .map(pairs)
        }

        mutating func removeNestedValue(path: [String]) {
            guard let first = path.first, case .map(var pairs) = self else { return }
            if path.count == 1 {
                pairs.removeAll(where: { $0.0 == first })
            } else if let idx = pairs.firstIndex(where: { $0.0 == first }) {
                var child = pairs[idx].1
                child.removeNestedValue(path: Array(path.dropFirst()))
                pairs[idx] = (first, child)
            }
            self = .map(pairs)
        }
    }

    private struct FlowYAMLParser {
        let chars: [Character]
        var index: Int = 0

        init(_ text: String) {
            self.chars = Array(text)
        }

        mutating func skipWhitespaceAndComments() {
            while index < chars.count {
                let c = chars[index]
                if c.isWhitespace {
                    index += 1
                } else if c == "#" {
                    while index < chars.count && chars[index] != "\n" {
                        index += 1
                    }
                } else {
                    break
                }
            }
        }

        mutating func parseValue() throws -> YAMLNode {
            skipWhitespaceAndComments()
            guard index < chars.count else {
                throw AgentConfigError.invalidExistingConfig("Unexpected EOF in flow YAML")
            }
            let c = chars[index]
            if c == "{" { return try parseMap() }
            if c == "[" { return try parseArray() }
            if c == "\"" { return .string(try parseDoubleQuoted()) }
            if c == "'" { return .string(try parseSingleQuoted()) }
            return parsePlainScalar()
        }

        mutating func parseMap() throws -> YAMLNode {
            index += 1 // '{'
            var pairs: [(String, YAMLNode)] = []
            while true {
                skipWhitespaceAndComments()
                guard index < chars.count else { throw AgentConfigError.invalidExistingConfig("Unclosed '{' in flow YAML") }
                if chars[index] == "}" {
                    index += 1
                    return .map(pairs)
                }
                let key = try parseKey()
                skipWhitespaceAndComments()
                guard index < chars.count && chars[index] == ":" else {
                    throw AgentConfigError.invalidExistingConfig("Expected ':' after key in flow YAML")
                }
                index += 1
                let val = try parseValue()
                pairs.append((key, val))
                skipWhitespaceAndComments()
                if index < chars.count && chars[index] == "," {
                    index += 1
                    continue
                }
                if index < chars.count && chars[index] == "}" {
                    index += 1
                    return .map(pairs)
                }
                throw AgentConfigError.invalidExistingConfig("Expected ',' or '}' in flow YAML")
            }
        }

        mutating func parseArray() throws -> YAMLNode {
            index += 1 // '['
            var items: [YAMLNode] = []
            while true {
                skipWhitespaceAndComments()
                guard index < chars.count else { throw AgentConfigError.invalidExistingConfig("Unclosed '[' in flow YAML") }
                if chars[index] == "]" {
                    index += 1
                    return .array(items)
                }
                items.append(try parseValue())
                skipWhitespaceAndComments()
                if index < chars.count && chars[index] == "," {
                    index += 1
                    continue
                }
                if index < chars.count && chars[index] == "]" {
                    index += 1
                    return .array(items)
                }
                throw AgentConfigError.invalidExistingConfig("Expected ',' or ']' in flow YAML")
            }
        }

        mutating func parseKey() throws -> String {
            skipWhitespaceAndComments()
            if index < chars.count && chars[index] == "\"" { return try parseDoubleQuoted() }
            if index < chars.count && chars[index] == "'" { return try parseSingleQuoted() }
            var buf = ""
            while index < chars.count {
                let c = chars[index]
                if c == ":" || c == "," || c == "}" || c == "]" { break }
                buf.append(c)
                index += 1
            }
            return buf.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func parseDoubleQuoted() throws -> String {
            index += 1 // '"'
            var buf = ""
            while index < chars.count {
                let c = chars[index]
                index += 1
                if c == "\"" { return buf }
                if c == "\\", index < chars.count {
                    let next = chars[index]
                    index += 1
                    switch next {
                    case "n": buf.append("\n")
                    case "r": buf.append("\r")
                    case "t": buf.append("\t")
                    case "\"": buf.append("\"")
                    case "\\": buf.append("\\")
                    default: buf.append(next)
                    }
                } else {
                    buf.append(c)
                }
            }
            throw AgentConfigError.invalidExistingConfig("Unterminated string in flow YAML")
        }

        mutating func parseSingleQuoted() throws -> String {
            index += 1 // '\''
            var buf = ""
            while index < chars.count {
                let c = chars[index]
                index += 1
                if c == "'" {
                    if index < chars.count && chars[index] == "'" {
                        index += 1
                        buf.append("'")
                    } else {
                        return buf
                    }
                } else {
                    buf.append(c)
                }
            }
            throw AgentConfigError.invalidExistingConfig("Unterminated single-quoted string in flow YAML")
        }

        mutating func parsePlainScalar() -> YAMLNode {
            var buf = ""
            while index < chars.count {
                let c = chars[index]
                if c == "," || c == "}" || c == "]" || c == "\n" || c == "\r" { break }
                buf.append(c)
                index += 1
            }
            let trimmed = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "true" { return .bool(true) }
            if trimmed == "false" { return .bool(false) }
            if trimmed == "null" || trimmed == "~" { return .null }
            if !trimmed.isEmpty, Double(trimmed) != nil, trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) {
                return .number(trimmed)
            }
            return .string(trimmed)
        }
    }

    private static func parseFlowEntry(_ text: String) throws -> YAMLNode {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var parser = FlowYAMLParser(trimmed)
        return try parser.parseValue()
    }

    private static func renderBlockEntry(from node: YAMLNode) -> [String] {
        guard case .map(let pairs) = node, !pairs.isEmpty else {
            return ["- {}"]
        }
        var lines: [String] = []
        for (idx, (key, val)) in pairs.enumerated() {
            let prefix = idx == 0 ? "- " : "  "
            lines.append(contentsOf: renderYAMLKeyValue(key: key, value: val, prefix: prefix, childIndent: 4))
        }
        return lines
    }

    private static func renderYAMLKeyValue(
        key: String,
        value: YAMLNode,
        prefix: String,
        childIndent: Int
    ) -> [String] {
        let renderedKey = needsYAMLQuoting(key) ? "\"\(escapeYAMLQuotedString(key))\"" : key
        switch value {
        case .map(let pairs):
            if pairs.isEmpty { return ["\(prefix)\(renderedKey): {}"] }
            var out = ["\(prefix)\(renderedKey):"]
            let p = String(repeating: " ", count: childIndent)
            for (k, v) in pairs {
                out.append(contentsOf: renderYAMLKeyValue(key: k, value: v, prefix: p, childIndent: childIndent + 2))
            }
            return out
        case .array(let items):
            if items.isEmpty { return ["\(prefix)\(renderedKey): []"] }
            var out = ["\(prefix)\(renderedKey):"]
            let p = String(repeating: " ", count: childIndent)
            for item in items {
                out.append(contentsOf: renderYAMLSequenceItem(item, indent: childIndent, prefix: "\(p)- "))
            }
            return out
        case .string(let s):
            return ["\(prefix)\(renderedKey): \"\(escapeYAMLQuotedString(s))\""]
        case .number(let n):
            return ["\(prefix)\(renderedKey): \(n)"]
        case .bool(let b):
            return ["\(prefix)\(renderedKey): \(b ? "true" : "false")"]
        case .null:
            return ["\(prefix)\(renderedKey): null"]
        }
    }

    private static func renderYAMLSequenceItem(_ node: YAMLNode, indent: Int, prefix: String) -> [String] {
        switch node {
        case .map(let pairs):
            if pairs.isEmpty { return ["\(prefix){}"] }
            var out: [String] = []
            let cont = String(repeating: " ", count: indent + 2)
            for (idx, (k, v)) in pairs.enumerated() {
                out.append(contentsOf: renderYAMLKeyValue(
                    key: k,
                    value: v,
                    prefix: idx == 0 ? prefix : cont,
                    childIndent: indent + 4
                ))
            }
            return out
        case .array(let items):
            if items.isEmpty { return ["\(prefix)[]"] }
            var out = ["\(prefix)"]
            let sub = String(repeating: " ", count: indent + 2)
            for item in items {
                out.append(contentsOf: renderYAMLSequenceItem(item, indent: indent + 2, prefix: "\(sub)- "))
            }
            return out
        case .string(let s):
            return ["\(prefix)\"\(escapeYAMLQuotedString(s))\""]
        case .number(let n):
            return ["\(prefix)\(n)"]
        case .bool(let b):
            return ["\(prefix)\(b ? "true" : "false")"]
        case .null:
            return ["\(prefix)null"]
        }
    }

    private static func needsYAMLQuoting(_ key: String) -> Bool {
        key.isEmpty || key.contains(":") || key.contains(" ") || key.contains("#") || key.contains("{") || key.contains("}")
    }
}
