import XCTest
@testable import AutoModelCore

final class P1AgentIdentityTests: XCTestCase {
    func testStableAgentAliasResolutionAndPolicyPrecedence() throws {
        let global = RoutingPolicyConfig(activeStrategy: .costFirst)
        let codex = AgentPolicyProfile(kind: .codex, strategy: .qualityFirst, defaultTier: .high)
        let profiles = [AgentKind.codex.rawValue: codex]

        let aliased = try AgentRequestResolver.resolve(
            requestedModel: "auto/agent/codex",
            agentHeader: nil,
            globalPolicy: global,
            profiles: profiles
        )
        XCTAssertEqual(aliased.effectiveRequestedModel, "auto/high")
        XCTAssertEqual(aliased.agentKind, .codex)
        XCTAssertEqual(aliased.identitySource, .modelAlias)
        XCTAssertEqual(aliased.policy.activeStrategy, .qualityFirst)
        XCTAssertTrue(aliased.appliesAgentPolicy)

        let explicitTier = try AgentRequestResolver.resolve(
            requestedModel: "auto/low",
            agentHeader: "codex",
            globalPolicy: global,
            profiles: profiles
        )
        XCTAssertEqual(explicitTier.effectiveRequestedModel, "auto/low")
        XCTAssertEqual(explicitTier.agentKind, .codex)
        XCTAssertEqual(explicitTier.identitySource, .explicitHeader)
        XCTAssertEqual(explicitTier.policy.activeStrategy, .costFirst)
        XCTAssertFalse(explicitTier.appliesAgentPolicy)

        let legacy = try AgentRequestResolver.resolve(
            requestedModel: "auto",
            agentHeader: nil,
            globalPolicy: global,
            profiles: profiles
        )
        XCTAssertNil(legacy.agentKind)
        XCTAssertEqual(legacy.policy.activeStrategy, .costFirst)

        let concrete = try AgentRequestResolver.resolve(
            requestedModel: "provider/model",
            agentHeader: "codex",
            globalPolicy: global,
            profiles: profiles
        )
        XCTAssertEqual(concrete.effectiveRequestedModel, "provider/model")
        XCTAssertFalse(concrete.appliesAgentPolicy)

        for invalid in ["auto/agent/unknown", "auto/agent/CODEX", "auto/agent/", "auto/agent"] {
            XCTAssertThrowsError(
                try AgentRequestResolver.resolve(
                    requestedModel: invalid,
                    agentHeader: nil,
                    globalPolicy: global,
                    profiles: profiles
                )
            ) { error in
                XCTAssertEqual((error as? AgentRequestResolutionError)?.code, "unknown_agent_alias")
                XCTAssertEqual((error as? AgentRequestResolutionError)?.statusCode, 400)
            }
        }
    }

    func testOneClickDefaultsCarryStableIdentityAndOldConfigStillDecodes() throws {
        let config = AppConfigBundle()
        for kind in AgentKind.allCases {
            let binding = config.binding(for: kind)
            let alias = "auto/agent/\(kind.rawValue)"
            XCTAssertEqual(binding.defaultModelOption, alias)
            XCTAssertEqual(binding.lowModelOption, "\(alias)/low")
            XCTAssertEqual(binding.mediumModelOption, "\(alias)/medium")
            XCTAssertEqual(binding.highModelOption, "\(alias)/high")
        }

        let legacy = try JSONDecoder().decode(
            AppConfigBundle.self,
            from: Data(#"{"agentBindings":{"codex":{"defaultModelOption":"auto","lowModelOption":"auto/low","mediumModelOption":"auto/medium","highModelOption":"auto/high"}}}"#.utf8)
        )
        XCTAssertEqual(legacy.binding(for: .codex).defaultModelOption, "auto")
        XCTAssertTrue(legacy.agentPolicyProfiles.isEmpty)
    }

    @MainActor
    func testEngineRejectsUnknownAliasAndRecordsResolvedAgentMetadata() async throws {
        let store = LocalPersistenceStore(
            baseDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let engine = AutoModelEngine(
            persistence: store,
            keychain: InMemoryKeychainService(),
            autoStartProxyIfConfigured: false
        )

        let invalid = await engine.executeChatCompletion(
            payload: ["model": "auto/agent/not-a-real-agent", "messages": [["role": "user", "content": "hello"]]],
            source: .externalProxy
        )
        XCTAssertEqual(invalid.httpStatusCode, 400)
        let errorJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: invalid.responseBody) as? [String: Any])
        let error = try XCTUnwrap(errorJSON["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "unknown_agent_alias")
        XCTAssertTrue(engine.callHistory.isEmpty == false)

        let resolved = await engine.executeChatCompletion(
            payload: ["model": "auto/agent/codex", "messages": [["role": "user", "content": "hello"]]],
            source: .externalProxy
        )
        XCTAssertEqual(resolved.httpStatusCode, 503)
        XCTAssertEqual(resolved.callRecord.requestedModel, "auto/agent/codex")
        XCTAssertEqual(resolved.callRecord.decision.agentID, AgentKind.codex.rawValue)
        XCTAssertEqual(resolved.callRecord.decision.agentIdentitySource, .modelAlias)
        XCTAssertNotNil(resolved.callRecord.decision.agentPolicyOverrideReason)
    }

    func testEveryAgentWriterUsesItsStableAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentConfigService(
            homeDirectory: root.appendingPathComponent("home"),
            backupDirectory: root.appendingPathComponent("backups")
        )

        for kind in AgentKind.allCases {
            let binding = AppConfigBundle().binding(for: kind)
            _ = try service.applyAgentConfig(
                kind: kind,
                binding: binding,
                proxyPort: 8765,
                localAPIToken: "test-local-token"
            )
            let output = try String(contentsOf: service.primaryConfigURL(for: kind), encoding: .utf8)
            XCTAssertTrue(output.contains("auto/agent/\(kind.rawValue)"), kind.rawValue)
        }
    }
}
