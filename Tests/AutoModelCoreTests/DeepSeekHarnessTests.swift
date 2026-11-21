import Foundation
import XCTest
@testable import AutoModelCore

final class DeepSeekHarnessTests: XCTestCase {
    private func makeTempHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRouteDSHTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testGeneratedModelKeyPassesValidation() throws {
        let key = try LocalAPITokenManager.generateModelAPIKey()
        XCTAssertTrue(key.hasPrefix("ar-"))
        XCTAssertNoThrow(try LocalModelAPIKeyError.validate(key, managementToken: "some-management-token"))
    }

    func testFreshInstallWritesPatchAndOwnerOnlyCredentialsAndRestoresCleanly() throws {
        let root = makeTempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let service = AgentConfigService(homeDirectory: home, backupDirectory: backups)

        let token = "ar-fresh-dsh-key-123"
        let binding = AgentModelBinding.stableIdentity(for: .deepseekHarness)
        let status = try service.applyAgentConfig(
            kind: .deepseekHarness,
            binding: binding,
            proxyPort: 8765,
            localAPIToken: token,
            resolvedTierDisplayNames: [.low: "Fast Mini", .medium: "Balanced Mid", .high: "Pro High"]
        )

        XCTAssertTrue(status.isConnectedToAutoModel)
        XCTAssertTrue(status.hasBackup)
        XCTAssertEqual(status.currentBaseURL, "http://127.0.0.1:8765/v1")
        XCTAssertEqual(status.currentModelSummary, "automodel/auto/agent/deepseek_harness")

        let patchURL = service.primaryConfigURL(for: .deepseekHarness)
        let patchText = try String(contentsOf: patchURL, encoding: .utf8)
        XCTAssertTrue(patchText.contains("- id: agent-default-model"))
        XCTAssertTrue(patchText.contains("provider: automodel"))
        XCTAssertTrue(patchText.contains("model: \"auto/agent/deepseek_harness\""))
        XCTAssertTrue(patchText.contains("- id: llm-pi-ai"))
        XCTAssertTrue(patchText.contains("apiKeyEnv: \"AUTOROUTE_API_KEY\""))
        XCTAssertTrue(patchText.contains("api: \"openai-completions\""))
        XCTAssertTrue(patchText.contains("baseURL: \"http://127.0.0.1:8765/v1\""))
        XCTAssertTrue(patchText.contains("auto/agent/deepseek_harness/low"))
        XCTAssertTrue(patchText.contains("auto/agent/deepseek_harness/medium"))
        XCTAssertTrue(patchText.contains("auto/agent/deepseek_harness/high"))
        XCTAssertFalse(patchText.contains(token), "Patch file must reference apiKeyEnv, not raw secret")

        let credsURL = service.dshCredentialsURL()
        let credsText = try String(contentsOf: credsURL, encoding: .utf8)
        XCTAssertTrue(credsText.contains("version: 1"))
        XCTAssertTrue(credsText.contains("AUTOROUTE_API_KEY: \"\(token)\""))

        let attrs = try FileManager.default.attributesOfItem(atPath: credsURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600, ".credentials.yaml must be owner-only (0600) for dsh-credentials-local")

        let restored = try service.restoreAgentConfig(kind: .deepseekHarness, proxyPort: 8765)
        XCTAssertFalse(restored.isConnectedToAutoModel)
        XCTAssertFalse(restored.hasBackup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: credsURL.path))
    }

    func testApplyPreservesExistingBlockEntriesAndCredentialsRecordsOnThreeWayRestore() throws {
        let root = makeTempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let service = AgentConfigService(homeDirectory: home, backupDirectory: backups)

        let patchURL = service.primaryConfigURL(for: .deepseekHarness)
        let credsURL = service.dshCredentialsURL()
        try FileManager.default.createDirectory(at: patchURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let originalPatch = """
        # Profile patch header
        - id: agent-default-model
          name: "@deepseek-ai/dsh-agent-default-model"
          config:
            provider: deepseek-account
            model: deepseek-flash
            reasoningEffort: high
        - id: ui-settings-account
          name: "@deepseek-ai/dsh-client-ui-settings-account"
          config:
            version: 1
            developerTools: true
        """
        try originalPatch.write(to: patchURL, atomically: true, encoding: .utf8)

        let originalCreds = """
        version: 1
        records:
          deepseek-account-platform/default:
            kind: grant
            payload:
              version: 1
              token: original-oauth-token
              issuer: https://platform.deepseek.com
        """
        try DeepSeekHarnessConfigSupport.writeOwnerOnlyFile(originalCreds, to: credsURL)

        let status = try service.applyAgentConfig(
            kind: .deepseekHarness,
            binding: .stableIdentity(for: .deepseekHarness),
            proxyPort: 8765,
            localAPIToken: "ar-key-1"
        )
        XCTAssertTrue(status.isConnectedToAutoModel)

        let updatedPatch = try String(contentsOf: patchURL, encoding: .utf8)
        XCTAssertTrue(updatedPatch.contains("ui-settings-account"))
        XCTAssertTrue(updatedPatch.contains("developerTools: true"))
        XCTAssertFalse(updatedPatch.contains("reasoningEffort: high"), "Stale reasoningEffort must not remain on automodel default")

        // Simulate dsh refreshing its OAuth record & adding a post-injection UI setting
        let credsWithUpdatedRecord = try String(contentsOf: credsURL, encoding: .utf8)
            .replacingOccurrences(of: "original-oauth-token", with: "refreshed-oauth-token")
        try DeepSeekHarnessConfigSupport.writeOwnerOnlyFile(credsWithUpdatedRecord, to: credsURL)

        let patchWithLateEntry = updatedPatch + """
        - id: ui-chat
          name: "@deepseek-ai/dsh-client-ui-chat"
          config:
            transcriptView: compact
        """
        try patchWithLateEntry.write(to: patchURL, atomically: true, encoding: .utf8)

        let restored = try service.restoreAgentConfig(kind: .deepseekHarness, proxyPort: 8765)
        XCTAssertFalse(restored.isConnectedToAutoModel)

        let finalPatch = try String(contentsOf: patchURL, encoding: .utf8)
        XCTAssertTrue(finalPatch.contains("provider: deepseek-account"))
        XCTAssertTrue(finalPatch.contains("model: deepseek-flash"))
        XCTAssertTrue(finalPatch.contains("reasoningEffort: high"))
        XCTAssertTrue(finalPatch.contains("ui-chat"))
        XCTAssertFalse(finalPatch.contains("llm-pi-ai"))

        let finalCreds = try String(contentsOf: credsURL, encoding: .utf8)
        XCTAssertTrue(finalCreds.contains("refreshed-oauth-token"), "Live login credentials updated after apply must be preserved")
        XCTAssertFalse(finalCreds.contains("AUTOROUTE_API_KEY"))
        let attrs = try FileManager.default.attributesOfItem(atPath: credsURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testApplyAndRestoreWithFlowStyleLlmPiAiPreservesExternalProviders() throws {
        let root = makeTempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let service = AgentConfigService(homeDirectory: home, backupDirectory: backups)

        let patchURL = service.primaryConfigURL(for: .deepseekHarness)
        try FileManager.default.createDirectory(at: patchURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let flowPatch = """
        - {
            id: llm-pi-ai,
            name: "@deepseek-ai/dsh-llm-pi-ai",
            config:
              {
                providers:
                  {
                    qurwork:
                      {
                        displayName: QuWork,
                        api: openai-completions,
                        baseURL: https://llm.quwork.cn/v1,
                        models: [ { id: deepseek-flash, name: DeepSeek-Flash } ]
                      }
                  }
              }
          }
        """
        try flowPatch.write(to: patchURL, atomically: true, encoding: .utf8)

        let status = try service.applyAgentConfig(
            kind: .deepseekHarness,
            binding: .stableIdentity(for: .deepseekHarness),
            proxyPort: 8765,
            localAPIToken: "ar-flow-test"
        )
        XCTAssertTrue(status.isConnectedToAutoModel)

        let applied = try String(contentsOf: patchURL, encoding: .utf8)
        XCTAssertTrue(applied.contains("qurwork:"))
        XCTAssertTrue(applied.contains("https://llm.quwork.cn/v1"))
        XCTAssertTrue(applied.contains("automodel:"))

        // Mutate slightly so three-way restore runs
        try (applied + "\n# user comment\n").write(to: patchURL, atomically: true, encoding: .utf8)
        _ = try service.restoreAgentConfig(kind: .deepseekHarness, proxyPort: 8765)
        let restored = try String(contentsOf: patchURL, encoding: .utf8)
        XCTAssertTrue(restored.contains("qurwork:"))
        XCTAssertFalse(restored.contains("automodel:"))
    }

    func testPreviewDoesNotMutateLiveFiles() throws {
        let root = makeTempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let service = AgentConfigService(homeDirectory: home, backupDirectory: backups)

        let preview = try service.previewAgentConfig(
            kind: .deepseekHarness,
            binding: .stableIdentity(for: .deepseekHarness),
            proxyPort: 8765,
            localAPIToken: "secret-preview-token"
        )
        XCTAssertTrue(preview.after.contains("automodel"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.primaryConfigURL(for: .deepseekHarness).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.dshCredentialsURL().path))
    }

    @MainActor
    func testEngineAppliesCustomModelKeyAndRoutesDeepSeekHarnessRequests() async throws {
        let root = makeTempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = InMemoryKeychainService()
        let upstream = LocalTestUpstreamServer()
        let upstreamPort = try upstream.start(port: 0)
        defer { upstream.stop() }

        let service = AgentConfigService(
            homeDirectory: root.appendingPathComponent("home"),
            backupDirectory: root.appendingPathComponent("backups")
        )
        let engine = AutoModelEngine(
            persistence: LocalPersistenceStore(baseDirectoryURL: root.appendingPathComponent("data")),
            keychain: keychain,
            agentConfigService: service,
            alertNotifier: NoOpSystemAlertNotifier(),
            autoStartProxyIfConfigured: false
        )

        let provider = ProviderConfig(name: "Mock", baseURL: "http://127.0.0.1:\(upstreamPort)")
        try engine.upsertProvider(provider, apiKey: "upstream-key")
        engine.upsertModel(ModelConfig(providerID: provider.id, modelID: "mock-fast-mini", capabilities: [.chat]))
        let proxyPort = try XCTUnwrap(LoopbackHTTPServer.findAvailablePort(startingFrom: 25_800))
        engine.updateProxyPort(proxyPort)
        engine.startProxy()
        defer { engine.stopProxy() }

        let customKey = "ar-dsh-custom-key-01"
        try engine.setLocalModelAPIKey(customKey)
        let status = try engine.applyAgentIntegration(kind: .deepseekHarness)
        XCTAssertTrue(status.isConnectedToAutoModel)

        let credsText = try String(contentsOf: service.dshCredentialsURL(), encoding: .utf8)
        XCTAssertTrue(credsText.contains(customKey))
        XCTAssertFalse(credsText.contains(engine.localAPIToken))

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(customKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "auto/agent/deepseek_harness",
            "messages": [["role": "user", "content": "hello from dsh"]]
        ])
        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let lastRecord = try XCTUnwrap(engine.callHistory.first)
        XCTAssertEqual(lastRecord.decision.agentID, AgentKind.deepseekHarness.rawValue)
        XCTAssertEqual(lastRecord.decision.agentIdentitySource, .modelAlias)
        XCTAssertEqual(engine.agentReadiness(for: .deepseekHarness), .verified(lastRecord.id))
    }
}
